import "@stdlib/reflection"
import "@contracts/common/comments/constants"
import "@contracts/common/comments/messages"
import "@contracts/common/gas/costs"
import "@contracts/common/jetton/constants"
import "@contracts/common/jetton/messages"
import "@contracts/common/usdt/network_constants"
import "@contracts/common/usdt/wallet"
import "address"
import "constants"
import "enums"
import "messages"
import "storage"

// The published intake remains contributor-owned. Each allocation uses a fresh holding; the
// escrow durably selects exactly one funded holding for the beneficiary. Intake retries can
// therefore never turn a duplicate contributor transfer into a second beneficiary payment.
type AllowedMessage =
    | ProbeUsdtDeposit
    | ReportUsdtDeposit
    | AssignUsdtDeposit
    | RestoreUsdtDepositAssignment
    | RefundUsdtDeposit
    | WithdrawUsdtDeposit
    | PrepareUsdtHolding
    | UsdtHoldingReady
    | UsdtHoldingUnavailable
    | UsdtDepositAssigned
    | JettonTransferNotification
    | JettonExcesses

contract UsdtDepositVault {
    author: "Gettran"
    version: "1.0.0"
    description: "Contributor USDT intake with single-selection principal holdings"
    storage: UsdtDepositVaultStorage
    incomingMessages: AllowedMessage
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }
    val msg = lazy AllowedMessage.fromSlice(in.body);
    var storage = UsdtDepositVaultStorage.load();
    val terms = storage.terms.load();
    assert (terms.amount > 0) throw UsdtDepositVaultErrors.InvalidAmount;

    match (msg) {
        ProbeUsdtDeposit => {
            assert (
                storage.status != UsdtDepositStatus.Refunded
            ) throw UsdtDepositVaultErrors.InvalidStatus;
            preserveDepositReserve(in.valueCoins, USDT_DEPOSIT_PREPARE_VALUE);
            if (storage.status != UsdtDepositStatus.Collecting) {
                reportDeposit(storage);
                return;
            }
            // A self-transfer proves custody when the original notification was lost. It is
            // never used to prove that an earlier outbound beneficiary payment succeeded.
            transferDepositTokens(
                contract.getAddress(),
                terms.amount,
                USDT_DEPOSIT_PROBE_QUERY,
                storage.holdingAttempt != null &&
                    in.valueCoins >= USDT_HOLDING_FUND_FORWARD_VALUE + grams("0.04")
                    ? USDT_HOLDING_FUND_FORWARD_VALUE
                    : grams("0.03"),
                in.senderAddress,
            );
        }
        ReportUsdtDeposit => {
            preserveDepositReserve(in.valueCoins, grams("0.03"));
            reportDeposit(storage);
        }
        PrepareUsdtHolding => {
            assert (storage.holdingAttempt != null) throw UsdtDepositVaultErrors.InvalidStatus;
            assert (
                in.senderAddress == mainVault(storage.terms).calculateAddress()
            ) throw UsdtDepositVaultErrors.InvalidVault;
            preserveDepositReserve(in.valueCoins, 0);
            if (storage.status != UsdtDepositStatus.Collecting) {
                reportDeposit(storage);
                return;
            }
            val ready = createMessage({
                bounce: true,
                value: grams("0"),
                dest: in.senderAddress,
                body: UsdtHoldingReady { attempt: storage.holdingAttempt },
            });
            // SAFETY: Retained holding TON is reserved; only the deployment budget returns to the canonical parent.
            ready.send(SEND_MODE_CARRY_ALL_BALANCE);
        }
        UsdtHoldingReady => {
            assert (storage.holdingAttempt == null) throw UsdtDepositVaultErrors.InvalidStatus;
            assert (
                in.senderAddress == holdingVault(storage.terms, msg.attempt).calculateAddress()
            ) throw UsdtDepositVaultErrors.InvalidVault;
            if (
                storage.status != UsdtDepositStatus.Assigned || storage.selectedAttempt != null ||
                storage.allocation == null
            ) {
                return;
            }
            var allocation = storage.allocation.load();
            if (allocation.attempt != msg.attempt || allocation.dispatched) {
                return;
            }
            preserveDepositReserve(in.valueCoins, USDT_HOLDING_FUND_FORWARD_VALUE + grams("0.03"));
            // Never reset on rejection. Owner recreation allocates a new transaction-LT holding
            // instead of risking another debit into the old, possibly selected holding.
            allocation.dispatched = true;
            storage.allocation = allocation.toCell();
            storage.save();
            transferDepositTokens(
                in.senderAddress,
                terms.amount,
                msg.attempt,
                USDT_HOLDING_FUND_FORWARD_VALUE,
                contract.getAddress(),
            );
        }
        UsdtHoldingUnavailable => {
            assert (storage.holdingAttempt == null) throw UsdtDepositVaultErrors.InvalidStatus;
            assert (
                in.senderAddress == holdingVault(storage.terms, msg.attempt).calculateAddress()
            ) throw UsdtDepositVaultErrors.InvalidVault;
            if (
                storage.status != UsdtDepositStatus.Assigned || storage.selectedAttempt != null ||
                storage.allocation == null ||
                storage.allocation.load().attempt != msg.attempt
            ) {
                return;
            }
            preserveDepositReserve(in.valueCoins, USDT_HOLDING_FUND_FORWARD_VALUE + grams("0.03"));
            // The old probe's rejection does not prove absence of an in-flight transfer. A new
            // holding is safe anyway: the escrow can select only one funded allocation.
            allocatePrincipal(mutate storage, storage.beneficiary!);
        }
        JettonTransferNotification => {
            assert (
                in.senderAddress == deriveUsdtWalletFor(contract.getAddress())
            ) throw UsdtDepositVaultErrors.InvalidNotification;
            if (storage.status != UsdtDepositStatus.Collecting) {
                return;
            }
            assert (msg.transferInitiator != null) throw UsdtDepositVaultErrors.InvalidNotification;
            val isSelfProbe = msg.transferInitiator == contract.getAddress() &&
                msg.queryId == USDT_DEPOSIT_PROBE_QUERY;
            val expectedContributor = storage.holdingAttempt == null
                ? terms.contributor
                : mainVault(storage.terms).calculateAddress();
            assert (
                msg.transferInitiator == expectedContributor || isSelfProbe
            ) throw UsdtDepositVaultErrors.InvalidNotification;
            // Overpayment funds one obligation. Partial/unnotified intake stays recoverable by
            // an exact self-probe or the escrow's final refund, without a second payer transfer.
            assert (
                storage.holdingAttempt == null
                    ? msg.jettonAmount >= terms.amount
                    : msg.jettonAmount == terms.amount
            ) throw UsdtDepositVaultErrors.InvalidAmount;
            preserveDepositReserve(in.valueCoins, 0);
            storage.status = UsdtDepositStatus.Deposited;
            storage.save();
            reportDeposit(storage);
        }
        AssignUsdtDeposit => {
            assert (in.senderAddress == terms.escrow) throw UsdtDepositVaultErrors.NotEscrow;
            assert (
                storage.status == UsdtDepositStatus.Deposited ||
                storage.status == UsdtDepositStatus.Assigned
            ) throw UsdtDepositVaultErrors.InvalidStatus;
            preserveDepositReserve(
                in.valueCoins,
                storage.holdingAttempt == null
                    ? USDT_DEPOSIT_ASSIGN_VALUE
                    : USDT_HOLDING_ASSIGN_VALUE,
            );
            if (storage.holdingAttempt == null) {
                allocatePrincipal(mutate storage, msg.beneficiary);
            } else {
                assignHoldingBeneficiary(mutate storage, msg.beneficiary);
            }
        }
        RestoreUsdtDepositAssignment => {
            // A recreated parent forwards only the selection restored by the escrow. The
            // canonical parent cannot originate this command from a public retry or report.
            assert (
                in.senderAddress == terms.escrow ||
                (storage.holdingAttempt != null &&
                    in.senderAddress == mainVault(storage.terms).calculateAddress())
            ) throw UsdtDepositVaultErrors.NotEscrow;
            assert (
                storage.status != UsdtDepositStatus.Refunded
            ) throw UsdtDepositVaultErrors.InvalidStatus;
            preserveDepositReserve(
                in.valueCoins,
                storage.holdingAttempt == null
                    ? USDT_DEPOSIT_ASSIGN_VALUE
                    : USDT_HOLDING_ASSIGN_VALUE,
            );
            if (storage.holdingAttempt != null) {
                assert (
                    msg.holdingAttempt != null && msg.holdingAttempt == storage.holdingAttempt
                ) throw UsdtDepositVaultErrors.InvalidTerms;
                assignHoldingBeneficiary(mutate storage, msg.beneficiary);
                return;
            }
            if (msg.holdingAttempt == null) {
                if (storage.allocation != null) {
                    storage.fixBeneficiary(msg.beneficiary);
                    storage.status = UsdtDepositStatus.Assigned;
                    storage.save();
                    reportDeposit(storage);
                    return;
                }
                allocatePrincipal(mutate storage, msg.beneficiary);
                return;
            }
            storage.fixBeneficiary(msg.beneficiary);
            assert (
                storage.selectedAttempt == null || storage.selectedAttempt == msg.holdingAttempt
            ) throw UsdtDepositVaultErrors.BeneficiaryAlreadyAssigned;
            storage.status = UsdtDepositStatus.Assigned;
            storage.selectedAttempt = msg.holdingAttempt;
            storage.save();
            // Restore the escrow's durable decision, never a new debit into the selected child.
            val restoration = createMessage({
                bounce: true,
                value: grams("0"),
                dest: holdingVault(storage.terms, msg.holdingAttempt),
                body: RestoreUsdtDepositAssignment {
                    beneficiary: msg.beneficiary,
                    holdingAttempt: msg.holdingAttempt,
                },
            });
            // SAFETY: Retained intake TON is reserved; the escrow-funded budget restores its fixed selected holding.
            restoration.send(SEND_MODE_CARRY_ALL_BALANCE);
        }
        UsdtDepositAssigned => {
            assert (storage.holdingAttempt == null) throw UsdtDepositVaultErrors.InvalidStatus;
            assert (
                msg.terms.hash() == storage.terms.hash() &&
                in.senderAddress ==
                holdingVault(storage.terms, msg.holdingAttempt).calculateAddress()
            ) throw UsdtDepositVaultErrors.InvalidVault;
            assert (
                storage.status == UsdtDepositStatus.Assigned && storage.beneficiary != null &&
                storage.beneficiary == msg.beneficiary &&
                (storage.selectedAttempt == null || storage.selectedAttempt == msg.holdingAttempt)
            ) throw UsdtDepositVaultErrors.BeneficiaryAlreadyAssigned;
            storage.selectedAttempt = msg.holdingAttempt;
            storage.save();
            returnVaultSurplus(terms.contributor);
        }
        RefundUsdtDeposit => {
            assert (in.senderAddress == terms.escrow) throw UsdtDepositVaultErrors.NotEscrow;
            assert (
                storage.status != UsdtDepositStatus.Assigned
            ) throw UsdtDepositVaultErrors.InvalidStatus;
            preserveDepositReserve(in.valueCoins, USDT_DEPOSIT_REFUND_VALUE);
            if (storage.status != UsdtDepositStatus.Refunded) {
                storage.status = UsdtDepositStatus.Refunded;
                storage.beneficiary = terms.contributor;
                storage.refundComment = msg.comment;
                storage.save();
            }
            transferDepositTokens(
                terms.contributor,
                terms.amount,
                terms.nonce,
                0,
                contract.getAddress(),
                storage.refundComment!,
            );
        }
        WithdrawUsdtDeposit => {
            assert (
                storage.status == UsdtDepositStatus.Refunded ||
                (storage.status == UsdtDepositStatus.Assigned &&
                    (storage.holdingAttempt != null || storage.selectedAttempt != null))
            ) throw UsdtDepositVaultErrors.InvalidStatus;
            preserveDepositReserve(in.valueCoins, USDT_DEPOSIT_REFUND_VALUE);
            transferDepositTokens(
                storage.holdingAttempt == null ? terms.contributor : storage.beneficiary!,
                msg.amount,
                terms.nonce,
                0,
                in.senderAddress,
                storage.transferComment(),
            );
        }
        JettonExcesses => {
            // A matching excess never changes principal selection, allowances, or settlement.
            val recipient = storage.holdingAttempt == null
                ? terms.contributor
                : storage.beneficiary;
            if (storage.holdingAttempt == null && storage.allocation != null) {
                val allocation = storage.allocation.load();
                if (
                    (msg.queryId == allocation.attempt ||
                        msg.queryId == USDT_DEPOSIT_PROBE_QUERY) &&
                    in.senderAddress ==
                    deriveUsdtWalletFor(
                        holdingVault(storage.terms, allocation.attempt).calculateAddress(),
                    )
                ) {
                    returnVaultSurplus(terms.contributor);
                    return;
                }
            }
            if (
                recipient != null && in.senderAddress == deriveUsdtWalletFor(recipient) &&
                msg.queryId == terms.nonce &&
                (storage.status == UsdtDepositStatus.Assigned ||
                    storage.status == UsdtDepositStatus.Refunded)
            ) {
                returnVaultSurplus(terms.contributor);
            }
        }
        else => {
            throw UsdtDepositVaultErrors.InvalidMessage;
        }
    }
}

