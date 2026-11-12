tolk 1.5

import "@stdlib/gas-payments"
import "messages"
import "sworn"
import "till-code-hash"

// Sworn lock item: an NFT (TEP-62) that is also the vault holding the locked jettons, and the only
// contract with per-lock state. It is its own creation record and its own refund record.
//
// Trust model:
// - Address = hash(code, {root, index}) with index = hash(terms): only the creator the terms name can
//   deploy a lock, only with the terms its index commits to, and only before the terms' createBefore.
//   The root never sends it anything.
// - Of a jetton it uses only what TEP-74 describes, and TEP-74 gives a contract no way to ask a master
//   which wallet is whose: its jetton wallet is the creator's word (InitLock), taken from the master's
//   get_wallet_address. The lock cannot tell a false word; whoever relies on a lock can: a lock shows
//   tokens only if get_wallet_address(lock) == jettonWallet (SPEC.md 3.5). Nobody but that creator can
//   name it, and real tokens are never credited by a lock with another wallet: they go back.
// - Locked amounts come only from transfer_notifications sent by that wallet. Only the owner and the
//   creator can add to the schedule.
// - Fees go to the lock's till (root-derived) at the rates the till attested during setup; the flat
//   fee travels on its own, never through jetton code.
// - Nobody but the owner can move tokens, and only as the schedule allows. No admin, no upgrade.
// - Handlers pay for their messages and events from the incoming value; the balance is the
//   storage prepayment and is never spent on someone's request. During setup the balance also
//   holds the creator's budget, which the setup steps spend and the funding returns.

const ERROR_NOT_OWNER = 402;
const ERROR_NOT_FUNDED = 403;
const ERROR_NOTHING_TO_CLAIM = 405;
const ERROR_AMOUNT_TOO_HIGH = 406;
const ERROR_INSUFFICIENT_VALUE = 407;
const ERROR_INVALID_EXTENSION = 408;
const ERROR_SOULBOUND = 409;
const ERROR_WRONG_WORKCHAIN = 410;
const ERROR_FORBIDDEN_WALLET = 411;
const ERROR_NOT_SUPPORTED = 412;
const ERROR_BAD_STATUS = 414;
const ERROR_NOT_FINISHED = 415;
const ERROR_BAD_TERMS = 416;
const ERROR_BAD_TILL_CODE = 417;
const ERROR_TOO_EARLY = 419;
const ERROR_NOT_CREATOR = 420;
const ERROR_NOTHING_OWED = 422;
const ERROR_CREATE_EXPIRED = 423;
const ERROR_FEE_UNSETTLED = 426;
const ERROR_MISSING_FORWARD_PAYLOAD = 708;  // the code of the TEP-62 reference item
const ERROR_UNKNOWN_OP = 0xFFFF;

// What measuring a Claim's forward payload costs per cell
const GAS_PER_PAYLOAD_CELL = 135;

// Status reported by the getters of an address that was deployed but never initialized
const STATUS_NOT_INITIALIZED = 255;

// Reasons of LockCancelledEvent
const CANCEL_TILL_REFUSED = 3;      // creation disabled, or fees above the creator's maxima
const CANCEL_REQUESTED = 4;         // CancelCreation by the creator
const CANCEL_EXPIRED = 5;           // the last setup event came after SETUP_WINDOW, or anyone's CancelCreation after it
const CANCEL_BUDGET = 6;            // the budget no longer covered the funding (prices rose meanwhile)
const CANCEL_SCHEDULE = 7;          // its schedule had ended, or could never start, when InitLock came

// queryId flags of the lock's own jetton transfers, so a bounce tells which record to restore:
// UNCREDITED (sweeps, send-backs of finished or cancelled locks, recoveries): nothing; PENDING: the
// pending funding (cancelled locks only); FEE: feeOwed (funded locks only); SENDBACK: a deposit the
// lock sent back, free balance like a gift; none: a claim, back to the free balance. Every
// user-supplied queryId is masked to 59 bits before a flag is added, so no caller can make a bounce
// restore a record. The GRAM a bounce brings back goes to the bounced message's response
// destination, which is always whoever paid for it (the lock asks for rich bounces).
const QID_UNCREDITED = 1 << 63;
const QID_PENDING = 1 << 62;
const QID_FEE = 1 << 61;
const QID_SENDBACK = 1 << 60;
const QID_USER_MASK = (1 << 59) - 1;

// Every bounceable message of the lock bounces with its whole root cell (the response destination
// is in it); none needs its refs back
const LOCK_BOUNCE = BounceMode.RichBounceOnlyRootCell;

// The empty body of a plain GRAM transfer (a jetton wallet's storage top-up). Non-bounceable, so the
// value stays on that account whatever its code makes of it: nothing here relies on a jetton's code.
struct PlainGram {
}

// Fields of the incoming message (InMessage cannot be passed around as an object)
struct LockIncoming {
    sender: address
    value: coins
    fwdFee: coins
    body: slice
}

struct LockBalances {
    totalAmount: coins          // locked by the schedule (0 until funded)
    claimed: coins              // scheduled tokens already claimed
    freeBalance: coins          // claimable at any time (direct deposits, bounced claims)
    lastDepositLt: uint64       // logical time of the transaction of the latest deposit (the funding or
                                // a top-up): each deposit's event names the previous one, so the list
                                // of deposits is read in O(deposits) whatever else the lock received
}

// The creation record and refund record. Fixed size: one slot, one payer.
struct LockSetup {
    till: address               // till (index mod TILL_COUNT), derived at init
    termsAttested: bool         // the till attested fees within the creator's maxima
    pendingAmount: coins        // funding received through the lock's wallet, not yet credited or refunded
    setupExtra: coins           // other deposits through it during setup that could not be sent back:
                                // free balance once funded, the creator's if cancelled
    feeOwed: coins              // fee tokens whose transfer to the till bounced
    cancelReason: uint8         // CANCEL_* once cancelled (0 otherwise): readable without the history
    feeSentAt: uint48           // the latest fee-token transfer to the till: a Sweep waits FEE_SETTLE
                                // after it, since it may still bounce back
    walletSeq: uint32           // the recoveries, through the lock's wallet, of what no record counts in a
                                // cancelled lock: only they can take what a refund left there, so a refund's
                                // bounce restores the record only if it carries the latest (none went out
                                // after it)
    refundSentAt: uint48        // the latest refund transfer through the lock's wallet (0: none): nobody but
                                // the creator makes such a recovery within FEE_SETTLE of it, while it may
                                // still bounce back
}

// Everything that can change after init (the terms cell is immutable, hashed into the index)
struct LockLive {
    jettonWallet: address       // the creator's word (InitLock), see the trust model
    createdAt: uint48
    permanent: bool
    schedule: Schedule          // zeros for permanent locks
    feeBps: uint16              // fee rates fixed at setup from the till's attestation
    flatFee: coins
    topUpFlatFee: coins
    walletPaidUntil: uint48     // the jetton wallet's storage is paid until then (0 until funded): every
                                // longer life pays it from there on, a permanent lock's renewal too
    setup: Cell<LockSetup>
}

struct LockStorage {
    collection: address
    index: uint256
    status: uint8
    owner: address
    lastTx: uint48              // last time the state was saved with no storage fee due: the storage due
                                // now is at most what accrued since then (the quotes count from it)
    balances: Cell<LockBalances>
    terms: Cell<LockTerms>
    live: Cell<LockLive>
}

@noinline
fun LockStorage.load(): LockStorage {
    return LockStorage.fromCell(contract.getData());
}

@noinline
fun LockStorage.save(self) {
    var s = self;
    // while a debt is still due (a bounceable message leaves it to the next one), the storage it is for
    // accrued since the last save without one: the quotes must keep counting from there
    if (contract.getStorageDuePayment() == 0) {
        s.lastTx = blockchain.now();
    }
    contract.setData(s.toCell());
}

fun isInitialized(): bool {
    // initial data is collection (267) + index (256)
    return contract.getData().beginParse().remainingBitsCount() > 267 + 256;
}

// queryId of the lock's own requests and transfers: the low bits of the index, clear of the flags
@inline
fun queryIdOf(index: int): uint64 {
    return index & QID_USER_MASK;
}

// A caller's queryId with flags: the caller's bits never reach the flag positions
@inline
fun flagged(queryId: int, flags: int): uint64 {
    return (queryId & QID_USER_MASK) | flags;
}

// queryId of a transfer of the refund a cancelled lock owes: the flag and the lock's walletSeq when it
// went out, which its bounce must match to restore the record. Refund transfers do not move the sequence:
// each takes its own share of the record, so one refused is restored whatever the others did.
const WALLET_SEQ_MASK = (1 << 32) - 1;

@inline
fun pendingQueryId(walletSeq: int): uint64 {
    return QID_PENDING | walletSeq;
}

@inline
fun nextWalletSeq(walletSeq: int): int {
    return (walletSeq + 1) & WALLET_SEQ_MASK;
}

@noinline
fun LockStorage.creator(self): address {
    return self.terms.load().parties.load().creator;
}

// Accounts a lock never pays out to or hands itself to: none of them can ever move what it gets (the
// till would take tokens for fees; a jetton wallet owned by a jetton wallet is unreachable). The SDK
// refuses the other tills too.
fun LockStorage.isForbiddenRecipient(self, live: LockLive, setup: LockSetup, a: address): bool {
    return a == self.collection || a == setup.till || a == contract.getAddress() || a == live.jettonWallet;
}

