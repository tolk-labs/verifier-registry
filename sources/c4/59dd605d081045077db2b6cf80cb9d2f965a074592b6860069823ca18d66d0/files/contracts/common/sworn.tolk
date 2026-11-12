tolk 1.5

import "@stdlib/gas-payments"
import "messages"

// Shared constants and helpers for the Sworn root, tills and lock items.

const SWORN_VERSION = 6;

// Number of tills. A lock pays its fees to till (index mod TILL_COUNT). 255 so that one root
// transaction can push a config change to every till (255 outgoing messages is the action limit).
const TILL_COUNT = 255;

// Hard caps on fees: in the root (SetFees), the tills (SetTillConfig) and the locks (attestation),
// so no single contract can be talked into a higher fee. Cannot change without a new version.
const MAX_FLAT_FEE = grams("100");
const MAX_FEE_BPS = 200;            // 2%
const MAX_ROYALTY_BPS = 500;        // 5% on marketplace sales of transferable locks

const SECONDS_PER_YEAR = 31536000;

// Upper bound on a (non-permanent) lock's end, counted from now. Also rejects millisecond
// timestamps. Permanent locks cover "forever".
const MAX_LOCK_DURATION = 50 * SECONDS_PER_YEAR;

// A creation must complete within this time after InitLock; after it, the lock cancels instead of
// funding, and anyone (not only the creator) may cancel it. The budget carries the storage for it.
const SETUP_WINDOW = 7 * 86400;
// The terms' createBefore may be at most this far ahead of the InitLock that uses them. Its creator may
// come back that long: tokens sent without the InitLock (a wallet short of GRAM skips it and still sends
// the transfer) are recovered by initializing the lock and cancelling it. Far shorter than the decades
// a lock's prepaid storage must run out and its debt grow before it can be deleted, so a deleted lock
// can never be initialized again.
const MAX_CREATE_AHEAD = 365 * 86400;
// A Sweep waits this long after the lock's latest fee-token transfer to its till: until then that
// transfer may still bounce back (restoring feeOwed), and a sweep must not take those tokens
const FEE_SETTLE = 86400;
// A sweep waits for fee tokens this long after the lock's end at most, and goes without them after
const FEE_GIVE_UP = 30 * 86400;
// A quoted cost that grows with time (the storage due in get_extend_cost and get_top_up_cost) still
// covers a message that lands this long after the quote (a slow wallet, a multisig); the unused part
// comes back with the excesses
const QUOTE_MARGIN = 30 * 86400;

// Storage is prepaid for the lock duration plus this grace (time to come and claim), and for
// PERMANENT_STORAGE_HORIZON for permanent locks. Anyone can top up.
const STORAGE_GRACE = 3 * SECONDS_PER_YEAR;
const PERMANENT_STORAGE_HORIZON = 50 * SECONDS_PER_YEAR;
const MIN_STORAGE_PREPAY = grams("0.01");
// The storage prices in force until 2026-04-29 (the first entry of ConfigParam 18 on mainnet and on
// testnet), per bit and per cell for 65536 seconds. That day validators cut the basechain's about 7 times,
// and what they lowered they can raise again: no storage is paid in advance at less than these.
const FLOOR_BIT_PRICE = 1;
const FLOOR_CELL_PRICE = 500;
const FLOOR_MC_BIT_PRICE = 1000;
const FLOOR_MC_CELL_PRICE = 500000;
// A cancelled lock keeps this much life: tokens can still reach it (ClaimForeign, RecoverUnrecorded)
const CANCELLED_STORAGE_HORIZON = 2 * SECONDS_PER_YEAR;

// Account sizes used for storage prepayment: what the network charges the lock and the till for (their
// storage stat: code, data and the account cell; the lock in every state and with the largest amounts, the
// till at the fee caps), with a margin; the jetton wallet values are deliberately generous since wallet
// code varies. Never below the real size: a storage fee computed from them at the prices in force is an
// upper bound.
const LOCK_STATE_BITS = 106000;
const LOCK_STATE_CELLS = 232;
// A jetton wallet's state as the network charges it: 1.6 times the bits and 1.7 times the cells of the
// largest wallet among the deployed jettons sampled (19 869 bits and 46 cells of code and data, 47 cells
// with the account cell)
const JETTON_WALLET_STATE_BITS = 32000;
const JETTON_WALLET_STATE_CELLS = 80;
const TILL_STATE_BITS = 12000;
const TILL_STATE_CELLS = 30;
// What a jetton wallet spends to take in a plain GRAM transfer (the reference wallet 597 gas, the governed
// one 930). An extension pays it with the storage it sends the wallet: without it a short extension would
// buy the wallet nothing, its few nanoGRAM going to that gas.
const WALLET_PLAIN_GAS = 1500;