fun mainVault(terms: Cell<UsdtDepositTerms>): AutoDeployAddress {
    return usdtVaultInitWithCode(contract.getCode(), terms);
}

fun holdingVault(terms: Cell<UsdtDepositTerms>, attempt: uint64): AutoDeployAddress {
    return usdtVaultInitWithCode(contract.getCode(), terms, attempt);
}

fun preserveDepositReserve(msgValue: coins, requiredValue: coins) {
    assert (msgValue >= requiredValue) throw UsdtDepositVaultErrors.NotEnoughValue;
    reserveGramsOnBalance(
        max(usdtRecoveryStorageReserve(), contract.getOriginalBalance() - msgValue),
        RESERVE_MODE_EXACT_AMOUNT,
    );
}

fun transferDepositTokens(
    recipient: address,
    amount: coins,
    queryId: uint64,
    forward: coins,
    sponsor: address,
    comment: Cell<TextComment>? = null,
) {
    assert (amount > 0) throw UsdtDepositVaultErrors.InvalidAmount;
    var forwardPayload = beginCell().storeBool(false).toSlice();
    if (comment != null) {
        forwardPayload = comment.forwardPayload();
    }
    val transfer = createMessage({
        bounce: true,
        value: grams("0"),
        dest: deriveUsdtWalletFor(contract.getAddress()),
        body: JettonTransfer {
            queryId,
            jettonAmount: amount,
            transferRecipient: recipient,
            sendExcessesTo: sponsor,
            forwardTonAmount: comment == null ? forward : JETTON_COMMENT_NOTIFY_VALUE,
            forwardPayload,
        },
    });
    // SAFETY: the preceding reserve protects retained TON; only the caller funds this cascade.
    transfer.send(SEND_MODE_CARRY_ALL_BALANCE);
}

