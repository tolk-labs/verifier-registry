import "@gen/UsdtDepositVault.code"
import "@contracts/usdt_deposit_vault/address"
import "@contracts/usdt_deposit_vault/enums"
import "@contracts/usdt_deposit_vault/messages"
import "@contracts/usdt_deposit_vault/storage"
import "@contracts/common/comments/messages"
import "@contracts/common/comments/refund_reason"
import "@contracts/common/offer/enums"
import "@contracts/common/offer/messages"
import "@contracts/common/offer/terms"
import "@contracts/common/usdt/network_constants"
import "constants"
import "enums"
import "messages"

struct UsdtDepositRecord {
    terms: Cell<UsdtDepositTerms>
    assignmentStatus: UsdtDepositAssignmentStatus = UsdtDepositAssignmentStatus.Unsent
    automaticAttempts: uint8 = 0
    lastAttemptAt: uint32 = 0
    // Persisted before granting beneficiary control. Parent owner recreation cannot select a
    // second holding or replay a debit into the original selected holding.
    selectedAttempt: uint64? = null
    termsPayloadBits: uint32 = 0
    termsPayloadCells: uint32 = 0
}

struct UsdtDeposits {
    principal: coins = 0
    fee: coins = 0
    count: uint8 = 0
    assignedCount: uint8 = 0
    entries: map<address, UsdtDepositRecord> = []
    termsPayloadBits: uint32 = 0
    termsPayloadCells: uint32 = 0
}

fun usdtDepositInit(terms: Cell<UsdtDepositTerms>): AutoDeployAddress {
    return usdtVaultInitWithCode(usdtDepositVaultCompiledCode(), terms);
}

fun usdtHoldingInit(terms: Cell<UsdtDepositTerms>, attempt: uint64): AutoDeployAddress {
    return usdtVaultInitWithCode(usdtDepositVaultCompiledCode(), terms, attempt);
}

fun authenticateUsdtHolding(sender: address, terms: Cell<UsdtDepositTerms>, attempt: uint64) {
    assert (terms.load().escrow == contract.getAddress()) throw UsdtDepositVaultErrors.InvalidTerms;
    assert (
        sender == usdtHoldingInit(terms, attempt).calculateAddress()
    ) throw UsdtDepositVaultErrors.InvalidVault;
}

fun authenticateUsdtDeposit(sender: address, terms: Cell<UsdtDepositTerms>) {
    assert (terms.load().escrow == contract.getAddress()) throw UsdtDepositVaultErrors.InvalidTerms;
    assert (
        sender == usdtDepositInit(terms).calculateAddress()
    ) throw UsdtDepositVaultErrors.InvalidVault;
}

fun UsdtDeposits.canAccept(self, terms: UsdtDepositTerms, payment: PaymentTerms): bool {
    if (terms.amount <= 0 || self.count >= MAX_USDT_DEPOSITS || terms.side != payment.payer) {
        return false;
    }
    if (terms.purpose == UsdtDepositPurpose.Principal) {
        return self.principal + terms.amount <= payment.amount - payment.marketplaceFee;
    }
    return self.fee + terms.amount <= payment.marketplaceFee;
}

fun UsdtDeposits.add(mutate self, terms: Cell<UsdtDepositTerms>) {
    val vault = usdtDepositInit(terms).calculateAddress();
    assert (!self.entries.exists(vault)) throw UsdtDepositVaultErrors.DuplicateDeposit;
    val (cells, bits, _) = terms.calculateSizeStrict(8192);
    self.termsPayloadBits += bits;
    self.termsPayloadCells += cells;
    val deposit = terms.load();
    if (deposit.purpose == UsdtDepositPurpose.Principal) {
        self.principal += deposit.amount;
    } else {
        self.fee += deposit.amount;
    }
    self.count += 1;
    self
        .entries
        .set(
            vault,
            {
                terms,
                termsPayloadBits: bits,
                termsPayloadCells: cells,
            },
        );
}

