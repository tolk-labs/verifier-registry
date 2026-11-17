tolk 1.5

import "@stdlib/gas-payments"
import "messages"
import "sworn"
import "till-code-hash"

// What a lock of jettons (lock-core.tolk) and a lock of GRAM (gram-lock-core.tolk) share. They are the same
// NFT (TEP-62, soulbound or not), created from the same terms through the same tills, with the same
// schedule, events and get methods. This file has their error codes, their statuses, the rule of their
// queryIds, their events, the reading of the lock's own balance, the messages both send, the checks of the
// terms at creation, the rule of an extension, who moves what is foreign to a lock, the NFT and SBT
// handlers, the costs both count and the shapes of the get methods. The message layouts are in
// messages.tolk; the constants, the schedule math and the other costs are in sworn.tolk.

// The codes both throw; each adds the few codes of its own (JettonErrors, GramErrors)
enum LockErrors {
    NotOwner = 401              // only the owner may send this
    NotFunded = 402             // only a funded lock does this
    ZeroAmount = 403            // an amount of zero, or nothing claimable
    AmountTooHigh = 404         // more than is claimable, or than the refund owed
    InsufficientValue = 405     // the message carries less GRAM than it needs
    InvalidExtension = 406      // an extension the rule refuses (extendedSchedule), or of a finished lock
    Soulbound = 407             // a soulbound lock is never transferred
    // an owner, a creator or a destination off the basechain, or an account the lock is asked to send a
    // message to (reachableWorkchain: the lock's jetton wallet at its creation among them) on neither the
    // basechain nor the masterchain
    WrongWorkchain = 408
    // an account that cannot be named there: the root, the lock's till, the lock itself, its jetton wallet
    // or, as the recipient, the wallet the tokens come from or the NFT that is moved
    ForbiddenAccount = 409
    NotSupported = 410          // a TEP-85 request to a transferable lock; destroy and revoke
    BadStatus = 411             // the lock is not in the status this message is for
    NotFinished = 412           // a sweep before the schedule has ended, or of a permanent lock
    BadTerms = 413              // terms that are not those of the index, or that no lock can start from
    BadTillCode = 414           // the till code sent is not the one compiled into the lock
    TooEarly = 415              // for the time being only the creator may do this
    NotCreator = 416            // the creator alone may send this, or name a destination other than itself
    CreateExpired = 417         // createBefore has passed, or is more than MAX_CREATE_AHEAD ahead
    // what the owner adds to a claim has more than MAX_PAYLOAD_CELLS cells or MAX_PAYLOAD_BITS bits, or is
    // deeper than MAX_PAYLOAD_DEPTH
    PayloadTooLarge = 418
    AlreadyCreated = 419        // InitLock or InitGramLock at a lock that was created
    MissingForwardPayload = 420 // an NFT transfer without the bit that says where its forward payload is
    UnknownOp = 0xFFFF          // no handler takes this message
}

// Gas of measuring one cell of what the owner adds to a claim (payloadCarriage). The network charges 100
// for the first load of a cell, and a claim whose payload has MAX_PAYLOAD_CELLS cells used 100.16 a cell
// more than one with no payload (tests/Lock.spec.ts): a third above it.
const GAS_PER_PAYLOAD_CELL = 135
// The most of what the owner adds to a claim, in cells, in bits and in depth: half of what the network lets
// one message carry (8192 cells, 2^21 bits and a depth of 512, ConfigParam 43), so that it fits in every
// message that carries it on, whatever that message adds
const MAX_PAYLOAD_CELLS = 4096
const MAX_PAYLOAD_BITS = 1 << 20
const MAX_PAYLOAD_DEPTH = 256

// The status of a lock, as its get methods and a LockState report it.

// Created, and waiting for the till's attestation and, for a lock of jettons, the funding
const STATUS_AWAITING_SETUP = 0
// The till attested the fees and the funding came: tokens reported by the wallet the creator named, or the
// GRAM the creation carried
const STATUS_FUNDED = 1
// The creation failed: what was to be locked goes back to the creator
const STATUS_CANCELLED = 2
// An address that was deployed and where no lock was created (the get methods report it: no lock stores it)
const STATUS_NOT_INITIALIZED = 255

// Why a creation was cancelled: the reason of LockCancelledEvent, which the lock keeps (get_custody_data)
const CANCEL_TILL_REFUSED = 1 // creation disabled, or a fee above the creator's maxima or the caps
const CANCEL_REQUESTED = 2 // CancelCreation by the creator
const CANCEL_EXPIRED = 3 // after SETUP_WINDOW: the last setup event, or a CancelCreation by someone else
const CANCEL_BUDGET = 4 // the budget no longer covered the funding (prices rose meanwhile)