fun reportDeposit(storage: UsdtDepositVaultStorage) {
    if (storage.holdingAttempt == null) {
        if (storage.status == UsdtDepositStatus.Deposited) {
            val receipt = createMessage({
                bounce: true,
                value: grams("0"),
                dest: storage.terms.load().escrow,
                body: UsdtDepositReceived { terms: storage.terms },
            });
            // SAFETY: Retained intake TON is reserved; only incoming notification/report gas is forwarded to its escrow.
            receipt.send(SEND_MODE_CARRY_ALL_BALANCE);
            return;
        }
        assert (
            storage.status == UsdtDepositStatus.Assigned
        ) throw UsdtDepositVaultErrors.InvalidStatus;
        if (storage.selectedAttempt != null) {
            val report = createMessage({
                bounce: true,
                value: grams("0"),
                dest: holdingVault(storage.terms, storage.selectedAttempt),
                body: ReportUsdtDeposit {},
            });
            // SAFETY: Retained intake TON is reserved; the caller sponsors only the fixed selected holding report.
            report.send(SEND_MODE_CARRY_ALL_BALANCE);
        } else {
            val allocation = storage.allocation!.load();
            if (allocation.dispatched) {
                val probe = createMessage({
                    bounce: true,
                    value: grams("0"),
                    dest: holdingVault(storage.terms, allocation.attempt),
                    body: ProbeUsdtDeposit {},
                });
                // SAFETY: Retained intake TON is reserved; the caller sponsors a custody probe, never a second allocation.
                probe.send(SEND_MODE_CARRY_ALL_BALANCE);
            } else {
                prepareHolding(storage.terms, allocation.attempt);
            }
        }
        return;
    }
    if (storage.status == UsdtDepositStatus.Deposited) {
        val funded = createMessage({
            bounce: true,
            value: grams("0"),
            dest: storage.terms.load().escrow,
            body: UsdtHoldingFunded {
                terms: storage.terms,
                attempt: storage.holdingAttempt,
            },
        });
        // SAFETY: Retained holding TON is reserved; the notification/report budget goes to its immutable escrow.
        funded.send(SEND_MODE_CARRY_ALL_BALANCE);
        return;
    }
    assert (
        storage.status == UsdtDepositStatus.Assigned
    ) throw UsdtDepositVaultErrors.InvalidStatus;
    val receipt = UsdtDepositAssigned {
        terms: storage.terms,
        beneficiary: storage.beneficiary!,
        holdingAttempt: storage.holdingAttempt,
    };
    val escrowReceipt = createMessage({
        bounce: true,
        value: USDT_DEPOSIT_REPORT_VALUE,
        dest: storage.terms.load().escrow,
        body: receipt,
    });
    escrowReceipt.send(SEND_MODE_PAY_FEES_SEPARATELY);
    val parentReceipt = createMessage({
        bounce: true,
        value: grams("0"),
        dest: mainVault(storage.terms),
        body: receipt,
    });
    // SAFETY: Retained holding TON is reserved; only the remaining report budget returns to its canonical parent.
    parentReceipt.send(SEND_MODE_CARRY_ALL_BALANCE);
}

