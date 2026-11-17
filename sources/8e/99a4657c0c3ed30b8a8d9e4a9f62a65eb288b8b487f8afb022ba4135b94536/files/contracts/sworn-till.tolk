tolk 1.5

import "common/messages"
import "common/sworn"

// Sworn till: one of TILL_COUNT identical fee receivers derived from the root (address = hash(till code,
// {root, n})). A lock pays its fees to the till numbered index mod TILL_COUNT.
//
// - Holds a copy of the root's fee config and attests it to locks during their setup (AttestFees,
//   read-only). The lock fixes the attested rates for its whole life.
// - Receives fee tokens (in its jetton wallets), flat fees and the fees of locks of GRAM (in GRAM) and
//   emits a receipt event for each, paid by the message that brought it: a lock's brings what the event
//   costs, and a message that brings less than its event costs leaves none. Nothing here is owed to anyone,
//   so there is no accounting and nothing to pay back.
// - Only the root can change the config or withdraw; fee caps are checked here again.
// - Never spends GRAM of its own for a message, whoever sends it (rule 1 of common/sworn.tolk): its events
//   are paid by the message that caused them; only the admin's withdrawal of GRAM takes any out.
//
// Receipts carry who sent them: for fee tokens the jetton-level sender (as the notifying wallet reports it)
// and that wallet, for a FeeNotice the sending contract. Anyone can send either to any till, so indexers
// check all of this before counting a receipt: this till is the one of the receipt's index (index mod
// TILL_COUNT); the sender is the lock the root derives from that index; the master named is what that lock
// holds (for a lock of GRAM: none); and for tokens the notifying wallet is this till's wallet as that
// master derives it.
//
// The till's storage and its address derivation are in common/sworn.tolk (TillStorage, tillDeployAddress),
// its messages in common/messages.tolk. The hash of this contract's code is compiled into every lock
// (common/till-code-hash.tolk, written by the build): a lock checks the till code its creator supplies
// against that hash, then derives its till's address from the code.

contract SwornTill {
    description: "Sworn till: one of the 255 fee receivers of a root"
    version: "8"
    storage: TillStorage
    incomingMessages: TillMessage
    thrownErrors: TillErrors
}

enum TillErrors {
    NotRoot = 601           // only the root sets the config and withdraws
    FeeAboveCap = 602       // a fee above its cap, even from the root
    NotConfigured = 603     // AttestFees before the root's config has come
    WrongWorkchain = 604    // a destination or a new owner off the basechain
    Reserve = 605           // a withdrawal of GRAM that would leave less than the till keeps
    InsufficientValue = 606 // an AttestFees that carries less GRAM than its answer costs
    UnknownOp = 0xFFFF      // no handler takes this message
}

// What TillWithdrawGrams leaves on the till at least: TILL_RESERVE, and its storage for
// TILL_STORAGE_HORIZON paid in advance as every advance of storage is (storageAdvance), at the size a till
// is priced at (TILL_STATE_BITS, TILL_STATE_CELLS). At the floor price that advance is 0.069774170 GRAM, so
// a withdrawal leaves 0.119774170 GRAM. At the price in force, 135 nanoGRAM per cell and nothing per bit,
// the 29 cells the network charges a till for cost 0.001883903 GRAM a year: what a withdrawal leaves pays
// for 63 years of them (tests/StorageFloor.spec.ts measures both). A till needs no more. No lock depends on
// its till to pay out: a lock asks its till once, at its creation (AttestFees), and whatever it sends the
// till afterwards is a fee, in a message that cannot bounce. Anyone can add GRAM to a till with a plain
// transfer. And every fee a till receives stays on it, above what is kept here, until the admin withdraws
// it.
const TILL_STORAGE_HORIZON = 5 * SECONDS_PER_YEAR
const TILL_RESERVE = grams("0.05")

// ============== Storage ==============
// TillStorage is in common/sworn.tolk, with the derivation of a till's address from it