// ============== QueryIds ==============
// One rule for the queryId of what a lock sends. What it sends for the message it is handling carries that
// message's queryId, so that whoever sent it can pair the two: an answer, an excess, the transfer the
// message asks for. What it sends on its own account carries a queryId of its own. That is the low 60 bits
// of its index (queryIdOf) in what it sends its till (the setup request, a fee notice, a transfer of fee
// tokens) and in what the setup sends back to the creator when the till's answer or the funding completes
// or cancels the creation. In the refund a cancelled lock owes it is the lock's walletSeq (pendingQueryId,
// in lock-core). What is left of a refused message goes back with queryId 0 (refuse): nothing of such a
// message is read.
//
// A lock of jettons puts four flags in the four bits above those 60, bits 60 to 63, of the transfers it
// makes through jetton wallets. They tell the bounce of such a transfer what record to restore
// (handleLockBounce, in lock-core):
// - QID_SEND_BACK: a deposit the lock sent back. It stays as a gift does: free balance, or setupExtra
//   during the setup.
// - QID_FEE: the fee tokens a funded lock owes its till (feeOwed).
// - QID_PENDING: the refund a cancelled lock owes (pendingAmount).
// - QID_UNCREDITED: none. Sweeps, foreign claims, recoveries of what no record counts, and the send-backs
//   that are not to be credited: through another wallet, of a finished or cancelled lock, of a top-up of
//   the owner or the creator.
// - none of them: a claim, back to the free balance.
// In such a transfer a queryId a caller supplies is cut to its low 60 bits (QID_USER_MASK), with a flag or
// without, so nothing a caller sends can pass for a flag. Everywhere else it travels whole, and a lock of
// GRAM, which has no record for a bounce to restore, flags nothing.
const QID_USER_MASK = (1 << 60) - 1
const QID_SEND_BACK = 1 << 60
const QID_FEE = 1 << 61
const QID_PENDING = 1 << 62
const QID_UNCREDITED = 1 << 63

// Every bounceable message of the lock bounces with its whole root cell (the response destination is in
// it); none needs its refs back
const LOCK_BOUNCE = BounceMode.RichBounceOnlyRootCell

// Fields of the incoming message (InMessage cannot be passed around as an object)
struct LockIncoming {
    sender: address
    value: coins
    fwdFee: coins // the forward fee the message paid (InMessage.originalForwardFee)
    body: slice
}

// Whether the incoming message asked to come back should it fail. The standard library gives the other
// fields of the incoming message (InMessage) and not this one.
// SAFETY: INMSG_BOUNCE takes nothing and pushes the bounce flag of the message being handled, as the
// instructions behind InMessage's fields push theirs; called from onInternalMessage only.
fun incomingBounces(): bool
    asm "INMSG_BOUNCE"