fun assignUsdtDeposit(
    terms: Cell<UsdtDepositTerms>,
    beneficiary: address,
    selectedAttempt: uint64? = null,
) {
    if (selectedAttempt != null) {
        restoreUsdtDepositAssignment(terms, beneficiary, selectedAttempt);
        return;
    }
    val assignment = createMessage({
        bounce: true,
        value: USDT_DEPOSIT_ASSIGN_VALUE,
        dest: usdtDepositInit(terms),
        body: AssignUsdtDeposit { beneficiary },
    });
    assignment.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun refundUsdtDeposit(terms: Cell<UsdtDepositTerms>, comment: Cell<TextComment>) {
    val refund = createMessage({
        bounce: true,
        value: USDT_DEPOSIT_REFUND_VALUE,
        dest: usdtDepositInit(terms),
        body: RefundUsdtDeposit { comment },
    });
    refund.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun restoreUsdtDepositAssignment(
    terms: Cell<UsdtDepositTerms>,
    beneficiary: address,
    selectedAttempt: uint64? = null,
    value: coins = USDT_DEPOSIT_ASSIGN_VALUE,
) {
    val restoration = createMessage({
        bounce: true,
        value,
        dest: usdtDepositInit(terms),
        body: RestoreUsdtDepositAssignment {
            beneficiary,
            holdingAttempt: selectedAttempt,
        },
    });
    restoration.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun usdtDepositBeneficiary(
    terms: UsdtDepositTerms,
    recipient: address,
    treasury: address,
): address {
    return terms.purpose == UsdtDepositPurpose.Principal ? recipient : treasury;
}

fun UsdtDepositRecord.isRetryable(self, automatic: bool): bool {
    val isPendingTimedOut = self.assignmentStatus == UsdtDepositAssignmentStatus.Pending &&
        blockchain.now() >= (self.lastAttemptAt as int) + USDT_ASSIGNMENT_RETRY_TIMEOUT;
    val mayRetry = self.assignmentStatus == UsdtDepositAssignmentStatus.Unsent ||
        self.assignmentStatus == UsdtDepositAssignmentStatus.Failed ||
        isPendingTimedOut;
    return mayRetry &&
        (!automatic || self.automaticAttempts < MAX_AUTOMATIC_USDT_ASSIGNMENT_ATTEMPTS);
}

fun UsdtDeposits.retryableAssignmentCount(self, automatic: bool): int {
    var count = 0;
    var entry = self.entries.findFirst();
    while (entry.isFound) {
        val deposit = entry.loadValue();
        if (deposit.isRetryable(automatic)) {
            count += 1;
        }
        entry = self.entries.iterateNext(entry);
    }
    return count;
}

fun UsdtDeposits.assignRetryable(
    mutate self,
    recipient: address,
    treasury: address,
    automatic: bool,
) {
    var entry = self.entries.findFirst();
    while (entry.isFound) {
        var deposit = entry.loadValue();
        if (deposit.isRetryable(automatic)) {
            deposit.assignmentStatus = UsdtDepositAssignmentStatus.Pending;
            deposit.lastAttemptAt = blockchain.now() as uint32;
            if (automatic) {
                deposit.automaticAttempts += 1;
            }
            self.entries.set(entry.getKey(), deposit);
            assignUsdtDeposit(
                deposit.terms,
                usdtDepositBeneficiary(deposit.terms.load(), recipient, treasury),
                deposit.selectedAttempt,
            );
        }
        entry = self.entries.iterateNext(entry);
    }
}

fun UsdtDeposits.assignOne(
    mutate self,
    vault: address,
    recipient: address,
    treasury: address,
    automatic: bool,
) {
    val entry = self.entries.get(vault);
    assert (entry.isFound) throw UsdtDepositVaultErrors.UnknownDeposit;
    var deposit = entry.loadValue();
    assert (deposit.isRetryable(automatic)) throw UsdtDepositVaultErrors.DecisionPending;
    deposit.assignmentStatus = UsdtDepositAssignmentStatus.Pending;
    deposit.lastAttemptAt = blockchain.now() as uint32;
    if (automatic) {
        deposit.automaticAttempts += 1;
    }
    self.entries.set(vault, deposit);
    assignUsdtDeposit(
        deposit.terms,
        usdtDepositBeneficiary(deposit.terms.load(), recipient, treasury),
        deposit.selectedAttempt,
    );
}

fun UsdtDeposits.refund(self, reason: RefundReason) {
    val comment = TextComment { text: reason.comment() }.toCell();
    // Refund only needs the immutable first ref. Lazy typed parsing avoids decoding assignment
    // bookkeeping for every entry in the 100-NFT/32-contribution cancellation gas envelope.
    val encodedEntries = createMapFromLowLevelDict<address, slice>(self.entries.toLowLevelDict());
    var entry = encodedEntries.findFirst();
    while (entry.isFound) {
        val deposit = lazy UsdtDepositRecord.fromSlice(entry.loadValue());
        refundUsdtDeposit(deposit.terms, comment);
        entry = encodedEntries.iterateNext(entry);
    }
}

fun UsdtDeposits.selectHolding(
    mutate self,
    sender: address,
    terms: Cell<UsdtDepositTerms>,
    attempt: uint64,
): bool {
    authenticateUsdtHolding(sender, terms, attempt);
    val vault = usdtDepositInit(terms).calculateAddress();
    val entry = self.entries.get(vault);
    assert (entry.isFound) throw UsdtDepositVaultErrors.UnknownDeposit;
    var deposit = entry.loadValue();
    assert (deposit.terms.hash() == terms.hash()) throw UsdtDepositVaultErrors.InvalidTerms;
    if (deposit.selectedAttempt == null) {
        deposit.selectedAttempt = attempt;
        self.entries.set(vault, deposit);
    }
    return deposit.selectedAttempt == attempt;
}

// Only an authenticated, funded holding chosen in the durable escrow record can confirm the
// principal claim. Merely dispatching an intake transfer never releases the counter-asset.
fun UsdtDeposits.confirmAssignment(
    mutate self,
    sender: address,
    terms: Cell<UsdtDepositTerms>,
    attempt: uint64,
) {
    authenticateUsdtHolding(sender, terms, attempt);
    val vault = usdtDepositInit(terms).calculateAddress();
    val entry = self.entries.get(vault);
    assert (entry.isFound) throw UsdtDepositVaultErrors.UnknownDeposit;
    var deposit = entry.loadValue();
    assert (deposit.terms.hash() == terms.hash()) throw UsdtDepositVaultErrors.InvalidTerms;
    assert (
        deposit.selectedAttempt != null && deposit.selectedAttempt == attempt
    ) throw UsdtDepositVaultErrors.InvalidVault;
    if (deposit.assignmentStatus == UsdtDepositAssignmentStatus.Assigned) {
        return;
    }
    deposit.assignmentStatus = UsdtDepositAssignmentStatus.Assigned;
    self.entries.set(vault, deposit);
    self.assignedCount += 1;
}

// The caller reserves the pre-message escrow balance first. These decisions spend only the
// incoming participant-funded cascade; a low-budget receipt can be resumed with Resolve.
fun selectUsdtHolding(
    terms: Cell<UsdtDepositTerms>,
    attempt: uint64,
    beneficiary: address,
    msgValue: coins,
) {
    if (msgValue < USDT_HOLDING_ASSIGN_VALUE + grams("0.01")) {
        return;
    }
    val assignment = createMessage({
        bounce: true,
        value: grams("0"),
        dest: usdtHoldingInit(terms, attempt),
        body: AssignUsdtDeposit { beneficiary },
    });
    // SAFETY: The caller reserved the pre-message escrow balance; only this receipt budget funds the selected holding.
    assignment.send(SEND_MODE_CARRY_ALL_BALANCE);
}

fun refundUsdtHolding(
    terms: Cell<UsdtDepositTerms>,
    attempt: uint64,
    reason: RefundReason,
    msgValue: coins,
) {
    if (msgValue < USDT_DEPOSIT_REFUND_VALUE + grams("0.01")) {
        return;
    }
    val refund = createMessage({
        bounce: true,
        value: grams("0"),
        dest: usdtHoldingInit(terms, attempt),
        body: RefundUsdtDeposit { comment: TextComment { text: reason.comment() }.toCell() },
    });
    // SAFETY: The caller reserved the pre-message escrow balance; only this receipt budget funds the fixed contributor refund.
    refund.send(SEND_MODE_CARRY_ALL_BALANCE);
}

fun resolveUnselectedUsdtHolding(
    deposits: UsdtDeposits,
    terms: Cell<UsdtDepositTerms>,
    attempt: uint64,
    isFinalRefund: bool,
    reason: RefundReason,
    msgValue: coins,
) {
    val deposit = terms.load();
    assert (
        deposit.escrow == contract.getAddress() && deposit.amount > 0
    ) throw UsdtDepositVaultErrors.InvalidTerms;
    assert (msgValue >= USDT_DEPOSIT_RESOLVE_VALUE) throw UsdtDepositVaultErrors.NotEnoughValue;
    val entry = deposits.entries.get(usdtDepositInit(terms).calculateAddress());
    var hasOtherSelectedHolding = false;
    if (entry.isFound) {
        val record = entry.loadValue();
        assert (record.terms.hash() == terms.hash()) throw UsdtDepositVaultErrors.InvalidTerms;
        if (record.selectedAttempt != null) {
            // A terminal status must never override the durable beneficiary entitlement.
            assert (
                record.selectedAttempt != attempt
            ) throw UsdtDepositVaultErrors.BeneficiaryAlreadyAssigned;
            hasOtherSelectedHolding = true;
        }
    }
    assert (isFinalRefund || hasOtherSelectedHolding) throw UsdtDepositVaultErrors.DecisionPending;
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - msgValue),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    refundUsdtHolding(terms, attempt, reason, msgValue);
}

fun UsdtDeposits.failAssignment(mutate self, sender: address) {
    val entry = self.entries.get(sender);
    if (!entry.isFound) {
        return;
    }
    var deposit = entry.loadValue();
    if (deposit.assignmentStatus != UsdtDepositAssignmentStatus.Pending) {
        return;
    }
    deposit.assignmentStatus = UsdtDepositAssignmentStatus.Failed;
    self.entries.set(sender, deposit);
}

fun prepareUsdtPayment(
    sender: address,
    msgValue: coins,
    payment: PaymentTerms,
    preparation: PrepareUsdtPayment,
    preMessageBalanceToReserve: coins? = null,
) {
    assert (
        payment.asset == PaymentAsset.Usdt &&
        preparation.principal + preparation.marketplaceFee > 0 &&
        preparation.principal <= payment.amount - payment.marketplaceFee &&
        preparation.marketplaceFee <= payment.marketplaceFee
    ) throw UsdtDepositVaultErrors.InvalidTerms;
    val vaultCount = (preparation.principal > 0 ? 1 : 0) + (preparation.marketplaceFee > 0 ? 1 : 0);
    assert (
        msgValue >= USDT_DEPOSIT_PREPARE_VALUE * vaultCount + USDT_DEPOSIT_PREPARATION_OVERHEAD
    ) throw UsdtDepositVaultErrors.NotEnoughValue;
    reserveGramsOnBalance(
        preMessageBalanceToReserve == null
            ? max(0, contract.getOriginalBalance() - msgValue)
            : preMessageBalanceToReserve,
        RESERVE_MODE_EXACT_AMOUNT,
    );

    if (preparation.principal > 0) {
        prepareUsdtContribution(
            UsdtDepositTerms {
                escrow: contract.getAddress(),
                contributor: sender,
                offerExecutionNumber: preparation.offerExecutionNumber,
                side: payment.payer,
                purpose: UsdtDepositPurpose.Principal,
                nonce: preparation.nonce,
                amount: preparation.principal,
                // Only a full principal receipt may acquire the execution. A fee vault can be
                // arbitrarily small and therefore is not an anti-griefing commitment.
                execution: preparation.execution,
            }.toCell(),
        );
    }
    if (preparation.marketplaceFee > 0) {
        prepareUsdtContribution(
            UsdtDepositTerms {
                escrow: contract.getAddress(),
                contributor: sender,
                offerExecutionNumber: preparation.offerExecutionNumber,
                side: payment.payer,
                purpose: UsdtDepositPurpose.MarketplaceFee,
                nonce: preparation.nonce,
                amount: preparation.marketplaceFee,
                execution: null,
            }.toCell(),
        );
    }
    // Custodied Sale уже проверила полный бюджет нового резерва. Его нельзя переносить в
    // self-message: следующий Prepare должен видеть деньги прежнего плательщика сразу.
    if (preMessageBalanceToReserve != null) {
        return;
    }
    // Для maker-funded escrow готовность проверяется после оплаты исходящих vault actions.
    val depositEscrowReserve = createMessage({
        bounce: false,
        value: grams("0"),
        dest: contract.getAddress(),
        body: DepositEscrowReserve { queryId: preparation.nonce },
    });
    // SAFETY: прежний баланс зарезервирован, а vault actions уже стоят перед отправкой остатка.
    depositEscrowReserve.send(SEND_MODE_CARRY_ALL_BALANCE);
}

fun prepareUsdtContribution(terms: Cell<UsdtDepositTerms>) {
    val preparation = createMessage({
        bounce: true,
        value: USDT_DEPOSIT_PREPARE_VALUE,
        dest: usdtDepositInit(terms),
        body: ProbeUsdtDeposit {},
    });
    preparation.send(SEND_MODE_PAY_FEES_SEPARATELY);
}