// ============== Events ==============

struct (0x4c6b4352) LockCreatedEvent {
    index: uint256
    jettonWallet: address
    terms: Cell<LockTerms>
}

struct (0x4c6b4655) LockFundedEvent {
    index: uint256
    amount: coins
    fee: coins
}

// prevDepositLt: logical time of the previous deposit's transaction (the funding or a top-up)
struct (0x4c6b5433) LockToppedUpEvent {
    index: uint256
    amount: coins
    fee: coins
    from: address
    prevDepositLt: uint64
}

struct (0x4c6b434c) LockClaimedEvent {
    index: uint256
    queryId: uint64
    amount: coins
    destination: address
}

struct (0x4c6b5357) LockSweptEvent {
    index: uint256
    amount: coins
    destination: address
}

struct (0x4c6b4558) LockExtendedEvent {
    index: uint256
    permanent: bool
    schedule: Schedule
}

struct (0x4c6b4344) LockCancelledEvent {
    index: uint256
    reason: uint8
}

// A claim the lock's wallet refused was credited back to the free balance (LockClaimed overstated)
struct (0x4c6b5253) LockClaimRestoredEvent {
    index: uint256
    amount: coins
}

fun emitEvent<T>(body: T) {
    createExternalLogMessage({
        dest: createAddressNone(),
        body: body
    }).send(SEND_MODE_REGULAR);
}

// Everything sent after this comes from the incoming value; the balance the lock had before the
// message (its storage prepayment) stays. Events must be emitted before it.
fun keepOwnBalance(extra: coins) {
    reserveToncoinsOnBalance(extra, RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE);
}

// ============== Accounting ==============

fun LockStorage.scheduledClaimable(self, bal: LockBalances, live: LockLive, now: int): int {
    if (self.status != STATUS_FUNDED || live.permanent) {
        return 0;
    }
    val unlocked = live.schedule.unlockedAt(bal.totalAmount, now);
    return max(unlocked - bal.claimed, 0);
}

fun LockStorage.claimable(self, bal: LockBalances, live: LockLive, now: int): int {
    return bal.freeBalance + self.scheduledClaimable(bal, live, now);
}

// Nothing is locked any more: everything in the wallet belongs to the owner
fun LockStorage.isFinished(self, live: LockLive, now: int): bool {
    if (self.status == STATUS_CANCELLED) {
        return true;
    }
    return self.status == STATUS_FUNDED && !live.permanent && now >= live.schedule.end;
}

// A sweep no longer waits for fee tokens this long after the lock's end
fun LockLive.feeGivenUp(self, now: int): bool {
    return !self.permanent && now >= self.schedule.end + FEE_GIVE_UP;
}

// A top-up adds to the schedule only while the lock is funded and not finished
fun LockStorage.acceptsTopUp(self, live: LockLive, now: int): bool {
    return self.status == STATUS_FUNDED && (live.permanent || now < live.schedule.end);
}

// A Claim through the lock's wallet (of that workchain): the handler, the event, the transfer
fun claimMinValue(walletWorkchain: int, forwardTonAmount: coins): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_CLAIM) + jettonTransferValueOn(walletWorkchain) + forwardTonAmount
        + smallMessageFee() + messageFeeOn(walletWorkchain);
}

// A Sweep of a lock still owing fee tokens to its till pays that transfer first, on its own (the
// sweep itself follows once it has settled)
@noinline
fun sweepMinValue(walletWorkchain: int, feeOwed: coins): coins {
    val base = calculateGasFee(BASECHAIN, LOCK_GAS_SWEEP) + jettonTransferValueOn(walletWorkchain)
        + smallMessageFee() + messageFeeOn(walletWorkchain);
    if (feeOwed > 0) {
        return base + tillReceiptForward(walletWorkchain);
    }
    return base;
}

// Forward fee of the owner's forward payload, carried three times (lock to wallet, wallet to wallet,
// wallet to recipient) at the prices of the wallet's chain, and the gas of measuring it
fun payloadForwardFee(walletWorkchain: int, payload: cell?): coins {
    if (payload == null) {
        return 0;
    }
    val (cells, bits, refs) = payload!!.calculateSizeStrict(8192);
    return 3 * calculateForwardFee(walletWorkchain, bits, cells) + calculateGasFee(BASECHAIN, cells * GAS_PER_PAYLOAD_CELL);
}

// GRAM an Extend must bring: the storage prepayment for the longer life of the lock, its jetton wallet's
// storage from where it is paid until to the end of that life (on the wallet's chain), plus the handler.
// `margin`: for a quote, how much later the message may land (a permanent lock's life runs from then).
// Returns the lock's extra, the wallet's extra, until when the wallet is then paid, and the total.
fun extendCost(live: LockLive, permanent: bool, end: int, now: int, balance: coins, margin: int): (coins, coins, int, coins) {
    val extraLock = max(lockStoragePrepay(permanent, end, now) - balance, 0);
    val paidUntil = storageEnd(permanent, end, now + margin);
    val from = max(live.walletPaidUntil, now);
    var extraWallet: coins = 0;
    if (paidUntil > from) {
        // with the gas the wallet spends to take it in, so that what it keeps is the storage
        val walletWorkchain = live.jettonWallet.getWorkchain();
        extraWallet = walletStorageExtra(walletWorkchain, paidUntil - from) + calculateGasFee(walletWorkchain, WALLET_PLAIN_GAS);
    }
    val total =extraLock + extraWallet + calculateGasFee(BASECHAIN, LOCK_GAS_EXTEND) + 2 * smallMessageFee() + messageFeeTo(live.jettonWallet);
    return (extraLock, extraWallet, max(paidUntil, live.walletPaidUntil), total);
}

// What the lock holds of its own right now: the balance at the start of the transaction, net of a
// storage fee still due (the next transaction takes it out first) and of the incoming value
fun ownBalance(incoming: coins): int {
    return contract.getOriginalBalance() - contract.getStorageDuePayment() - incoming;
}

// GRAM this handler may spend from the balance on top of what it must keep (`reserve`): the
// balance at the start of the transaction, minus a storage fee still due, minus the handler's own
// gas, minus the reserve. Guards every send from the balance so an action can never fail and revert
// a recorded state.
fun spendableAbove(reserve: coins, gasBudget: int): int {
    return ownBalance(0) - calculateGasFee(BASECHAIN, gasBudget) - reserve;
}

@noinline
fun sendJettonTransfer(wallet: address, queryId: uint64, amount: coins, destination: address,
                       responseDestination: address, forwardTonAmount: coins,
                       forwardPayload: RemainingBitsAndRefs, value: coins, mode: int) {
    createMessage({
        bounce: LOCK_BOUNCE,
        dest: wallet,
        value: value,
        body: JettonTransfer {
            queryId: queryId,
            amount: amount,
            destination: destination,
            responseDestination: responseDestination,
            customPayload: null,
            forwardTonAmount: forwardTonAmount,
            forwardPayload: forwardPayload
        }
    }).send(mode);
}

// Fee tokens to the till, with its receipt's GRAM and the tag naming this lock (a bounce restores feeOwed)
@noinline
fun sendFeeTokens(wallet: address, index: int, amount: coins, till: address, response: address, master: address, kind: int,
                  value: coins, mode: int) {
    sendJettonTransfer(wallet, QID_FEE | queryIdOf(index), amount, till, response, tillReceiptForward(wallet.getWorkchain()),
                       refPayload(FeeTag { index: index, master: master, kind: kind }.toCell()), value, mode);
}

// Tokens sent back through the wallet that reported them, to whoever it says sent them, from the
// notification's value. Non-bounceable and never credited: if that wallet is fake, nothing happens;
// if it is real, the tokens stay there to recover should the transfer fail.
fun sendBackUncredited(in: LockIncoming, msg: TransferNotification) {
    val previousOwner = msg.sender;
    val workchain = in.sender.getWorkchain();
    if (previousOwner != null && in.value >= lockRefundCost(workchain)) {
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: in.sender,
            value: 0,
            body: JettonTransfer {
                queryId: flagged(msg.queryId, QID_UNCREDITED),
                amount: msg.amount,
                destination: previousOwner!!,
                responseDestination: previousOwner!!,
                customPayload: null,
                forwardTonAmount: sendBackForward(in.value, workchain),
                forwardPayload: emptyForwardPayload()
            }
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
    }
}

fun askTillForTerms(till: address, index: int, value: coins, mode: int) {
    createMessage({
        bounce: LOCK_BOUNCE,
        dest: till,
        value: value,
        body: AttestTerms { queryId: queryIdOf(index) }
    }).send(mode);
}

fun sendFeeNotice(till: address, index: int, master: address, kind: int, value: coins, mode: int) {
    createMessage({
        bounce: BounceMode.NoBounce,
        dest: till,
        value: value,
        body: FeeNotice { queryId: queryIdOf(index), index: index, master: master, kind: kind }
    }).send(mode | SEND_MODE_IGNORE_ERRORS);
}

@noinline
fun returnExcess(destination: address, queryId: uint64, mode: int) {
    createMessage({
        bounce: BounceMode.NoBounce,
        dest: destination,
        value: 0,
        body: Excesses { queryId: queryId }
    }).send(mode | SEND_MODE_IGNORE_ERRORS);
}

// ============== Init ==============

