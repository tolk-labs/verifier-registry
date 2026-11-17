tolk 1.5

import "@stdlib/exotic-cells"
import "@stdlib/gas-payments"
import "lock-base"
import "messages"
import "sworn"

// Sworn lock of GRAM: an NFT (TEP-62) whose own balance holds the locked GRAM, and the only contract with
// per-lock state. It is its own creation record.
//
// This file has what only a lock of GRAM does. The two contracts that are a lock of GRAM
// (sworn-gram-lock-transferable.tolk and sworn-gram-lock-soulbound.tolk) declare the entrypoints and the
// get methods and call the handlers here, telling them which kind they are. What a lock of GRAM shares with
// a lock of jettons (lock-core.tolk) is in lock-base.tolk, the message layouts are in messages.tolk, and
// the constants, the schedule math, the address derivations and the costs are in sworn.tolk.
//
// Trust model:
// - Address = hash(code, {root, index}) with index = hash(terms) and the kind in its two low bits: only the
//   creator the terms name can create the lock, only with the terms its index commits to, and only until
//   the terms' createBefore. The lock takes no instruction from the root.
// - It holds what its account holds: there is no jetton wallet, so nothing here is anyone's word. The GRAM
//   comes with InitGramLock and with the top-ups of the owner and the creator; nothing else adds to the
//   schedule.
// - Fees go to the lock's till (root-derived) at the rates the till attested during setup, in GRAM.
// - Once the lock is funded, nobody but its owner can move the GRAM, and only as the schedule allows. No
//   admin, no upgrade.
// - One balance holds what is locked and what pays the lock's storage. GRAM leaves the locked part only by
//   a claim, a sweep of a finished lock, the refund of a creation that failed and the fee of a funding or a
//   top-up. A handler that sends anything either sends one message carrying what is left of the incoming
//   value and no more, or reserves the balance it must leave (keepOwnBalance and the like) before any
//   message that carries everything above it: a handler that would leave less fails there. The setup has
//   two exceptions. The till's answer spends the balance on gas, from the creator's budget. A creation that
//   is cancelled keeps at most the storage of a cancelled lock, and everything else goes back to the
//   creator.
// - What the lock pays out goes in messages that cannot bounce: it is the destination's whatever its code
//   does, so no payout comes back by failing and nothing is ever claimable outside the schedule. GRAM a
//   destination sends the lock of its own accord is plain GRAM: storage, as from anyone.
// - The lock sends its owner's own words only in the places meant for them: the forward payload of an NFT
//   transfer (TEP-62), the data of an ownership proof (TEP-85) and the text comment of a payout (opcode 0).
//   A payout carries nothing else, so never a body that could pass for a message of the lock's own.
// - Storage is paid in advance for the lock's life and STORAGE_GRACE more (for PERMANENT_STORAGE_HORIZON if
//   the lock is permanent), and anyone can add to it (a plain transfer). Should it ever run out, the
//   network takes its storage fee from the balance, which is then the locked GRAM: the lock reports and
//   pays what it still holds, and storage paid later makes it whole.

// The codes only a lock of GRAM throws, next to those of every lock (LockErrors, in lock-base)
enum GramErrors {
    NotParty = 423   // only the owner or the creator adds GRAM to a lock
    Finished = 424   // nothing is added to a lock whose schedule has ended
    BadComment = 425 // a payout carries a text comment or nothing
}

struct GramLockBalances {
    totalAmount: coins // locked by the schedule (0 until funded)
    claimed: coins     // of it, already paid out (all of it once the lock is swept)
    // logical time of the transaction of the latest deposit (the funding or a top-up): each deposit's event
    // names the previous one, so the list of deposits is read in O(deposits)
    lastDepositLt: uint64
}

// What the lock records next to its terms, whose cell is immutable and hashed into the index: when it was
// created, the schedule in force (an extension changes it), the fee rates fixed at its setup, its till, and
// why it was cancelled if it was
struct GramLockLive {
    createdAt: uint48   // when InitGramLock came: SETUP_WINDOW runs from then
    permanent: bool
    schedule: Schedule  // zeros for permanent locks
    flatFee: coins      // fee rates fixed at setup from the till's attestation
    topUpFlatFee: coins
    feeBps: uint16
    till: address       // the lock's till (index mod TILL_COUNT), derived at its creation
    cancelReason: uint8 // CANCEL_* once cancelled (0 otherwise): readable without the history
}

// The lock's data. Its first two fields are the data the lock is deployed with (LockInitData): the root,
// which TEP-62 calls the collection, and the index. `status` is STATUS_AWAITING_SETUP, STATUS_FUNDED or
// STATUS_CANCELLED.
struct GramLockStorage {
    collection: address
    index: uint256
    status: uint8
    owner: address
    // last time the state was saved with no storage fee due: the storage due now is at most what accrued
    // since then (the quotes count from it)
    lastTx: uint48
    balances: Cell<GramLockBalances>
    terms: Cell<LockTerms>
    live: Cell<GramLockLive>
}