// Value attached to messages handled by contracts Sworn does not control. TEP-74 caps what a jetton transfer
// may keep: the wallets must send back all of the value but forward_ton_amount, 2 * max_tx_gas_price
// and 2 * fwd_fee. That much, priced live on the wallet's own chain (a master may derive its wallets on
// the masterchain), is what a transfer attaches at least, and unused value comes back as excesses. It is
// a minimum, not a promise: TEP-74 lets a wallet refuse less for its own reasons, and some deployed ones
// have fixed gas constants above it. A refusal loses nothing, and whoever moves tokens can attach more
// (Claim, Sweep, RetryRefund, RetryFee, RecoverUnrecorded, ClaimForeign).
const MAX_TX_GAS = 1000000;                         // gas_limit of ConfigParams 20 and 21 (immutable code does not parse the config)
// Should gas get much cheaper: wallets with fixed gas constants (the reference one's 0.04 + fees)
const JETTON_TRANSFER_VALUE_FLOOR = grams("0.06");
const ATTEST_VALUE_FLOOR = grams("0.015");          // AttestTerms -> TermsAttested
// Some deployed wallets deliver a little less than forward_ton_amount (0.0042 GRAM measured): what is
// quoted as a forward amount leaves room for that, and comes back when unused
const FORWARD_SLACK = grams("0.02");

const BPS_DENOMINATOR = 10000;

// Gas units of Sworn's own handlers, priced from the live config: an upper bound for every path, none
// of which depends on anything but the message and fixed state.
const LOCK_GAS_INIT = 33000;
const LOCK_GAS_SETUP_STEP = 16000;      // a setup event that does not complete the funding
const LOCK_GAS_COMPLETE = 45000;        // the setup event that completes (or cancels) the funding
const LOCK_GAS_NOTIFY = 25000;          // any other transfer notification (deposits, top-ups sent back)
const LOCK_GAS_BOUNCE = 21000;          // a bounce restoring a record
const LOCK_GAS_CLAIM = 24000;
const LOCK_GAS_SWEEP = 35000;           // may also pay the fee owed to the till
const LOCK_GAS_NFT_TRANSFER = 16000;
const LOCK_GAS_TOP_UP = 40000;
const LOCK_GAS_CANCEL = 39000;
const LOCK_GAS_EXTEND = 26000;
const LOCK_GAS_RETRY = 21000;
const TILL_GAS_ATTEST = 4000;
const TILL_GAS_RECEIPT = 8000;
const TILL_GAS_CONFIG = 6000;
const TILL_GAS_WITHDRAW = 6000;
const ROOT_GAS_DEPLOY_TILL = 7500;
const ROOT_GAS_WITHDRAW_TILL = 9500;
const ROOT_GAS_BROADCAST = 710000;      // TILL_COUNT messages, each with an address derivation (about 2200 gas each)

// Forward fee budget per small internal message (bits/cells upper bound: the largest is a fee-token transfer
// with its tag and an amount of 15 bytes, 1 347 bits)
const SMALL_MSG_BITS = 1400;
const SMALL_MSG_CELLS = 3;

// Lock status
const STATUS_AWAITING_SETUP = 0;       // deployed; waiting for the till and the funding
const STATUS_FUNDED = 2;               // tokens confirmed by the wallet the creator named
const STATUS_CANCELLED = 3;            // creation failed, tokens returned to the creator

// Lock index encodes the kind: even = transferable NFT, odd = soulbound (TEP-85)
@inline
fun isSoulboundIndex(index: int): bool {
    return (index & 1) == 1;
}

// Initial data of a lock item (TEP-62 style: collection + index). The index is the hash of the
// lock's terms with its low bit set to the kind, so the address commits to the terms.
struct LockInitData {
    collection: address
    index: uint256
}

fun lockDeployAddress(lockCode: cell, collection: address, index: int): AutoDeployAddress {
    return {
        stateInit: {
            code: lockCode,
            data: LockInitData { collection, index }.toCell()
        }
    };
}