fun TillStorage.load(): TillStorage {
    return TillStorage.fromCell(contract.getData());
}

fun TillStorage.save(self) {
    contract.setData(self.toCell());
}

// ============== Events ==============
// External messages with no destination, for indexers. Each tag is four ASCII characters: "Ti" for a till,
// then two for the event.

// The jetton and the wallet of a fee receipt, in a cell of their own (FeeReceivedEvent.details)
struct FeeDetails {
    master: address? // the lock's jetton (none for a lock of GRAM)
    wallet: address? // the notifying jetton wallet (none for a FeeNotice)
}

// A fee came ("TiFR"). `index` and `kind` are what its sender states. `from` is who sent the fee: for
// tokens the jetton-level sender the notifying wallet reports (only a genuine wallet's word counts), for a
// FeeNotice the sending contract
struct (0x54694652) FeeReceivedEvent {
    index: uint256
    from: address?
    kind: uint8  // FEE_KIND_*
    // the fee on the amount: tokens, or for a lock of GRAM the part of `value` its notice states (0 in the
    // notice of a lock of jettons, whose tokens come with a receipt of their own)
    amount: coins
    value: coins // GRAM that came (the flat fee, a lock of GRAM's fee on the amount, the receipt's gas)
    details: Cell<FeeDetails>
}

