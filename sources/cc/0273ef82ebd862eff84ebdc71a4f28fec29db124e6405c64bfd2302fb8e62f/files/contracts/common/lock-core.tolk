tolk 1.5

import "@stdlib/gas-payments"
import "lock-base"
import "messages"
import "sworn"

// Sworn lock of jettons: an NFT (TEP-62) that is also the vault holding the locked jettons, and the only
// contract with per-lock state. It is its own creation record and its own refund record.
//
// This file has what only a lock of jettons does. The two contracts that are a lock of jettons
// (sworn-lock-transferable.tolk and sworn-lock-soulbound.tolk) declare the entrypoints and the get methods
// and call the handlers here, telling them which kind they are. What a lock of jettons shares with a lock
// of GRAM (gram-lock-core.tolk) is in lock-base.tolk, the message layouts are in messages.tolk, and the
// constants, the schedule math, the address derivations and the costs are in sworn.tolk.
//
// Trust model:
// - Address = hash(code, {root, index}) with index = hash(terms) and the kind in its two low bits: whoever
//   deploys the code at that address, only the creator the terms name can create the lock (InitLock), only
//   with the terms its index commits to, and only until the terms' createBefore. The root never sends it
//   anything.
// - Of a jetton it uses only what TEP-74 describes, and TEP-74 gives a contract no way to ask a master
//   which wallet is whose: its jetton wallet is the creator's word (InitLock), taken from the master's
//   get_wallet_address. The lock cannot tell a false word; whoever relies on a lock can: what a lock
//   reports counts only if get_wallet_address(lock) == jettonWallet (SPEC.md 3.5). Nobody but that creator
//   can name it, and a lock with another wallet never credits real tokens: they go back, or stay in the
//   real wallet for ClaimForeign.
// - Locked amounts come only from transfer_notifications sent by that wallet. Only the owner and the
//   creator can add to the schedule.
// - Fees go to the lock's till (root-derived) at the rates the till attested during setup; the flat fee
//   travels on its own, never through jetton code.
// - Nobody but the owner can move locked tokens, and only as the schedule allows. No admin, no upgrade.
// - Handlers pay for their messages and events from the incoming value; the balance is the storage
//   prepayment, and no request spends it but one: a SweepGram, which pays the owner of a finished lock what
//   the balance holds above the storage a cancelled lock keeps. During setup the balance also holds the
//   creator's budget, which the setup steps spend and whose rest goes back to the creator when the lock
//   funds or its creation is cancelled. Only a bounce that restores a record may take gas from the
//   balance, and only where the transfer that bounced was the owner's, the creator's or prepaid
//   (handleLockBounce).

// The codes only a lock of jettons throws, next to those of every lock (LockErrors, in lock-base)
enum JettonErrors {
    NothingToRetry = 421 // nothing to retry: no refund owed, no fee tokens owed, or the till has attested
    // a Sweep or a SweepGram while the lock's latest fee transfer may still bounce back, or a SweepGram
    // while fee tokens are owed to the till
    FeeUnsettled = 422
}

// One more reason of LockCancelledEvent, of a lock of jettons only (the others are in lock-base)
const CANCEL_SCHEDULE = 5 // the schedule of the terms could not start when InitLock came (handleInit)

// The empty body of a plain GRAM transfer, which pays a jetton wallet's storage. It is sent non-bounceable,
// so the value stays on that account whatever its code makes of it: nothing here relies on a jetton's code.
struct PlainGram {}

struct LockBalances {
    totalAmount: coins // locked by the schedule (0 until funded)
    claimed: coins     // scheduled tokens already claimed
    // claimable at any time: gifts and other deposits outside the schedule, claims the wallet refused
    freeBalance: coins
    // logical time of the transaction of the latest deposit (the funding or a top-up): each deposit's event
    // names the previous one, so the list of deposits is read in O(deposits) whatever else the lock
    // received
    lastDepositLt: uint64
}

// What the lock holds and owes besides its schedule, and how its creation went: its till, the creation
// record, the refund record and the fee tokens owed. Fixed size: one slot for the funding, which only the
// creator fills.
struct LockCustody {
    till: address        // the lock's till (index mod TILL_COUNT), derived at InitLock
    feesAttested: bool   // the till attested fees within the creator's maxima
    pendingAmount: coins // funding received through the lock's wallet, not yet credited or refunded
    // other deposits through it during setup that could not be sent back: free balance once funded, the
    // creator's if cancelled
    setupExtra: coins
    feeOwed: coins       // fee tokens whose transfer to the till bounced
    cancelReason: uint8  // CANCEL_* once cancelled (0 otherwise): readable without the history
    // when the latest fee-token transfer to the till went out (0: none): a Sweep and a SweepGram wait
    // TRANSFER_SETTLE after it, since it may still bounce back
    feeSentAt: uint48
    // how many recoveries of what no record counts went out through the lock's wallet, in a cancelled lock.
    // Such a recovery can take the tokens of a refund that is still to bounce, so a refund's bounce
    // restores the record only if it carries the present number: none went out after it
    walletSeq: uint32
    // when the latest refund transfer through the lock's wallet went out (0: none): nobody but the creator
    // makes such a recovery within TRANSFER_SETTLE of it, while it may still bounce back
    refundSentAt: uint48
}

// The lock's state outside its terms: what InitLock records and what later handlers change (the terms cell
// is immutable, hashed into the index)
struct LockLive {
    jettonWallet: address // the creator's word (InitLock), see the trust model; it never changes
    createdAt: uint48     // when InitLock came: SETUP_WINDOW runs from it
    permanent: bool
    schedule: Schedule    // the terms' schedule until an ExtendLock changes it; zeros for permanent locks
    flatFee: coins        // fee rates fixed at setup from the till's attestation
    topUpFlatFee: coins
    feeBps: uint16
    // the jetton wallet's storage is paid until then (0 until funded): every longer life pays it from there
    // on, a permanent lock's renewal too
    walletPaidUntil: uint48
    custody: Cell<LockCustody>
}