// Till storage. Its initial form (unconfigured, all zeros) is the same for every till of a root
// except n, so till n's address is a function of (till code, root, n) alone.
struct TillStorage {
    root: address
    n: uint8
    configured: bool            // false until the root pushed a config: attestations refused meanwhile
    enabled: bool
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

fun tillDeployAddress(tillCode: cell, root: address, n: int): AutoDeployAddress {
    return {
        stateInit: {
            code: tillCode,
            data: TillStorage { root, n, configured: false, enabled: false, flatFee: 0, topUpFlatFee: 0, feeBps: 0 }.toCell()
        }
    };
}

// ============== Schedule ==============

fun Schedule.isValidForCreation(self, now: int): bool {
    if (self.cliff > self.end) {
        return false;
    }
    if (self.end <= now || self.end > now + MAX_LOCK_DURATION) {
        return false;
    }
    if (self.initialBps > BPS_DENOMINATOR) {
        return false;
    }
    if (self.step > 0 && ((self.end - self.cliff) % self.step) != 0) {
        return false;
    }
    return true;
}

fun Schedule.isZero(self): bool {
    return self.cliff == 0 && self.end == 0 && self.step == 0 && self.initialBps == 0;
}

// Unlocked part of `total` at time t (rounded down)
@noinline
fun Schedule.unlockedAt(self, total: int, t: int): int {
    if (t < self.cliff) {
        return 0;
    }
    if (t >= self.end) {
        return total;
    }
    val initial = mulDivFloor(total, self.initialBps, BPS_DENOMINATOR);
    var elapsed = t - self.cliff;
    if (self.step > 0) {
        elapsed -= elapsed % self.step;
    }
    return initial + mulDivFloor(total - initial, elapsed, self.end - self.cliff);
}

// An extension is allowed only if the new schedule never unlocks more than the old one at any
// time: cliff and end can only move later, the initial share can only shrink, and with steps
// both moves must be whole steps (otherwise step boundaries shift and can unlock earlier).
fun Schedule.isValidExtension(self, next: Schedule, now: int): bool {
    if (next.step != self.step) {
        return false;
    }
    if (next.cliff < self.cliff || next.end < self.end || next.cliff > next.end) {
        return false;
    }
    if (next.initialBps > self.initialBps) {
        return false;
    }
    if (next.end > now + MAX_LOCK_DURATION && next.end != self.end) {
        return false;
    }
    if (self.step > 0) {
        if ((next.cliff - self.cliff) % self.step != 0 || (next.end - self.end) % self.step != 0) {
            return false;
        }
    }
    return true;
}

// ============== Storage prepayment ==============

@noinline
fun storageHorizon(permanent: bool, end: int, now: int): int {
    if (permanent) {
        return PERMANENT_STORAGE_HORIZON;
    }
    return max(end - now, 0) + STORAGE_GRACE;
}

// When the storage prepaid now for that horizon runs out
fun storageEnd(permanent: bool, end: int, now: int): int {
    return now + storageHorizon(permanent, end, now);
}

// Storage of `seconds` on that chain, paid in advance: 1.5x the live price or the floor price, whichever
// is more. A lock funded at today's price keeps its whole horizon paid if the price of before April 2026
// returns, with nobody doing anything; above that, or 1.5x today's when that is more, it needs a top-up.
@noinline
fun storageAdvance(workchain: int, seconds: int, bits: int, cells: int): coins {
    return max(calculateStorageFee(workchain, seconds, bits, cells) * 3 / 2, floorStorageFee(workchain, seconds, bits, cells));
}

// What `seconds` of storage cost at the floor prices of that chain, rounded up as the chain rounds its own
// storage fee. As the chain's own fee does, any chain but the basechain is priced as the masterchain.
@noinline
fun floorStorageFee(workchain: int, seconds: int, bits: int, cells: int): coins {
    val perPeriod = workchain == BASECHAIN
        ? bits * FLOOR_BIT_PRICE + cells * FLOOR_CELL_PRICE
        : bits * FLOOR_MC_BIT_PRICE + cells * FLOOR_MC_CELL_PRICE;
    return mulDivCeil(perPeriod, seconds, 65536);
}

fun prepayFor(workchain: int, seconds: int, bits: int, cells: int): coins {
    return max(storageAdvance(workchain, seconds, bits, cells), MIN_STORAGE_PREPAY);
}

fun lockStoragePrepay(permanent: bool, end: int, now: int): coins {
    return prepayFor(BASECHAIN, storageHorizon(permanent, end, now), LOCK_STATE_BITS, LOCK_STATE_CELLS);
}

// The jetton wallet's storage for `seconds`, on the chain the wallet lives on: masterchain storage costs
// thousands of times more, and a wallet whose storage runs out is deleted with the tokens in it
fun walletStoragePrepay(workchain: int, seconds: int): coins {
    return prepayFor(workchain, seconds, JETTON_WALLET_STATE_BITS, JETTON_WALLET_STATE_CELLS);
}

// The same for a longer life (no minimum: what an extension adds)
fun walletStorageExtra(workchain: int, seconds: int): coins {
    return storageAdvance(workchain, seconds, JETTON_WALLET_STATE_BITS, JETTON_WALLET_STATE_CELLS);
}

fun cancelledStorageReserve(): coins {
    return prepayFor(BASECHAIN, CANCELLED_STORAGE_HORIZON, LOCK_STATE_BITS, LOCK_STATE_CELLS);
}

// ============== Metadata ==============

// Appends `v` (< 10^26) in decimal; `width` > 0 pads with leading zeros to that many digits
fun builder.storeDigits(mutate self, v: int, width: int) {
    var digits = 0;
    var reversed = 0;
    var rest = v;
    while (rest > 0) {
        reversed = reversed * 10 + (rest % 10);
        rest /= 10;
        digits += 1;
    }
    if (width > 0) {
        repeat (width - digits) {
            self.storeUint(48, 8);
        }
    } else if (digits == 0) {
        self.storeUint(48, 8);
    }
    repeat (digits) {
        self.storeUint(48 + reversed % 10, 8);
        reversed /= 10;
    }
}

// Decimal digits of a non-negative integer up to 2^256 (at most 78 digits: 624 bits, one cell).
// Three limbs of 26 digits keep the reversal within an int.
fun decimalStringCell(value: int): cell {
    val limb = 100000000000000000000000000;    // 10^26
    val hi = value / (limb * limb);
    val mid = (value / limb) % limb;
    val lo = value % limb;
    var b = beginCell();
    if (hi > 0) {
        b.storeDigits(hi, 0);
        b.storeDigits(mid, 26);
        b.storeDigits(lo, 26);
    } else if (mid > 0) {
        b.storeDigits(mid, 0);
        b.storeDigits(lo, 26);
    } else {
        b.storeDigits(lo, 0);
    }
    return b.endCell();
}

// ============== Payloads ==============

// Forward payload in a ref (Either bit 1). Every payload Sworn sends travels this way: TEP-74
// allows inline or ref, but some deployed jetton wallets read Maybe ^Cell and drop inline payloads.
fun refPayload(c: cell?): RemainingBitsAndRefs {
    if (c == null) {
        return emptyForwardPayload();
    }
    return beginCell().storeBool(true).storeRef(c).endCell().beginParse();
}

fun emptyForwardPayload(): RemainingBitsAndRefs {
    return beginCell().storeBool(false).endCell().beginParse();
}

// Either-encoded forward payload -> slice of the payload itself (never throws)
fun readForwardPayload(fp: slice): slice? {
    var s = fp;
    if (s.remainingBitsCount() < 1) {
        return null;
    }
    if (s.loadBool()) {
        if (s.remainingRefsCount() < 1) {
            return null;
        }
        return s.loadRef().beginParse();
    }
    return s;
}

// Opcode of a forward payload, 0 when there is none (never throws)
fun payloadOp(fp: slice): (int, slice?) {
    val payload = readForwardPayload(fp);
    if (payload == null || payload.remainingBitsCount() < 32) {
        return (0, payload);
    }
    return (payload.preloadUint(32), payload);
}

// ============== Costs (GRAM the creator must attach) ==============

@noinline
fun smallMessageFee(): coins {
    return calculateForwardFee(BASECHAIN, SMALL_MSG_BITS, SMALL_MSG_CELLS);
}

// The same to an account of that workchain (a jetton wallet may live on its jetton's habitat workchain), at
// that chain's prices. For the messages paying this on top of their value: one that cannot would fail the
// whole transaction.
fun messageFeeOn(workchain: int): coins {
    return calculateForwardFee(workchain, SMALL_MSG_BITS, SMALL_MSG_CELLS);
}

fun messageFeeTo(wallet: address): coins {
    return messageFeeOn(wallet.getWorkchain());
}

// What a wallet off the basechain may take out of a forward amount for its own message (TEP-74 lets a wallet
// deliver less than forward_ton_amount, and some do): a message fee on its chain. Nothing on the basechain,
// where FORWARD_SLACK and the forwards below are what real wallets were measured to need.
fun forwardShave(walletWorkchain: int): coins {
    if (walletWorkchain == BASECHAIN) {
        return 0;
    }
    return messageFeeOn(walletWorkchain);
}

// Value of AttestTerms: the till's answer and the lock's handling of it
fun attestValue(): coins {
    return max(ATTEST_VALUE_FLOOR,
        calculateGasFee(BASECHAIN, TILL_GAS_ATTEST + LOCK_GAS_COMPLETE) + 2 * smallMessageFee());
}

// TEP-74's bound for a transfer by a jetton wallet of that workchain (see MAX_TX_GAS)
@noinline
fun jettonTransferValueOn(workchain: int): coins {
    return max(JETTON_TRANSFER_VALUE_FLOOR, 2 * calculateGasFee(workchain, MAX_TX_GAS) + 2 * messageFeeOn(workchain));
}

fun jettonTransferValueTo(wallet: address): coins {
    return jettonTransferValueOn(wallet.getWorkchain());
}

// GRAM a fee receipt (notification or FeeNotice) must carry for the till's handler
fun tillReceiptValue(): coins {
    return calculateGasFee(BASECHAIN, TILL_GAS_RECEIPT) + smallMessageFee();
}

// forward_ton_amount of fee tokens sent to the till through a wallet of that workchain: the receipt's value
// once that wallet has taken its share
fun tillReceiptForward(walletWorkchain: int): coins {
    return tillReceiptValue() + forwardShave(walletWorkchain);
}

// forward_ton_amount of the funding transfer to a lock whose jetton wallet lives on `walletWorkchain`: the
// lock's handler (which may complete the funding) and, should the slot be taken already, sending the tokens
// back through that wallet
fun fundForward(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_COMPLETE) + jettonTransferValueOn(walletWorkchain)
        + smallMessageFee() + messageFeeOn(walletWorkchain) + FORWARD_SLACK + forwardShave(walletWorkchain);
}