fun UsdtDepositVaultStorage.fixBeneficiary(mutate self, beneficiary: address) {
    assert (
        self.beneficiary == null || self.beneficiary == beneficiary
    ) throw UsdtDepositVaultErrors.BeneficiaryAlreadyAssigned;
    self.beneficiary = beneficiary;
}

fun allocatePrincipal(mutate storage: UsdtDepositVaultStorage, beneficiary: address) {
    storage.fixBeneficiary(beneficiary);
    storage.status = UsdtDepositStatus.Assigned;
    if (storage.selectedAttempt != null) {
        reportDeposit(storage);
        return;
    }
    // LTIME is unique per account transaction, including after owner deletion/recreation.
    val attempt = blockchain.logicalTime() as uint64;
    storage.allocation = UsdtPrincipalAllocation { attempt }.toCell();
    storage.save();
    prepareHolding(storage.terms, attempt);
}

fun prepareHolding(terms: Cell<UsdtDepositTerms>, attempt: uint64) {
    val preparation = createMessage({
        bounce: true,
        value: grams("0"),
        dest: holdingVault(terms, attempt),
        body: PrepareUsdtHolding {},
    });
    // SAFETY: Retained intake TON is reserved; this fresh holding receives only the current assignment budget.
    preparation.send(SEND_MODE_CARRY_ALL_BALANCE);
}

