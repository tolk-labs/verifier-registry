// PotVault.tolk — Hot potato prize pot for one GRAM-paired launch.
//
// The creator funds a GRAM pot when they launch. Every buy of at least
// `minBuy` GRAM (on the curve or, after graduation, in the DeDust pool)
// restarts a 15-minute countdown; when it runs out the last qualifying buyer
// wins the whole pot. DeDust cannot report buys to a contract, so a dedicated
// referee wallet (its own key, no other role anywhere) watches the chain and
// names the winner. This vault limits what that key can do:
//
//   * the pot pays out EXACTLY ONCE, either to a winner (PAYW) or back to the
//     creator (PRCL); afterwards every message is refused;
//   * PAYW needs a started game (PSTA) and a reset time at least 15 minutes
//     in the past, and can never pay the creator;
//   * if the game never starts within 7 days (+1 h grace for the referee to
//     record a late-seen first buy), ANYONE may send PRCL and the pot goes to
//     the creator — the only address it can reach that way;
//   * the creator can never withdraw a running game;
//   * the pot is 10–10,000 GRAM; the creator's first deposit also pays the
//     referee a fixed 0.15 GRAM once, so it always has gas to start the
//     countdown and send the payout or the return.
//
// It has no link to curves, fees, LP, the treasury or the multisig: the 1%
// fee and every split are untouched; this money only ever comes from the
// creator (plus voluntary top-ups).
//
// Storage (init data = deterministic address of (referee, creator, curve, minBuy)):
//   referee:MsgAddress creator:MsgAddress minBuy:Coins createdAt:uint32
//   startedAt:uint32 lastReset:uint32 started:uint1 paid:uint2
//   ^[ curve:MsgAddress winner:MsgAddress ]    (winner = curve until paid)

const OP_FUND = 0x50464e44;      // "PFND"  fund / top up (first one: creator only)
const OP_START = 0x50535441;     // "PSTA"  referee: first qualifying buy seen
const OP_PAY_WINNER = 0x50415957; // "PAYW" referee: countdown ran out, pay the winner
const OP_RECLAIM = 0x5052434c;   // "PRCL"  anyone: unstarted after 7 d + 1 h -> creator

const ERR_NOT_REFEREE = 801;
const ERR_NOT_CREATOR = 802;
const ERR_DONE = 803;
const ERR_NOT_FUNDED = 804;
const ERR_STARTED = 805;
const ERR_NOT_STARTED = 806;
const ERR_TOO_EARLY = 807;
const ERR_BAD_TIME = 808;
const ERR_BAD_WINNER = 809;
const ERR_BAD_MIN_BUY = 810;
const ERR_POT_TOO_SMALL = 811;
const ERR_POT_TOO_BIG = 812;
const ERR_UNKNOWN_OP = 0xffff;

const COUNTDOWN_SECS = 900;               // 15 minutes
const START_WINDOW_SECS = 7 * 24 * 3600;  // first qualifying buy must land within 7 days
const RECLAIM_GRACE_SECS = 3600;          // referee gets 1 h to record a late-seen first buy
const MIN_BUY_FLOOR = 5000000000;         // 5 GRAM
const MIN_BUY_CEIL = 100000000000;        // 100 GRAM
const MIN_POT = 10000000000;              // 10 GRAM
const MAX_POT = 10000000000000;           // 10,000 GRAM (plus a small gas margin below)
const POT_GAS_MARGIN = 1000000000;        // 1 GRAM headroom for gas leftovers on top of MAX_POT
// Paid to the referee once, from the creator's first deposit, so the referee
// wallet always has the gas for this pot's start mark and its payout/return.
const REFEREE_FEE = 150000000;            // 0.15 GRAM
const KEEP_ON_VAULT = 20000000;           // 0.02 GRAM stays for storage after payout

const PAID_NONE = 0;
const PAID_WINNER = 1;
const PAID_CREATOR = 2;

struct Pot {
    referee: address;
    creator: address;
    minBuy: coins;
    createdAt: int;
    startedAt: int;
    lastReset: int;
    started: int;
    paid: int;
    curve: address;
    winner: address;
}

fun loadPot(): Pot {
    var cs = contract.getData().beginParse();
    val referee = cs.loadAddress();
    val creator = cs.loadAddress();
    val minBuy = cs.loadCoins();
    val createdAt = cs.loadUint(32);
    val startedAt = cs.loadUint(32);
    val lastReset = cs.loadUint(32);
    val started = cs.loadUint(1);
    val paid = cs.loadUint(2);
    var r = cs.loadRef().beginParse();
    return {
        referee: referee,
        creator: creator,
        minBuy: minBuy,
        createdAt: createdAt,
        startedAt: startedAt,
        lastReset: lastReset,
        started: started,
        paid: paid,
        curve: r.loadAddress(),
        winner: r.loadAddress(),
    };
}

fun savePot(p: Pot) {
    contract.setData(beginCell()
        .storeAddress(p.referee)
        .storeAddress(p.creator)
        .storeCoins(p.minBuy)
        .storeUint(p.createdAt, 32)
        .storeUint(p.startedAt, 32)
        .storeUint(p.lastReset, 32)
        .storeUint(p.started, 1)
        .storeUint(p.paid, 2)
        .storeRef(beginCell().storeAddress(p.curve).storeAddress(p.winner).endCell())
        .endCell());
}