// The till took a config from the root, by SetTillConfig ("TiCF")
struct (0x54694346) TillConfigChangedEvent {
    n: uint8
    enabled: bool
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

// An event of the till, paid by the message being handled and by nothing else (rule 1 of
// common/sworn.tolk). The till first keeps the balance it had before the message
// (RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE; all it has now, should that be less: RESERVE_MODE_AT_MOST, so
// that this never fails). The event then leaves if what is left of the message's value pays its forward
// fee, and is skipped otherwise (SEND_MODE_IGNORE_ERRORS): the till never ends lower for an event, whatever
// the message brought, whatever the prices are and whatever storage it owed. What the event did not use
// stays on the till, less what the network takes for a message it skips.
fun emitPaidEvent<T>(body: T) {
    reserveGramsOnBalance(0, RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_AT_MOST);
    createExternalLogMessage({
        dest: createAddressNone(),
        body,
    }).send(SEND_MODE_IGNORE_ERRORS);
}

// ============== Messages ==============

type TillMessage =
    | AttestFees
    | TransferNotification
    | FeeNotice
    | SetTillConfig
    | TillWithdrawJetton
    | TillWithdrawGrams
    | TillWithdrawNft
    | Excesses

// Every internal message. Fees, requests for the config and plain GRAM come from anyone; the config and the
// withdrawals only from the root.
fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return; // plain GRAM stays here
    }
    val msg = lazy TillMessage.fromSlice(in.body);
    var storage = TillStorage.load();

    match (msg) {
        AttestFees => {
            // Read-only: the config, to whoever asks, on the request's own value, which must cover the
            // answer (get_answer_cost of the asker's chain; rule 2 of common/sworn.tolk). A till without a
            // config (anyone can deploy one; only the root configures it) answers nothing: the request
            // bounces, and the lock waits until the config has come (anyone has the root send it:
            // DeployTill) and the lock asks again (anyone has it ask: RetryFunding). A request that carries
            // too little bounces the same way. A lock's carries attestValue, which is above what is asked
            // here at the prices it was sent at; should they rise beyond that while it travels, it bounces
            // like any other and the lock waits (RetryFunding).
            assert (storage.configured) throw TillErrors.NotConfigured;
            assert (
                in.valueCoins >= tillAnswerCost(in.senderAddress.getWorkchain())
            ) throw TillErrors.InsufficientValue;
            val attestationMessage = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: FeesAttested {
                    queryId: msg.queryId,
                    enabled: storage.enabled,
                    flatFee: storage.flatFee,
                    topUpFlatFee: storage.topUpFlatFee,
                    feeBps: storage.feeBps,
                },
            });
            attestationMessage.send(ON_REQUEST_VALUE);
        }

        TransferNotification => {
            // Tokens with a well-formed fee tag are a fee: they stay in the notifying wallet, the GRAM
            // stays here, and the receipt says who sent them. Nothing about the sender is checked: see the
            // top of the file. The receipt's event is paid by the notification and by nothing else
            // (emitPaidEvent): a lock's fee transfer forwards what the receipt costs at its bounds
            // (tillReceiptValue) and what its wallet may take of it for the notification
            // (tillReceiptForward). When what a notification brought does not pay for the event, the tokens
            // stay, and so does the GRAM less what the network takes for a message it skips, without an
            // event: tokens cannot bounce.
            val (op, payload) = payloadOp(msg.forwardPayload);
            if (op == opcodeOf<FeeTag>()) {
                var tag: FeeTag? = null;
                try {
                    tag = FeeTag.fromSlice(payload!);
                } catch {
                    // a payload with the tag's opcode that is not a tag: the tokens are stray
                }
                if (tag != null) {
                    emitPaidEvent(FeeReceivedEvent {
                        index: tag.index,
                        from: msg.sender,
                        kind: tag.kind,
                        amount: msg.amount,
                        value: in.valueCoins,
                        details: FeeDetails {
                            master: tag.master,
                            wallet: in.senderAddress,
                        }.toCell(),
                    });
                    return; // the GRAM stays here
                }
            }
            // Stray tokens: nothing legitimate sends tokens here but a lock paying fees. Back through the
            // notifying wallet when the GRAM allows, on what is left of the notification's value (the till
            // spends nothing of its own, whatever that wallet is), with enough for a lock to record them
            // should a lock have sent them; otherwise they stay in that wallet, and the admin can send them
            // back (WithdrawTillJetton).
            sendBackUncredited(in.senderAddress, in.valueCoins, msg, msg.queryId);
        }

        FeeNotice => {
            // A lock's flat fee, and a lock of GRAM's fee on the amount, came as this message's value and
            // stay here; the receipt says who sent it. Nothing about the sender is checked: see the top of
            // the file. As for fee tokens, the event is paid by the notice and by nothing else: a lock's
            // notice brings what the receipt costs at its bounds (tillReceiptValue) on top of the fee. When
            // what a notice brought does not pay for the event, the GRAM stays, less what the network takes
            // for a message it skips, without an event: a fee never goes back.
            emitPaidEvent(FeeReceivedEvent {
                index: msg.index,
                from: in.senderAddress,
                kind: msg.kind,
                amount: msg.amount,
                value: in.valueCoins,
                details: FeeDetails {
                    master: msg.master,
                    wallet: null,
                }.toCell(),
            });
        }

        SetTillConfig => {
            // The root's fee config, sent to every till when it changes (SetFees, SetCreationEnabled) and
            // to one till by DeployTill. The caps are checked here again: the root alone cannot make a till
            // attest a fee above them. The config is recorded whenever the message pays for this handler's
            // gas; its event is paid by the message and by nothing else (emitPaidEvent). The root sends it
            // with what this handler and its event cost at their bounds (tillConfigValue) at least.
            assert (in.senderAddress == storage.root) throw TillErrors.NotRoot;
            assert (
                msg.flatFee <= MAX_FLAT_FEE && msg.topUpFlatFee <= MAX_FLAT_FEE
            ) throw TillErrors.FeeAboveCap;
            assert (msg.feeBps <= MAX_FEE_BPS) throw TillErrors.FeeAboveCap;
            storage.configured = true;
            storage.enabled = msg.enabled;
            storage.flatFee = msg.flatFee;
            storage.topUpFlatFee = msg.topUpFlatFee;
            storage.feeBps = msg.feeBps;
            storage.save();
            emitPaidEvent(TillConfigChangedEvent {
                n: storage.n,
                enabled: msg.enabled,
                flatFee: msg.flatFee,
                topUpFlatFee: msg.topUpFlatFee,
                feeBps: msg.feeBps,
            });
        }

        TillWithdrawJetton => {
            // The admin's withdrawal of fee tokens, through the root (WithdrawTillJetton). A till holds
            // only fees, so any wallet and any amount: the wallet's own balance check bounds it, and a
            // bounce leaves the tokens where they were. On the message's own value, which the root has
            // checked covers the whole way; the excess goes to the destination, like the tokens.
            assert (in.senderAddress == storage.root) throw TillErrors.NotRoot;
            // a guard: the root holds a withdrawal to the basechain before it passes it on
            assert (msg.destination.getWorkchain() == BASECHAIN) throw TillErrors.WrongWorkchain;
            sendWithdrawnJetton(msg.wallet, msg.queryId, msg.amount, msg.destination);
        }

        TillWithdrawGrams => {
            // The admin's withdrawal of GRAM, through the root (WithdrawTillGrams): `amount` exactly, its
            // forward fee paid on top. The root has checked that the admin's message carries this handler
            // and that fee (withdrawGramsCost), so they come out of this message's value: the till keeps
            // its reserve whole, and what is left of the value.
            assert (in.senderAddress == storage.root) throw TillErrors.NotRoot;
            // a guard: the root holds a withdrawal to the basechain before it passes it on
            assert (msg.destination.getWorkchain() == BASECHAIN) throw TillErrors.WrongWorkchain;
            val reserve = TILL_RESERVE +
                storageAdvance(BASECHAIN, TILL_STORAGE_HORIZON, TILL_STATE_BITS, TILL_STATE_CELLS);
            // getOriginalBalance() includes this message's value, which must not count
            assert (
                contract.getOriginalBalance() - in.valueCoins >= msg.amount + reserve
            ) throw TillErrors.Reserve;
            sendWithdrawnGrams(msg.destination, msg.queryId, msg.amount);
        }

        TillWithdrawNft => {
            // An NFT the till owns, only ever by someone's mistake (a lock refuses its own till as owner):
            // the admin sends it on, through the root (WithdrawTillNft), which never passes on a request to
            // move a Sworn lock and has checked that the message carries the whole way
            assert (in.senderAddress == storage.root) throw TillErrors.NotRoot;
            // a guard: the root holds a withdrawal to the basechain before it passes it on
            assert (msg.newOwner.getWorkchain() == BASECHAIN) throw TillErrors.WrongWorkchain;
            sendWithdrawnNft(msg.nft, msg.queryId, msg.newOwner);
        }

        Excesses => {
            // accepted: GRAM that someone returns to the till stays here
        }

        else => {
            throw TillErrors.UnknownOp;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {
    // A withdrawal the jetton wallet or the NFT refused. The tokens or the NFT are where they were, the
    // till has no record to restore, and what the bounce brings back stays here.
}

// ============== Get methods ==============

// What get_till_data returns
struct TillInfo {
    version: int
    root: address
    n: int
    configured: bool
    enabled: bool
    flatFee: int
    topUpFlatFee: int
    feeBps: int
}

// The till's root, its number and its fee config (`configured`: the root has sent one), with the version of
// the Sworn contracts this code is part of
get fun get_till_data(): TillInfo {
    val s = TillStorage.load();
    return {
        version: SWORN_VERSION,
        root: s.root,
        n: s.n,
        configured: s.configured,
        enabled: s.enabled,
        flatFee: s.flatFee,
        topUpFlatFee: s.topUpFlatFee,
        feeBps: s.feeBps,
    };
}

// GRAM an AttestFees must carry, which the till answers on the request's own value. `workchain` is the
// asker's: 0, or -1 for the masterchain, whose prices are those of any chain but the basechain.
get fun get_answer_cost(workchain: int): int {
    return tillAnswerCost(workchain);
}

// The version of the Sworn contracts this code is part of
get fun get_sworn_version(): int {
    return SWORN_VERSION;
}