fun handleInit(in: LockIncoming, soulbound: bool) {
    val init = LockInitData.fromCell(contract.getData());
    val msg = InitLock.fromSlice(in.body);
    val terms = msg.terms.load();
    val now = blockchain.now();

    // The content is authenticated by the hash, not the sender: these terms are the only ones
    // that can ever initialize this address
    assert((msg.terms.hash() & ~1) == (init.index & ~1)) throw ERROR_BAD_TERMS;
    assert(terms.soulbound == soulbound && isSoulboundIndex(init.index) == soulbound) throw ERROR_BAD_TERMS;
    assert(terms.version == SWORN_VERSION) throw ERROR_BAD_TERMS;
    assert(terms.expectedAmount > 0) throw ERROR_BAD_TERMS;
    // ... and only by createBefore, itself close to now: once it has passed, this address can never
    // be initialized again, not even after a deletion for storage debt decades later
    assert(now <= terms.createBefore && terms.createBefore <= now + MAX_CREATE_AHEAD) throw ERROR_CREATE_EXPIRED;
    assert(msg.tillCode.hash() == TILL_CODE_HASH) throw ERROR_BAD_TILL_CODE;
    // One meaning, one index: the terms must be in their canonical encoding (no padding, no stray refs)
    assert(terms.toCell().hash() == msg.terms.hash()) throw ERROR_BAD_TERMS;
    val parties = terms.parties.load();
    assert(parties.toCell().hash() == terms.parties.hash()) throw ERROR_BAD_TERMS;
    // The jetton wallet below is not in the hash: only the creator's word counts
    assert(in.sender == parties.creator) throw ERROR_NOT_CREATOR;
    // refunds and payouts go to standard wallets, which refuse other workchains
    assert(parties.owner.getWorkchain() == BASECHAIN && parties.creator.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
    // A schedule that has ended, or can never start, locks nothing. But tokens may already wait in this
    // address's jetton wallet (a wallet short of GRAM can skip InitLock and still send them; a wallet can
    // refuse to send them back) and only this lock can ever move them: so it starts cancelled, at no fee
    // and without its till, and they are the creator's to recover until createBefore.
    val startable = terms.permanent ? terms.schedule.isZero() : terms.schedule.isValidForCreation(now);
    // the jetton wallet's part priced on the chain it lives on (where its master puts it)
    val cost = startable ? createCost(terms.maxFlatFee, terms.permanent, terms.schedule.end, now, msg.jettonWallet.getWorkchain())
                         : unstartableCost();
    assert(in.value >= cost) throw ERROR_INSUFFICIENT_VALUE;

    val till = tillDeployAddress(msg.tillCode, init.collection, init.index % TILL_COUNT).calculateAddress();
    // neither party may be an account that can never send a message to the lock
    assert(parties.owner != init.collection && parties.owner != till && parties.owner != msg.jettonWallet) throw ERROR_FORBIDDEN_WALLET;
    assert(parties.creator != init.collection && parties.creator != till && parties.creator != msg.jettonWallet) throw ERROR_FORBIDDEN_WALLET;
    var storage = LockStorage {
        collection: init.collection,
        index: init.index,
        status: STATUS_AWAITING_SETUP,
        owner: parties.owner,
        lastTx: now,
        balances: LockBalances { totalAmount: 0, claimed: 0, freeBalance: 0, lastDepositLt: 0 }.toCell(),
        terms: msg.terms,
        live: LockLive {
            jettonWallet: msg.jettonWallet,
            createdAt: now,
            permanent: terms.permanent,
            schedule: terms.schedule,
            feeBps: 0,
            flatFee: 0,
            topUpFlatFee: 0,
            walletPaidUntil: 0,
            setup: LockSetup {
                till: till,
                termsAttested: false,
                pendingAmount: 0,
                setupExtra: 0,
                feeOwed: 0,
                cancelReason: 0,
                feeSentAt: 0,
                walletSeq: 0,
                refundSentAt: 0
            }.toCell()
        }.toCell()
    };
    emitEvent(LockCreatedEvent { index: init.index, jettonWallet: msg.jettonWallet, terms: msg.terms });
    if (!startable) {
        val live = storage.live.load();
        storage.cancel(live, live.setup.load(), CANCEL_SCHEDULE, LOCK_GAS_INIT + LOCK_GAS_CANCEL, null, 0);
        return;
    }
    storage.save();

    // The setup request; everything else (storage prepayments, flat fee, fee transfer) stays here as
    // the budget until the funding completes or the creation is cancelled
    askTillForTerms(till, init.index, attestValue(), SEND_MODE_PAY_FEES_SEPARATELY);
}

// ============== Setup ==============

// Saves the setup, and funds the lock once the two setup events are in: the till attested the fees
// and the creator's tokens arrived through the lock's wallet. It funds only within SETUP_WINDOW and
// while the budget covers everything the funding pays (prices can rise meanwhile); otherwise the
// creation is cancelled and everything goes back to the creator. Called last by its handler, which
// raised its gas limit to LOCK_GAS_SETUP_STEP (on the budget).
fun LockStorage.advanceSetup(mutate self, live: LockLive, setup: LockSetup) {
    if (!setup.termsAttested || setup.pendingAmount == 0) {
        var l = live;
        l.setup = setup.toCell();
        self.live = l.toCell();
        self.save();
        return;
    }
    setGasLimit(LOCK_GAS_COMPLETE);
    if (blockchain.now() > live.createdAt + SETUP_WINDOW) {
        self.cancel(live, setup, CANCEL_EXPIRED, LOCK_GAS_COMPLETE, null, 0);
        return;
    }
    val terms = self.terms.load();
    val creator = terms.parties.load().creator;
    val gross = setup.pendingAmount;
    val fee = mulDivFloor(gross, live.feeBps, BPS_DENOMINATOR);
    val walletWorkchain = live.jettonWallet.getWorkchain();
    val prepay = lockStoragePrepay(live.permanent, live.schedule.end, live.createdAt);
    val walletPrepay = walletStoragePrepay(walletWorkchain, storageHorizon(live.permanent, live.schedule.end, live.createdAt));
    if (spendableAbove(prepay, LOCK_GAS_COMPLETE) < fundingNeeds(walletPrepay, live.flatFee, fee > 0, walletWorkchain)) {
        self.cancel(live, setup, CANCEL_BUDGET, LOCK_GAS_COMPLETE, null, 0);
        return;
    }

    var s = setup;
    val extra = s.setupExtra;
    s.pendingAmount = 0;
    s.setupExtra = 0;
    if (fee > 0) {
        s.feeSentAt = blockchain.now();
    }
    var l = live;
    l.walletPaidUntil = storageEnd(live.permanent, live.schedule.end, live.createdAt);
    l.setup = s.toCell();
    self.live = l.toCell();
    self.status = STATUS_FUNDED;
    self.balances = LockBalances {
        totalAmount: gross - fee,
        claimed: 0,
        freeBalance: extra,
        lastDepositLt: blockchain.logicalTime()
    }.toCell();
    self.save();
    emitEvent(LockFundedEvent { index: self.index, amount: gross - fee, fee: fee });

    // The jetton wallet's storage for the lock's life, now that the lock holds tokens there.
    // Non-bounceable: the value stays on that address even if the wallet is not deployed yet.
    createMessage({
        bounce: BounceMode.NoBounce,
        dest: live.jettonWallet,
        value: walletPrepay,
        body: PlainGram {}
    }).send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
    // The flat fee goes straight to the till, with a receipt so the till's events list every funded
    // lock; the fee tokens follow through the jetton wallets (a bounce leaves them owed: RetryFee)
    sendFeeNotice(s.till, self.index, terms.jettonMaster, FEE_KIND_FUNDING, live.flatFee + tillReceiptValue(), SEND_MODE_PAY_FEES_SEPARATELY);
    if (fee > 0) {
        sendFeeTokens(live.jettonWallet, self.index, fee, s.till, creator, terms.jettonMaster, FEE_KIND_FUNDING,
                      jettonTransferValueOn(walletWorkchain) + tillReceiptForward(walletWorkchain), SEND_MODE_PAY_FEES_SEPARATELY);
    }

    // Keep the storage prepayment; what is left of the budget goes back to the creator
    reserveToncoinsOnBalance(prepay, RESERVE_MODE_AT_MOST);
    returnExcess(creator, queryIdOf(self.index), SEND_MODE_CARRY_ALL_BALANCE);
}

// A creation failed: the pending funding (if any) goes back to the creator through the wallet it
// came in by, the setup GRAM goes back to the creator, and the lock keeps a little life. A refund
// that bounces stays owed (RetryRefund). Deposits that could not be sent back during the setup stay
// in the wallet unrecorded, the creator's (RecoverUnrecorded). A `helper` who paid for
// this cancel (someone else than the creator) pays only for it: the rest of its value comes back to
// it, the refund transfer's excess included.
fun LockStorage.cancel(mutate self, live: LockLive, setup: LockSetup, reason: int, gasBudget: int,
                       helper: address?, helperValue: coins) {
    val creator = self.creator();
    self.status = STATUS_CANCELLED;
    emitEvent(LockCancelledEvent { index: self.index, reason: reason });

    val reserve = cancelledStorageReserve();
    // the event is paid from the balance too
    val rest = spendableAbove(reserve, gasBudget) - smallMessageFee();
    var s = setup;
    s.setupExtra = 0;
    s.cancelReason = reason;
    var response = creator;
    var helperBack: int = helperValue - calculateGasFee(BASECHAIN, gasBudget) - 2 * smallMessageFee();
    if (helper != null) {
        response = helper!!;
    }
    val refundValue = jettonTransferValueTo(live.jettonWallet);
    if (s.pendingAmount > 0 && rest >= refundValue + messageFeeTo(live.jettonWallet)) {
        // the slot is emptied by the transfer and restored by its bounce (RetryRefund resends)
        s.refundSentAt = blockchain.now();
        sendJettonTransfer(live.jettonWallet, pendingQueryId(s.walletSeq), s.pendingAmount, creator, response, 0,
                           emptyForwardPayload(), refundValue, SEND_MODE_PAY_FEES_SEPARATELY);
        s.pendingAmount = 0;
        helperBack -= refundValue + messageFeeTo(live.jettonWallet);
    }
    var l = live;
    l.setup = s.toCell();
    self.live = l.toCell();
    self.save();

    if (helper != null && helperBack > 0) {
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: helper!!,
            value: helperBack,
            body: Excesses { queryId: queryIdOf(self.index) }
        }).send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
    }
    reserveToncoinsOnBalance(reserve, RESERVE_MODE_AT_MOST);
    returnExcess(creator, queryIdOf(self.index), SEND_MODE_CARRY_ALL_BALANCE);
}