// Pay everything except the storage cushion to `to`, non-bounceable, so a
// payout to a fresh wallet can never come back and reopen the pot.
fun payOutAll(to: address) {
    reserveGramsOnBalance(KEEP_ON_VAULT, RESERVE_MODE_AT_MOST);
    sendRawMessage(beginCell()
        .storeUint(0x10, 6)
        .storeAddress(to)
        .storeCoins(0)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .endCell(), 128 + 2);
}

fun onBouncedMessage(in: InMessageBounced) {
    // Payouts are non-bounceable; nothing this vault sends can bounce back.
}

fun onInternalMessage(in: InMessage) {
    var p = loadPot();
    var body = in.body;

    // Plain transfers top up a live pot; a finished pot refuses them (bounce).
    if (body.isEmpty()) {
        assert(p.paid == PAID_NONE, ERR_DONE);
        assert(p.createdAt != 0, ERR_NOT_FUNDED);
        assert(contract.getOriginalBalance() <= MAX_POT + POT_GAS_MARGIN, ERR_POT_TOO_BIG);
        return;
    }
    val op = body.loadUint(32);
    if (op == 0xffffffff) { return; }
    body.loadUint(64);   // query id
    val now = blockchain.now();

    if (op == OP_FUND) {
        assert(p.paid == PAID_NONE, ERR_DONE);
        if (p.createdAt == 0) {
            // The first fund opens the 7-day start window, so only the
            // creator may send it, with a real pot and an allowed minimum.
            assert(in.senderAddress == p.creator, ERR_NOT_CREATOR);
            assert(p.minBuy >= MIN_BUY_FLOOR && p.minBuy <= MIN_BUY_CEIL, ERR_BAD_MIN_BUY);
            assert(in.valueCoins >= MIN_POT + REFEREE_FEE, ERR_POT_TOO_SMALL);
            assert(in.valueCoins <= MAX_POT + REFEREE_FEE + POT_GAS_MARGIN, ERR_POT_TOO_BIG);
            p.createdAt = now;
            savePot(p);
            // Referee gas for this pot, paid once from the deposit (non-bounceable).
            sendRawMessage(beginCell()
                .storeUint(0x10, 6)
                .storeAddress(p.referee)
                .storeCoins(REFEREE_FEE)
                .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .endCell(), 1);
            return;
        }
        assert(contract.getOriginalBalance() <= MAX_POT + POT_GAS_MARGIN, ERR_POT_TOO_BIG);
        return;
    }

    if (op == OP_START) {
        assert(in.senderAddress == p.referee, ERR_NOT_REFEREE);
        assert(p.paid == PAID_NONE, ERR_DONE);
        assert(p.createdAt != 0, ERR_NOT_FUNDED);
        assert(p.started == 0, ERR_STARTED);
        val firstBuyAt = body.loadUint(32);
        assert(firstBuyAt >= p.createdAt && firstBuyAt < p.createdAt + START_WINDOW_SECS && firstBuyAt <= now, ERR_BAD_TIME);
        p.started = 1;
        p.startedAt = firstBuyAt;
        p.lastReset = firstBuyAt;
        savePot(p);
        return;
    }

    if (op == OP_PAY_WINNER) {
        assert(in.senderAddress == p.referee, ERR_NOT_REFEREE);
        assert(p.paid == PAID_NONE, ERR_DONE);
        assert(p.started == 1, ERR_NOT_STARTED);
        val winner = body.loadAddress();
        val lastReset = body.loadUint(32);
        assert(winner.getWorkchain() == 0 && winner != p.creator && winner != p.curve
            && winner != contract.getAddress(), ERR_BAD_WINNER);
        assert(lastReset >= p.startedAt && lastReset <= now, ERR_BAD_TIME);
        assert(now >= lastReset + COUNTDOWN_SECS, ERR_TOO_EARLY);
        p.paid = PAID_WINNER;
        p.lastReset = lastReset;
        p.winner = winner;
        savePot(p);
        payOutAll(winner);
        return;
    }

    if (op == OP_RECLAIM) {
        // Permissionless: the money can only go to the creator.
        assert(p.paid == PAID_NONE, ERR_DONE);
        assert(p.createdAt != 0, ERR_NOT_FUNDED);
        assert(p.started == 0, ERR_STARTED);
        assert(now >= p.createdAt + START_WINDOW_SECS + RECLAIM_GRACE_SECS, ERR_TOO_EARLY);
        p.paid = PAID_CREATOR;
        p.winner = p.creator;
        savePot(p);
        payOutAll(p.creator);
        return;
    }

    assert(false, ERR_UNKNOWN_OP);
}

/// (referee, creator, curve, minBuy, createdAt, started, startedAt, lastReset, paid, winner)
/// paid: 0 = running/unfunded, 1 = paid to winner, 2 = returned to creator.
/// `winner` is the curve address until paid.
get fun get_pot_state(): (address, address, address, int, int, int, int, int, int, address) {
    val p = loadPot();
    return (p.referee, p.creator, p.curve, p.minBuy, p.createdAt, p.started, p.startedAt, p.lastReset, p.paid, p.winner);
}