// Storage of the lock while its setup runs (SETUP_WINDOW at most)
fun setupWindowStorage(): coins {
    return storageAdvance(BASECHAIN, SETUP_WINDOW, LOCK_STATE_BITS, LOCK_STATE_CELLS);
}

// What the funding pays from the budget on top of the lock's own storage prepayment: the jetton
// wallet's storage, the flat fee with its notice, the fee tokens' transfer when there are fee
// tokens, the event and the excess back to the creator
fun fundingNeeds(walletPrepay: coins, flatFee: coins, withFeeTokens: bool, walletWorkchain: int): coins {
    var need = walletPrepay + messageFeeOn(walletWorkchain) + flatFee + tillReceiptValue() + 3 * smallMessageFee();
    if (withFeeTokens) {
        need += jettonTransferValueOn(walletWorkchain) + tillReceiptForward(walletWorkchain) + messageFeeOn(walletWorkchain);
    }
    return need;
}

// Everything the lock needs after InitLock, whatever the till gives back and however late in
// SETUP_WINDOW the funding completes: its storage prepayment and the window's storage, the setup
// request and the event, the gas of the two setup events and what the funding pays (but the flat fee),
// the jetton wallet's part priced on the chain it lives on
fun lockBudget(permanent: bool, end: int, now: int, walletWorkchain: int): coins {
    return lockStoragePrepay(permanent, end, now)
        + setupWindowStorage()
        + calculateGasFee(BASECHAIN, LOCK_GAS_INIT)
        + attestValue() + 2 * smallMessageFee()
        + calculateGasFee(BASECHAIN, LOCK_GAS_COMPLETE) + calculateGasFee(BASECHAIN, LOCK_GAS_SETUP_STEP)
        + fundingNeeds(walletStoragePrepay(walletWorkchain, storageHorizon(permanent, end, now)), 0, true, walletWorkchain);
}