// The lock's data. It starts with the two fields a lock is deployed with (LockInitData) and holds more than
// them: that is how isInitialized tells a lock from an address InitLock has not reached.
struct LockStorage {
    collection: address // the root
    index: uint256
    status: uint8       // STATUS_*
    owner: address
    // last time the state was saved with no storage fee due: the storage due now is at most what accrued
    // since then (the quotes count from it)
    lastTx: uint48
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

// A caller's queryId with flags: the caller's bits never reach the flag positions
@inline
fun flagged(queryId: int, flags: int): uint64 {
    return (queryId & QID_USER_MASK) | flags;
}

// The bits of a queryId that carry walletSeq: its low 32
const WALLET_SEQ_MASK = (1 << 32) - 1

// The queryId of a transfer of the refund a cancelled lock owes: QID_PENDING and, in its low 32 bits, the
// lock's walletSeq when the transfer went out, which its bounce must match to restore the record. Refund
// transfers do not move walletSeq: each takes its own share of the record, so one the wallet refuses is
// restored whatever the others did.
@inline
fun pendingQueryId(walletSeq: int): uint64 {
    return QID_PENDING | walletSeq;
}

// walletSeq after one more recovery of what no record counts; it wraps, to stay within its 32 bits
@inline
fun nextWalletSeq(walletSeq: int): int {
    return (walletSeq + 1) & WALLET_SEQ_MASK;
}

// Accounts a lock never pays out to or hands itself to: the root, the lock's till, the lock itself and its
// jetton wallet. None of them can send what an owner sends, so a lock one of them owned could never be
// claimed. And tokens paid to them would be out of the owner's reach: what the root or a till receives is
// Sworn's to withdraw, and what a jetton wallet is sent sits in a wallet owned by a wallet, which nothing
// can move. The SDK refuses the other tills too.
fun LockStorage.isForbiddenRecipient(self, live: LockLive, custody: LockCustody, a: address): bool {
    return a == self.collection || a == custody.till || a == contract.getAddress() ||
        a == live.jettonWallet;
}

// ============== Events ==============
// The events every lock emits are in lock-base. This one is emitted by a lock of jettons only.

// A claim the lock's jetton wallet refused was credited back to the free balance ("LkRS"): the
// LockClaimedEvent of that claim stated more than was paid
struct (0x4c6b5253) LockClaimRestoredEvent {
    index: uint256
    amount: coins
}

// ============== Accounting ==============

// What the schedule has unlocked and not paid out: nothing unless the lock is funded, and nothing in a
// permanent lock
fun LockStorage.scheduledClaimable(self, bal: LockBalances, live: LockLive, now: int): int {
    if (self.status != STATUS_FUNDED || live.permanent) {
        return 0;
    }
    val unlocked = live.schedule.unlockedAt(bal.totalAmount, now);
    return max(unlocked - bal.claimed, 0);
}

// What a Claim can take: the free balance, and what the schedule has unlocked and not paid out
fun LockStorage.claimable(self, bal: LockBalances, live: LockLive, now: int): int {
    return bal.freeBalance + self.scheduledClaimable(bal, live, now);
}

// Finished: funded, with a schedule that has ended. Nothing is locked any more: what the lock's wallet
// holds is its owner's, except fee tokens still owed to the till. A permanent lock never is.
fun LockStorage.isFinished(self, live: LockLive, now: int): bool {
    return self.status == STATUS_FUNDED && !live.permanent && now >= live.schedule.end;
}

// Closed: finished, or cancelled (what a cancelled lock's wallet holds is its creator's). A closed lock
// credits no deposit and no bounced claim: a sweep, or the creator's recovery, takes what is there.
fun LockStorage.isClosed(self, live: LockLive, now: int): bool {
    return self.status == STATUS_CANCELLED || self.isFinished(live, now);
}

// Whether fee tokens still owed to the till are given up: from FEE_GIVE_UP after the lock's end a sweep
// neither waits for them nor pays them first. Never in a permanent lock, which has no end.
fun LockLive.feeGivenUp(self, now: int): bool {
    return !self.permanent && now >= self.schedule.end + FEE_GIVE_UP;
}

// Whether the lock is even with its till as far as a SweepGram goes: the fee tokens are given up, or none
// is owed and the time a bounce is given has passed since the latest transfer of them (TRANSFER_SETTLE)
fun LockLive.feeSettled(self, custody: LockCustody, now: int): bool {
    return self.feeGivenUp(now) ||
        (custody.feeOwed == 0 && now >= custody.feeSentAt + TRANSFER_SETTLE);
}

// What a SweepGram asks of the lock, and of the account it pays when one is named (a get method names
// none): a funded lock that is finished, a destination on the basechain that the lock may pay, as a Sweep
// asks, and a lock that is even with its till. Throws the error of the first that fails.
// Never during the setup, when the lock's GRAM is its creator's budget, nor once cancelled, when it pays
// for the bounce of a refund the lock may still owe (NotFunded); never in a permanent lock, which does not
// finish (NotFinished); and not while fee tokens are owed to the till or their transfer may still bounce
// back, when it pays for restoring that record (FeeUnsettled): the SweepGram waits as a Sweep does, and for
// the Sweep or the RetryFee that pays them.
@noinline
fun LockStorage.assertSweepsGram(self, destination: address?, now: int) {
    assert (self.status == STATUS_FUNDED) throw LockErrors.NotFunded;
    val live = self.live.load();
    val custody = live.custody.load();
    assert (self.isFinished(live, now)) throw LockErrors.NotFinished;
    if (destination != null) {
        assert (destination.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
        assert (
            !self.isForbiddenRecipient(live, custody, destination)
        ) throw LockErrors.ForbiddenAccount;
    }
    assert (live.feeSettled(custody, now)) throw JettonErrors.FeeUnsettled;
}

// A top-up adds to the schedule of a funded lock only while it is not finished
fun LockLive.acceptsTopUp(self, now: int): bool {
    return self.permanent || now < self.schedule.end;
}

// GRAM an ExtendLock must bring. For the lock: what its storage prepayment for the longer life exceeds
// `balance` by, the GRAM it holds of its own. For its jetton wallet: the storage from walletPaidUntil (from
// now, if that has passed) to the end of that life, on the wallet's chain. For the handler: its gas, the
// event, the excess back and the message to the wallet.
// `margin`: for a quote, how much later the message may land (a permanent lock's life runs from then).
// Returns the lock's extra, the wallet's extra, until when the wallet is then paid, and the total.
fun extendCost(
    live: LockLive,
    permanent: bool,
    end: int,
    now: int,
    balance: coins,
    margin: int,
): (coins, coins, int, coins) {
    val extraLock = max(lockStoragePrepay(storageHorizon(permanent, end, now)) - balance, 0);
    val landing = now + margin;
    val paidUntil = landing + storageHorizon(permanent, end, landing);
    val from = max(live.walletPaidUntil, now);
    val walletWorkchain = live.jettonWallet.getWorkchain();
    var extraWallet: coins = 0;
    if (paidUntil > from) {
        // with the gas the wallet spends to take it in, so that what it keeps is the storage
        extraWallet = walletStorageExtra(walletWorkchain, paidUntil - from) +
            calculateGasFee(walletWorkchain, WALLET_PLAIN_GAS);
    }
    val total = extraLock + extraWallet + calculateGasFee(BASECHAIN, LOCK_GAS_EXTEND) +
        2 * smallMessageFee() +
        messageFeeOn(walletWorkchain);
    return (extraLock, extraWallet, max(paidUntil, live.walletPaidUntil), total);
}

// Fee tokens to the till, with its receipt's GRAM as their forward amount and, in a ref, the tag naming
// this lock. `response`: whoever pays for the transfer. A bounce restores feeOwed (QID_FEE).
@noinline
fun sendFeeTokens(
    wallet: address,
    index: int,
    amount: coins,
    till: address,
    response: address,
    master: address,
    kind: int,
    value: coins,
    mode: int,
) {
    sendJettonTransfer(
        wallet,
        QID_FEE | queryIdOf(index),
        amount,
        till,
        response,
        tillReceiptForward(wallet.getWorkchain()),
        refPayload(FeeTag { index, master, kind }.toCell()),
        value,
        mode,
    );
}

// ============== Init ==============

// InitLock, the message that makes this address a lock. It checks the terms against the index and the
// sender against the creator they name (admittedTerms), takes the lock's jetton wallet as that creator's
// word, records the lock as awaiting its setup and asks its till for the fee rates. What the message
// carries beyond that request stays on the lock: it is the budget of the setup. A lock whose schedule
// cannot start is recorded as cancelled instead, and asks nothing.
fun handleInit(in: LockIncoming, soulbound: bool) {
    val init = LockInitData.fromCell(contract.getData());
    val msg = InitLock.fromSlice(in.body);
    val now = blockchain.now();
    // admittedTerms lets only the creator the terms name through: the jetton wallet in the message is
    // outside the terms' hash, so nothing but the creator's word stands for it
    val (terms, parties) = admittedTerms(
        in,
        init,
        msg.terms,
        msg.tillCode,
        soulbound,
        false,
        now,
    );
    // That wallet is on the basechain or on the masterchain, like every account a lock sends a message to:
    // the costs below price those two chains and no other. A creation that names one elsewhere is refused
    // before anything is recorded, and its value goes back like that of any refused creation (refuse).
    val walletWorkchain = reachableWorkchain(msg.jettonWallet);
    // A schedule that cannot start (it has ended, or it is not a valid one: isValidForCreation, all zeros
    // for a permanent lock) locks nothing. But tokens may already wait in this address's jetton wallet,
    // where only this lock can ever move them: the creator's own wallet, short of GRAM, can skip InitLock
    // and still send the transfer, and what reaches an address that is not a lock yet goes back only if the
    // notification's GRAM allows and the jetton wallet agrees. So such a lock starts cancelled, at no fee
    // and without asking its till, and its creator recovers them (RecoverUnrecorded). The terms'
    // createBefore bounds this as it bounds every InitLock.
    val startable = terms.permanent
        ? terms.schedule.isZero()
        : terms.schedule.isValidForCreation(now);
    // the jetton wallet's part priced on the chain it lives on (where its master puts it)
    val cost = startable
        ? createCost(
            terms.maxFlatFee,
            terms.permanent,
            terms.schedule.end,
            now,
            walletWorkchain,
        )
        : unstartableCost();
    assert (in.value >= cost) throw LockErrors.InsufficientValue;

    val till = tillOfLock(msg.tillCode, init, parties);
    // tillOfLock refuses a party that is the root or the till. Nor may one be the lock's jetton wallet: a
    // wallet sends notifications and bounces, never what an owner or a creator sends
    assert (
        parties.owner != msg.jettonWallet && parties.creator != msg.jettonWallet
    ) throw LockErrors.ForbiddenAccount;
    var storage = LockStorage {
        collection: init.collection,
        index: init.index,
        status: STATUS_AWAITING_SETUP,
        owner: parties.owner,
        lastTx: now,
        balances: LockBalances {
            totalAmount: 0,
            claimed: 0,
            freeBalance: 0,
            lastDepositLt: 0,
        }.toCell(),
        terms: msg.terms,
        live: LockLive {
            jettonWallet: msg.jettonWallet,
            createdAt: now,
            permanent: terms.permanent,
            schedule: terms.schedule,
            flatFee: 0,
            topUpFlatFee: 0,
            feeBps: 0,
            walletPaidUntil: 0,
            custody: LockCustody {
                till,
                feesAttested: false,
                pendingAmount: 0,
                setupExtra: 0,
                feeOwed: 0,
                cancelReason: 0,
                feeSentAt: 0,
                walletSeq: 0,
                refundSentAt: 0,
            }.toCell(),
        }.toCell(),
    };
    emitLockEvent(LockCreatedEvent {
        index: init.index,
        jettonWallet: msg.jettonWallet,
        terms: msg.terms,
    });
    if (!startable) {
        // Starts cancelled: this handler and the cancel share one gas budget, the lock keeps a cancelled
        // lock's storage and the rest of the value goes back to the creator
        val live = storage.live.load();
        storage.cancel(
            live,
            live.custody.load(),
            CANCEL_SCHEDULE,
            LOCK_GAS_INIT + LOCK_GAS_CANCEL,
            msg.queryId,
            null,
            0,
        );
        return;
    }
    storage.save();

    // The setup request, which carries attestValue() with its forward fee paid on top. Everything else
    // (storage prepayments, flat fee, fee transfer) stays here as the budget until the funding completes or
    // the creation is cancelled: nothing is reserved, and nothing goes back to the creator yet.
    askTillForFees(till, init.index);
}

// ============== Setup ==============

// Saves the setup, and funds the lock once the two setup events are in: the till attested the fees and the
// creator's tokens arrived through the lock's wallet. It funds only within SETUP_WINDOW and while the
// budget covers everything the funding pays (prices can rise meanwhile); otherwise the creation is
// cancelled and everything goes back to the creator. Called last by its handler, which raised its gas limit
// to LOCK_GAS_SETUP_STEP (on the budget).
fun LockStorage.advanceSetup(mutate self, live: LockLive, custody: LockCustody) {
    if (!custody.feesAttested || custody.pendingAmount == 0) {
        var l = live;
        l.custody = custody.toCell();
        self.live = l.toCell();
        self.save();
        return;
    }
    // both setup events are in: the gas of what follows is in the budget too
    setGasLimit(LOCK_GAS_COMPLETE);
    if (blockchain.now() > live.createdAt + SETUP_WINDOW) {
        self.cancel(
            live,
            custody,
            CANCEL_EXPIRED,
            LOCK_GAS_COMPLETE,
            queryIdOf(self.index),
            null,
            0,
        );
        return;
    }
    val terms = self.terms.load();
    val creator = terms.parties.load().creator;
    val gross = custody.pendingAmount;
    val fee = mulDivFloor(gross, live.feeBps, BPS_DENOMINATOR);
    val walletWorkchain = live.jettonWallet.getWorkchain();
    // both storage prepayments are for the life the lock has from its creation
    val horizon = storageHorizon(live.permanent, live.schedule.end, live.createdAt);
    val prepay = lockStoragePrepay(horizon);
    val walletPrepay = walletStoragePrepay(walletWorkchain, horizon);
    // What the balance can spend above the lock's own storage prepayment and this handler's gas must cover
    // everything the funding sends: none of its messages may fail once the lock is recorded as funded
    if (
        spendableAbove(prepay, LOCK_GAS_COMPLETE) <
        fundingNeeds(walletPrepay, live.flatFee, fee > 0, walletWorkchain)
    ) {
        self.cancel(
            live,
            custody,
            CANCEL_BUDGET,
            LOCK_GAS_COMPLETE,
            queryIdOf(self.index),
            null,
            0,
        );
        return;
    }

    // the funding leaves the slot for the schedule; the other deposits recorded during the setup become
    // free balance
    var s = custody;
    val extra = s.setupExtra;
    s.pendingAmount = 0;
    s.setupExtra = 0;
    // the fee transfer's time holds sweeps back until it has settled
    if (fee > 0) {
        s.feeSentAt = blockchain.now();
    }
    var l = live;
    l.walletPaidUntil = live.createdAt + horizon;
    l.custody = s.toCell();
    self.live = l.toCell();
    self.status = STATUS_FUNDED;
    self.balances = LockBalances {
        totalAmount: gross - fee,
        claimed: 0,
        freeBalance: extra,
        lastDepositLt: blockchain.logicalTime(),
    }.toCell();
    self.save();
    emitLockEvent(LockFundedEvent {
        index: self.index,
        amount: gross - fee,
        fee,
    });

    // The jetton wallet's storage for the lock's life, paid once the lock holds tokens there: walletPrepay
    // exactly, the forward fee on top. Non-bounceable: the value stays on that account whatever its code
    // makes of it. Should the message fail to leave all the same, it alone is skipped and the funding
    // stands (SEND_MODE_IGNORE_ERRORS).
    val walletStorageMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: live.jettonWallet,
        value: walletPrepay,
        body: PlainGram {},
    });
    walletStorageMessage.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
    // The flat fee goes straight to the till as the value of a FeeNotice, which is sent even when the fee
    // is 0, so that the till's events list the funded locks: the notice brings what its receipt costs at
    // its bounds, and the till emits the event when what arrives pays for it. The fee tokens follow through
    // the jetton wallets, their excess to the creator (a bounce leaves them owed: RetryFee). Their transfer
    // leaves with exactly the value counted for it, its forward fee paid on top
    // (SEND_MODE_PAY_FEES_SEPARATELY): the budget of the funding counts both (fundingNeeds).
    sendFeeNotice(
        s.till,
        self.index,
        terms.jettonMaster,
        FEE_KIND_FUNDING,
        0,
        live.flatFee + tillReceiptValue(),
    );
    if (fee > 0) {
        sendFeeTokens(
            live.jettonWallet,
            self.index,
            fee,
            s.till,
            creator,
            terms.jettonMaster!,
            FEE_KIND_FUNDING,
            jettonTransferValueOn(walletWorkchain) + tillReceiptForward(walletWorkchain),
            SEND_MODE_PAY_FEES_SEPARATELY,
        );
    }