fun assignHoldingBeneficiary(mutate storage: UsdtDepositVaultStorage, beneficiary: address) {
    storage.fixBeneficiary(beneficiary);
    if (storage.status == UsdtDepositStatus.Assigned) {
        reportDeposit(storage);
        return;
    }
    storage.status = UsdtDepositStatus.Assigned;
    storage.save();
    val receipt = UsdtDepositAssigned {
        terms: storage.terms,
        beneficiary,
        holdingAttempt: storage.holdingAttempt!,
    };
    val escrowReceipt = createMessage({
        bounce: true,
        value: USDT_DEPOSIT_REPORT_VALUE,
        dest: storage.terms.load().escrow,
        body: receipt,
    });
    escrowReceipt.send(SEND_MODE_PAY_FEES_SEPARATELY);
    val parentReceipt = createMessage({
        bounce: true,
        value: USDT_DEPOSIT_REPORT_VALUE,
        dest: mainVault(storage.terms),
        body: receipt,
    });
    parentReceipt.send(SEND_MODE_PAY_FEES_SEPARATELY);
    val terms = storage.terms.load();
    transferDepositTokens(
        beneficiary,
        terms.amount,
        terms.nonce,
        0,
        contract.getAddress(),
        storage.transferComment(),
    );
}

fun UsdtDepositVaultStorage.transferComment(self): Cell<TextComment> {
    if (self.status == UsdtDepositStatus.Refunded) {
        return self.refundComment!;
    }
    if (self.holdingAttempt == null) {
        return TextComment {
            text: "@gettran: Refund (surplus contribution)".literalSlice(),
        }.toCell();
    }
    return TextComment {
        text: self.terms.load().purpose == UsdtDepositPurpose.MarketplaceFee
            ? MARKETPLACE_FEE_COMMENT
            : SETTLEMENT_PAYMENT_COMMENT,
    }.toCell();
}