@noinline
fun LockStorage.onTermsAttested(mutate self, in: LockIncoming, msg: TermsAttested) {
    var live = self.live.load();
    var setup = live.setup.load();
    if (in.sender != setup.till || self.status != STATUS_AWAITING_SETUP || setup.termsAttested
        || msg.queryId != queryIdOf(self.index)) {
        return;
    }
    // The answer carries whatever the till left of the request's value; this handler's gas is
    // budgeted in the lock's own balance
    setGasLimit(LOCK_GAS_SETUP_STEP);
    val terms = self.terms.load();
    // the caps are checked here too, so neither the root nor a till can raise a fee above them
    if (!msg.enabled
        || msg.flatFee > terms.maxFlatFee || msg.feeBps > terms.maxFeeBps || msg.topUpFlatFee > terms.maxTopUpFlatFee
        || msg.flatFee > MAX_FLAT_FEE || msg.topUpFlatFee > MAX_FLAT_FEE || msg.feeBps > MAX_FEE_BPS) {
        setGasLimit(LOCK_GAS_COMPLETE);
        self.cancel(live, setup, CANCEL_TILL_REFUSED, LOCK_GAS_COMPLETE, null, 0);
        return;
    }
    live.flatFee = msg.flatFee;
    live.topUpFlatFee = msg.topUpFlatFee;
    live.feeBps = msg.feeBps;
    setup.termsAttested = true;
    self.advanceSetup(live, setup);
}

// ============== Deposits ==============

fun LockStorage.onNotification(mutate self, in: LockIncoming, msg: TransferNotification, now: int) {
    var live = self.live.load();
    var setup = live.setup.load();

    if (in.sender != live.jettonWallet) {
        // Another jetton, or a wallet the creator did not name. This lock holds one jetton only: back
        // through the same wallet when the GRAM allows; otherwise they stay there, for the owner
        // (ClaimForeign), or the creator if the creation is cancelled (RecoverUnrecorded).
        sendBackUncredited(in, msg);
        return;
    }

    val previousOwner = msg.sender;
    if (self.status == STATUS_AWAITING_SETUP) {
        // The creator's funding through the lock's wallet fills the one slot, whatever its payload
        // (some wallets drop tags)
        if (setup.pendingAmount == 0 && msg.amount > 0 && previousOwner != null && previousOwner!! == self.creator()) {
            setGasLimit(LOCK_GAS_SETUP_STEP);  // may complete the funding: budgeted like the attestation
            setup.pendingAmount = msg.amount;
            self.advanceSetup(live, setup);
            return;
        }
        // Anything else through it (a second deposit, someone else's tokens) goes back to its sender
        // when the GRAM allows, and if that wallet refuses, or the GRAM does not allow, it is recorded:
        // free balance once the lock funds, the creator's if the creation is cancelled
        if (previousOwner != null && in.value >= lockRefundCost(in.sender.getWorkchain())) {
            self.sendBack(in, msg, live, now, true);
            return;
        }
        setup.setupExtra += msg.amount;
        live.setup = setup.toCell();
        self.live = live.toCell();
        self.save();
        return;
    }

    if (self.status == STATUS_CANCELLED) {
        // nothing can be locked here any more: back to the sender (its bounce is not credited:
        // whatever stays is the creator's to recover)
        if (previousOwner != null && in.value >= lockRefundCost(in.sender.getWorkchain())) {
            self.sendBack(in, msg, live, now, true);
        }
        return;
    }

    val (tag, _) = payloadOp(msg.forwardPayload);
    if (tag == 0x60f47ca2 && previousOwner != null) {
        self.onTopUp(in, msg, live, setup, now);
        return;
    }
    if (tag == 0x3671e1cc && previousOwner != null && in.value >= lockRefundCost(in.sender.getWorkchain())) {
        // The same creation sent twice: not a gift, back to its sender
        self.sendBack(in, msg, live, now, true);
        return;
    }
    // Direct deposit (or a gift): not locked, claimable at any time
    self.creditDeposit(live, msg.amount, now);
}

// A deposit that stays (a gift, or one that cannot even be sent back). Once the lock is finished nothing
// is recorded: a sweep takes whatever is there, and may already have taken what this notification is about.
fun LockStorage.creditDeposit(mutate self, live: LockLive, amount: coins, now: int) {
    if (!self.isFinished(live, now)) {
        self.creditFree(amount);
    }
}

// Tokens that stay in the wallet as free balance
@noinline
fun LockStorage.creditFree(mutate self, amount: coins) {
    var bal = self.balances.load();
    bal.freeBalance += amount;
    self.balances = bal.toCell();
    self.save();
}