    // The lock keeps its storage prepayment (RESERVE_MODE_AT_MOST: all it has, should that be less, without
    // failing); what is left of the budget goes back to the creator
    reserveGramsOnBalance(prepay, RESERVE_MODE_AT_MOST);
    returnExcess(creator, queryIdOf(self.index), SEND_MODE_CARRY_ALL_BALANCE);
}

// A creation failed: the pending funding (if any) goes back to the creator through the wallet it came in
// by, what is left of the budget goes back to the creator, and the lock keeps the storage of a cancelled
// lock (lockCancelledReserve). A refund the balance cannot pay, or that bounces, stays owed
// (RetryRefund). Deposits that could not be sent back during the setup stay in the wallet unrecorded, the
// creator's (RecoverUnrecorded). `gasBudget`: the gas of the whole handler that cancels, set aside before
// anything goes back. `queryId`: that of what goes back, the message's own when a CancelCreation or an
// InitLock cancels, the lock's when a setup event does. A `helper` who paid for this cancel (someone other
// than the creator) pays only for it: the rest of `helperValue`, the value of its message, comes back to
// it, the refund transfer's excess included.
fun LockStorage.cancel(
    mutate self,
    live: LockLive,
    custody: LockCustody,
    reason: int,
    gasBudget: int,
    queryId: uint64,
    helper: address?,
    helperValue: coins,
) {
    val creator = creatorOf(self.terms);
    self.status = STATUS_CANCELLED;
    emitLockEvent(LockCancelledEvent {
        index: self.index,
        reason,
    });

    val reserve = lockCancelledReserve();
    // what the balance can spend above that reserve, the handler's gas and the event
    val rest = spendableAbove(reserve, gasBudget) - smallMessageFee();
    var s = custody;
    s.setupExtra = 0;
    s.cancelReason = reason;
    var response = creator;
    // what a helper's value leaves once it has paid the handler's gas and the event (and, below, the refund
    // transfer); there is nothing to work out when no helper sent the message
    var helperBack: int = 0;
    if (helper != null) {
        response = helper;
        helperBack = helperValue - calculateGasFee(BASECHAIN, gasBudget) - smallMessageFee();
    }
    val walletWorkchain = live.jettonWallet.getWorkchain();
    val refundValue = jettonTransferValueOn(walletWorkchain);
    val refundCost = refundValue + messageFeeOn(walletWorkchain);
    if (s.pendingAmount > 0 && rest >= refundCost) {
        // The balance can pay the refund's transfer (the refund stays owed otherwise): it leaves with
        // refundValue exactly, its forward fee paid on top (SEND_MODE_PAY_FEES_SEPARATELY), and refundCost
        // is both. The slot is emptied by the transfer and restored by its bounce (RetryRefund resends);
        // the transfer's excess goes to the creator, or to the helper who paid for it.
        s.refundSentAt = blockchain.now();
        sendJettonTransfer(
            live.jettonWallet,
            pendingQueryId(s.walletSeq),
            s.pendingAmount,
            creator,
            response,
            0,
            emptyForwardPayload(),
            refundValue,
            SEND_MODE_PAY_FEES_SEPARATELY,
        );
        s.pendingAmount = 0;
        helperBack -= refundCost;
    }
    var l = live;
    l.custody = s.toCell();
    self.live = l.toCell();
    self.save();

    if (helper != null && helperBack > 0) {
        val helperChangeMessage = createMessage({
            bounce: BounceMode.NoBounce,
            dest: helper,
            value: helperBack,
            body: Excesses { queryId },
        });
        // SEND_MODE_REGULAR: the change pays its own forward fee out of its value, on whatever chain the
        // helper lives. Should it fail to be sent, it alone is skipped and the cancel stands
        // (SEND_MODE_IGNORE_ERRORS).
        helperChangeMessage.send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
    }
    // The lock keeps a cancelled lock's storage (RESERVE_MODE_AT_MOST: all it has, should that be less);
    // the rest goes back to the creator
    reserveGramsOnBalance(reserve, RESERVE_MODE_AT_MOST);
    returnExcess(creator, queryId, SEND_MODE_CARRY_ALL_BALANCE);
}