@noinline
fun GramLockStorage.load(): GramLockStorage {
    return GramLockStorage.fromCell(contract.getData());
}

@noinline
fun GramLockStorage.save(self) {
    var s = self;
    // lastTx moves only when no storage fee is due. A fee can still be due here: the network charges
    // storage before it credits the value of a bounceable message, and leaves what the balance could not
    // pay to the next transaction. The storage such a debt is for accrued since the last save made without
    // one, and the quotes must keep counting from there.
    if (contract.getStorageDuePayment() == 0) {
        s.lastTx = blockchain.now();
    }
    contract.setData(s.toCell());
}

// Accounts a lock never pays out to or hands itself to: the root and the till would keep the GRAM as
// theirs, and what the lock sent itself would stay in it unrecorded
fun GramLockStorage.isForbiddenRecipient(self, live: GramLockLive, a: address): bool {
    return a == self.collection || a == live.till || a == contract.getAddress();
}

// ============== Accounting ==============

// The GRAM this lock owes: the creator's while it is set up, what the schedule has not paid out once it is
// funded, none once cancelled (it all went back)
fun GramLockStorage.owed(self, bal: GramLockBalances): coins {
    if (self.status == STATUS_FUNDED) {
        return bal.totalAmount - bal.claimed;
    }
    if (self.status == STATUS_AWAITING_SETUP) {
        return self.terms.load().expectedAmount;
    }
    return 0;
}

// Of what a funded lock owes, what its balance still holds: all of it, unless the storage paid in advance
// ran out and the network took its storage fee from the rest. `own`: the lock's balance without the
// incoming message's value (ownBalance), or as a get method sees it (balanceNow), both in lock-base.
fun GramLockStorage.held(self, bal: GramLockBalances, own: int): coins {
    if (self.status != STATUS_FUNDED) {
        return 0;
    }
    return min(bal.totalAmount - bal.claimed, max(own, 0));
}

// What the owner may claim: what the schedule has unlocked and not paid out, as far as the lock still holds
// it. Nothing in a permanent lock.
fun GramLockStorage.claimable(
    self,
    bal: GramLockBalances,
    live: GramLockLive,
    own: int,
    now: int,
): coins {
    if (self.status != STATUS_FUNDED || live.permanent) {
        return 0;
    }
    val unlocked = live.schedule.unlockedAt(bal.totalAmount, now);
    return min(max(unlocked - bal.claimed, 0), self.held(bal, own));
}

// Nothing is locked any more: everything the lock holds belongs to the owner
fun GramLockStorage.isFinished(self, live: GramLockLive, now: int): bool {
    return self.status == STATUS_FUNDED && !live.permanent && now >= live.schedule.end;
}

// The lock ends the transaction with the balance it had before the message less `paid`: the reserve is the
// original balance minus the amount (RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE with
// RESERVE_MODE_NEGATE_AMOUNT). `paid` leaves with what is sent after this, together with the rest of the
// message's value. A balance that cannot meet the reserve fails the transaction, and the message bounces if
// it asked to (RESERVE_MODE_BOUNCE_ON_ACTION_FAIL).
fun keepOwnBalanceLess(paid: coins) {
    reserveGramsOnBalance(
        paid,
        RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_NEGATE_AMOUNT |
            RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
    );
}

// What a payout may carry as its body: nothing, or a text comment as wallets write one, 32 zero bits and
// then the text. Anything else could pass for a message of the lock's own (an ownership_assigned, a
// LockState, a fee notice) with its owner's wording. An exotic cell is refused too: an ordinary read of a
// library reference gives the cell it stands for, which is not the cell the payout would carry, so the
// comment is read as the cell it is (beginParseSpecial).
fun isTextComment(comment: cell?): bool {
    if (comment == null) {
        return true;
    }
    val (s, exotic) = comment.beginParseSpecial();
    return !exotic && s.remainingBitsCount() >= OPCODE_BITS && s.preloadUint(OPCODE_BITS) == 0;
}

// The payout of a claim: the same (payOut, in lock-base), with the owner's comment as its body when there
// is one
fun payOutWithComment(destination: address, comment: cell?) {
    if (comment == null) {
        payOut(destination);
        return;
    }
    val payoutMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: destination,
        value: 0,
        body: comment,
    });
    // SAFETY: called right after a reserve of the balance the lock keeps; this carries what is above it
    payoutMessage.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// ============== Init ==============