fun returnVaultSurplus(contributor: address) {
    reserveGramsOnBalance(
        usdtRecoveryStorageReserve(),
        RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_AT_MOST,
    );
    val change = createMessage({
        bounce: BounceMode.NoBounce,
        dest: contributor,
        value: grams("0"),
        body: UnsafeBodyNoRef { forceInline: TextComment { text: GAS_REFUND_COMMENT } },
    });
    // SAFETY: Recovery storage is reserved and the TON recipient is the immutable contributor.
    change.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

// A rejected custody probe resumes allocation with its returned sponsor budget. It does not
// restore an allowance or infer the outcome of an earlier beneficiary transfer.
fun onBouncedMessage(in: InMessageBounced) {
    var body = in.bouncedBody;
    // transferDepositTokens explicitly uses the standard first-256-bits bounce format.
    if (
        body.remainingBitsCount() < 128 || body.loadUint(32) != 0xFFFFFFFF ||
        body.loadUint(32) != reflect.serializationPrefixOf<JettonTransfer>().0 ||
        body.loadUint(64) != USDT_DEPOSIT_PROBE_QUERY
    ) {
        return;
    }
    val storage = UsdtDepositVaultStorage.load();
    if (
        storage.holdingAttempt == null || storage.status != UsdtDepositStatus.Collecting ||
        in.senderAddress != deriveUsdtWalletFor(contract.getAddress())
    ) {
        return;
    }
    preserveDepositReserve(in.valueCoins, 0);
    val unavailable = createMessage({
        bounce: true,
        value: grams("0"),
        dest: mainVault(storage.terms),
        body: UsdtHoldingUnavailable { attempt: storage.holdingAttempt },
    });
    // SAFETY: retained holding TON is reserved; only the rejected probe's sponsor budget returns.
    unavailable.send(SEND_MODE_CARRY_ALL_BALANCE);
}

get fun deposit_state(): UsdtDepositVaultStorage {
    return UsdtDepositVaultStorage.load();
}

get fun usdt_recovery_storage_reserve(): coins {
    return usdtRecoveryStorageReserve();
}