// Value of InitLock: the flat fee the creator accepts (what the till attests is charged, the rest
// comes back) plus the lock's budget
fun createCost(maxFlatFee: coins, permanent: bool, end: int, now: int, walletWorkchain: int): coins {
    return maxFlatFee + lockBudget(permanent, end, now, walletWorkchain);
}

// Value of an InitLock whose schedule cannot start: the handler, the cancel with its events and what a
// cancelled lock keeps
fun unstartableCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_INIT + LOCK_GAS_CANCEL) + cancelledStorageReserve() + 4 * smallMessageFee();
}

// GRAM to attach (forward_ton_amount) to a top-up sent straight to a lock: the lock's work, the
// flat fee with its notice, the fee tokens' transfer through its wallet, the event and the excess back
// to the sender
fun topUpCost(topUpFlatFee: coins, walletWorkchain: int): coins {
    return topUpFlatFee + tillReceiptValue()
        + calculateGasFee(BASECHAIN, LOCK_GAS_TOP_UP)
        + jettonTransferValueOn(walletWorkchain) + tillReceiptForward(walletWorkchain)
        + 3 * smallMessageFee() + messageFeeOn(walletWorkchain);
}

// Sending tokens back through the notifying wallet (of that workchain), from the notification's value
fun lockRefundCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_NOTIFY) + jettonTransferValueOn(walletWorkchain) + messageFeeOn(walletWorkchain);
}