// FeesAttested, the till's answer to AttestFees: its fee config at that moment. The lock fixes these rates
// for its life, or cancels its creation when creation is disabled or a fee is above what its creator
// accepted or above the caps. Only the first answer of the lock's own till to the lock's own request
// counts, and only during the setup: any other changes nothing, and its value stays on the lock. (The
// queryId is a guard: a till answers with the queryId it was asked with, and the lock asks with no other
// than its own.)
@noinline
fun LockStorage.onFeesAttested(mutate self, in: LockIncoming, msg: FeesAttested) {
    var live = self.live.load();
    var custody = live.custody.load();
    if (
        in.sender != custody.till || self.status != STATUS_AWAITING_SETUP || custody.feesAttested ||
        msg.queryId != queryIdOf(self.index)
    ) {
        return;
    }
    // The sender is the lock's till, so the gas limit may rise on the lock's own balance, where this
    // handler's gas is budgeted: the answer carries only whatever the till left of the request's value
    setGasLimit(LOCK_GAS_SETUP_STEP);
    val terms = self.terms.load();
    // the caps are checked here too, so neither the root nor a till can raise a fee above them
    if (
        !msg.enabled || msg.flatFee > terms.maxFlatFee ||
        msg.topUpFlatFee > terms.maxTopUpFlatFee ||
        msg.feeBps > terms.maxFeeBps ||
        msg.flatFee > MAX_FLAT_FEE ||
        msg.topUpFlatFee > MAX_FLAT_FEE ||
        msg.feeBps > MAX_FEE_BPS
    ) {
        setGasLimit(LOCK_GAS_COMPLETE);
        self.cancel(
            live,
            custody,
            CANCEL_TILL_REFUSED,
            LOCK_GAS_COMPLETE,
            queryIdOf(self.index),
            null,
            0,
        );
        return;
    }
    live.flatFee = msg.flatFee;
    live.topUpFlatFee = msg.topUpFlatFee;
    live.feeBps = msg.feeBps;
    custody.feesAttested = true;
    self.advanceSetup(live, custody);
}

// ============== Deposits ==============

// transfer_notification: a jetton wallet reports tokens it received for the lock. What becomes of them
// depends on the wallet and on the lock's status. From another wallet than the lock's: sent back, never
// recorded. From the lock's wallet during the setup: the creator's first deposit is the funding, anything
// else is sent back or recorded apart. In a cancelled lock: sent back. In a funded lock: a top-up, a
// duplicate funding (sent back) or a gift (free balance). Nothing is sent back to a sender that is not an
// account (TEP-74 lets a notification name none).
fun LockStorage.onNotification(mutate self, in: LockIncoming, msg: TransferNotification, now: int) {
    var live = self.live.load();
    var custody = live.custody.load();

    if (in.sender != live.jettonWallet) {
        // Another jetton, or a wallet the creator did not name. This lock holds one jetton only: back
        // through the same wallet when the GRAM allows; otherwise they stay there, for the owner once the
        // lock is funded (ClaimForeign), or the creator if the creation is cancelled (RecoverUnrecorded).
        sendBackUncredited(in.sender, in.value, msg, flagged(msg.queryId, QID_UNCREDITED));
        return;
    }

    val previousOwner = msg.sender;
    if (self.status == STATUS_AWAITING_SETUP) {
        // The creator's funding through the lock's wallet fills the one slot, whatever its payload (some
        // wallets drop tags)
        if (
            custody.pendingAmount == 0 && msg.amount > 0 && previousOwner != null &&
            previousOwner == creatorOf(self.terms)
        ) {
            // may complete the funding: budgeted like the attestation
            setGasLimit(LOCK_GAS_SETUP_STEP);
            custody.pendingAmount = msg.amount;
            self.advanceSetup(live, custody);
            return;
        }
        // Anything else through it (a second deposit, someone else's tokens) goes back to its sender when
        // the GRAM allows. If that wallet refuses, the GRAM does not allow or there is no sender to send it
        // back to, it is recorded: free balance once the lock funds, the creator's if the creation is
        // cancelled. A send-back that the network does not carry is dropped (sendBack) and nothing is
        // recorded: the tokens stay in the lock's wallet, in no record. The creator recovers them from a
        // cancelled lock (RecoverUnrecorded); from a funded one its owner takes them with a Sweep after the
        // end, and a permanent lock keeps them (tests/SendBack.spec.ts, tests/Custody.spec.ts).
        if (previousOwner != null && in.value >= sendBackCost(in.sender.getWorkchain())) {
            self.sendBack(in, msg, live, now, true);
            return;
        }
        custody.setupExtra += msg.amount;
        live.custody = custody.toCell();
        self.live = live.toCell();
        self.save();
        return;
    }

    if (self.status == STATUS_CANCELLED) {
        // nothing can be locked here any more: back to the sender (its bounce is not credited: whatever
        // stays is the creator's to recover)
        if (previousOwner != null && in.value >= sendBackCost(in.sender.getWorkchain())) {
            self.sendBack(in, msg, live, now, false);
        }
        return;
    }

    // A funded lock: the forward payload says what the deposit is
    val (tag, _) = payloadOp(msg.forwardPayload);
    if (tag == opcodeOf<TopUpTag>() && previousOwner != null) {
        self.onTopUp(in, msg, live, custody, now);
        return;
    }
    if (
        tag == opcodeOf<FundTag>() && previousOwner != null &&
        in.value >= sendBackCost(in.sender.getWorkchain())
    ) {
        // The same creation sent twice: not a gift, back to its sender
        self.sendBack(in, msg, live, now, true);
        return;
    }
    // Anything else is a gift: not locked, claimable at any time
    self.creditDeposit(live, msg.amount, now);
}