// Tokens the lock does not take, back to their sender through its own wallet, from the
// notification's value, with a notification for the sender when the GRAM allows. A bounce makes
// them free balance (SENDBACK) while the lock is not finished (during its setup, once it funds);
// otherwise it is not credited (a sweep may have taken them; a cancelled lock's tokens are the creator's).
// Nor is it with `credit` false: what was meant to be locked never becomes claimable.
fun LockStorage.sendBack(self, in: LockIncoming, msg: TransferNotification, live: LockLive, now: int, credit: bool) {
    val qid = flagged(msg.queryId, credit && !self.isFinished(live, now) ? QID_SENDBACK : QID_UNCREDITED);
    val previousOwner = msg.sender!!;
    sendJettonTransfer(in.sender, qid, msg.amount, previousOwner, previousOwner, sendBackForward(in.value, in.sender.getWorkchain()),
                       emptyForwardPayload(), 0, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

// Tokens sent straight to the lock with a TopUpPayload by its owner or its creator: added to the
// same schedule, minus the fee rates fixed at setup. Anyone else's, or what the lock cannot take,
// goes back to the sender (free balance when there is not even GRAM to send it back).
fun LockStorage.onTopUp(mutate self, in: LockIncoming, msg: TransferNotification, live: LockLive, setup: LockSetup, now: int) {
    val from = msg.sender!!;
    val wallet = live.jettonWallet;
    val walletWorkchain = wallet.getWorkchain();
    val allowed = from == self.owner || from == self.creator();

    if (!allowed || !self.acceptsTopUp(live, now) || in.value < topUpCost(live.topUpFlatFee, walletWorkchain)) {
        // The owner's or the creator's own top-up was meant to be locked and must not become claimable: when
        // its value covers neither taking it nor returning it (prices rose on its way), or its way back is
        // refused, it is left out of the records, for the sweep at the end (in a permanent lock it stays)
        if (in.value >= lockRefundCost(walletWorkchain)) {
            self.sendBack(in, msg, live, now, !allowed);
        } else if (!allowed) {
            self.creditDeposit(live, msg.amount, now);  // cannot even be returned: claimable by the owner
        }
        return;
    }

    val fee = mulDivFloor(msg.amount, live.feeBps, BPS_DENOMINATOR);
    var bal = self.balances.load();
    val prevDepositLt = bal.lastDepositLt;
    bal.totalAmount += msg.amount - fee;
    bal.lastDepositLt = blockchain.logicalTime();
    self.balances = bal.toCell();
    // the fee transfer's time holds sweeps back until it has settled
    if (fee > 0) {
        var l = live;
        var su = setup;
        su.feeSentAt = now;
        l.setup = su.toCell();
        self.live = l.toCell();
    }
    self.save();
    emitEvent(LockToppedUpEvent { index: self.index, amount: msg.amount - fee, fee: fee, from: from, prevDepositLt: prevDepositLt });

    val master = self.terms.load().jettonMaster;
    keepOwnBalance(0);
    // the flat fee straight to the till; the fee tokens through the jetton wallets
    sendFeeNotice(setup.till, self.index, master, FEE_KIND_TOPUP, live.topUpFlatFee + tillReceiptValue(), SEND_MODE_PAY_FEES_SEPARATELY);
    if (fee > 0) {
        sendFeeTokens(wallet, self.index, fee, setup.till, from, master, FEE_KIND_TOPUP,
                      jettonTransferValueOn(walletWorkchain) + tillReceiptForward(walletWorkchain), SEND_MODE_PAY_FEES_SEPARATELY);
    }
    returnExcess(from, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
}

// ============== Main handler ==============

type LockMessage =
    | TermsAttested
    | TransferNotification
    | Claim
    | ExtendLock
    | ClaimForeign
    | ClaimForeignNft
    | Sweep
    | RetryFunding
    | RetryRefund
    | RetryFee
    | CancelCreation
    | RecoverUnrecorded
    | NftTransfer
    | GetStaticData
    | ProveOwnership
    | RequestOwner
    | Destroy
    | Revoke
    | StorageTopUp
    | RequestLockState
    | Excesses;

fun handleLockMessage(in: LockIncoming, soulbound: bool) {
    if (in.body.isEmpty()) {
        return;  // storage top-up
    }
    if (!isInitialized()) {
        if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == OP_TRANSFER_NOTIFICATION) {
            // Tokens sent to a lock that does not exist (yet): back through the same wallet
            sendBackUncredited(in, TransferNotification.fromSlice(in.body));
            return;
        }
        handleInit(in, soulbound);
        return;
    }

    val msg = lazy LockMessage.fromSlice(in.body);
    var storage = LockStorage.load();
    val now = blockchain.now();

    match (msg) {
        TermsAttested => {
            storage.onTermsAttested(in, msg);
        }

        TransferNotification => {
            storage.onNotification(in, msg, now);
        }

        Claim => {
            assert(in.sender == storage.owner) throw ERROR_NOT_OWNER;
            // nothing is the owner's while the lock is being set up or once it is cancelled
            assert(storage.status == STATUS_FUNDED) throw ERROR_NOT_FUNDED;
            val live = storage.live.load();
            val setup = live.setup.load();
            assert(msg.destination.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert(!storage.isForbiddenRecipient(live, setup, msg.destination)) throw ERROR_FORBIDDEN_WALLET;
            val walletWorkchain = live.jettonWallet.getWorkchain();
            assert(in.value >= claimMinValue(walletWorkchain, msg.forwardTonAmount) + payloadForwardFee(walletWorkchain, msg.forwardPayload)) throw ERROR_INSUFFICIENT_VALUE;

            var bal = storage.balances.load();
            val available = storage.claimable(bal, live, now);
            val amount: int = msg.amount == 0 ? available : (msg.amount as int);
            assert(amount > 0) throw ERROR_NOTHING_TO_CLAIM;
            assert(amount <= available) throw ERROR_AMOUNT_TOO_HIGH;

            // Free balance first, then scheduled tokens
            val fromFree = min(amount, bal.freeBalance);
            bal.freeBalance -= fromFree;
            bal.claimed += amount - fromFree;
            storage.balances = bal.toCell();
            storage.save();

            var response = storage.owner;
            if (msg.responseDestination != null && msg.responseDestination!!.getWorkchain() == BASECHAIN) {
                response = msg.responseDestination!!;
            }
            emitEvent(LockClaimedEvent {
                index: storage.index,
                queryId: msg.queryId,
                amount: amount,
                destination: msg.destination
            });
            keepOwnBalance(0);
            sendJettonTransfer(live.jettonWallet, msg.queryId & QID_USER_MASK, amount, msg.destination,
                               response, msg.forwardTonAmount, refPayload(msg.forwardPayload), 0, SEND_MODE_CARRY_ALL_BALANCE);
        }

        ExtendLock => {
            assert(in.sender == storage.owner) throw ERROR_NOT_OWNER;
            assert(storage.status == STATUS_FUNDED) throw ERROR_NOT_FUNDED;
            var live = storage.live.load();
            // A finished lock stays finished (its tokens may have been swept): relock = new lock
            assert(!live.permanent || msg.makePermanent) throw ERROR_INVALID_EXTENSION;
            assert(live.permanent || now < live.schedule.end) throw ERROR_INVALID_EXTENSION;
            var next = live.schedule;
            if (msg.makePermanent) {
                // a permanent lock has no schedule, whichever way it became permanent
                next = Schedule { cliff: 0, end: 0, step: 0, initialBps: 0 };
            } else {
                assert(live.schedule.isValidExtension(msg.schedule, now)) throw ERROR_INVALID_EXTENSION;
                next = msg.schedule;
            }
            // The longer life must come with its storage prepayment, the lock's and its wallet's. What the lock
            // holds of its own: getOriginalBalance() includes this message's value, and a storage fee still
            // due is taken out of the balance by the next transaction
            val (extraLock, extraWallet, walletPaidUntil, cost) = extendCost(live, msg.makePermanent, next.end, now,
                                                                             ownBalance(in.value), 0);
            assert(in.value >= cost) throw ERROR_INSUFFICIENT_VALUE;

            live.schedule = next;
            live.permanent = msg.makePermanent;
            live.walletPaidUntil = walletPaidUntil;
            storage.live = live.toCell();
            storage.save();

            emitEvent(LockExtendedEvent { index: storage.index, permanent: live.permanent, schedule: live.schedule });
            keepOwnBalance(extraLock);
            if (extraWallet > 0) {
                createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: live.jettonWallet,
                    value: extraWallet,
                    body: PlainGram {}
                }).send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
            }
            returnExcess(in.sender, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }

        ClaimForeign => {
            assert(in.sender == storage.owner) throw ERROR_NOT_OWNER;
            // Nothing in a lock that is not funded is the owner's: during setup the creator's funding
            // may sit in any wallet, and a cancelled lock's wallets hold only the creator's tokens
            // (RecoverUnrecorded)
            assert(storage.status == STATUS_FUNDED) throw ERROR_NOT_FUNDED;
            val live = storage.live.load();
            val setup = live.setup.load();
            assert(msg.destination.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert(!storage.isForbiddenRecipient(live, setup, msg.destination) && msg.destination != msg.jettonWallet) throw ERROR_FORBIDDEN_WALLET;
            // the wallet the lock holds its tokens in is reached by Claim and Sweep only
            assert(msg.jettonWallet != live.jettonWallet) throw ERROR_FORBIDDEN_WALLET;
            assert(msg.amount > 0) throw ERROR_NOTHING_TO_CLAIM;
            assert(in.value >= claimForeignCost(msg.jettonWallet.getWorkchain())) throw ERROR_INSUFFICIENT_VALUE;
            sendJettonTransfer(msg.jettonWallet, flagged(msg.queryId, QID_UNCREDITED), msg.amount, msg.destination,
                               storage.owner, 0, emptyForwardPayload(), 0, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        ClaimForeignNft => {
            // NFTs in a funded lock are the owner's; in a cancelled lock everything is the creator's
            // (anyone may send them to the creator)
            if (storage.status == STATUS_FUNDED) {
                assert(in.sender == storage.owner) throw ERROR_NOT_OWNER;
            } else {
                assert(storage.status == STATUS_CANCELLED) throw ERROR_BAD_STATUS;
                val creator = storage.creator();
                assert(in.sender == creator || msg.newOwner == creator) throw ERROR_NOT_CREATOR;
            }
            val nftLive = storage.live.load();
            assert(msg.nft != contract.getAddress()) throw ERROR_FORBIDDEN_WALLET;
            assert(msg.newOwner.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert(!storage.isForbiddenRecipient(nftLive, nftLive.setup.load(), msg.newOwner) && msg.newOwner != msg.nft) throw ERROR_FORBIDDEN_WALLET;
            createMessage({
                bounce: LOCK_BOUNCE,
                dest: msg.nft,
                value: 0,
                body: NftTransfer {
                    queryId: msg.queryId & QID_USER_MASK,
                    newOwner: msg.newOwner,
                    responseDestination: in.sender,
                    customPayload: null,
                    forwardAmount: 0,
                    forwardPayload: emptyForwardPayload()
                }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        Sweep => {
            assert(in.sender == storage.owner) throw ERROR_NOT_OWNER;
            // nothing in a cancelled lock is the owner's: its wallet holds the creator's tokens
            assert(storage.status == STATUS_FUNDED) throw ERROR_NOT_FUNDED;
            var live = storage.live.load();
            var setup = live.setup.load();
            assert(storage.isFinished(live, now)) throw ERROR_NOT_FINISHED;
            assert(msg.destination.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert(!storage.isForbiddenRecipient(live, setup, msg.destination)) throw ERROR_FORBIDDEN_WALLET;
            assert(msg.amount > 0) throw ERROR_NOTHING_TO_CLAIM;
            // A fee transfer to the till may still bounce back (restoring feeOwed) until FEE_SETTLE
            // after it: the sweep waits, so it can never take those tokens. It waits for FEE_GIVE_UP after
            // the end at most, and from then on no longer pays them first: a fee transfer the wallet always
            // refuses, or anyone's RetryFee every day, must not keep what is the owner's for ever.
            val gaveUp = live.feeGivenUp(now);
            assert(gaveUp || now >= setup.feeSentAt + FEE_SETTLE) throw ERROR_FEE_UNSETTLED;
            assert(in.value >= sweepMinValue(live.jettonWallet.getWorkchain(), setup.feeOwed)) throw ERROR_INSUFFICIENT_VALUE;
            val owed = setup.feeOwed;
            if (owed > 0 && !gaveUp) {
                // The till's tokens first, alone and with all the GRAM; the sweep itself can run once
                // this transfer has settled
                setup.feeOwed = 0;
                setup.feeSentAt = now;
                live.setup = setup.toCell();
                storage.live = live.toCell();
                storage.save();
                sendFeeTokens(live.jettonWallet, storage.index, owed, setup.till, storage.owner, storage.terms.load().jettonMaster,
                              FEE_KIND_RETRY, 0, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
                return;
            }
            // Settle the accounting (nothing is locked any more), so the getters never show swept
            // tokens; the jetton wallet's own balance check bounds the amount. `amount` is what the
            // owner asked for, not what the wallet held.
            var bal = storage.balances.load();
            bal.claimed = bal.totalAmount;
            bal.freeBalance = 0;
            storage.balances = bal.toCell();
            setup.feeOwed = 0;
            live.setup = setup.toCell();
            storage.live = live.toCell();
            storage.save();
            emitEvent(LockSweptEvent { index: storage.index, amount: msg.amount, destination: msg.destination });
            keepOwnBalance(0);
            sendJettonTransfer(live.jettonWallet, flagged(msg.queryId, QID_UNCREDITED), msg.amount, msg.destination,
                               storage.owner, 0, emptyForwardPayload(), 0, SEND_MODE_CARRY_ALL_BALANCE);
        }

        RetryFunding => {
            // Ask the till again (one deployed late); the caller's surplus comes back to it
            assert(storage.status == STATUS_AWAITING_SETUP) throw ERROR_BAD_STATUS;
            val setup = storage.live.load().setup.load();
            assert(!setup.termsAttested) throw ERROR_NOTHING_OWED;
            assert(in.value >= retryFundingCost()) throw ERROR_INSUFFICIENT_VALUE;
            keepOwnBalance(0);
            askTillForTerms(setup.till, storage.index, attestValue(), SEND_MODE_PAY_FEES_SEPARATELY);
            returnExcess(in.sender, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }

        RetryRefund => {
            assert(storage.status == STATUS_CANCELLED) throw ERROR_BAD_STATUS;
            var live = storage.live.load();
            var setup = live.setup.load();
            assert(setup.pendingAmount > 0) throw ERROR_NOTHING_OWED;
            assert(in.value >= retryCost(live.jettonWallet.getWorkchain())) throw ERROR_INSUFFICIENT_VALUE;
            val amount = setup.pendingAmount;
            setup.pendingAmount = 0;
            setup.refundSentAt = now;
            live.setup = setup.toCell();
            storage.live = live.toCell();
            storage.save();
            // the gas of restoring the record on a bounce stays here, paid by the caller
            keepOwnBalance(bouncePrepay());
            sendJettonTransfer(live.jettonWallet, pendingQueryId(setup.walletSeq), amount,
                               storage.creator(), in.sender, 0, emptyForwardPayload(), 0, SEND_MODE_CARRY_ALL_BALANCE);
        }

        RetryFee => {
            assert(storage.status == STATUS_FUNDED) throw ERROR_BAD_STATUS;
            var live = storage.live.load();
            var setup = live.setup.load();
            assert(setup.feeOwed > 0) throw ERROR_NOTHING_OWED;
            assert(in.value >= retryCost(live.jettonWallet.getWorkchain())) throw ERROR_INSUFFICIENT_VALUE;
            val amount = setup.feeOwed;
            setup.feeOwed = 0;
            setup.feeSentAt = now;
            live.setup = setup.toCell();
            storage.live = live.toCell();
            storage.save();
            // the gas of restoring the record on a bounce stays here, paid by the caller
            keepOwnBalance(bouncePrepay());
            sendFeeTokens(live.jettonWallet, storage.index, amount, setup.till, in.sender, storage.terms.load().jettonMaster,
                          FEE_KIND_RETRY, 0, SEND_MODE_CARRY_ALL_BALANCE);
        }

        CancelCreation => {
            assert(storage.status == STATUS_AWAITING_SETUP) throw ERROR_BAD_STATUS;
            val live = storage.live.load();
            val creator = storage.creator();
            // The creator may give up at any time; anyone else only once the creation can no longer
            // complete, so nobody can cancel a creation its creator is still funding
            assert(in.sender == creator || now > live.createdAt + SETUP_WINDOW) throw ERROR_TOO_EARLY;
            // enough to pay the refund, so the creator never waits on a second message
            assert(in.value >= cancelCost(live.jettonWallet.getWorkchain())) throw ERROR_INSUFFICIENT_VALUE;
            if (in.sender == creator) {
                storage.cancel(live, live.setup.load(), CANCEL_REQUESTED, LOCK_GAS_CANCEL, null, 0);
            } else {
                // a helper pays for the cancel only: the rest of its value comes back to it
                storage.cancel(live, live.setup.load(), CANCEL_EXPIRED, LOCK_GAS_CANCEL, in.sender, in.value);
            }
        }

        RecoverUnrecorded => {
            // Everything in a cancelled lock's wallets is the creator's: funding that arrived before the
            // lock existed, a refund its own wallet refused, deposits that could not be sent back during
            // the setup. Any wallet may be named (fake or not, it only moves what it holds for the
            // lock). Through the wallet still owing the pending refund, the recovery is the refund: the
            // record shrinks first, so RetryRefund can never pay it a second time from other tokens.
            // What no record counts in the lock's own wallet, a transfer can take together with what a
            // refund on its way left there, so that refund's bounce then restores nothing. The creator may
            // do that at any time; anyone else recovers for the creator only once the latest refund has
            // settled (FEE_SETTLE), so nobody can empty the record of a refund the wallet refused.
            assert(storage.status == STATUS_CANCELLED) throw ERROR_BAD_STATUS;
            var live = storage.live.load();
            var setup = live.setup.load();
            // anyone may recover for the creator; only the creator may send the tokens elsewhere
            val creator = storage.creator();
            assert(in.sender == creator || msg.destination == creator) throw ERROR_NOT_CREATOR;
            assert(msg.destination.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert(!storage.isForbiddenRecipient(live, setup, msg.destination) && msg.destination != msg.wallet) throw ERROR_FORBIDDEN_WALLET;
            assert(msg.amount > 0) throw ERROR_NOTHING_TO_CLAIM;
            val walletWorkchain = msg.wallet.getWorkchain();
            if (msg.wallet == live.jettonWallet && setup.pendingAmount > 0) {
                // Through the wallet still owing the pending refund the recovery is that refund, at most
                // the amount owed: the record shrinks now and a bounce restores it, as for RetryRefund
                // (whose bounce gas the caller pays here too)
                assert(msg.amount <= setup.pendingAmount) throw ERROR_AMOUNT_TOO_HIGH;
                assert(in.value >= claimMinValue(walletWorkchain, 0) + bouncePrepay()) throw ERROR_INSUFFICIENT_VALUE;
                setup.pendingAmount -= msg.amount;
                setup.refundSentAt = now;
                live.setup = setup.toCell();
                storage.live = live.toCell();
                storage.save();
                keepOwnBalance(bouncePrepay());
                sendJettonTransfer(msg.wallet, pendingQueryId(setup.walletSeq), msg.amount, msg.destination,
                                   in.sender, 0, emptyForwardPayload(), 0, SEND_MODE_CARRY_ALL_BALANCE);
                return;
            }
            // anything else is uncredited: on a bounce the tokens are still there to recover again
            assert(in.value >= claimMinValue(walletWorkchain, 0)) throw ERROR_INSUFFICIENT_VALUE;
            if (msg.wallet == live.jettonWallet) {
                // This may take what a refund still on its way left in that wallet (its bounce has not come back
                // yet): that bounce must not restore the record over tokens gone. The creator's choice alone
                // while a refund may still be on its way.
                assert(in.sender == creator || now > setup.refundSentAt + FEE_SETTLE) throw ERROR_TOO_EARLY;
                setup.walletSeq = nextWalletSeq(setup.walletSeq);
                live.setup = setup.toCell();
                storage.live = live.toCell();
                storage.save();
            }
            sendJettonTransfer(msg.wallet, flagged(msg.queryId, QID_UNCREDITED), msg.amount, msg.destination,
                               in.sender, 0, emptyForwardPayload(), 0, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        NftTransfer => {
            assert(!soulbound) throw ERROR_SOULBOUND;
            assert(in.sender == storage.owner) throw ERROR_NOT_OWNER;
            // a lock in setup or cancelled must not change hands as if it held something
            assert(storage.status == STATUS_FUNDED) throw ERROR_NOT_FUNDED;
            assert(msg.newOwner.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            // nobody could ever claim a lock owned by the root, its till or itself
            val transferLive = storage.live.load();
            assert(!storage.isForbiddenRecipient(transferLive, transferLive.setup.load(), msg.newOwner)) throw ERROR_FORBIDDEN_WALLET;
            assert(msg.forwardPayload.remainingBitsCount() >= 1) throw ERROR_MISSING_FORWARD_PAYLOAD;

            val needResponse = msg.responseDestination != null && msg.responseDestination!!.getWorkchain() == BASECHAIN;
            // Pay for this transfer from the incoming value, never from the storage prepayment
            var rest: int = in.value - calculateGasFee(BASECHAIN, LOCK_GAS_NFT_TRANSFER);
            if (msg.forwardAmount > 0) {
                rest -= msg.forwardAmount + in.fwdFee;
            }
            if (needResponse) {
                rest -= in.fwdFee;
            }
            assert(rest >= 0) throw ERROR_INSUFFICIENT_VALUE;

            val prevOwner = storage.owner;
            storage.owner = msg.newOwner;
            storage.save();

            if (msg.forwardAmount > 0) {
                createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.newOwner,
                    value: msg.forwardAmount,
                    body: OwnershipAssigned {
                        queryId: msg.queryId,
                        prevOwner: prevOwner,
                        forwardPayload: msg.forwardPayload
                    }
                }).send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            if (needResponse && rest > 0) {
                createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.responseDestination!!,
                    value: rest,
                    body: Excesses { queryId: msg.queryId }
                }).send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
            }
        }

        GetStaticData => {
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.sender,
                value: 0,
                body: ReportStaticData { queryId: msg.queryId, index: storage.index, collection: storage.collection }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        ProveOwnership => {
            assert(soulbound) throw ERROR_NOT_SUPPORTED;
            assert(in.sender == storage.owner) throw ERROR_NOT_OWNER;
            // a lock in setup or cancelled proves nothing; a funded one proves who owns it, while what it
            // holds is for the receiver to check as SPEC.md 3.5 says (its jetton wallet is its creator's word)
            assert(storage.status == STATUS_FUNDED) throw ERROR_NOT_FUNDED;
            createMessage({
                bounce: LOCK_BOUNCE,
                dest: msg.dest,
                value: 0,
                body: OwnershipProof {
                    queryId: msg.queryId,
                    itemId: storage.index,
                    owner: storage.owner,
                    data: msg.forwardPayload,
                    revokedAt: 0,
                    content: msg.withContent ? decimalStringCell(storage.index) : null
                }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        RequestOwner => {
            assert(soulbound) throw ERROR_NOT_SUPPORTED;
            assert(storage.status == STATUS_FUNDED) throw ERROR_NOT_FUNDED;
            createMessage({
                bounce: LOCK_BOUNCE,
                dest: msg.dest,
                value: 0,
                body: OwnerInfo {
                    queryId: msg.queryId,
                    itemId: storage.index,
                    initiator: in.sender,
                    owner: storage.owner,
                    data: msg.forwardPayload,
                    revokedAt: 0,
                    content: msg.withContent ? decimalStringCell(storage.index) : null
                }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        Destroy => {
            throw ERROR_NOT_SUPPORTED;  // a lock is kept as permanent proof
        }

        Revoke => {
            throw ERROR_NOT_SUPPORTED;  // no authority can revoke a lock
        }

        StorageTopUp => {
            // accepted, value stays on the lock
        }

        RequestLockState => {
            // Read-only, to whoever asks, on the request's own value. Whoever has just been given a lock
            // (ownership_assigned) can rely on it: only the owner can then lessen what the lock holds
            val live = storage.live.load();
            val bal = storage.balances.load();
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.sender,
                value: 0,
                body: LockState {
                    queryId: msg.queryId,
                    index: storage.index,
                    status: storage.status,
                    permanent: live.permanent,
                    schedule: live.schedule,
                    totalAmount: storage.status == STATUS_FUNDED ? bal.totalAmount : 0,
                    claimed: bal.claimed,
                    freeBalance: bal.freeBalance,
                    parties: LockStateParties {
                        owner: storage.owner,
                        jettonMaster: storage.terms.load().jettonMaster,
                        jettonWallet: live.jettonWallet
                    }.toCell()
                }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        Excesses => {
            // excess value from jetton wallets or the till
        }

        else => {
            throw ERROR_UNKNOWN_OP;
        }
    }
}

// Bounces restore the record their message took away, and give what is left of its GRAM back to
// whoever paid: the bounced message's response destination. The setup request carries the budget's
// GRAM: during the setup a bounce leaves it in the budget (RetryFunding re-asks), afterwards it goes
// to the creator. A restore that may need more gas than its bounce brings raises the gas limit on
// the lock's balance only where whoever triggered the transfer prepaid it (bouncePrepay) or is the
// owner, creator or budget; other bounces run on their own value.
fun handleLockBounce(in: LockIncoming) {
    if (!isInitialized() || in.body.remainingBitsCount() < 32 || in.body.preloadUint(32) != 0xfffffffe) {
        return;
    }
    // lazily: fields are read on demand, so a later extension of the format still parses
    val rich = lazy RichBounceBody.fromSlice(in.body);
    var body = rich.originalBody.beginParse();
    val op = body.loadUint(32);
    val queryId = body.loadUint(64);
    var storage = LockStorage.load();

    if (op == OP_OWNERSHIP_PROOF) {
        // TEP-85: tell the owner their ownership proof was rejected, with the value back
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: storage.owner,
            value: 0,
            body: OwnershipProofBounced { queryId: queryId }
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
        return;
    }
    if (op == OP_OWNER_INFO) {
        // TEP-85: the value back to whoever asked
        body.skipBits(256);
        returnExcess(body.loadAddress(), queryId, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }
    if (op == OP_NFT_TRANSFER) {
        // a foreign NFT refused to move: nothing to restore
        body.skipAny<address>();
        returnBounced(body.loadAddressOpt(), queryId);
        return;
    }
    if (op != OP_JETTON_TRANSFER) {
        // an attestation request: nothing to restore (RetryFunding re-asks)
        storage.returnSetupBounce();
        return;
    }
    val amount = body.loadCoins();
    body.skipAny<address>();    // destination
    val response = body.loadAddressOpt();
    var live = storage.live.load();
    var setup = live.setup.load();

    if ((queryId & QID_UNCREDITED) != 0) {
        // sweep, send-backs, recoveries: the tokens stay in the wallet, nothing recorded
    } else if ((queryId & QID_PENDING) != 0) {
        // The refund of pending funding was refused by the lock's wallet: still owed, RetryRefund. Unless a
        // recovery of what no record counts went out through the wallet after it and may have taken those
        // tokens (the wallet runs the lock's transfers in order): then they are left unrecorded, the
        // creator's to recover as they are.
        if (storage.status == STATUS_CANCELLED && in.sender == live.jettonWallet
            && (queryId & WALLET_SEQ_MASK) == setup.walletSeq) {
            setGasLimit(LOCK_GAS_BOUNCE);
            setup.pendingAmount += amount;
            live.setup = setup.toCell();
            storage.live = live.toCell();
            storage.save();
        }
    } else if (in.sender != live.jettonWallet) {
        // send-backs through other wallets: those tokens never left
    } else if ((queryId & QID_FEE) != 0) {
        // the lock's wallet refused to pay the till: the tokens stay owed (RetryFee, Sweep), until a sweep
        // no longer waits for them
        if (storage.status == STATUS_FUNDED && !live.feeGivenUp(blockchain.now())) {
            setGasLimit(LOCK_GAS_BOUNCE);
            setup.feeOwed += amount;
            live.setup = setup.toCell();
            storage.live = live.toCell();
            storage.save();
        }
    } else if (storage.isFinished(live, blockchain.now())) {
        // once the lock is finished a sweep may already have taken them: whatever is still there is
        // sweepable, nothing is credited
    } else if ((queryId & QID_SENDBACK) != 0) {
        // A deposit the lock sent back came back: it stays, free balance like a gift (during the setup,
        // once the lock funds). On the bounce's own value and without an event: whoever made it bounce pays
        // for this.
        if (storage.status == STATUS_AWAITING_SETUP) {
            setup.setupExtra += amount;
            live.setup = setup.toCell();
            storage.live = live.toCell();
            storage.save();
        } else {
            storage.creditFree(amount);
        }
    } else {
        // A claim the jetton wallet refused: the tokens are still there, make them claimable again
        setGasLimit(LOCK_GAS_BOUNCE);
        var bal = storage.balances.load();
        bal.freeBalance += amount;
        storage.balances = bal.toCell();
        storage.save();
        emitEvent(LockClaimRestoredEvent { index: storage.index, amount: amount });
        // the event and this handler are paid from the bounced value as far as it goes: what is above
        // the lock's own balance goes back
        reserveToncoinsOnBalance(0, RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_AT_MOST);
        if (response != null) {
            returnExcess(response!!, queryId & QID_USER_MASK, SEND_MODE_CARRY_ALL_BALANCE);
        }
        return;
    }
    returnBounced(response, queryId);
}

// A setup request bounced: its GRAM stays in the budget during the setup, and is the creator's after
@noinline
fun LockStorage.returnSetupBounce(self) {
    if (self.status != STATUS_AWAITING_SETUP) {
        returnExcess(self.creator(), queryIdOf(self.index), SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
    }
}

// What is left of a bounced message's value, to its response destination
fun returnBounced(response: address?, queryId: int) {
    if (response != null) {
        returnExcess(response!!, queryId & QID_USER_MASK, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
    }
}

// ============== Getters ==============

struct LockInfo {
    status: int
    index: int
    collection: address
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
    totalAmount: int            // tokens held under the schedule (0 until funded)
    expectedAmount: int         // what the creator sends (until funded)
    claimed: int
    freeBalance: int
    claimableNow: int
    feeBps: int                 // fee rates of this lock (0 until attested)
    topUpFlatFee: int
    version: int
    lastDepositLt: int          // logical time of the latest deposit's transaction (0 until funded)
    createBefore: int           // from the terms (0 if never initialized)
}

@noinline
fun readLockInfo(): LockInfo {
    if (!isInitialized()) {
        val init = LockInitData.fromCell(contract.getData());
        return {
            status: STATUS_NOT_INITIALIZED, index: init.index, collection: init.collection,
            owner: null, jettonMaster: null, jettonWallet: null, creator: null, createdAt: 0,
            cliff: 0, end: 0, step: 0, initialBps: 0, permanent: false, totalAmount: 0,
            expectedAmount: 0, claimed: 0, freeBalance: 0, claimableNow: 0, feeBps: 0,
            topUpFlatFee: 0, version: SWORN_VERSION, lastDepositLt: 0, createBefore: 0
        };
    }
    val storage = LockStorage.load();
    val terms = storage.terms.load();
    val live = storage.live.load();
    val bal = storage.balances.load();
    val funded = storage.status == STATUS_FUNDED;
    return {
        status: storage.status,
        index: storage.index,
        collection: storage.collection,
        owner: storage.owner,
        jettonMaster: terms.jettonMaster,
        jettonWallet: live.jettonWallet,
        creator: terms.parties.load().creator,
        createdAt: live.createdAt,
        cliff: live.schedule.cliff,
        end: live.schedule.end,
        step: live.schedule.step,
        initialBps: live.schedule.initialBps,
        permanent: live.permanent,
        totalAmount: funded ? bal.totalAmount : 0,
        expectedAmount: storage.status == STATUS_AWAITING_SETUP ? terms.expectedAmount : 0,
        claimed: bal.claimed,
        freeBalance: bal.freeBalance,
        claimableNow: storage.claimable(bal, live, blockchain.now()),
        feeBps: live.feeBps,
        topUpFlatFee: live.topUpFlatFee,
        version: SWORN_VERSION,
        lastDepositLt: bal.lastDepositLt,
        createBefore: terms.createBefore
    };
}

// TEP-62: (init?, index, collection, owner, individual_content)
get fun get_nft_data(): (bool, int, address, address?, cell) {
    if (!isInitialized()) {
        val init = LockInitData.fromCell(contract.getData());
        return (false, init.index, init.collection, null, beginCell().endCell());
    }
    val storage = LockStorage.load();
    return (true, storage.index, storage.collection, storage.owner, decimalStringCell(storage.index));
}

get fun get_lock_data(): LockInfo {
    return readLockInfo();
}

struct SetupInfo {
    till: address?
    termsAttested: bool
    pendingAmount: int          // funding held in the slot, or a refund still owed after a cancel
    feeOwed: int                // fee tokens whose transfer bounced (RetryFee)
    flatFee: int                // attested flat fee (0 until attested)
    setupExtra: int             // deposits during setup that could not be sent back
    setupDeadline: int          // the funding completes only until then (0 if never initialized)
    cancelReason: int           // CANCEL_* once cancelled, 0 otherwise
    sweepFrom: int              // a Sweep waits until then for the latest fee transfer to settle
    walletPaidUntil: int        // the jetton wallet's storage is prepaid until then (0 until funded): an Extend renews it
}

// The creation and refund record of this lock
get fun get_setup_data(): SetupInfo {
    if (!isInitialized()) {
        return {
            till: null, termsAttested: false, pendingAmount: 0, feeOwed: 0, flatFee: 0, setupExtra: 0, setupDeadline: 0,
            cancelReason: 0, sweepFrom: 0, walletPaidUntil: 0
        };
    }
    val live = LockStorage.load().live.load();
    val setup = live.setup.load();
    return {
        till: setup.till,
        termsAttested: setup.termsAttested,
        pendingAmount: setup.pendingAmount,
        feeOwed: setup.feeOwed,
        flatFee: live.flatFee,
        setupExtra: setup.setupExtra,
        setupDeadline: live.createdAt + SETUP_WINDOW,
        cancelReason: setup.cancelReason,
        sweepFrom: setup.feeSentAt == 0 ? 0
            : live.permanent ? setup.feeSentAt + FEE_SETTLE
            : min(setup.feeSentAt + FEE_SETTLE, live.schedule.end + FEE_GIVE_UP),
        walletPaidUntil: live.walletPaidUntil
    };
}

// The immutable terms this lock's index commits to
get fun get_lock_terms(): cell {
    if (!isInitialized()) {
        return beginCell().endCell();
    }
    return LockStorage.load().terms;
}

// Unlocked amount of the schedule at time t (ignores claims and free balance)
get fun get_unlocked_at(t: int): int {
    if (!isInitialized()) {
        return 0;
    }
    val storage = LockStorage.load();
    val live = storage.live.load();
    if (storage.status != STATUS_FUNDED || live.permanent) {
        return 0;
    }
    return live.schedule.unlockedAt(storage.balances.load().totalAmount, t);
}

get fun get_claimable(): int {
    if (!isInitialized()) {
        return 0;
    }
    val storage = LockStorage.load();
    return storage.claimable(storage.balances.load(), storage.live.load(), blockchain.now());
}

// The workchain of the lock's jetton wallet, which prices what goes through it (basechain until initialized)
fun lockWalletWorkchain(): int {
    if (!isInitialized()) {
        return BASECHAIN;
    }
    return LockStorage.load().live.load().jettonWallet.getWorkchain();
}

// GRAM a Claim with this forward amount and no forward payload must carry (as version 2 locks answer)
get fun get_claim_min_value(forwardTonAmount: int): int {
    return claimMinValue(lockWalletWorkchain(), forwardTonAmount);
}

// GRAM a Claim with this forward amount and forward payload must carry. Getters take no nullable
// argument: common APIs (toncenter's runGetMethod) cannot pass a null.
get fun get_claim_min_value_with_payload(forwardTonAmount: int, forwardPayload: cell): int {
    val workchain = lockWalletWorkchain();
    return claimMinValue(workchain, forwardTonAmount) + payloadForwardFee(workchain, forwardPayload);
}

// Storage fee due when a message quoted now lands: what accrued since the last save with nothing due (a
// debt left by a bounceable message included), plus QUOTE_MARGIN for the message's way here. What the next
// message pays first. The network charges each stretch of that time at the price then in force, which a
// getter cannot know: it is counted at the higher of the live price and the floor price. That is an upper
// bound unless the price stood above both and was cut since; a message sent at such a quote is refused,
// its value comes back, and the next quote is right, the refused message having settled the storage.
fun storageDebtBound(storage: LockStorage): coins {
    val seconds = max(blockchain.now() - storage.lastTx, 0) + QUOTE_MARGIN;
    return max(calculateStorageFee(BASECHAIN, seconds, LOCK_STATE_BITS, LOCK_STATE_CELLS),
               floorStorageFee(BASECHAIN, seconds, LOCK_STATE_BITS, LOCK_STATE_CELLS));
}

// GRAM to attach (forward_ton_amount) to a top-up of this lock, storage debt included, with room for
// a wallet delivering a little less
get fun get_top_up_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    val storage = LockStorage.load();
    val live = storage.live.load();
    val walletWorkchain = live.jettonWallet.getWorkchain();
    return topUpCost(live.topUpFlatFee, walletWorkchain) + storageDebtBound(storage) + FORWARD_SLACK + forwardShave(walletWorkchain);
}

// GRAM a Sweep must carry (more while fee tokens are owed to the till)
get fun get_sweep_min_value(): int {
    if (!isInitialized()) {
        return sweepMinValue(BASECHAIN, 0);
    }
    val live = LockStorage.load().live.load();
    return sweepMinValue(live.jettonWallet.getWorkchain(), live.setup.load().feeOwed);
}

// GRAM a ClaimForeign through a jetton wallet of that workchain must carry
get fun get_claim_foreign_cost(walletWorkchain: int): int {
    return claimForeignCost(walletWorkchain);
}

// GRAM a jetton transfer through this lock's wallet needs on top of its forward_ton_amount: TEP-74's
// bound on what it may cost (an app attaches this much plus get_top_up_cost to a top-up; the rest
// comes back)
get fun get_jetton_transfer_value(): int {
    return jettonTransferValueOn(lockWalletWorkchain());
}

// GRAM to attach to an Extend to `end` (or to make the lock permanent), for a message landing up to
// QUOTE_MARGIN from now
get fun get_extend_cost(permanent: bool, end: int): int {
    if (!isInitialized()) {
        return 0;
    }
    val storage = LockStorage.load();
    val live = storage.live.load();
    val now = blockchain.now();
    // the balance here is before the storage fee due since the last save with nothing due: take out an
    // upper bound; a permanent lock's life (and its wallet's storage) runs from when the message lands
    val (extraLock, extraWallet, walletPaidUntil, cost) = extendCost(live, permanent || live.permanent, permanent ? 0 : end,
                                                                     now, contract.getOriginalBalance() - storageDebtBound(storage), QUOTE_MARGIN);
    return cost;
}

get fun get_cancel_cost(): int {
    return cancelCost(lockWalletWorkchain());
}

// GRAM a RetryRefund or RetryFee must carry
get fun get_retry_cost(): int {
    return retryCost(lockWalletWorkchain());
}

// GRAM a RecoverUnrecorded through a jetton wallet of that workchain must carry: the transfer from that wallet,
// and the gas of restoring the refund record should it bounce (paid when the recovery is the refund owed)
get fun get_recover_cost(walletWorkchain: int): int {
    return claimMinValue(walletWorkchain, 0) + bouncePrepay();
}

// GRAM a RetryFunding must carry
get fun get_retry_funding_cost(): int {
    return retryFundingCost();
}

get fun get_sworn_version(): int {
    return SWORN_VERSION;
}