// InitGramLock, the message that creates the lock: checks the terms and the value, records the lock as
// awaiting its setup and asks its till for the fee rates. `soulbound`: the kind of the contract running
// this.
fun handleGramInit(in: LockIncoming, soulbound: bool) {
    val init = LockInitData.fromCell(contract.getData());
    val msg = InitGramLock.fromSlice(in.body);
    val now = blockchain.now();
    val (terms, parties) = admittedTerms(
        in,
        init,
        msg.terms,
        msg.tillCode,
        soulbound,
        true,
        now,
    );
    // Nothing of a lock of GRAM waits anywhere before it exists, so a schedule that has ended, or can never
    // start, is refused, and a refused creation goes back with all it carries (refuse)
    assert (
        terms.permanent ? terms.schedule.isZero() : terms.schedule.isValidForCreation(now)
    ) throw LockErrors.BadTerms;
    // the value must cover the GRAM to lock and, on top of it, what the creation costs
    // (get_gram_create_cost on the root)
    assert (
        in.value >=
        terms.expectedAmount +
        gramCreateCost(terms.maxFlatFee, terms.permanent, terms.schedule.end, now)
    ) throw LockErrors.InsufficientValue;
    val till = tillOfLock(msg.tillCode, init, parties);

    val storage = GramLockStorage {
        collection: init.collection,
        index: init.index,
        status: STATUS_AWAITING_SETUP,
        owner: parties.owner,
        lastTx: now,
        balances: GramLockBalances {
            totalAmount: 0,
            claimed: 0,
            lastDepositLt: 0,
        }.toCell(),
        terms: msg.terms,
        live: GramLockLive {
            createdAt: now,
            permanent: terms.permanent,
            schedule: terms.schedule,
            flatFee: 0,
            topUpFlatFee: 0,
            feeBps: 0,
            till,
            cancelReason: 0,
        }.toCell(),
    };
    storage.save();
    emitLockEvent(LockCreatedEvent {
        index: init.index,
        jettonWallet: null,
        terms: msg.terms,
    });
    // The setup request, at its own value with its fees on top (SEND_MODE_PAY_FEES_SEPARATELY); should it
    // fail to be sent, the creation fails and its message bounces if it asked to
    // (SEND_MODE_BOUNCE_ON_ACTION_FAIL). Everything else stays here until the till answers or the creation
    // is cancelled: the GRAM to lock, and the budget (the storage prepayment, the flat fee, what the
    // funding pays).
    askTillForFees(till, init.index);
    // Nothing is sent after this reserve. It only states the least the handler leaves, the balance the
    // address had and the GRAM to lock, and fails the creation if less would be left.
    keepOwnBalance(terms.expectedAmount);
}

// ============== Setup ==============

// A creation failed: everything goes back to the creator in one message, the GRAM that was to be locked
// with what is left of the budget, and the lock keeps the storage of a cancelled lock at most
// (gramLockCancelledReserve). `gasBudget`: the gas bound of the handler that cancels. `queryId`: that of
// what goes back, the message's own when a CancelCreation cancels, the lock's when the till's answer does.
// A `helper` who paid for this cancel (someone other than the creator) pays only for it: the rest of its
// value comes back to it.
fun GramLockStorage.cancel(
    mutate self,
    live: GramLockLive,
    terms: LockTerms,
    reason: int,
    gasBudget: int,
    queryId: uint64,
    helper: address?,
    helperValue: coins,
) {
    self.status = STATUS_CANCELLED;
    var l = live;
    l.cancelReason = reason;
    self.live = l.toCell();
    self.save();
    emitLockEvent(LockCancelledEvent {
        index: self.index,
        reason,
    });

    // What the lock has beyond the creator's GRAM once this handler and its event are paid for. They are
    // paid from the balance, which holds the incoming value. When a helper cancels they are paid from the
    // helper's value alone, which is left out of the balance: its change goes back to the helper and pays
    // its own way (SEND_MODE_REGULAR), and it alone is skipped if it cannot be sent, the cancel standing
    // (SEND_MODE_IGNORE_ERRORS).
    val spare: int = helper == null
        ? spendableAbove(terms.expectedAmount, gasBudget) - smallMessageFee()
        : ownBalance(helperValue) - terms.expectedAmount;
    if (helper != null) {
        val helperBack: int = helperValue - calculateGasFee(BASECHAIN, gasBudget) -
            smallMessageFee();
        if (helperBack > 0) {
            val helperChangeMessage = createMessage({
                bounce: BounceMode.NoBounce,
                dest: helper,
                value: helperBack,
                body: Excesses { queryId },
            });
            helperChangeMessage.send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
        }
    }
    // Of that the lock keeps a cancelled lock's storage at most, and never any of the creator's GRAM. The
    // reserve is of that much, or of the whole balance if it holds less (RESERVE_MODE_AT_MOST), so a cancel
    // never fails here. Everything above it goes to the creator (SEND_MODE_CARRY_ALL_BALANCE).
    reserveGramsOnBalance(min(max(spare, 0), gramLockCancelledReserve()), RESERVE_MODE_AT_MOST);
    returnExcess(terms.parties.load().creator, queryId, SEND_MODE_CARRY_ALL_BALANCE);
}