// A deposit that stays (a gift, or one that cannot even be sent back). Once the lock is finished nothing is
// recorded: a sweep takes whatever is there, and may already have taken what this notification is about.
fun LockStorage.creditDeposit(mutate self, live: LockLive, amount: coins, now: int) {
    if (!self.isClosed(live, now)) {
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

// Tokens the lock does not take, back to their sender through the lock's wallet, which reported them, on
// what is left of the notification's value, with a notification for the sender when that GRAM allows
// (sendBackForward). A bounce makes them free balance (QID_SEND_BACK) while the lock is not finished, or
// setupExtra during its setup; otherwise it is not credited (a sweep may have taken them; a cancelled
// lock's tokens are the creator's). Nor is it with `credit` false: what was meant to be locked never
// becomes claimable. A transfer that cannot be sent is dropped (SEND_MODE_IGNORE_ERRORS): refusing a
// notification returns no token.
fun LockStorage.sendBack(
    self,
    in: LockIncoming,
    msg: TransferNotification,
    live: LockLive,
    now: int,
    credit: bool,
) {
    val qid = flagged(
        msg.queryId,
        credit && !self.isClosed(live, now) ? QID_SEND_BACK : QID_UNCREDITED,
    );
    val previousOwner = msg.sender!;
    sendJettonTransfer(
        in.sender,
        qid,
        msg.amount,
        previousOwner,
        previousOwner,
        sendBackForward(in.value, in.sender.getWorkchain()),
        emptyForwardPayload(),
        0,
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
    );
}

// A deposit with a TopUpTag through the lock's wallet. From the owner or the creator, to a funded lock that
// is not finished, with the GRAM a top-up costs: it is added to the schedule, less the fee at the rates
// fixed at setup. Otherwise it goes back to its sender when its GRAM allows; when it does not, anyone
// else's becomes free balance and the owner's or the creator's own stays out of the records.
fun LockStorage.onTopUp(
    mutate self,
    in: LockIncoming,
    msg: TransferNotification,
    live: LockLive,
    custody: LockCustody,
    now: int,
) {
    val from = msg.sender!;
    val wallet = live.jettonWallet;
    val walletWorkchain = wallet.getWorkchain();
    val allowed = from == self.owner || from == creatorOf(self.terms);

    if (
        !allowed || !live.acceptsTopUp(now) || in.value <
        topUpCost(live.topUpFlatFee, walletWorkchain)
    ) {
        // The owner's or the creator's own top-up was meant to be locked and must not become claimable:
        // when its value covers neither taking it nor sending it back (prices rose on its way), or its way
        // back is refused, it is left out of the records, for the sweep at the end (in a permanent lock it
        // stays)
        if (in.value >= sendBackCost(walletWorkchain)) {
            self.sendBack(in, msg, live, now, !allowed);
        } else if (!allowed) {
            // cannot even be sent back: claimable by the owner
            self.creditDeposit(live, msg.amount, now);
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
        var su = custody;
        su.feeSentAt = now;
        l.custody = su.toCell();
        self.live = l.toCell();
    }
    self.save();
    emitLockEvent(LockToppedUpEvent {
        index: self.index,
        amount: msg.amount - fee,
        fee,
        from,
        prevDepositLt,
    });

    val master = self.terms.load().jettonMaster!;
    // The lock keeps the balance it had: the fee and the excess come out of the notification's value
    keepOwnBalance(0);
    // the flat fee straight to the till; the fee tokens through the jetton wallets, their excess to the
    // sender of the top-up, like what is left of the value. Their transfer leaves with exactly the value
    // counted for it, its forward fee paid on top (SEND_MODE_PAY_FEES_SEPARATELY): a top-up is taken only
    // when it brings both (topUpCost).
    sendFeeNotice(
        custody.till,
        self.index,
        master,
        FEE_KIND_TOP_UP,
        0,
        live.topUpFlatFee + tillReceiptValue(),
    );
    if (fee > 0) {
        sendFeeTokens(
            wallet,
            self.index,
            fee,
            custody.till,
            from,
            master,
            FEE_KIND_TOP_UP,
            jettonTransferValueOn(walletWorkchain) + tillReceiptForward(walletWorkchain),
            SEND_MODE_PAY_FEES_SEPARATELY,
        );
    }
    returnExcess(from, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
}

// ============== Main handler ==============

// The messages a lock of jettons takes. InitLock creates it (handleInit): sent to a lock that was created,
// it is refused.
type LockMessage =
    | FeesAttested
    | TransferNotification
    | Claim
    | ExtendLock
    | ClaimForeign
    | ClaimForeignNft
    | Sweep
    | SweepGram
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
    | InitLock
    | Excesses

// Every internal message. `soulbound`: the kind of the contract that calls. A handler refuses a message by
// throwing: the entry file then bounces it or returns its value (refuse, in lock-base).
fun handleLockMessage(in: LockIncoming, soulbound: bool) {
    if (in.body.isEmpty()) {
        return; // plain GRAM stays on the lock, as storage
    }
    if (!isInitialized()) {
        if (isBodyOf<TransferNotification>(in.body)) {
            // Tokens sent to a lock that does not exist (yet): back through the same wallet, when their
            // GRAM allows
            val stray = TransferNotification.fromSlice(in.body);
            sendBackUncredited(in.sender, in.value, stray, flagged(stray.queryId, QID_UNCREDITED));
            return;
        }
        // whatever else reaches an address that is not a lock yet is read as its InitLock
        handleInit(in, soulbound);
        return;
    }

    val msg = lazy LockMessage.fromSlice(in.body);
    var storage = LockStorage.load();
    val now = blockchain.now();

    match (msg) {
        FeesAttested => {
            storage.onFeesAttested(in, msg);
        }

        TransferNotification => {
            storage.onNotification(in, msg, now);
        }

        Claim => {
            // The owner takes claimable tokens (`amount` 0: all of them) to `destination`, through the
            // lock's wallet
            assert (in.sender == storage.owner) throw LockErrors.NotOwner;
            // nothing is the owner's while the lock is being set up or once it is cancelled
            assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
            val live = storage.live.load();
            val custody = live.custody.load();
            assert (msg.destination.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            assert (
                !storage.isForbiddenRecipient(live, custody, msg.destination)
            ) throw LockErrors.ForbiddenAccount;
            val walletWorkchain = live.jettonWallet.getWorkchain();
            assert (
                in.value >=
                claimCost(walletWorkchain, msg.forwardTonAmount) +
                // the forward payload travels lock to wallet, wallet to wallet, wallet to recipient
                payloadCarriage(walletWorkchain, msg.forwardPayload, 3)
            ) throw LockErrors.InsufficientValue;

            var bal = storage.balances.load();
            val available = storage.claimable(bal, live, now);
            val amount: int = msg.amount == 0 ? available : (msg.amount as int);
            assert (amount > 0) throw LockErrors.ZeroAmount;
            assert (amount <= available) throw LockErrors.AmountTooHigh;

            // Free balance first, then scheduled tokens
            val fromFree = min(amount, bal.freeBalance);
            bal.freeBalance -= fromFree;
            bal.claimed += amount - fromFree;
            storage.balances = bal.toCell();
            storage.save();

            // The transfer's excess, and what a bounce of it brings back, go to the response destination
            // the owner names when it is a basechain account, to the owner otherwise
            var response = storage.owner;
            if (
                msg.responseDestination != null &&
                msg.responseDestination.getWorkchain() == BASECHAIN
            ) {
                response = msg.responseDestination;
            }
            emitLockEvent(LockClaimedEvent {
                index: storage.index,
                amount,
                destination: msg.destination,
            });
            // The lock keeps the balance it had; all that is left of the message's value goes with the
            // transfer, which bears no flag: its bounce puts the amount back in the free balance
            keepOwnBalance(0);
            sendJettonTransfer(
                live.jettonWallet,
                msg.queryId & QID_USER_MASK,
                amount,
                msg.destination,
                response,
                msg.forwardTonAmount,
                refPayload(msg.forwardPayload),
                0,
                SEND_MODE_CARRY_ALL_BALANCE,
            );
        }

        ExtendLock => {
            // The owner moves the schedule later or makes the lock permanent: nothing that would unlock
            // anything earlier (extendedSchedule)
            assert (in.sender == storage.owner) throw LockErrors.NotOwner;
            assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
            var live = storage.live.load();
            val next = extendedSchedule(live.permanent, live.schedule, msg, now);
            // The longer life must come with its storage prepayment, the lock's and its wallet's. The
            // lock's is counted against what the lock holds of its own (ownBalance: the balance without
            // this message's value and without a storage fee still due)
            val (extraLock, extraWallet, walletPaidUntil, cost) = extendCost(
                live,
                msg.makePermanent,
                next.end,
                now,
                ownBalance(in.value),
                0,
            );
            assert (in.value >= cost) throw LockErrors.InsufficientValue;

            live.schedule = next;
            live.permanent = msg.makePermanent;
            live.walletPaidUntil = walletPaidUntil;
            storage.live = live.toCell();
            storage.save();

            emitLockEvent(LockExtendedEvent {
                index: storage.index,
                permanent: live.permanent,
                schedule: live.schedule,
            });
            // The lock keeps the balance it had and its extra prepayment. The wallet gets its own in a
            // plain transfer: extraWallet exactly, its forward fee paid on top
            // (SEND_MODE_PAY_FEES_SEPARATELY; extendCost counts it), and skipped alone should it fail to
            // leave, so that the extension stands (SEND_MODE_IGNORE_ERRORS). The rest of the value goes
            // back.
            keepOwnBalance(extraLock);
            if (extraWallet > 0) {
                val walletStorageMessage = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: live.jettonWallet,
                    value: extraWallet,
                    body: PlainGram {},
                });
                walletStorageMessage.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
            }
            returnExcess(in.sender, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }

        ClaimForeign => {
            // The owner takes tokens that any wallet but the lock's own holds for the lock, on the
            // message's own value. Nothing is recorded, and a bounce leaves them where they were.
            assert (in.sender == storage.owner) throw LockErrors.NotOwner;
            // Nothing in a lock that is not funded is the owner's: during setup the creator's funding may
            // sit in any wallet, and a cancelled lock's wallets hold only the creator's tokens
            // (RecoverUnrecorded)
            assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
            val live = storage.live.load();
            val custody = live.custody.load();
            assert (msg.destination.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            // the transfer goes to the wallet named: it is on a chain a message can be sent to
            val walletWorkchain = reachableWorkchain(msg.wallet);
            assert (
                !storage.isForbiddenRecipient(live, custody, msg.destination) &&
                msg.destination != msg.wallet
            ) throw LockErrors.ForbiddenAccount;
            // the wallet the lock holds its tokens in is reached by Claim and Sweep only
            assert (msg.wallet != live.jettonWallet) throw LockErrors.ForbiddenAccount;
            assert (msg.amount > 0) throw LockErrors.ZeroAmount;
            assert (
                in.value >= claimForeignCost(walletWorkchain)
            ) throw LockErrors.InsufficientValue;
            sendJettonTransfer(
                msg.wallet,
                flagged(msg.queryId, QID_UNCREDITED),
                msg.amount,
                msg.destination,
                in.sender,
                0,
                emptyForwardPayload(),
                0,
                ON_REQUEST_VALUE,
            );
        }

        ClaimForeignNft => {
            // An NFT that reached the lock is handed on, on the message's own value: by the owner of a
            // funded lock, or out of a cancelled one by its creator, or by anyone to its creator
            // (assertMayMoveForeign)
            assertMayMoveForeign(
                in.sender,
                msg.newOwner,
                storage.status,
                storage.owner,
                storage.terms,
            );
            val live = storage.live.load();
            assert (msg.nft != contract.getAddress()) throw LockErrors.ForbiddenAccount;
            assert (msg.newOwner.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            assert (
                !storage.isForbiddenRecipient(live, live.custody.load(), msg.newOwner) &&
                msg.newOwner != msg.nft
            ) throw LockErrors.ForbiddenAccount;
            assert (
                in.value >= answerCost(reachableWorkchain(msg.nft), false, null)
            ) throw LockErrors.InsufficientValue;
            sendForeignNft(msg.nft, msg.queryId, msg.newOwner, in.sender);
        }

        Sweep => {
            // The owner of a funded lock that is finished moves whatever its wallet holds: what was locked,
            // the free balance and what no record counts
            assert (in.sender == storage.owner) throw LockErrors.NotOwner;
            // nothing in a cancelled lock is the owner's: its wallet holds the creator's tokens
            assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
            var live = storage.live.load();
            var custody = live.custody.load();
            assert (storage.isFinished(live, now)) throw LockErrors.NotFinished;
            assert (msg.destination.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            assert (
                !storage.isForbiddenRecipient(live, custody, msg.destination)
            ) throw LockErrors.ForbiddenAccount;
            assert (msg.amount > 0) throw LockErrors.ZeroAmount;
            // A fee transfer to the till may still bounce back (restoring feeOwed) until TRANSFER_SETTLE
            // after it: the sweep waits, so it can never take those tokens. It waits for FEE_GIVE_UP after
            // the end at most, and from then on no longer pays them first: a fee transfer the wallet always
            // refuses, or anyone's RetryFee every day, must not keep what is the owner's for ever.
            val gaveUp = live.feeGivenUp(now);
            assert (
                gaveUp || now >= custody.feeSentAt + TRANSFER_SETTLE
            ) throw JettonErrors.FeeUnsettled;
            assert (
                in.value >= sweepCost(live.jettonWallet.getWorkchain(), custody.feeOwed)
            ) throw LockErrors.InsufficientValue;
            val owed = custody.feeOwed;
            if (owed > 0 && !gaveUp) {
                // The till's tokens first, alone and with all the GRAM; the sweep itself can run once this
                // transfer has settled
                custody.feeOwed = 0;
                custody.feeSentAt = now;
                live.custody = custody.toCell();
                storage.live = live.toCell();
                storage.save();
                sendFeeTokens(
                    live.jettonWallet,
                    storage.index,
                    owed,
                    custody.till,
                    storage.owner,
                    storage.terms.load().jettonMaster!,
                    FEE_KIND_RETRY,
                    0,
                    ON_REQUEST_VALUE,
                );
                return;
            }
            // Settle the accounting (nothing is locked any more), so the get methods never show swept
            // tokens; the jetton wallet's own balance check bounds the amount. `amount` is what the owner
            // asked for, not what the wallet held.
            var bal = storage.balances.load();
            bal.claimed = bal.totalAmount;
            bal.freeBalance = 0;
            storage.balances = bal.toCell();
            // fee tokens still owed here are given up (FEE_GIVE_UP has passed): they leave with the rest
            custody.feeOwed = 0;
            live.custody = custody.toCell();
            storage.live = live.toCell();
            storage.save();
            emitLockEvent(LockSweptEvent {
                index: storage.index,
                amount: msg.amount,
                destination: msg.destination,
            });
            // As for a Claim, but flagged QID_UNCREDITED: a bounce restores nothing, the tokens are still
            // there to sweep
            keepOwnBalance(0);
            sendJettonTransfer(
                live.jettonWallet,
                flagged(msg.queryId, QID_UNCREDITED),
                msg.amount,
                msg.destination,
                storage.owner,
                0,
                emptyForwardPayload(),
                0,
                SEND_MODE_CARRY_ALL_BALANCE,
            );
        }

        SweepGram => {
            // The owner of a funded lock that is finished takes the GRAM the lock does not need any more:
            // the storage paid for a life it will not have, and plain GRAM that reached it. The tokens
            // leave with a Sweep, before or after this one. No record changes, so there is no event.
            assert (in.sender == storage.owner) throw LockErrors.NotOwner;
            storage.assertSweepsGram(msg.destination, now);
            assert (in.value >= lockSweepGramCost()) throw LockErrors.InsufficientValue;
            // The lock ends with exactly what sweepKeeps allows it (RESERVE_MODE_EXACT_AMOUNT): of its own
            // GRAM, counted without this message's value and without a storage fee still due, the storage
            // of a cancelled lock at most. Everything else leaves with the payout, and nothing goes to the
            // lock's jetton wallet. A balance that cannot meet the reserve fails the sweep, and the request
            // bounces with its value if it asked to (RESERVE_MODE_BOUNCE_ON_ACTION_FAIL).
            reserveGramsOnBalance(
                sweepKeeps(ownBalance(in.value), 0, lockCancelledReserve()),
                RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
            );
            payOut(msg.destination);
        }

        RetryFunding => {
            // Anyone: ask the till again while it has not answered (it was not deployed, or not configured,
            // when the lock asked). The lock keeps the balance it had: the request is paid from the
            // caller's value, and the rest of it comes back to the caller.
            assert (storage.status == STATUS_AWAITING_SETUP) throw LockErrors.BadStatus;
            val custody = storage.live.load().custody.load();
            assert (!custody.feesAttested) throw JettonErrors.NothingToRetry;
            assert (in.value >= retryFundingCost()) throw LockErrors.InsufficientValue;
            keepOwnBalance(0);
            askTillForFees(custody.till, storage.index);
            returnExcess(in.sender, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }

        RetryRefund => {
            // Anyone: send again the refund a cancelled lock owes its creator, whose transfer bounced or
            // could not be paid. Its excess, or what a bounce leaves, is the caller's.
            assert (storage.status == STATUS_CANCELLED) throw LockErrors.BadStatus;
            var live = storage.live.load();
            var custody = live.custody.load();
            assert (custody.pendingAmount > 0) throw JettonErrors.NothingToRetry;
            assert (
                in.value >= retryCost(live.jettonWallet.getWorkchain(), false)
            ) throw LockErrors.InsufficientValue;
            val amount = custody.pendingAmount;
            custody.pendingAmount = 0;
            custody.refundSentAt = now;
            live.custody = custody.toCell();
            storage.live = live.toCell();
            storage.save();
            // the gas of restoring the record on a bounce stays here, paid by the caller
            keepOwnBalance(bouncePrepay());
            sendJettonTransfer(
                live.jettonWallet,
                pendingQueryId(custody.walletSeq),
                amount,
                creatorOf(storage.terms),
                in.sender,
                0,
                emptyForwardPayload(),
                0,
                SEND_MODE_CARRY_ALL_BALANCE,
            );
        }

        RetryFee => {
            // Anyone: send again the fee tokens a funded lock owes its till, whose transfer bounced. Its
            // excess, or what a bounce leaves, is the caller's.
            assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
            var live = storage.live.load();
            var custody = live.custody.load();
            assert (custody.feeOwed > 0) throw JettonErrors.NothingToRetry;
            assert (
                in.value >= retryCost(live.jettonWallet.getWorkchain(), true)
            ) throw LockErrors.InsufficientValue;
            val amount = custody.feeOwed;
            custody.feeOwed = 0;
            custody.feeSentAt = now;
            live.custody = custody.toCell();
            storage.live = live.toCell();
            storage.save();
            // the gas of restoring the record on a bounce stays here, paid by the caller
            keepOwnBalance(bouncePrepay());
            sendFeeTokens(
                live.jettonWallet,
                storage.index,
                amount,
                custody.till,
                in.sender,
                storage.terms.load().jettonMaster!,
                FEE_KIND_RETRY,
                0,
                SEND_MODE_CARRY_ALL_BALANCE,
            );
        }

        CancelCreation => {
            // Ends a creation that has not completed (cancel)
            assert (storage.status == STATUS_AWAITING_SETUP) throw LockErrors.BadStatus;
            val live = storage.live.load();
            val creator = creatorOf(storage.terms);
            // The creator may give up at any time; anyone else only once the creation can no longer
            // complete, so nobody can cancel a creation its creator is still funding
            assert (
                in.sender == creator || now > live.createdAt + SETUP_WINDOW
            ) throw LockErrors.TooEarly;
            // enough to pay the refund, so the creator never waits on a second message
            assert (
                in.value >= cancelCost(live.jettonWallet.getWorkchain())
            ) throw LockErrors.InsufficientValue;
            if (in.sender == creator) {
                storage.cancel(
                    live,
                    live.custody.load(),
                    CANCEL_REQUESTED,
                    LOCK_GAS_CANCEL,
                    msg.queryId,
                    null,
                    0,
                );
            } else {
                // a helper pays for the cancel only: the rest of its value comes back to it
                storage.cancel(
                    live,
                    live.custody.load(),
                    CANCEL_EXPIRED,
                    LOCK_GAS_CANCEL,
                    msg.queryId,
                    in.sender,
                    in.value,
                );
            }
        }

        RecoverUnrecorded => {
            // Everything in a cancelled lock's wallets is the creator's: funding that arrived before the
            // lock existed, a refund the creator's own jetton wallet refused (it came back silently),
            // deposits that could not be sent back during the setup. Any wallet may be named: genuine or
            // not, it only moves what it holds for the lock.
            // Through the lock's own wallet while a refund is owed, the recovery is that refund: the record
            // shrinks first, so RetryRefund can never pay it a second time from other tokens. Otherwise it
            // takes what no record counts. In the lock's own wallet that can be the tokens of a refund on
            // its way, which left the record at 0: should that refund bounce, it must then restore nothing
            // (walletSeq). The creator may do that at any time; anyone else recovers for the creator only
            // once TRANSFER_SETTLE has passed since the latest refund transfer, so nobody else can keep the
            // record of a refused refund at 0.
            assert (storage.status == STATUS_CANCELLED) throw LockErrors.BadStatus;
            var live = storage.live.load();
            var custody = live.custody.load();
            // anyone may recover for the creator; only the creator may send the tokens elsewhere
            val creator = creatorOf(storage.terms);
            assert (in.sender == creator || msg.destination == creator) throw LockErrors.NotCreator;
            assert (msg.destination.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            // the transfer goes to the wallet named: it is on a chain a message can be sent to
            val walletWorkchain = reachableWorkchain(msg.wallet);
            assert (
                !storage.isForbiddenRecipient(live, custody, msg.destination) &&
                msg.destination != msg.wallet
            ) throw LockErrors.ForbiddenAccount;
            assert (msg.amount > 0) throw LockErrors.ZeroAmount;
            if (msg.wallet == live.jettonWallet && custody.pendingAmount > 0) {
                // Through the lock's own wallet while a refund is owed, the recovery is that refund, at
                // most the amount owed: the record shrinks now and a bounce restores it, as for RetryRefund
                // (whose bounce gas the caller pays here too)
                assert (msg.amount <= custody.pendingAmount) throw LockErrors.AmountTooHigh;
                assert (
                    in.value >= recoverCost(walletWorkchain, true)
                ) throw LockErrors.InsufficientValue;
                custody.pendingAmount -= msg.amount;
                custody.refundSentAt = now;
                live.custody = custody.toCell();
                storage.live = live.toCell();
                storage.save();
                keepOwnBalance(bouncePrepay());
                sendJettonTransfer(
                    msg.wallet,
                    pendingQueryId(custody.walletSeq),
                    msg.amount,
                    msg.destination,
                    in.sender,
                    0,
                    emptyForwardPayload(),
                    0,
                    SEND_MODE_CARRY_ALL_BALANCE,
                );
                return;
            }
            // anything else is uncredited: on a bounce the tokens are still there to recover again
            assert (
                in.value >= recoverCost(walletWorkchain, false)
            ) throw LockErrors.InsufficientValue;
            if (msg.wallet == live.jettonWallet) {
                // This may take what a refund still on its way left in that wallet (its bounce has not come
                // back yet): that bounce must not restore the record over tokens gone. The creator's choice
                // alone while a refund may still be on its way.
                assert (
                    in.sender == creator || now >= custody.refundSentAt + TRANSFER_SETTLE
                ) throw LockErrors.TooEarly;
                custody.walletSeq = nextWalletSeq(custody.walletSeq);
                live.custody = custody.toCell();
                storage.live = live.toCell();
                storage.save();
            }
            sendJettonTransfer(
                msg.wallet,
                flagged(msg.queryId, QID_UNCREDITED),
                msg.amount,
                msg.destination,
                in.sender,
                0,
                emptyForwardPayload(),
                0,
                ON_REQUEST_VALUE,
            );
        }

        NftTransfer => {
            // TEP-62: the owner of a funded lock of the transferable kind hands it on (the checks and the
            // messages of a transfer are in lock-base)
            assertMayTransfer(in.sender, soulbound, storage.status, storage.owner);
            // nobody could ever claim a lock owned by the root, its till, its jetton wallet or itself
            val live = storage.live.load();
            assertTransferable(
                in,
                msg,
                storage.isForbiddenRecipient(live, live.custody.load(), msg.newOwner),
            );
            val prevOwner = storage.owner;
            storage.owner = msg.newOwner;
            storage.save();
            sendOwnershipMessages(msg, prevOwner);
        }

        GetStaticData => {
            // TEP-62: the index and the collection, to whoever asks, on the request's own value
            assert (
                in.value >= answerCost(in.sender.getWorkchain(), false, null)
            ) throw LockErrors.InsufficientValue;
            sendStaticData(in.sender, msg.queryId, storage.index, storage.collection);
        }

        ProveOwnership => {
            // TEP-85: the owner of a funded lock of the soulbound kind has it prove its ownership to `dest`
            assertProves(in.sender, soulbound, storage.status, storage.owner, true);
            assert (
                in.value >=
                answerCost(reachableWorkchain(msg.dest), msg.withContent, msg.forwardPayload)
            ) throw LockErrors.InsufficientValue;
            sendOwnershipProof(msg, storage.index, storage.owner);
        }

        RequestOwner => {
            // TEP-85: anyone has a funded lock of the soulbound kind tell `dest` who owns it
            assertProves(in.sender, soulbound, storage.status, storage.owner, false);
            assert (
                in.value >=
                answerCost(reachableWorkchain(msg.dest), msg.withContent, msg.forwardPayload)
            ) throw LockErrors.InsufficientValue;
            sendOwnerInfo(in.sender, msg, storage.index, storage.owner);
        }

        Destroy => {
            throw LockErrors.NotSupported; // TEP-85: a lock is never destroyed, it stays as a record
        }

        Revoke => {
            throw LockErrors.NotSupported; // TEP-85: a lock has no authority, nobody can revoke it
        }

        StorageTopUp => {
            // Accepted: its value stays on the lock, as storage. The save brings lastTx to now when no
            // storage fee is left due, so that the quotes count the storage from this message on, and not
            // from an earlier save.
            storage.save();
        }

        RequestLockState => {
            // Read-only, to whoever asks, on the request's own value. Whoever has just been given a lock
            // (ownership_assigned) can rely on it: only the owner can then lessen what the lock holds
            assert (
                in.value >= answerCost(in.sender.getWorkchain(), false, null)
            ) throw LockErrors.InsufficientValue;
            val live = storage.live.load();
            val bal = storage.balances.load();
            val lockStateMessage = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.sender,
                value: 0,
                body: LockState {
                    queryId: msg.queryId,
                    index: storage.index,
                    status: storage.status,
                    permanent: live.permanent,
                    schedule: live.schedule,
                    totalAmount: bal.totalAmount,
                    claimed: bal.claimed,
                    freeBalance: bal.freeBalance,
                    parties: LockStateParties {
                        owner: storage.owner,
                        jettonMaster: storage.terms.load().jettonMaster,
                        jettonWallet: live.jettonWallet,
                    }.toCell(),
                },
            });
            lockStateMessage.send(ON_REQUEST_VALUE);
        }

        InitLock => {
            // this lock was created: a creation sent again is refused, and what it carries goes back
            throw LockErrors.AlreadyCreated;
        }

        Excesses => {
            // accepted like plain GRAM: an excess that names the lock as its destination stays, as storage
        }

        else => {
            throw LockErrors.UnknownOp;
        }
    }
}

// Bounces of the lock's own messages. A bounce restores the record its message took away, and gives what is
// left of its GRAM back to whoever paid: the bounced message's response destination. The setup request
// carries the budget's GRAM, or the caller's when RetryFunding sent it: during the setup a bounce leaves it
// in the budget (RetryFunding re-asks), afterwards it goes to the creator. A restore that may need more gas
// than its bounce brings raises the gas limit on the lock's balance only where whoever triggered the
// transfer prepaid it (bouncePrepay) or is the owner, the creator or the creation's budget; other bounces
// run on their own value.
fun handleLockBounce(in: LockIncoming) {
    // Only bounces in the form the lock asks for (LOCK_BOUNCE) are read: what any other carries stays here.
    // (isInitialized is a guard: an address where no lock was created has sent nothing to bounce.)
    if (!isInitialized() || !isBodyOf<RichBounceBody>(in.body)) {
        return;
    }
    // lazily: fields are read on demand, so a later extension of the format still parses
    val rich = lazy RichBounceBody.fromSlice(in.body);
    var body = rich.originalBody.beginParse();
    val op = body.loadUint(OPCODE_BITS);
    val queryId = body.loadUint(64);
    var storage = LockStorage.load();

    // an ownership proof, an owner info or a foreign NFT's transfer came back: nothing to restore, its
    // value goes back (lock-base)
    if (returnStandardBounce(op, queryId, body, storage.owner)) {
        return;
    }
    if (op != opcodeOf<JettonTransfer>()) {
        // the lock's only other bounceable message, the setup request: nothing to restore
        returnSetupBounce(storage.status, storage.terms, storage.index);
        return;
    }
    val amount = body.loadCoins();
    body.skipAny<address>(); // destination
    val response = body.loadAddressOpt();
    var live = storage.live.load();
    var custody = live.custody.load();

    if ((queryId & QID_UNCREDITED) != 0) {
        // sweeps, foreign claims, recoveries, send-backs not to be credited: the tokens stay in the wallet,
        // nothing is recorded
    } else if ((queryId & QID_PENDING) != 0) {
        // The refund of pending funding was refused by the lock's wallet: still owed, RetryRefund. Unless a
        // recovery of what no record counts went out through the wallet after it and may have taken those
        // tokens (the wallet runs the lock's transfers in order): then they are left unrecorded, the
        // creator's to recover as they are.
        // (The status and the sender are guards: a refund leaves a cancelled lock only, through its own
        // wallet only.)
        if (
            storage.status == STATUS_CANCELLED && in.sender == live.jettonWallet &&
            (queryId & WALLET_SEQ_MASK) == custody.walletSeq
        ) {
            setGasLimit(LOCK_GAS_BOUNCE);
            custody.pendingAmount += amount;
            live.custody = custody.toCell();
            storage.live = live.toCell();
            storage.save();
        }
    } else if (in.sender != live.jettonWallet) {
        // (The sender is a guard: every record below is about the lock's own wallet, and every transfer
        // whose bounce can restore one went through it. A bounce from any other account restores nothing.)
    } else if ((queryId & QID_FEE) != 0) {
        // The lock's wallet refused to pay the till: the tokens stay owed (RetryFee, Sweep), until a sweep
        // no longer waits for them.
        // (The status is a guard: fee tokens leave a funded lock only, and a funded lock stays funded.)
        if (storage.status == STATUS_FUNDED && !live.feeGivenUp(blockchain.now())) {
            setGasLimit(LOCK_GAS_BOUNCE);
            custody.feeOwed += amount;
            live.custody = custody.toCell();
            storage.live = live.toCell();
            storage.save();
        }
    } else if (storage.isClosed(live, blockchain.now())) {
        // once the lock is finished a sweep may already have taken them: whatever is still there is
        // sweepable (the creator's to recover, in a cancelled lock), nothing is credited
    } else if ((queryId & QID_SEND_BACK) != 0) {
        // A deposit the lock sent back came back: it stays as a gift does, free balance, or setupExtra
        // during the setup (free balance once the lock funds). On the bounce's own value and without an
        // event: whoever made it bounce pays for this.
        if (storage.status == STATUS_AWAITING_SETUP) {
            custody.setupExtra += amount;
            live.custody = custody.toCell();
            storage.live = live.toCell();
            storage.save();
        } else {
            storage.creditFree(amount);
        }
    } else {
        // A claim the jetton wallet refused: the tokens are still there, make them claimable again
        setGasLimit(LOCK_GAS_BOUNCE);
        storage.creditFree(amount);
        // the record is restored whether or not the event can be paid for (emitLockEventIfPaid)
        emitLockEventIfPaid(LockClaimRestoredEvent {
            index: storage.index,
            amount,
        });
        // The event and this handler are paid from the bounced value as far as it goes: the lock keeps the
        // balance it had before the bounce, or all it has if the bounce brought less than they cost
        // (RESERVE_MODE_AT_MOST), and what is above that goes back
        reserveGramsOnBalance(0, RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_AT_MOST);
        if (response != null) {
            returnExcess(response, queryId & QID_USER_MASK, SEND_MODE_CARRY_ALL_BALANCE);
        }
        return;
    }
    // what is left of the bounce's value goes to the response destination of the transfer that bounced
    returnBounced(response, queryId & QID_USER_MASK);
}

// ============== Get methods ==============
// What the get methods answer once the lock was created (lock-base describes how they are declared)

// TEP-62: (init?, index, collection, owner, individual_content). The content is the index in decimal, which
// the root appends to its base URI (get_nft_content).
fun viewNftData(): (bool, int, address, address?, cell) {
    val storage = LockStorage.load();
    return (
        true,
        storage.index,
        storage.collection,
        storage.owner,
        decimalStringCell(storage.index),
    );
}

// get_lock_data: the lock as it stands (LockInfo, in lock-base). `totalAmount` counts once the lock is
// funded, `expectedAmount` while it awaits its setup.
fun viewLockData(): LockInfo {
    val storage = LockStorage.load();
    val terms = storage.terms.load();
    val live = storage.live.load();
    val bal = storage.balances.load();
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
        totalAmount: bal.totalAmount,
        expectedAmount: storage.status == STATUS_AWAITING_SETUP ? terms.expectedAmount : 0,
        claimed: bal.claimed,
        freeBalance: bal.freeBalance,
        claimableNow: storage.claimable(bal, live, blockchain.now()),
        topUpFlatFee: live.topUpFlatFee,
        feeBps: live.feeBps,
        version: SWORN_VERSION,
        lastDepositLt: bal.lastDepositLt,
        createBefore: terms.createBefore,
    };
}

// get_custody_data: what this lock holds and owes besides its schedule (CustodyInfo, in lock-base).
// `sweepFrom` is when a Sweep and a SweepGram stop waiting for the lock's latest fee transfer:
// TRANSFER_SETTLE after it, and FEE_GIVE_UP after the lock's end at the latest. It is 0 where nothing
// waits: no fee transfer went out, or the lock is permanent and is never swept. `recoverFrom` is from when
// anyone, and not only the creator, recovers what no record counts in a cancelled lock's wallet:
// TRANSFER_SETTLE after the latest refund transfer. It is 0 where no refund transfer went out, as in every
// lock that is not cancelled.
fun viewCustodyData(): CustodyInfo {
    val live = LockStorage.load().live.load();
    val custody = live.custody.load();
    return {
        till: custody.till,
        feesAttested: custody.feesAttested,
        pendingAmount: custody.pendingAmount,
        feeOwed: custody.feeOwed,
        flatFee: live.flatFee,
        setupExtra: custody.setupExtra,
        setupDeadline: live.createdAt + SETUP_WINDOW,
        cancelReason: custody.cancelReason,
        sweepFrom: custody.feeSentAt == 0 || live.permanent
            ? 0
            : min(custody.feeSentAt + TRANSFER_SETTLE, live.schedule.end + FEE_GIVE_UP),
        recoverFrom: custody.refundSentAt == 0 ? 0 : custody.refundSentAt + TRANSFER_SETTLE,
        walletPaidUntil: live.walletPaidUntil,
    };
}

// The immutable terms this lock's index commits to
fun viewLockTerms(): cell {
    return LockStorage.load().terms;
}

// Unlocked amount of the schedule at time t (ignores claims and free balance): 0 unless the lock is funded,
// and 0 in a permanent lock
fun viewUnlockedAt(t: int): int {
    val storage = LockStorage.load();
    val live = storage.live.load();
    if (storage.status != STATUS_FUNDED || live.permanent) {
        return 0;
    }
    return live.schedule.unlockedAt(storage.balances.load().totalAmount, t);
}

// What a Claim can take now: the free balance, and what the schedule has unlocked and not paid out
fun viewClaimable(): int {
    val storage = LockStorage.load();
    return storage.claimable(storage.balances.load(), storage.live.load(), blockchain.now());
}

// The workchain of the lock's jetton wallet, which prices what goes through it
fun lockWalletWorkchain(): int {
    return LockStorage.load().live.load().jettonWallet.getWorkchain();
}

// GRAM a Claim with this forward amount and no forward payload must carry
fun viewClaimCost(forwardTonAmount: int): int {
    return claimCost(lockWalletWorkchain(), forwardTonAmount);
}

// GRAM a Claim with this forward amount and forward payload must carry. Get methods take no nullable
// argument: common APIs (toncenter's runGetMethod) cannot pass a null.
fun viewClaimCostWithPayload(forwardTonAmount: int, forwardPayload: cell): int {
    val workchain = lockWalletWorkchain();
    return claimCost(workchain, forwardTonAmount) + payloadCarriage(workchain, forwardPayload, 3);
}

// GRAM to attach (forward_ton_amount) to a top-up of this lock, storage debt included, with room for a
// wallet delivering a little less
fun viewTopUpCost(): int {
    val storage = LockStorage.load();
    val live = storage.live.load();
    val walletWorkchain = live.jettonWallet.getWorkchain();
    return topUpCost(live.topUpFlatFee, walletWorkchain) +
        storageDebtBound(storage.lastTx, LOCK_STATE_BITS, LOCK_STATE_CELLS) +
        FORWARD_SLACK +
        forwardShave(walletWorkchain);
}

// GRAM a Sweep must carry (more while fee tokens are owed to the till)
fun viewSweepCost(): int {
    val live = LockStorage.load().live.load();
    return sweepCost(live.jettonWallet.getWorkchain(), live.custody.load().feeOwed);
}

// What a SweepGram would pay now, on top of what is left of its own value: the GRAM the lock holds above
// the storage it keeps, as a get method sees its balance (balanceNow, in lock-base). Nothing while the lock
// refuses a SweepGram for what it is (assertSweepsGram): before its end, in a permanent lock, during its
// setup, once cancelled, and while fee tokens are owed to the till or on their way to it.
fun viewSweepGramAmount(): int {
    val storage = LockStorage.load();
    try {
        storage.assertSweepsGram(null, blockchain.now());
    } catch {
        return 0; // the lock refuses a SweepGram as it stands: nothing is due
    }
    val own = max(balanceNow(storage.lastTx, LOCK_STATE_BITS, LOCK_STATE_CELLS), 0);
    return own - sweepKeeps(own, 0, lockCancelledReserve());
}

// GRAM a transfer of this lock's jetton needs on top of its forward_ton_amount: TEP-74's bound on what it
// may cost, on the chain of the lock's wallet (an app attaches this much plus get_top_up_cost to a top-up;
// the rest comes back)
fun viewJettonTransferValue(): int {
    return jettonTransferValueOn(lockWalletWorkchain());
}

// GRAM to attach to an ExtendLock to `end` (or one that makes the lock permanent), for a message landing up
// to QUOTE_MARGIN from now
fun viewExtendCost(permanent: bool, end: int): int {
    val storage = LockStorage.load();
    val live = storage.live.load();
    val now = blockchain.now();
    // the balance here is before the storage fee due since the last save with nothing due: take out an
    // upper bound; a permanent lock's life (and its wallet's storage) runs from when the message lands
    val (_extraLock, _extraWallet, _walletPaidUntil, cost) = extendCost(
        live,
        permanent || live.permanent,
        permanent ? 0 : end,
        now,
        contract.getOriginalBalance() -
            storageDebtBound(storage.lastTx, LOCK_STATE_BITS, LOCK_STATE_CELLS),
        QUOTE_MARGIN,
    );
    return cost;
}

// GRAM a CancelCreation must carry
fun viewCancelCost(): int {
    return cancelCost(lockWalletWorkchain());
}

// GRAM that covers a RetryRefund and a RetryFee alike: what a RetryFee must carry, which is the more of the
// two (a RetryRefund's transfer has no receipt to pay for, and what it does not use comes back)
fun viewRetryCost(): int {
    return retryCost(lockWalletWorkchain(), true);
}