// GRAM a CancelCreation must carry: the handler, the event, the refund transfer through the lock's
// wallet, the excess to the creator and a helper's surplus back to it
fun cancelCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_CANCEL) + jettonTransferValueOn(walletWorkchain)
        + messageFeeOn(walletWorkchain) + 3 * smallMessageFee();
}

// GRAM a RetryRefund or RetryFee must carry: the handler, one jetton transfer with its receipt, and
// the gas of handling its bounce, which the lock keeps: anyone may send these, and a transfer its
// wallet refuses must not make the lock pay for restoring the record
fun retryCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_RETRY) + jettonTransferValueOn(walletWorkchain) + tillReceiptForward(walletWorkchain)
        + messageFeeOn(walletWorkchain) + bouncePrepay();
}

// Gas of a bounce that restores a record, kept by the lock from the value of a transfer anyone may
// trigger (RetryRefund, RetryFee, RecoverUnrecorded of a pending refund)
fun bouncePrepay(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_BOUNCE);
}

// GRAM a RetryFunding must carry: the till's request and the excess back to the caller
fun retryFundingCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_RETRY) + attestValue() + 2 * smallMessageFee();
}

// GRAM a ClaimForeign must carry: one transfer through a wallet of that workchain
fun claimForeignCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_CLAIM) + jettonTransferValueOn(walletWorkchain) + messageFeeOn(walletWorkchain);
}

// forward_ton_amount of stray tokens the root or a till sends back when the GRAM allows, through a wallet of
// that workchain: enough for a lock's notification handler to record them (as free balance) should the sender
// be a lock
fun strayReturnForward(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_NOTIFY) + smallMessageFee() + forwardShave(walletWorkchain);
}

// forward_ton_amount of tokens sent back through a wallet of that workchain: a notification for the
// sender (a lock, a till or the root keeps books of what it holds) when the notification's GRAM allows,
// none otherwise
fun sendBackForward(value: coins, walletWorkchain: int): coins {
    if (value >= lockRefundCost(walletWorkchain) + strayReturnForward(walletWorkchain)) {
        return strayReturnForward(walletWorkchain);
    }
    return 0;
}

// Value of a SetTillConfig the root sends to one till
fun tillConfigValue(): coins {
    return calculateGasFee(BASECHAIN, TILL_GAS_CONFIG) + smallMessageFee();
}

// GRAM a SetFees / SetCreationEnabled must carry: a config push to every till
fun broadcastCost(): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_BROADCAST) + TILL_COUNT * (tillConfigValue() + smallMessageFee());
}

// GRAM a DeployTill must carry at least; anything more stays on the till as its storage balance. The
// message deploying a till carries its code and data.
fun deployTillCost(): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_DEPLOY_TILL) + tillConfigValue() + MIN_STORAGE_PREPAY
        + calculateForwardFee(BASECHAIN, TILL_STATE_BITS + SMALL_MSG_BITS, TILL_STATE_CELLS + SMALL_MSG_CELLS);
}

// GRAM a WithdrawTillFees / WithdrawRootJetton must carry: root and till handlers and one transfer through a
// wallet of that workchain
fun tillWithdrawCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_WITHDRAW_TILL + TILL_GAS_WITHDRAW) + jettonTransferValueOn(walletWorkchain)
        + smallMessageFee() + messageFeeOn(walletWorkchain);
}