// The till's answer funds the lock: while creation is enabled, within SETUP_WINDOW, at fees within the
// creator's maxima and the caps, and while the budget covers everything the funding pays (prices can rise
// meanwhile). Otherwise the creation is cancelled and everything goes back to the creator.
@noinline
fun GramLockStorage.onFeesAttested(mutate self, in: LockIncoming, msg: FeesAttested) {
    var live = self.live.load();
    if (
        in.sender != live.till || self.status != STATUS_AWAITING_SETUP ||
        msg.queryId != queryIdOf(self.index)
    ) {
        // Not the answer this lock waits for: nothing changes, and what the message carried stays here.
        // (The queryId is a guard: a till answers with the queryId it was asked with, and the lock asks
        // with no other than its own.)
        return;
    }
    // The answer carries whatever the till left of the request's value, which may be less than this handler
    // costs: its gas is in the creator's budget, in the lock's own balance. The limit is raised only here,
    // once the sender is known to be the lock's till.
    setGasLimit(LOCK_GAS_COMPLETE);
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
        self.cancel(
            live,
            terms,
            CANCEL_TILL_REFUSED,
            LOCK_GAS_COMPLETE,
            queryIdOf(self.index),
            null,
            0,
        );
        return;
    }
    if (blockchain.now() > live.createdAt + SETUP_WINDOW) {
        self.cancel(
            live,
            terms,
            CANCEL_EXPIRED,
            LOCK_GAS_COMPLETE,
            queryIdOf(self.index),
            null,
            0,
        );
        return;
    }
    val gross = terms.expectedAmount;
    val fee = mulDivFloor(gross, msg.feeBps, BPS_DENOMINATOR);
    val prepay = gramLockStoragePrepay(
        storageHorizon(live.permanent, live.schedule.end, live.createdAt),
    );
    // What the funding sends (gramFundingNeeds) must be in the balance above the GRAM to lock and the
    // storage prepayment, once this handler's gas is paid
    if (spendableAbove(gross + prepay, LOCK_GAS_COMPLETE) < gramFundingNeeds(msg.flatFee)) {
        self.cancel(
            live,
            terms,
            CANCEL_BUDGET,
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
    self.live = live.toCell();
    self.status = STATUS_FUNDED;
    self.balances = GramLockBalances {
        totalAmount: gross - fee,
        claimed: 0,
        lastDepositLt: blockchain.logicalTime(),
    }.toCell();
    self.save();
    emitLockEvent(LockFundedEvent {
        index: self.index,
        amount: gross - fee,
        fee,
    });

    // The flat fee and the fee on the amount go to the till as the value of one FeeNotice, with the GRAM of
    // the till's receipt at its bounds (tillReceiptValue), so that the till's events list the funded locks:
    // the till emits the event when what arrives pays for it. Its forward fee is paid on top, from the
    // budget (SEND_MODE_PAY_FEES_SEPARATELY), and a notice that cannot be sent is skipped, so that the
    // funding never fails on it (SEND_MODE_IGNORE_ERRORS).
    sendFeeNotice(
        live.till,
        self.index,
        null,
        FEE_KIND_FUNDING,
        fee,
        msg.flatFee + fee + tillReceiptValue(),
    );
    // The lock keeps what it now holds for its owner and its storage prepayment, exactly
    // (RESERVE_MODE_EXACT_AMOUNT: the budget check above made sure the balance holds it). What is left of
    // the budget goes back to the creator (SEND_MODE_CARRY_ALL_BALANCE).
    reserveGramsOnBalance(gross - fee + prepay, RESERVE_MODE_EXACT_AMOUNT);
    returnExcess(terms.parties.load().creator, queryIdOf(self.index), SEND_MODE_CARRY_ALL_BALANCE);
}

// ============== Main handler ==============

// The messages a lock of GRAM takes. InitGramLock creates it (handleGramInit): sent to a lock that was
// created, it is refused.
type GramLockMessage =
    | FeesAttested
    | TransferNotification
    | TopUpGram
    | ClaimGram
    | ExtendLock
    | ClaimForeign
    | ClaimForeignNft
    | SweepGram
    | RetryFunding
    | CancelCreation
    | NftTransfer
    | GetStaticData
    | ProveOwnership
    | RequestOwner
    | Destroy
    | Revoke
    | StorageTopUp
    | RequestLockState
    | InitGramLock
    | Excesses

// Every internal message to the lock but a bounce. What a handler throws is caught by the contract's
// entrypoint, which bounces the message, sends what is left of its value back, or leaves here the GRAM of a
// jetton wallet's notification that did not ask to bounce (refuse).
fun handleGramLockMessage(in: LockIncoming, soulbound: bool) {
    if (in.body.isEmpty()) {
        // GRAM with no body is storage: it stays here, whether or not the lock was created
        return;
    }
    if (!isInitialized()) {
        if (isBodyOf<TransferNotification>(in.body)) {
            // Tokens sent to a lock that does not exist (yet): back through the same wallet when the
            // notification's GRAM allows
            val stray = TransferNotification.fromSlice(in.body);
            sendBackUncredited(in.sender, in.value, stray, stray.queryId);
            return;
        }
        handleGramInit(in, soulbound);
        return;
    }

    val msg = lazy GramLockMessage.fromSlice(in.body);
    var storage = GramLockStorage.load();
    val now = blockchain.now();

    match (msg) {
        FeesAttested => {
            storage.onFeesAttested(in, msg);
        }

        TransferNotification => {
            // A lock of GRAM takes no jetton: back through the notifying wallet when the GRAM allows;
            // otherwise the tokens stay in that wallet, for ClaimForeign
            sendBackUncredited(in.sender, in.value, msg, msg.queryId);
        }

        TopUpGram => {
            // The owner or the creator adds GRAM to the schedule of a funded lock that is not finished,
            // less the fee at the rates fixed at setup
            assert (
                in.sender == storage.owner || in.sender == creatorOf(storage.terms)
            ) throw GramErrors.NotParty;
            assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
            val live = storage.live.load();
            assert (live.permanent || now < live.schedule.end) throw GramErrors.Finished;
            assert (msg.amount > 0) throw LockErrors.ZeroAmount;
            // A storage debt the network has not collected yet comes out of the balance at the next
            // transaction: the top-up brings it too, so that all it adds is held
            val debt = contract.getStorageDuePayment();
            // the value must cover the GRAM to add and, on top of it, what the top-up costs
            // (get_top_up_cost)
            assert (
                in.value >= msg.amount + gramTopUpCost(live.topUpFlatFee) + debt
            ) throw LockErrors.InsufficientValue;

            val fee = mulDivFloor(msg.amount, live.feeBps, BPS_DENOMINATOR);
            var bal = storage.balances.load();
            val prevDepositLt = bal.lastDepositLt;
            bal.totalAmount += msg.amount - fee;
            bal.lastDepositLt = blockchain.logicalTime();
            storage.balances = bal.toCell();
            storage.save();
            emitLockEvent(LockToppedUpEvent {
                index: storage.index,
                amount: msg.amount - fee,
                fee,
                from: in.sender,
                prevDepositLt,
            });
            // The flat fee of a top-up and the fee on the amount go to the till as the value of one
            // FeeNotice, with the GRAM of the till's receipt; its forward fee is paid on top
            // (SEND_MODE_PAY_FEES_SEPARATELY), and a notice that cannot be sent is skipped, so that a
            // top-up never fails on it (SEND_MODE_IGNORE_ERRORS)
            sendFeeNotice(
                live.till,
                storage.index,
                null,
                FEE_KIND_TOP_UP,
                fee,
                live.topUpFlatFee + fee + tillReceiptValue(),
            );
            // The lock keeps the balance it had, what the top-up adds to the schedule and the storage debt
            // it brought. The rest of its value goes back to the sender (SEND_MODE_CARRY_ALL_BALANCE).
            keepOwnBalance(msg.amount - fee + debt);
            returnExcess(in.sender, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }

        ClaimGram => {
            // The owner takes GRAM the schedule has unlocked (`amount` 0: all of it) to `destination`
            assert (in.sender == storage.owner) throw LockErrors.NotOwner;
            // nothing is the owner's while the lock is being set up or once it is cancelled
            assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
            val live = storage.live.load();
            assert (msg.destination.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            assert (
                !storage.isForbiddenRecipient(live, msg.destination)
            ) throw LockErrors.ForbiddenAccount;
            assert (isTextComment(msg.comment)) throw GramErrors.BadComment;
            // the comment is carried once, from the lock to the destination
            assert (
                in.value >= gramClaimCost() + payloadCarriage(BASECHAIN, msg.comment, 1)
            ) throw LockErrors.InsufficientValue;

            var bal = storage.balances.load();
            val available = storage.claimable(bal, live, ownBalance(in.value), now);
            val amount: int = msg.amount == 0 ? available : (msg.amount as int);
            assert (amount > 0) throw LockErrors.ZeroAmount;
            assert (amount <= available) throw LockErrors.AmountTooHigh;

            bal.claimed += amount;
            storage.balances = bal.toCell();
            storage.save();
            emitLockEvent(LockClaimedEvent {
                index: storage.index,
                amount,
                destination: msg.destination,
            });
            // The lock keeps the balance it had less the amount claimed: the payout carries that amount and
            // what is left of the message's value
            keepOwnBalanceLess(amount);
            payOutWithComment(msg.destination, msg.comment);
        }

        ExtendLock => {
            // The owner moves the schedule later or makes the lock permanent: nothing that would unlock
            // anything earlier (extendedSchedule)
            assert (in.sender == storage.owner) throw LockErrors.NotOwner;
            assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
            var live = storage.live.load();
            val next = extendedSchedule(live.permanent, live.schedule, msg, now);
            // The longer life must come with its storage prepayment. What the lock holds beyond what it
            // owes its owner counts towards it: less than nothing if the network took storage fees from
            // that, and the extension then brings that back too.
            val spare = ownBalance(in.value) - storage.owed(storage.balances.load());
            val extra = max(
                gramLockStoragePrepay(storageHorizon(msg.makePermanent, next.end, now)) - spare,
                0,
            );
            assert (in.value >= extra + gramExtendCost()) throw LockErrors.InsufficientValue;

            live.schedule = next;
            live.permanent = msg.makePermanent;
            storage.live = live.toCell();
            storage.save();
            emitLockEvent(LockExtendedEvent {
                index: storage.index,
                permanent: live.permanent,
                schedule: live.schedule,
            });
            // The lock keeps the balance it had and the storage the extension brings. The rest of the value
            // goes back to the owner (SEND_MODE_CARRY_ALL_BALANCE).
            keepOwnBalance(extra);
            returnExcess(in.sender, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }

        ClaimForeign => {
            // Every jetton is foreign to a lock of GRAM: the owner of a funded lock moves it, or out of a
            // cancelled one its creator, or anyone to its creator (assertMayMoveForeign). The transfer goes
            // to the wallet named on the message's own value. The wallet's excess, and the value of a
            // transfer it refuses, go to the sender.
            assertMayMoveForeign(
                in.sender,
                msg.destination,
                storage.status,
                storage.owner,
                storage.terms,
            );
            assert (msg.destination.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            // the transfer goes to the wallet named: it is on a chain a message can be sent to
            val walletWorkchain = reachableWorkchain(msg.wallet);
            assert (
                !storage.isForbiddenRecipient(storage.live.load(), msg.destination) &&
                msg.destination != msg.wallet
            ) throw LockErrors.ForbiddenAccount;
            assert (msg.amount > 0) throw LockErrors.ZeroAmount;
            assert (
                in.value >= claimForeignCost(walletWorkchain)
            ) throw LockErrors.InsufficientValue;
            sendJettonTransfer(
                msg.wallet,
                msg.queryId,
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
            assert (msg.nft != contract.getAddress()) throw LockErrors.ForbiddenAccount;
            assert (msg.newOwner.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            assert (
                !storage.isForbiddenRecipient(storage.live.load(), msg.newOwner) &&
                msg.newOwner != msg.nft
            ) throw LockErrors.ForbiddenAccount;
            assert (
                in.value >= answerCost(reachableWorkchain(msg.nft), false, null)
            ) throw LockErrors.InsufficientValue;
            sendForeignNft(msg.nft, msg.queryId, msg.newOwner, in.sender);
        }

        SweepGram => {
            // The owner of a finished lock takes what it still holds, the creator of a cancelled one what
            // reached it since. Either way the lock keeps the storage of a cancelled lock at most.
            val live = storage.live.load();
            if (storage.status == STATUS_CANCELLED) {
                // What a cancelled lock holds in GRAM is its creator's, who alone chooses where it goes.
                // Nothing of anyone else's waits on it, so nobody else moves it: the rule that lets anyone
                // send a foreign jetton or NFT to the creator is for what reached the lock by mistake.
                assert (in.sender == creatorOf(storage.terms)) throw LockErrors.NotCreator;
            } else {
                assert (in.sender == storage.owner) throw LockErrors.NotOwner;
                assert (storage.status == STATUS_FUNDED) throw LockErrors.NotFunded;
                assert (storage.isFinished(live, now)) throw LockErrors.NotFinished;
            }
            assert (msg.destination.getWorkchain() == BASECHAIN) throw LockErrors.WrongWorkchain;
            assert (
                !storage.isForbiddenRecipient(live, msg.destination)
            ) throw LockErrors.ForbiddenAccount;
            assert (in.value >= gramLockSweepGramCost()) throw LockErrors.InsufficientValue;
            val own = ownBalance(in.value);
            var released: coins = 0;
            if (storage.status == STATUS_FUNDED) {
                // Settle the accounting (nothing is locked any more), so the get methods never show swept
                // GRAM
                var bal = storage.balances.load();
                released = storage.held(bal, own);
                bal.claimed = bal.totalAmount;
                storage.balances = bal.toCell();
                storage.save();
                emitLockEvent(LockSweptEvent {
                    index: storage.index,
                    amount: released,
                    destination: msg.destination,
                });
            }
            // The lock ends with exactly what sweepKeeps allows it (RESERVE_MODE_EXACT_AMOUNT): of its own
            // GRAM beyond what it held for its owner, the storage of a cancelled lock at most. Everything
            // else leaves with the payout, the storage it will not use included. A balance that cannot meet
            // the reserve fails the sweep, and the request bounces with its value if it asked to
            // (RESERVE_MODE_BOUNCE_ON_ACTION_FAIL).
            reserveGramsOnBalance(
                sweepKeeps(own, released, gramLockCancelledReserve()),
                RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
            );
            payOut(msg.destination);
        }

        RetryFunding => {
            // Anyone: ask the till again while it has not answered (it was not deployed, or not configured,
            // when the lock asked). A lock of GRAM still being set up has had no answer: the first one
            // funds it or cancels it. The lock keeps the balance it had: the request is paid from the
            // caller's value, and the rest of it comes back to the caller.
            assert (storage.status == STATUS_AWAITING_SETUP) throw LockErrors.BadStatus;
            assert (in.value >= retryFundingCost()) throw LockErrors.InsufficientValue;
            keepOwnBalance(0);
            askTillForFees(storage.live.load().till, storage.index);
            returnExcess(in.sender, msg.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }

        CancelCreation => {
            // Ends a creation that has not completed (cancel)
            assert (storage.status == STATUS_AWAITING_SETUP) throw LockErrors.BadStatus;
            val live = storage.live.load();
            val terms = storage.terms.load();
            val byCreator = in.sender == terms.parties.load().creator;
            // The creator may give up at any time; anyone else only once the creation can no longer
            // complete, so nobody can cancel a creation its creator still waits for
            assert (byCreator || now > live.createdAt + SETUP_WINDOW) throw LockErrors.TooEarly;
            assert (in.value >= gramCancelCost()) throw LockErrors.InsufficientValue;
            if (byCreator) {
                storage.cancel(
                    live,
                    terms,
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
                    terms,
                    CANCEL_EXPIRED,
                    LOCK_GAS_CANCEL,
                    msg.queryId,
                    in.sender,
                    in.value,
                );
            }
        }

        NftTransfer => {
            // TEP-62: the owner of a funded lock of the transferable kind hands it on (the checks and the
            // messages of a transfer are in lock-base)
            assertMayTransfer(in.sender, soulbound, storage.status, storage.owner);
            // nobody could ever claim a lock owned by the root, its till or itself
            assertTransferable(
                in,
                msg,
                storage.isForbiddenRecipient(storage.live.load(), msg.newOwner),
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
            // storage fee is left due, so that the quotes and, in a lock of GRAM, the get methods count the
            // storage from this message on, and not from an earlier save.
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
                    // what the schedule has paid out and what the lock still holds for it
                    totalAmount: bal.claimed + storage.held(bal, ownBalance(in.value)),
                    claimed: bal.claimed,
                    freeBalance: 0,
                    parties: LockStateParties {
                        owner: storage.owner,
                        jettonMaster: null,
                        jettonWallet: null,
                    }.toCell(),
                },
            });
            lockStateMessage.send(ON_REQUEST_VALUE);
        }

        InitGramLock => {
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

// A message of the lock's that bounced. A bounce gives what is left of its message's GRAM back to whoever
// paid for it (SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE), and restores nothing: no bounceable message of
// a lock of GRAM takes anything out of its records. The setup request is the exception. Its GRAM is the
// budget's when InitGramLock sent it and the caller's when RetryFunding did: either way a bounce during the
// setup leaves it in the budget (RetryFunding asks again), and afterwards it goes to the creator.
fun handleGramLockBounce(in: LockIncoming) {
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
    val storage = GramLockStorage.load();

    // an ownership proof, an owner info or a foreign NFT's transfer came back: nothing to restore, its
    // value goes back (lock-base)
    if (returnStandardBounce(op, queryId, body, storage.owner)) {
        return;
    }
    if (op == opcodeOf<JettonTransfer>()) {
        // a jetton wallet refused a ClaimForeign: the tokens are still there
        body.loadCoins();
        body.skipAny<address>(); // destination
        returnBounced(body.loadAddressOpt(), queryId);
        return;
    }
    // the lock's only other bounceable message, the setup request
    returnSetupBounce(storage.status, storage.terms, storage.index);
}

// ============== Get methods ==============
// What the get methods answer once the lock was created (lock-base describes how they are declared), in the
// shapes of a lock of jettons: no master, no wallet, and nothing claimable outside the schedule.

// TEP-62: (init?, index, collection, owner, individual_content)
fun viewGramNftData(): (bool, int, address, address?, cell) {
    val storage = GramLockStorage.load();
    return (
        true,
        storage.index,
        storage.collection,
        storage.owner,
        decimalStringCell(storage.index),
    );
}

// get_lock_data: the lock as it stands (LockInfo, in lock-base). `totalAmount` is what the schedule has
// paid out and what the lock still holds for it: less than what was locked only if storage fees were taken
// from that.
fun viewGramLockData(): LockInfo {
    val storage = GramLockStorage.load();
    val terms = storage.terms.load();
    val live = storage.live.load();
    val bal = storage.balances.load();
    val own = balanceNow(storage.lastTx, GRAM_LOCK_STATE_BITS, GRAM_LOCK_STATE_CELLS);
    return {
        status: storage.status,
        index: storage.index,
        collection: storage.collection,
        owner: storage.owner,
        jettonMaster: null,
        jettonWallet: null,
        creator: terms.parties.load().creator,
        createdAt: live.createdAt,
        cliff: live.schedule.cliff,
        end: live.schedule.end,
        step: live.schedule.step,
        initialBps: live.schedule.initialBps,
        permanent: live.permanent,
        totalAmount: bal.claimed + storage.held(bal, own),
        expectedAmount: storage.status == STATUS_AWAITING_SETUP ? terms.expectedAmount : 0,
        claimed: bal.claimed,
        freeBalance: 0,
        claimableNow: storage.claimable(bal, live, own, blockchain.now()),
        topUpFlatFee: live.topUpFlatFee,
        feeBps: live.feeBps,
        version: SWORN_VERSION,
        lastDepositLt: bal.lastDepositLt,
        createBefore: terms.createBefore,
    };
}

// get_custody_data: what this lock holds and owes besides its schedule (CustodyInfo, in lock-base).
// `pendingAmount` is the creator's GRAM while the lock waits for its till, and `feesAttested` says that the
// till's answer funded it. What counts tokens or speaks of a jetton wallet is 0 in a lock of GRAM.
fun viewGramCustodyData(): CustodyInfo {
    val storage = GramLockStorage.load();
    val live = storage.live.load();
    return {
        till: live.till,
        feesAttested: storage.status == STATUS_FUNDED,
        pendingAmount: storage.status == STATUS_AWAITING_SETUP
            ? storage.terms.load().expectedAmount
            : 0,
        feeOwed: 0,
        flatFee: live.flatFee,
        setupExtra: 0,
        setupDeadline: live.createdAt + SETUP_WINDOW,
        cancelReason: live.cancelReason,
        sweepFrom: 0,
        recoverFrom: 0,
        walletPaidUntil: 0,
    };
}

// The immutable terms this lock's index commits to
fun viewGramLockTerms(): cell {
    return GramLockStorage.load().terms;
}

// Unlocked amount of the schedule at time t, whatever was claimed (0 unless funded, 0 in a permanent lock)
fun viewGramUnlockedAt(t: int): int {
    val storage = GramLockStorage.load();
    val live = storage.live.load();
    if (storage.status != STATUS_FUNDED || live.permanent) {
        return 0;
    }
    return live.schedule.unlockedAt(storage.balances.load().totalAmount, t);
}

// What a ClaimGram could pay now
fun viewGramClaimable(): int {
    val storage = GramLockStorage.load();
    return storage.claimable(
        storage.balances.load(),
        storage.live.load(),
        balanceNow(storage.lastTx, GRAM_LOCK_STATE_BITS, GRAM_LOCK_STATE_CELLS),
        blockchain.now(),
    );
}

// What a SweepGram would pay now, on top of what is left of its own value: what a finished lock still holds
// for its owner and the storage it will not use, or what reached a cancelled lock since. Nothing while a
// sweep is not due (a lock being set up, a permanent lock, or one whose schedule has not ended).
fun viewGramSweepGramAmount(): int {
    val storage = GramLockStorage.load();
    val own = max(balanceNow(storage.lastTx, GRAM_LOCK_STATE_BITS, GRAM_LOCK_STATE_CELLS), 0);
    if (storage.status == STATUS_CANCELLED) {
        return own - sweepKeeps(own, 0, gramLockCancelledReserve());
    }
    if (!storage.isFinished(storage.live.load(), blockchain.now())) {
        return 0;
    }
    return own -
        sweepKeeps(own, storage.held(storage.balances.load(), own), gramLockCancelledReserve());
}

// GRAM a ClaimGram with this comment must carry. Get methods take no nullable argument: common APIs
// (toncenter's runGetMethod) cannot pass a null.
fun viewGramClaimCostWithComment(comment: cell): int {
    return gramClaimCost() + payloadCarriage(BASECHAIN, comment, 1);
}

// GRAM a TopUpGram must carry on top of the GRAM it adds, with the most the lock's storage debt can be when
// the message lands (storageDebtBound)
fun viewGramTopUpCost(): int {
    val storage = GramLockStorage.load();
    return gramTopUpCost(storage.live.load().topUpFlatFee) +
        storageDebtBound(storage.lastTx, GRAM_LOCK_STATE_BITS, GRAM_LOCK_STATE_CELLS);
}

// GRAM to attach to an ExtendLock to `end` (or to one making the lock permanent), for a message landing up
// to QUOTE_MARGIN from now
fun viewGramExtendCost(permanent: bool, end: int): int {
    val storage = GramLockStorage.load();
    val live = storage.live.load();
    // the balance here is before the storage fee due since the last save with nothing due: take out an
    // upper bound
    val spare = contract.getOriginalBalance() -
        storageDebtBound(storage.lastTx, GRAM_LOCK_STATE_BITS, GRAM_LOCK_STATE_CELLS) -
        storage.owed(storage.balances.load());
    val prepay = gramLockStoragePrepay(
        storageHorizon(permanent || live.permanent, permanent ? 0 : end, blockchain.now()),
    );
    return max(prepay - spare, 0) + gramExtendCost();
}