// What a lock does with a message it refuses, for the reason `code`. One that asked to bounce bounces, with
// that code and the rest of its value. One that did not would leave its GRAM here, which for the creation
// or a top-up of a lock of GRAM is the GRAM to lock: what is left of it goes back to its sender instead, in
// an Excesses with queryId 0 (SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE). Not a jetton wallet's
// notification, though: the GRAM it carries is its jetton sender's, not the wallet's, and stays here as it
// would on any contract. Nothing the handler did before refusing stays (it runs in a try block, which
// undoes its data and its messages).
fun refuse(sender: address, body: slice, code: int) {
    if (incomingBounces() || isBodyOf<TransferNotification>(body)) {
        throw code;
    }
    returnExcess(sender, 0, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// Whether a lock was created at this address (InitLock or InitGramLock was accepted) and not only deployed:
// the data a lock is deployed with is the root's address and the index (LockInitData), and a lock that was
// created holds more
@noinline
fun isInitialized(): bool {
    return contract.getData().beginParse().remainingBitsCount() > LOCK_INIT_DATA_BITS;
}

// The queryId of a lock's own: the low 60 bits of its index
@inline
fun queryIdOf(index: int): uint64 {
    return index & QID_USER_MASK;
}

// ============== Events ==============
// External messages with no destination, for indexers. They are hints, not accounting: what a lock holds is
// read from its get methods. Each tag is four ASCII characters: "Lk" for a lock, then two for the event.

// InitLock or InitGramLock was accepted ("LkCR"). jettonWallet: the wallet the creator named (none for a
// lock of GRAM)
struct (0x4c6b4352) LockCreatedEvent {
    index: uint256
    jettonWallet: address?
    terms: Cell<LockTerms>
}

// The lock is funded ("LkFU"). amount: what the schedule holds, the fee on the amount taken out; fee: that
// fee
struct (0x4c6b4655) LockFundedEvent {
    index: uint256
    amount: coins
    fee: coins
}

// A top-up joined the schedule ("LkTU"). amount: what it adds, the fee on the amount taken out; from: the
// owner or the creator, whoever sent it; prevDepositLt: logical time of the previous deposit's transaction
// (the funding or a top-up)
struct (0x4c6b5455) LockToppedUpEvent {
    index: uint256
    amount: coins
    fee: coins
    from: address
    prevDepositLt: uint64
}

// A claim ("LkCL"). amount: what the lock was asked to pay and sent on its way. A lock of GRAM pays it in
// the same transaction; a lock of jettons has its wallet pay it, which may refuse (LockClaimRestoredEvent
// in lock-core). No event carries a caller's queryId: a claim and its event are in one transaction.
struct (0x4c6b434c) LockClaimedEvent {
    index: uint256
    amount: coins
    destination: address
}

// A sweep ("LkSW"). amount: in a lock of jettons the amount asked for, which its wallet bounds; in a lock
// of GRAM what the lock still held for its owner (the storage that leaves with it is not counted)
struct (0x4c6b5357) LockSweptEvent {
    index: uint256
    amount: coins
    destination: address
}

// An extension ("LkEX"): the schedule in force from then on (all zeros in a permanent lock)
struct (0x4c6b4558) LockExtendedEvent {
    index: uint256
    permanent: bool
    schedule: Schedule
}

// The creation was cancelled ("LkCD"). reason: CANCEL_*
struct (0x4c6b4344) LockCancelledEvent {
    index: uint256
    reason: uint8
}

// An event that cannot be paid for fails its transaction, whose message then bounces if it asked to
// (SEND_MODE_BOUNCE_ON_ACTION_FAIL): the handlers that emit one count its fee in the value they ask for or
// in the budget they spend, so a record never changes without its event.
fun emitLockEvent<T>(body: T) {
    createExternalLogMessage({
        dest: createAddressNone(),
        body,
    }).send(SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// The event of a record a bounce has just restored. A bounce brings what it brings and cannot bounce again:
// failing its transaction for an event it cannot pay would only undo the restoration. So such an event is
// skipped when it cannot be paid for (SEND_MODE_IGNORE_ERRORS), and the record stands. An indexer that
// misses it still reads the truth from the get methods.
fun emitLockEventIfPaid<T>(body: T) {
    createExternalLogMessage({
        dest: createAddressNone(),
        body,
    }).send(SEND_MODE_IGNORE_ERRORS);
}

// ============== The lock's own balance ==============

// The lock ends the transaction with the balance it had before the message, plus `extra` of the message's
// value (RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE). Whatever is sent after this comes from the rest of
// that value, and what was sent before it is checked by it: a handler that would leave less fails here, and
// its message bounces if it asked to (RESERVE_MODE_BOUNCE_ON_ACTION_FAIL). Events are emitted before it, so
// that it counts their fees too.
fun keepOwnBalance(extra: coins) {
    reserveGramsOnBalance(
        extra,
        RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
    );
}

// What the lock holds of its own: the balance when the handler starts, which includes the value of the
// message it handles, net of a storage fee still due (the next transaction takes it out first) and of
// `incoming`: the value of that message, or 0 to count it in (a get method handles none)
fun ownBalance(incoming: coins): int {
    return contract.getOriginalBalance() - contract.getStorageDuePayment() - incoming;
}

// The lock's balance as a get method sees it: what the last transaction left, less the most the network may
// charge a lock of that size (`bits`, `cells`: the size its kind is priced at) for the storage since
// `lastTx`, the last save of the state with no storage fee due (storageBound, as the quotes count it: the
// next transaction pays the storage first). So what the get methods report as held is there when a message
// arrives, unless the price stood above both the live and the floor price meanwhile and was cut since. The
// bound can be more than the network takes: it is at the higher of the two prices, and it runs from lastTx
// even when a later transaction that saved nothing (plain GRAM, a request) paid the storage up to its own
// time. Once it is more than the GRAM the lock has beyond what it owes, as in a lock left untouched beyond
// the life its storage was paid for, the get methods can report less than a message would find, and less as
// time passes, until the state is saved again: a StorageTopUp from anyone does that.
fun balanceNow(lastTx: int, bits: int, cells: int): int {
    return ownBalance(0) - storageBound(max(blockchain.now() - lastTx, 0), bits, cells);
}

// What a SweepGram leaves on the lock out of the balance `own`. `released` is what the lock still held for
// its owner, which leaves with the sweep: GRAM in a lock of GRAM, none in a lock of jettons, which holds
// tokens for its owner. Of the GRAM beyond it the lock keeps `reserve` at most, the storage a cancelled
// lock of its kind keeps, and the rest leaves too.
fun sweepKeeps(own: int, released: coins, reserve: coins): coins {
    return min(max(own - released, 0), reserve);
}

// GRAM a handler may spend from the balance, the incoming value included, on top of what it must keep
// (`reserve`): the balance when the handler starts, minus a storage fee still due, minus the handler's own
// gas at its bound (`gasBudget`), minus the reserve. Guards every send from the balance so an action can
// never fail and revert a recorded state.
fun spendableAbove(reserve: coins, gasBudget: int): int {
    return ownBalance(0) - calculateGasFee(BASECHAIN, gasBudget) - reserve;
}

// ============== Messages ==============

// A TEP-74 transfer of tokens the lock holds in `wallet`. Bounceable (LOCK_BOUNCE): what a wallet refuses
// comes back to the lock's bounce handler. `value` and `mode` are the caller's.
@noinline
fun sendJettonTransfer(
    wallet: address,
    queryId: uint64,
    amount: coins,
    destination: address,
    responseDestination: address,
    forwardTonAmount: coins,
    forwardPayload: RemainingBitsAndRefs,
    value: coins,
    mode: int,
) {
    val jettonTransferMessage = createMessage({
        bounce: LOCK_BOUNCE,
        dest: wallet,
        value,
        body: JettonTransfer {
            queryId,
            amount,
            destination,
            responseDestination,
            customPayload: null,
            forwardTonAmount,
            forwardPayload,
        },
    });
    jettonTransferMessage.send(mode);
}

// AttestFees to the lock's till: the setup request. It carries attestValue(), with its forward fee paid on
// top (SEND_MODE_PAY_FEES_SEPARATELY). Bounceable: from a till that is not deployed, or has no config yet,
// the rest of the request's value comes back. A request that cannot be sent fails the transaction, whose
// message then bounces if it asked to (SEND_MODE_BOUNCE_ON_ACTION_FAIL).
fun askTillForFees(till: address, index: int) {
    val feesRequestMessage = createMessage({
        bounce: LOCK_BOUNCE,
        dest: till,
        value: attestValue(),
        body: AttestFees { queryId: queryIdOf(index) },
    });
    feesRequestMessage.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// The flat fee to the till, as the message's value, with the GRAM of the till's receipt (its handler and
// its event). A lock of GRAM adds the fee on the amount to that value and states it (`amount`); a lock of
// jettons sends that fee as tokens. Its forward fee is paid on top (SEND_MODE_PAY_FEES_SEPARATELY).
// Non-bounceable: what it carries is the till's. A notice that cannot be sent is skipped
// (SEND_MODE_IGNORE_ERRORS), so a funding or a top-up never fails on it.
fun sendFeeNotice(
    till: address,
    index: int,
    master: address?,
    kind: int,
    amount: coins,
    value: coins,
) {
    val feeNoticeMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: till,
        value,
        body: FeeNotice {
            queryId: queryIdOf(index),
            index,
            master,
            kind,
            amount,
        },
    });
    feeNoticeMessage.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
}

// GRAM the lock pays out: everything above the balance its handler has just reserved
// (SEND_MODE_CARRY_ALL_BALANCE), in a message that cannot bounce and has no body. A payout that cannot be
// sent fails the transaction, which undoes the claim or the sweep it belongs to, and the message bounces if
// it asked to (SEND_MODE_BOUNCE_ON_ACTION_FAIL).
fun payOut(destination: address) {
    val payoutMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: destination,
        value: 0,
    });
    // SAFETY: called right after a reserve of the balance the lock keeps; this carries what is above it
    payoutMessage.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// An Excesses to `destination` with no value of its own: `mode` says what it carries, the rest of the
// incoming value or everything above a reserve. Non-bounceable, and skipped if it cannot be sent
// (SEND_MODE_IGNORE_ERRORS): what is too little to pay its own way stays on the lock.
@noinline
fun returnExcess(destination: address, queryId: uint64, mode: int) {
    val excessMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: destination,
        value: 0,
        body: Excesses { queryId },
    });
    excessMessage.send(mode | SEND_MODE_IGNORE_ERRORS);
}

// What is left of a bounced message's value, to its response destination (it stays on the lock when the
// message named none)
fun returnBounced(response: address?, queryId: uint64) {
    if (response != null) {
        returnExcess(response, queryId, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
    }
}

// The setup request bounced (the till is not deployed, or not configured). During the setup its GRAM stays
// here, in the budget (RetryFunding asks again); once the setup is over it goes to the creator.
fun returnSetupBounce(status: int, terms: Cell<LockTerms>, index: int) {
    if (status != STATUS_AWAITING_SETUP) {
        returnExcess(
            creatorOf(terms),
            queryIdOf(index),
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
        );
    }
}

// ============== Creation ==============

// What every lock checks of the terms it is created with, whatever it locks: they are the terms its index
// commits to, of its kind and of this version, in their canonical encoding, sent in time by the creator
// they name. Returns them with their parties.
fun admittedTerms(
    in: LockIncoming,
    init: LockInitData,
    termsCell: Cell<LockTerms>,
    tillCode: cell,
    soulbound: bool,
    gram: bool,
    now: int,
): (LockTerms, LockParties) {
    val terms = termsCell.load();
    val termsHash = termsCell.hash();
    // The content is authenticated by the hash, not the sender: these terms are the only ones a lock can
    // ever be created with at this address
    assert (
        (termsHash & ~INDEX_KIND_MASK) == (init.index & ~INDEX_KIND_MASK)
    ) throw LockErrors.BadTerms;
    // ... and only a lock of the kind they describe, which is also the kind of the code running here
    assert (
        terms.soulbound == soulbound && isSoulboundIndex(init.index) == soulbound
    ) throw LockErrors.BadTerms;
    assert (
        (terms.jettonMaster == null) == gram && isGramIndex(init.index) == gram
    ) throw LockErrors.BadTerms;
    assert (terms.version == SWORN_VERSION) throw LockErrors.BadTerms;
    assert (terms.expectedAmount > 0) throw LockErrors.BadTerms;
    // ... and only by createBefore, itself at most MAX_CREATE_AHEAD from now: once it has passed, no lock
    // can ever be created at this address again, not even after a deletion for storage debt decades later
    assert (
        now <= terms.createBefore && terms.createBefore <= now + MAX_CREATE_AHEAD
    ) throw LockErrors.CreateExpired;
    // the till code comes with the terms only to derive the till's address: it must be the one compiled in
    assert (tillCode.hash() == TILL_CODE_HASH) throw LockErrors.BadTillCode;
    // One meaning, one index: the terms must be in their canonical encoding (no padding, no stray refs)
    assert (terms.toCell().hash() == termsHash) throw LockErrors.BadTerms;
    val parties = terms.parties.load();
    assert (parties.toCell().hash() == terms.parties.hash()) throw LockErrors.BadTerms;
    // only the creator these terms name creates the lock
    assert (in.sender == parties.creator) throw LockErrors.NotCreator;
    // refunds and payouts go to the basechain only: standard jetton wallets send tokens nowhere else, and
    // the lock prices its own messages there
    assert (
        parties.owner.getWorkchain() == BASECHAIN && parties.creator.getWorkchain() == BASECHAIN
    ) throw LockErrors.WrongWorkchain;
    return (terms, parties);
}

// The lock's till, n = index mod TILL_COUNT, derived from the till code sent with the terms. Called once
// the value of the creation has been checked. Neither party may be the root or that till: neither can ever
// send what an owner or a creator sends, so what the lock held for it would stay there for good.
fun tillOfLock(tillCode: cell, init: LockInitData, parties: LockParties): address {
    val till = tillDeployAddress(
        tillCode,
        init.collection,
        init.index % TILL_COUNT,
    ).calculateAddress();
    assert (
        parties.owner != init.collection && parties.owner != till &&
        parties.creator != init.collection &&
        parties.creator != till
    ) throw LockErrors.ForbiddenAccount;
    return till;
}

// The creator the terms of a lock name
@noinline
fun creatorOf(terms: Cell<LockTerms>): address {
    return terms.load().parties.load().creator;
}

// ============== Extension ==============

// The schedule an ExtendLock asks for, if the lock may have it: it never unlocks anything earlier than the
// schedule in force (`schedule`, with `permanent`), and a permanent lock has none (all zeros), whichever
// way it became permanent
fun extendedSchedule(permanent: bool, schedule: Schedule, msg: ExtendLock, now: int): Schedule {
    // a permanent lock stays permanent: it can only be made permanent again, which pays its storage further
    assert (!permanent || msg.makePermanent) throw LockErrors.InvalidExtension;
    // a finished lock stays finished (what it held may be gone): locking again takes another lock
    assert (permanent || now < schedule.end) throw LockErrors.InvalidExtension;
    if (msg.makePermanent) {
        return {
            cliff: 0,
            end: 0,
            step: 0,
            initialBps: 0,
        };
    }
    assert (schedule.isValidExtension(msg.schedule, now)) throw LockErrors.InvalidExtension;
    return msg.schedule;
}

// ============== What reached a lock and is not what it locks ==============

// Who may move a jetton or an NFT that is foreign to the lock out of it. In a funded lock it is the
// owner's: the owner moves it. In a cancelled lock everything is the creator's: the creator moves it to any
// destination, and anyone else only to the creator. Nobody may while the lock is being set up.
fun assertMayMoveForeign(
    sender: address,
    destination: address,
    status: int,
    owner: address,
    terms: Cell<LockTerms>,
) {
    if (status == STATUS_CANCELLED) {
        val creator = creatorOf(terms);
        assert (sender == creator || destination == creator) throw LockErrors.NotCreator;
        return;
    }
    assert (sender == owner) throw LockErrors.NotOwner;
    assert (status == STATUS_FUNDED) throw LockErrors.NotFunded;
}

// ============== The lock as an NFT ==============

// Who may hand a lock on, and when: checked before anything of the transfer is read
fun assertMayTransfer(sender: address, soulbound: bool, status: int, owner: address) {
    assert (!soulbound) throw LockErrors.Soulbound;
    assert (sender == owner) throw LockErrors.NotOwner;
    // a lock in setup or cancelled must not change hands as if it held something
    assert (status == STATUS_FUNDED) throw LockErrors.NotFunded;
}

// What the transfer itself must satisfy before its handler records the new owner. `forbidden`: the new
// owner is an account that could never claim (the root, the lock's till, the lock itself, its jetton
// wallet). The transfer's value must cover the handler, the GRAM it forwards and, for each message it has
// the lock send, the forward fee the transfer itself paid (the notification carries the same payload, the
// excess less).
fun assertTransferable(in: LockIncoming, msg: NftTransfer, forbidden: bool) {
    assert (msg.newOwner.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
    assert (!forbidden) throw LockErrors.ForbiddenAccount;
    assert (msg.forwardPayload.remainingBitsCount() >= 1) throw LockErrors.MissingForwardPayload;
    var need: int = calculateGasFee(BASECHAIN, LOCK_GAS_NFT_TRANSFER);
    if (msg.forwardAmount > 0) {
        need += msg.forwardAmount + in.fwdFee;
    }
    if (wantsExcess(msg)) {
        need += in.fwdFee;
    }
    assert (in.value >= need) throw LockErrors.InsufficientValue;
}

// Whether a transfer names an account that takes what is left of its value
fun wantsExcess(msg: NftTransfer): bool {
    return msg.responseDestination != null && msg.responseDestination.getWorkchain() == BASECHAIN;
}

// The messages of that transfer, once the new owner is recorded: the notification for the new owner with
// the GRAM the sender forwards (none when it forwards none; its fee is paid on top), then all that is left
// of the incoming value to the response destination (keepOwnBalance, then SEND_MODE_CARRY_ALL_BALANCE).
// A transfer costs the lock nothing, whatever the messages turn out to cost: it ends with the balance it
// had (with what is left of the value on top when no response destination is named), and one that its value
// cannot pay fails.
fun sendOwnershipMessages(msg: NftTransfer, prevOwner: address) {
    if (msg.forwardAmount > 0) {
        val ownershipAssignedMessage = createMessage({
            bounce: BounceMode.NoBounce,
            dest: msg.newOwner,
            value: msg.forwardAmount,
            body: OwnershipAssigned {
                queryId: msg.queryId,
                prevOwner,
                forwardPayload: msg.forwardPayload,
            },
        });
        ownershipAssignedMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
    }
    keepOwnBalance(0);
    if (wantsExcess(msg)) {
        returnExcess(msg.responseDestination!, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
    }
}

// TEP-62 get_static_data: the index and the collection, which is the root, to whoever asks, on the
// request's own value
fun sendStaticData(to: address, queryId: uint64, index: int, collection: address) {
    val staticDataMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: ReportStaticData { queryId, index, collection },
    });
    staticDataMessage.send(ON_REQUEST_VALUE);
}

// TEP-85: only a funded soulbound lock answers, and a proof is its owner's to ask for (`byOwner`). A lock
// in setup or cancelled proves nothing; a funded one proves who owns it, while what it holds is for the
// receiver to check (SPEC.md 3.5). Checked before anything of the request is read.
fun assertProves(sender: address, soulbound: bool, status: int, owner: address, byOwner: bool) {
    assert (soulbound) throw LockErrors.NotSupported;
    assert (!byOwner || sender == owner) throw LockErrors.NotOwner;
    assert (status == STATUS_FUNDED) throw LockErrors.NotFunded;
}

// TEP-85 ownership_proof to the account the owner names, on the request's own value. Bounceable: the owner
// is told of a proof that came back (returnStandardBounce). No lock is ever revoked: revokedAt is 0.
fun sendOwnershipProof(msg: ProveOwnership, index: int, owner: address) {
    val ownershipProofMessage = createMessage({
        bounce: LOCK_BOUNCE,
        dest: msg.dest,
        value: 0,
        body: OwnershipProof {
            queryId: msg.queryId,
            itemId: index,
            owner,
            data: msg.forwardPayload,
            revokedAt: 0,
            content: msg.withContent ? decimalStringCell(index) : null,
        },
    });
    ownershipProofMessage.send(ON_REQUEST_VALUE);
}

// TEP-85 owner_info to the account named by whoever asks (`initiator`), on the request's own value.
// Bounceable: what comes back goes to the initiator (returnStandardBounce).
fun sendOwnerInfo(initiator: address, msg: RequestOwner, index: int, owner: address) {
    val ownerInfoMessage = createMessage({
        bounce: LOCK_BOUNCE,
        dest: msg.dest,
        value: 0,
        body: OwnerInfo {
            queryId: msg.queryId,
            itemId: index,
            initiator,
            owner,
            data: msg.forwardPayload,
            revokedAt: 0,
            content: msg.withContent ? decimalStringCell(index) : null,
        },
    });
    ownerInfoMessage.send(ON_REQUEST_VALUE);
}

// An NFT that reached the lock, to `newOwner`, on the message's own value. Bounceable: the value of a
// transfer the NFT refuses goes to `response` (returnStandardBounce).
fun sendForeignNft(nft: address, queryId: uint64, newOwner: address, response: address) {
    val nftTransferMessage = createMessage({
        bounce: LOCK_BOUNCE,
        dest: nft,
        value: 0,
        body: NftTransfer {
            queryId,
            newOwner,
            responseDestination: response,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: emptyForwardPayload(),
        },
    });
    nftTransferMessage.send(ON_REQUEST_VALUE);
}

// The bounces every lock answers alike, each with what is left of the bounced message's value. `body`: the
// bounced message after its opcode and queryId. Returns whether `op` was one of them.
fun returnStandardBounce(op: int, queryId: uint64, body: slice, owner: address): bool {
    var rest = body;
    if (op == opcodeOf<OwnershipProof>()) {
        // TEP-85: tell the owner their ownership proof was rejected, with the value back. Should that fail
        // to be sent it is dropped (SEND_MODE_IGNORE_ERRORS): a bounce has no sender to refuse.
        val proofBouncedMessage = createMessage({
            bounce: BounceMode.NoBounce,
            dest: owner,
            value: 0,
            body: OwnershipProofBounced { queryId },
        });
        proofBouncedMessage.send(
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
        );
        return true;
    }
    if (op == opcodeOf<OwnerInfo>()) {
        // TEP-85: the value back to whoever asked
        rest.skipBits(256); // itemId
        returnExcess(rest.loadAddress(), queryId, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return true;
    }
    if (op == opcodeOf<NftTransfer>()) {
        // a foreign NFT refused to move: nothing to restore
        rest.skipAny<address>(); // newOwner
        returnBounced(rest.loadAddressOpt(), queryId);
        return true;
    }
    return false;
}

// ============== Costs ==============

// The workchain of an account a message names for the lock to send a message to: the jetton wallet a
// creator names in InitLock, the NFT of a ClaimForeignNft, the `dest` of a TEP-85 request, the jetton
// wallet of a ClaimForeign or of a RecoverUnrecorded. It is the basechain or the masterchain, the two
// chains Sworn's costs have prices for and a message can be sent to. A message that names an account on any
// other workchain is refused (WrongWorkchain): the network would take no message for that account once the
// handler had accepted, and what the message carried would stay here. The sender of a message is not such
// an account: it exists, wherever it is, and what goes back to it is never refused for its chain.
fun reachableWorkchain(account: address): int {
    val workchain = account.getWorkchain();
    assert (workchain == BASECHAIN || workchain == MASTERCHAIN) throw LockErrors.WrongWorkchain;
    return workchain;
}

// The GRAM a request must carry that a lock answers on the request's own value: GetStaticData,
// RequestLockState, ClaimForeignNft, ProveOwnership and RequestOwner. It is the handler's gas at its bound,
// at the basechain's gas price, and the forward fee of the answer at the message prices of the chain it
// goes to. The bound is LOCK_GAS_ANSWER, and LOCK_GAS_ANSWER_CONTENT for a TEP-85 answer that carries the
// lock's content (`withContent`), which costs four times the gas of any other.
// `workchain` is the chain of the account the answer goes to. Where the request names that account (the
// NFT, the `dest` of a TEP-85 request), the handler has held it to the basechain or the masterchain
// (reachableWorkchain). Where the answer goes to the asker (GetStaticData, RequestLockState), it is the
// sender's own chain, whatever it is: an asker is never refused for its chain. calculateForwardFee takes
// the basechain's prices (ConfigParam 25) for workchain 0 and the masterchain's (ConfigParam 24) for any
// other, as the lock prices every account it sends to.
// For the two TEP-85 requests the carriage of the payload their answer passes on is added, at those same
// prices and bounded as a claim's is (payloadCarriage; `payload` is null for the other three). A request
// with less is refused: its answer could not leave, and its GRAM would stay here.
fun answerCost(workchain: int, withContent: bool, payload: cell?): coins {
    return calculateGasFee(BASECHAIN, withContent ? LOCK_GAS_ANSWER_CONTENT : LOCK_GAS_ANSWER) +
        answerMessageFeeOn(workchain) +
        payloadCarriage(workchain, payload, 1);
}

// Forward fee of what the owner adds to a claim (a jetton transfer's forward payload, a payout's comment),
// carried `hops` times at the prices of `workchain`, and the gas of measuring it. A payload of more than
// MAX_PAYLOAD_CELLS cells or MAX_PAYLOAD_BITS bits, or deeper than MAX_PAYLOAD_DEPTH, is refused with
// PayloadTooLarge: a message that carried it on could be more than the network takes, and the claim would
// then fail after its handler, or in a wallet further on. The depth is checked first: it is read from the
// cell, with nothing walked.
fun payloadCarriage(workchain: int, payload: cell?, hops: int): coins {
    if (payload == null) {
        return 0;
    }
    assert (payload.depth() <= MAX_PAYLOAD_DEPTH) throw LockErrors.PayloadTooLarge;
    val (cells, bits, _refs, fits) = payload.calculateSize(MAX_PAYLOAD_CELLS);
    assert (fits && bits! <= MAX_PAYLOAD_BITS) throw LockErrors.PayloadTooLarge;
    return hops * calculateForwardFee(workchain, bits!, cells!) +
        calculateGasFee(BASECHAIN, cells! * GAS_PER_PAYLOAD_CELL);
}

// Storage fee due when a message quoted now lands, which that message pays first: what accrued since the
// last save with nothing due (a debt left by a bounceable message included), plus QUOTE_MARGIN for the
// message's way here. The network charges each stretch of that time at the price then in force, which a get
// method cannot know: it is counted at the higher of the live price and the floor price, for a lock of that
// size (`bits`, `cells`). That is an upper bound unless the price stood above both and was cut since; a
// message sent at such a quote is refused, its value comes back, and the next quote is right, the refused
// message having settled the storage.
fun storageDebtBound(lastTx: int, bits: int, cells: int): coins {
    return storageBound(max(blockchain.now() - lastTx, 0) + QUOTE_MARGIN, bits, cells);
}

// What the network charges an account of that size for `seconds` of storage at most: at the higher of the
// live price and the floor price. A lock passes the size its kind is priced at.
fun storageBound(seconds: int, bits: int, cells: int): coins {
    return max(
        calculateStorageFee(BASECHAIN, seconds, bits, cells),
        floorStorageFee(BASECHAIN, seconds, bits, cells),
    );
}

// ============== Get methods ==============
// A lock of jettons and a lock of GRAM answer get_nft_data, get_lock_data, get_custody_data,
// get_lock_terms, get_unlocked_at, get_claimable and get_sworn_version in the same shapes; the quotes of
// their costs follow their own messages. Each contract's file declares its get methods (a contract's
// entrypoints stay in its own file). A get method that reads the lock returns what a `view` function of its
// core computes; one whose answer is a cost of sworn.tolk or of this file (answerCost) as it stands returns
// that cost.
//
// One rule where no lock was created (the address was deployed, and InitLock or InitGramLock has not come):
// every get method answers for the empty address. That is the three `...BeforeInit` views below, an empty
// cell for the terms, nothing unlocked or claimable, and 0 for every cost: no message is priced there but
// the creation, which the root quotes (get_create_cost, get_gram_create_cost).

// What get_lock_data returns. The master, the wallet and the free balance are of a lock of jettons: none,
// none and 0 in a lock of GRAM.
struct LockInfo {
    status: int         // STATUS_*, or STATUS_NOT_INITIALIZED
    index: int
    collection: address // the root
    owner: address?
    jettonMaster: address?
    jettonWallet: address?
    creator: address?
    createdAt: int
    cliff: int
    end: int
    step: int
    initialBps: int
    permanent: bool
    // locked under the schedule, claimed or not (0 unless funded); in a lock of GRAM what the schedule has
    // paid out and what the lock still holds for it
    totalAmount: int
    expectedAmount: int // what the creator is to send, while the lock awaits its setup (0 after)
    claimed: int
    freeBalance: int    // claimable at any time
    claimableNow: int
    topUpFlatFee: int   // fee rates of this lock (0 until attested)
    feeBps: int
    version: int
    lastDepositLt: int  // logical time of the latest deposit's transaction (0 until funded)
    createBefore: int   // from the terms (0 where no lock was created)
}

// What get_custody_data returns: what the lock holds and owes besides its schedule, and how its creation
// went. feeOwed, setupExtra, sweepFrom, recoverFrom and walletPaidUntil are of a lock of jettons: always 0
// in a lock of GRAM.
struct CustodyInfo {
    till: address?
    feesAttested: bool
    pendingAmount: int   // funding held during the setup, or a refund still owed after a cancel
    feeOwed: int         // fee tokens whose transfer bounced (RetryFee)
    flatFee: int         // attested flat fee (0 until attested)
    setupExtra: int      // deposits during setup that could not be sent back
    setupDeadline: int   // the funding completes only until then (0 where no lock was created)
    cancelReason: int    // CANCEL_* once cancelled, 0 otherwise
    // a Sweep and a SweepGram wait until then for the latest fee transfer to settle (0: no wait)
    sweepFrom: int
    // in a cancelled lock, anyone but the creator waits until then to recover what no record counts in the
    // lock's wallet: the latest refund transfer may still bounce back (0: no wait)
    recoverFrom: int
    walletPaidUntil: int // the jetton wallet's storage is paid until then (0 until funded)
}

// TEP-62 where no lock was created: `init?` false, the index and the collection the address was deployed
// with, no owner and no content
fun viewNftDataBeforeInit(): (bool, int, address, address?, cell) {
    val init = LockInitData.fromCell(contract.getData());
    return (false, init.index, init.collection, null, beginCell().endCell());
}

fun viewLockDataBeforeInit(): LockInfo {
    val init = LockInitData.fromCell(contract.getData());
    return {
        status: STATUS_NOT_INITIALIZED,
        index: init.index,
        collection: init.collection,
        owner: null,
        jettonMaster: null,
        jettonWallet: null,
        creator: null,
        createdAt: 0,
        cliff: 0,
        end: 0,
        step: 0,
        initialBps: 0,
        permanent: false,
        totalAmount: 0,
        expectedAmount: 0,
        claimed: 0,
        freeBalance: 0,
        claimableNow: 0,
        topUpFlatFee: 0,
        feeBps: 0,
        version: SWORN_VERSION,
        lastDepositLt: 0,
        createBefore: 0,
    };
}

fun viewCustodyDataBeforeInit(): CustodyInfo {
    return {
        till: null,
        feesAttested: false,
        pendingAmount: 0,
        feeOwed: 0,
        flatFee: 0,
        setupExtra: 0,
        setupDeadline: 0,
        cancelReason: 0,
        sweepFrom: 0,
        recoverFrom: 0,
        walletPaidUntil: 0,
    };
}
