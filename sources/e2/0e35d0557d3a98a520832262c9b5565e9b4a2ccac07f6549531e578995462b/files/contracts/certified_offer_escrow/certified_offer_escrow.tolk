import "@stdlib/gas-payments"
import "@contracts/usdt_deposit_vault/constants"
import "@contracts/usdt_deposit_vault/enums"
import "@contracts/usdt_deposit_vault/messages"
import "@contracts/usdt_deposit_vault/storage"
import "@contracts/common/comments/constants"
import "@contracts/common/comments/messages"
import "@contracts/common/comments/refund_reason"
import "@contracts/common/gas/constants"
import "@contracts/common/gas/costs"
import "@contracts/common/jetton/messages"
import "@contracts/common/jetton/transfers"
import "@contracts/common/maker_cancellation/authorization"
import "@contracts/common/nft/constants"
import "@contracts/common/nft/deliveries"
import "@contracts/common/nft/deposits"
import "@contracts/common/nft/enums"
import "@contracts/common/nft/messages"
import "@contracts/common/nft/recovery_messages"
import "@contracts/common/nft/transfers"
import "@contracts/common/offer/deposits"
import "@contracts/common/offer/enums"
import "@contracts/common/offer/execution_commitment"
import "@contracts/common/offer/messages"
import "@contracts/common/offer/terms"
import "@contracts/common/offer/wallets"
import "@contracts/common/ton/transfers"
import "@contracts/common/usdt/constants"
import "@contracts/common/usdt/deposits"
import "@contracts/common/usdt/messages"
import "@contracts/common/usdt/network_constants"
import "@contracts/common/usdt/wallet"
import "constants"
import "enums"
import "messages"
import "storage"

contract CertifiedOfferEscrow {
    author: "Gettran"
    version: "1.0.0"
    description: "Escrow for one indivisible Offer whose criterion-selected or provider-delivered positions require a bounded platform certificate and explicit finalization policy"
    storage: CertifiedOfferEscrowStorage
    incomingMessages: AllowedMessage
    incomingExternal: AllowedExternalMessage
}

type AllowedExternalMessage =
    | TriggerCertifiedOfferExpiry
    | TriggerCertifiedExpiredExecutionRelease
    | TriggerSettlementResume
    | TriggerNftDeliveryRetry
    | RelayCertifiedSettlementApproval
    | RelayCertifiedExecutionRejection
    | RelayCertifiedExecutionRejectionAndClose
    | RelayCertifiedCustodiedCancellation
    | RelayMakerCancellation

fun onExternalMessage(inMsgBody: slice) {
    val msg = lazy AllowedExternalMessage.fromSlice(inMsgBody);
    // Signed admission gets the first dispatch branches to preserve external gas credit.
    match (msg) {
        RelayCertifiedCustodiedCancellation => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            assertMayCancelStatus(storage.status);
            val (takerItemCount, paymentAsset) = assertCertifiedCustodiedCancellation(
                storage.terms,
                storage.certifierPublicKey,
                msg.signature,
                msg.signed,
            );
            // The validated policy proves zero maker obligations. The immutable taker cap
            // bounds a partial lot while its paid principal and fee remain exact.
            var takerItems = 0;
            var nativePrincipal = grams("0") as coins;
            var takerFee = grams("0") as coins;
            if (storage.executionAttempt != null) {
                takerItems = takerItemCount as int;
                val attempt = lazy storage.executionAttempt.load();
                if (paymentAsset == (PaymentAsset.Ton as int)) {
                    nativePrincipal = attempt.deposits.total;
                }
                if (attempt.feePayer != null) {
                    val details = lazy attempt.details.load();
                    takerFee = details.takerTonFee;
                }
            }
            val deposits = lazy storage.deposits.load();
            val obligations = nativePrincipal + takerFee;
            val required = paymentAsset == (PaymentAsset.Usdt as int)
                ? requiredExternalEscrowBalance(
                    obligations,
                    storage.automaticRecoveryBudget,
                    takerItems,
                    deposits.usdt.count,
                    false,
                    deposits.usdt.termsPayloadBits,
                    deposits.usdt.termsPayloadCells,
                )
                : requiredExternalEscrowBalance(
                    obligations,
                    storage.automaticRecoveryBudget,
                    takerItems,
                    0,
                    false,
                    0,
                    0,
                );
            assert (
                contract.getOriginalBalance() >= required
            ) throw CertifiedOfferEscrowErrors.AutomaticRecoveryUnavailable;
            acceptExternalMessage();
            closeExternallyVerifiedOffer(CertifiedOfferEscrowStatus.Cancelled);
        }
        RelayCertifiedSettlementApproval => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            assertExternalSettlementApproval(
                storage.terms,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                storage.makerItems,
                storage.certifierPublicKey,
                msg.signature,
                msg.signed,
            );
            acceptExternalMessage();
            applyExternallyVerifiedSettlementApproval(msg.signed);
        }
        RelayMakerCancellation => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            assertMayCancelStatus(storage.status);
            val terms = lazy storage.terms.load();
            assertMakerCancellationForParties(
                terms.offerId,
                terms.parties,
                msg.signature,
                msg.signed,
            );

            val paymentCell = terms.payment;
            var paymentIsUsdt = false;
            if (paymentCell != null) {
                val payment = lazy paymentCell.load();
                paymentIsUsdt = payment.asset == PaymentAsset.Usdt;
            }
            if (paymentIsUsdt && terms.makerTonFee == 0 && terms.takerTonFee == 0) {
                // This relay uses the immutable taker lot cap instead of decoding execution items.
                // Provider-only partial lots can use caller-funded internal cancellation.
                val deposits = lazy storage.deposits.load();
                val nftCount = (storage.makerItems.isEmpty() ? 0 : terms.makerItemCount as int) +
                    (storage.executionAttempt == null ? 0 : terms.takerItemCount as int);
                val required = requiredExternalEscrowBalance(
                    0,
                    storage.automaticRecoveryBudget,
                    nftCount,
                    deposits.usdt.count,
                    false,
                    deposits.usdt.termsPayloadBits,
                    deposits.usdt.termsPayloadCells,
                );
                assert (
                    contract.getOriginalBalance() >= required
                ) throw CertifiedOfferEscrowErrors.AutomaticRecoveryUnavailable;
                acceptExternalMessage();
                closeExternallyVerifiedOffer(CertifiedOfferEscrowStatus.Cancelled);
                return;
            }
            assertExternalTransitionReserve(
                terms.makerItemCount,
                terms.takerItemCount,
                terms.payment,
                terms.makerTonFee,
                terms.takerTonFee,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                storage.makerItems,
                false,
            );
            acceptExternalMessage();
            closeExternallyVerifiedOffer(CertifiedOfferEscrowStatus.Cancelled);
        }
        TriggerCertifiedOfferExpiry => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            storage.assertMayExternallyExpire(msg.offerId, msg.expiresAt);

            assertExternalTransitionReserveForTerms(
                storage.terms,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                storage.makerItems,
                false,
            );
            acceptExternalMessage();
            closeExternallyVerifiedOffer(CertifiedOfferEscrowStatus.Expired);
        }
        TriggerCertifiedExpiredExecutionRelease => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            storage.assertMayExternallyReleaseExecution(
                msg.offerId,
                msg.offerExecutionNumber,
            );

            assertExternalTransitionReserveForTerms(
                storage.terms,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                storage.makerItems,
                false,
            );
            acceptExternalMessage();
            releaseExternallyVerifiedExecutionAttempt();
        }
        TriggerSettlementResume => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            storage.assertMayExternallyResumeSettlement(
                msg.offerId,
                msg.payoutQueryId,
                msg.vault,
            );

            acceptExternalMessage();
            resumeExternallyVerifiedSettlement(msg.vault);
        }
        TriggerNftDeliveryRetry => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            storage.assertMayExternallyRetryNftDelivery(
                msg.offerId,
                msg.nft,
                msg.deliveryQueryId,
            );

            acceptExternalMessage();
            retryExternallyVerifiedNftDelivery(msg.nft);
        }
        RelayCertifiedExecutionRejection => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            storage.assertExternallyRelayedExecutionRejection(msg.signature, msg.signed);

            assertExternalTransitionReserveForTerms(
                storage.terms,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                storage.makerItems,
                false,
            );
            acceptExternalMessage();
            applyExternallyVerifiedExecutionRejection(msg.signed);
        }
        RelayCertifiedExecutionRejectionAndClose => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            storage.assertExternallyRelayedExecutionRejectionAndClose(
                msg.signature,
                msg.signed,
            );

            assertExternalTransitionReserveForTerms(
                storage.terms,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                storage.makerItems,
                false,
            );
            acceptExternalMessage();
            applyExternallyVerifiedExecutionRejectionAndClose(msg.signed);
        }
        else => {
            throw CertifiedOfferEscrowErrors.InvalidMessage;
        }
    }
}

type AllowedMessage =
    | NftOwnershipAssigned
    | NftReportStaticData
    | JettonTransferNotification
    | JettonExcesses
    | UsdtDepositReceived
    | UsdtDepositAssigned
    | UsdtHoldingFunded
    | ResolveUsdtDeposit
    | ResolveUsdtHolding
    | PrepareUsdtPayment
    | StartCertifiedOfferExecution
    | DepositCertifiedOfferPayment
    | BuyCertifiedOffer
    | ApplyCertifiedSettlementApproval
    | ReleaseCertifiedOfferExecutionAttempt
    | ApplyCertifiedExecutionRejection
    | ApplyCertifiedExecutionRejectionAndClose
    | ExpireCertifiedOffer
    | ResumeCertifiedSettlement
    | Cancel
    | RelayCertifiedCustodiedCancellation
    | DepositEscrowReserve
    | DepositSideFee
    | ConfirmNftDelivery
    | RetryNftDelivery
    | RecoverUnexpectedNft
    | TextComment

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);

    match (msg) {
        NftOwnershipAssigned => {
            applyItemDeposit(in.senderAddress, msg.previousOwner, msg.forwardPayload);
        }
        NftReportStaticData => {
            finishNftDeliveryFence(in.senderAddress, msg.queryId);
        }
        JettonTransferNotification => {
            applyUsdtDepositNotification(in.senderAddress, msg);
        }
        JettonExcesses => {
            // Only a tracked NFT refund can consume this receipt; USDT excesses prove no payout.
            confirmNftTransfer(in.senderAddress, msg.queryId);
        }
        UsdtDepositReceived => {
            applyUsdtDeposit(in.senderAddress, msg.terms);
        }
        UsdtDepositAssigned => {
            confirmUsdtDeposit(in.senderAddress, msg.terms, msg.beneficiary, msg.holdingAttempt);
        }
        UsdtHoldingFunded => {
            selectFundedUsdtHolding(in.senderAddress, in.valueCoins, msg.terms, msg.attempt);
        }
        PrepareUsdtPayment => {
            // Без полной side fee подготовка только коммитит execution в адресах vault. Lock
            // возникает после первого фактического USDT receipt.
            if (msg.execution != null && msg.sideFeeAmount > 0) {
                val executionAttempt = StartCertifiedOfferExecution.fromCell(
                    msg.execution,
                );
                assert (
                    executionAttempt.paymentAmount == 0 && executionAttempt.sideFeeAmount == 0
                ) throw CertifiedOfferEscrowErrors.InvalidTerms;
                CertifiedOfferEscrowStorage
                    .load()
                    .assertExecutionStartsWithCommitment(
                        executionAttempt.signed,
                        0,
                        msg.sideFeeAmount,
                    );
                startOfferExecution(
                    in.senderAddress,
                    executionAttempt.signature,
                    executionAttempt.signed,
                );
            }
            if (msg.sideFeeAmount > 0) {
                assert (
                    depositSideFee(
                        in.senderAddress,
                        msg.sideFeeAmount,
                        msg.offerExecutionNumber,
                    )
                ) throw CertifiedOfferEscrowErrors.InvalidTerms;
            }
            var storage = CertifiedOfferEscrowStorage.load();
            assert (!storage.isClosed()) throw CertifiedOfferEscrowErrors.AlreadyClosed;
            assert (
                storage.status == CertifiedOfferEscrowStatus.CollectingMaker ||
                storage.status == CertifiedOfferEscrowStatus.Open ||
                storage.status == CertifiedOfferEscrowStatus.CollectingTaker
            ) throw CertifiedOfferEscrowErrors.SettlementInProgress;
            val payment = storage.terms.load().payment;
            assert (payment != null) throw CertifiedOfferEscrowErrors.InvalidTerms;
            assert (
                payment.load().payer != OfferSide.Taker ||
                !storage.terms.load().parties.load().isMakerWallet(in.senderAddress)
            ) throw CertifiedOfferEscrowErrors.InvalidContributorSet;
            assert (
                msg.offerExecutionNumber ==
                (payment.load().payer == OfferSide.Maker
                    ? (0 as uint32)
                    : storage.offerExecutionNumber)
            ) throw CertifiedOfferEscrowErrors.ExecutionAttemptMoved;
            assert (
                in.valueCoins >= msg.sideFeeAmount
            ) throw CertifiedOfferEscrowErrors.NotEnoughValue;
            var preMessageBalanceToReserve: coins? = null;
            if (storage.terms.load().policy.load().custodiedCancellationByCertifier) {
                preMessageBalanceToReserve = max(
                    0,
                    contract.getOriginalBalance() - in.valueCoins + msg.sideFeeAmount,
                );
                val executionCell = msg.execution;
                assert (executionCell != null) throw CertifiedOfferEscrowErrors.InvalidCertificate;
                val execution = StartCertifiedOfferExecution.fromCell(executionCell);
                val certificate = CertifiedExecutionCertificate.fromCell(execution.signed);
                assert (
                    certificateIsValid(
                        storage,
                        certificate,
                        execution.signature,
                        execution.signed.hash(),
                    ) &&
                    certificate.details.load().contributorWallets.exists(in.senderAddress)
                ) throw CertifiedOfferEscrowErrors.InvalidCertificate;

                val executionAttempt = storage.executionAttempt;
                if (executionAttempt != null) {
                    val attempt = lazy executionAttempt.load();
                    assert (
                        attempt.certificateHash == execution.signed.hash() &&
                        attempt.confirmedContributorWallets.exists(in.senderAddress)
                    ) throw CertifiedOfferEscrowErrors.InvalidContributorSet;
                }

                val reserveRefundRecipient = storage.reserveRefundRecipient;
                if (
                    reserveRefundRecipient == null ||
                    (executionAttempt == null && reserveRefundRecipient != in.senderAddress)
                ) {
                    val vaultCount = (msg.principal > 0 ? 1 : 0) + (msg.marketplaceFee > 0 ? 1 : 0);
                    assert (
                        in.valueCoins >=
                        msg.sideFeeAmount + USDT_DEPOSIT_PREPARE_VALUE * vaultCount +
                        USDT_DEPOSIT_PREPARATION_OVERHEAD +
                        storage.requiredSettlementBalance(false)
                    ) throw CertifiedOfferEscrowErrors.NotEnoughValue;
                    // Подготовка не даёт эксклюзивность. Новый плательщик заменяет только резерв;
                    // возврат ограничен прежним балансом, чтобы ему не ушёл новый взнос.
                    if (reserveRefundRecipient != null) {
                        val previousBalance = max(0, contract.getOriginalBalance() - in.valueCoins);
                        val retainedBalance = min(
                            previousBalance,
                            closedEscrowStorageReserve(storage) + storage.automaticRecoveryBudget,
                        );
                        val refund = previousBalance - retainedBalance;
                        if (refund > 0) {
                            val reserveRefund = createMessage({
                                bounce: BounceMode.NoBounce,
                                value: refund,
                                dest: reserveRefundRecipient,
                            });
                            reserveRefund.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                        }
                        preMessageBalanceToReserve = retainedBalance + msg.sideFeeAmount;
                    }
                    storage.reserveRefundRecipient = in.senderAddress;
                    storage.save();
                }
                openIfMakerReady(mutate storage);
            }
            prepareUsdtPayment(
                in.senderAddress,
                in.valueCoins - msg.sideFeeAmount,
                payment.load(),
                msg,
                preMessageBalanceToReserve,
            );
            var fundedStorage = CertifiedOfferEscrowStorage.load();
            if (payment.load().payer == OfferSide.Maker) {
                val vaultCount = (msg.principal > 0 ? 1 : 0) + (msg.marketplaceFee > 0 ? 1 : 0);
                fundedStorage.recordMakerReservePayer(
                    in.senderAddress,
                    max(
                        0,
                        in.valueCoins - msg.sideFeeAmount -
                            USDT_DEPOSIT_PREPARE_VALUE * vaultCount -
                            USDT_DEPOSIT_PREPARATION_OVERHEAD,
                    ),
                );
                fundedStorage.save();
            }
        }
        ResolveUsdtDeposit => {
            resolveUsdtDeposit(in.valueCoins, msg.terms);
        }
        ResolveUsdtHolding => {
            val storage = CertifiedOfferEscrowStorage.load();
            val deposit = msg.terms.load();
            resolveUnselectedUsdtHolding(
                storage.deposits.load().usdt,
                msg.terms,
                msg.attempt,
                storage.isClosed() ||
                    (deposit.side == OfferSide.Taker && deposit.offerExecutionNumber <
                        storage.offerExecutionNumber),
                storage.paymentRefundReason(),
                in.valueCoins,
            );
        }
        StartCertifiedOfferExecution => {
            assert (
                in.valueCoins >= msg.paymentAmount + msg.sideFeeAmount
            ) throw CertifiedOfferEscrowErrors.NotEnoughValue;
            CertifiedOfferEscrowStorage
                .load()
                .assertExecutionStartsWithCommitment(
                    msg.signed,
                    msg.paymentAmount,
                    msg.sideFeeAmount,
                );
            startOfferExecution(in.senderAddress, msg.signature, msg.signed);
            val executionNumber = CertifiedOfferEscrowStorage.load().offerExecutionNumber;
            if (msg.sideFeeAmount > 0) {
                assert (
                    depositSideFee(
                        in.senderAddress,
                        msg.sideFeeAmount,
                        executionNumber,
                    )
                ) throw CertifiedOfferEscrowErrors.InvalidTerms;
            }
            if (msg.paymentAmount > 0) {
                assert (
                    applyTonDeposit(
                        in.senderAddress,
                        msg.paymentAmount,
                        executionNumber,
                        msg.paymentAmount,
                    )
                ) throw CertifiedOfferEscrowErrors.InvalidTerms;
            }
        }
        DepositCertifiedOfferPayment => {
            assert (
                msg.paymentAmount + msg.sideFeeAmount > 0 &&
                in.valueCoins >= msg.paymentAmount + msg.sideFeeAmount
            ) throw CertifiedOfferEscrowErrors.NotEnoughValue;
            if (msg.sideFeeAmount > 0 && msg.paymentAmount > 0) {
                assert (
                    depositSideFee(
                        in.senderAddress,
                        msg.sideFeeAmount,
                        msg.offerExecutionNumber,
                        in.valueCoins - msg.paymentAmount - msg.sideFeeAmount,
                    )
                ) throw CertifiedOfferEscrowErrors.InvalidTerms;
                assert (
                    applyTonDeposit(
                        in.senderAddress,
                        msg.paymentAmount,
                        msg.offerExecutionNumber,
                        msg.paymentAmount,
                        in.valueCoins - msg.paymentAmount - msg.sideFeeAmount,
                    )
                ) throw CertifiedOfferEscrowErrors.InvalidTerms;
            } else if (msg.sideFeeAmount > 0) {
                depositSideFee(
                    in.senderAddress,
                    msg.sideFeeAmount,
                    msg.offerExecutionNumber,
                    in.valueCoins - msg.paymentAmount - msg.sideFeeAmount,
                );
            } else {
                applyTonDeposit(
                    in.senderAddress,
                    msg.paymentAmount,
                    msg.offerExecutionNumber,
                    msg.paymentAmount,
                    in.valueCoins - msg.paymentAmount - msg.sideFeeAmount,
                );
            }
        }
        BuyCertifiedOffer => {
            buyWithTon(
                in.senderAddress,
                in.valueCoins,
                msg.paymentAmount,
                msg.signature,
                msg.signed,
            );
        }
        ApplyCertifiedSettlementApproval => {
            applySignedSettlementApproval(msg.signature, msg.signed);
        }
        ReleaseCertifiedOfferExecutionAttempt => {
            releaseOfferExecutionAttempt(in.senderAddress, msg.offerExecutionNumber);
        }
        ApplyCertifiedExecutionRejection => {
            applySignedExecutionRejection(msg.signature, msg.signed);
        }
        ApplyCertifiedExecutionRejectionAndClose => {
            applySignedExecutionRejectionAndClose(msg.signature, msg.signed);
        }
        ExpireCertifiedOffer => {
            expireOffer();
        }
        ResumeCertifiedSettlement => {
            resumeSettlement(in.valueCoins);
        }
        RelayCertifiedCustodiedCancellation => {
            val storage = lazy CertifiedOfferEscrowStorage.load();
            assertMayCancelStatus(storage.status);
            assertCertifiedCustodiedCancellation(
                storage.terms,
                storage.certifierPublicKey,
                msg.signature,
                msg.signed,
            );

            closeOffer(storage, CertifiedOfferEscrowStatus.Cancelled);
        }
        Cancel => {
            cancelOffer(in.senderAddress);
        }
        DepositSideFee => {
            depositSideFee(
                in.senderAddress,
                in.valueCoins,
                msg.offerExecutionNumber,
                max(0, in.valueCoins - CertifiedOfferEscrowStorage.load().terms.load().makerTonFee),
            );
        }
        DepositEscrowReserve => {
            depositEscrowReserve(in.senderAddress, in.valueCoins);
        }
        ConfirmNftDelivery => {
            confirmNftDeliveryReceipt(in.senderAddress, msg.nft);
        }
        RetryNftDelivery => {
            retryNftDelivery(in.senderAddress, in.valueCoins, msg.nft);
        }
        RecoverUnexpectedNft => {
            recoverUnexpectedNft(
                in.senderAddress,
                in.valueCoins,
                msg.recoveryId,
                msg.nft,
                msg.recipient,
            );
        }
        TextComment => {
            if (isCancelComment(msg.text)) {
                cancelOffer(in.senderAddress);
            } else {
                depositEscrowReserve(in.senderAddress, in.valueCoins);
            }
        }
        else => {
            assert (in.body.isEmpty()) throw CertifiedOfferEscrowErrors.InvalidMessage;
            depositEscrowReserve(in.senderAddress, in.valueCoins);
        }
    }
}

fun deliveryCount(commitment: Cell<DeliveryCommitment>?): int {
    if (commitment == null) {
        return 0;
    }
    val delivery = lazy commitment.load();
    return delivery.itemCount;
}

fun paymentTermsAreValid(
    paymentCell: Cell<PaymentTerms>?,
    hasSwapFee: bool,
    makerItemCount: int,
    takerItemCount: int,
): bool {
    if (paymentCell == null) {
        return true;
    }
    val payment = lazy paymentCell.load();
    return payment.amount > 0 && payment.marketplaceFee < payment.amount &&
        (!hasSwapFee || (makerItemCount > 0 && takerItemCount > 0));
}

struct DisjointItemProgress {
    isWithinLimit: bool
    isDisjoint: bool
    promisedCount: int
    depositedCount: int
}

// Считает позиции и проверяет пересечение за один проход одного map. Отдельные progress и overlap
// обходы почти удваивают compute именно на максимальном certified-наборе.
fun inspectDisjointItems(
    items: ItemDeposits,
    forbidden: ItemDeposits,
    maximumItems: int,
): DisjointItemProgress {
    var promisedCount = 0;
    var depositedCount = 0;
    var entry = items.findFirst();
    while (entry.isFound) {
        promisedCount += 1;
        if (promisedCount > maximumItems) {
            return {
                isWithinLimit: false,
                isDisjoint: false,
                promisedCount,
                depositedCount,
            };
        }
        if (forbidden.exists(entry.getKey())) {
            return {
                isWithinLimit: true,
                isDisjoint: false,
                promisedCount,
                depositedCount,
            };
        }
        if (entry.loadValue().isDeposited()) {
            depositedCount += 1;
        }
        entry = items.iterateNext(entry);
    }
    return {
        isWithinLimit: true,
        isDisjoint: true,
        promisedCount,
        depositedCount,
    };
}

fun termsAreValid(storage: CertifiedOfferEscrowStorage): bool {
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    val policy = lazy terms.policy.load();
    val makerProgress = storage.makerItems.progressWithin(MAX_CERTIFIED_OFFER_ITEMS);
    val fixedProgress = inspectDisjointItems(
        policy.fixedTakerItems,
        storage.makerItems,
        terms.takerItemCount,
    );
    val makerDeliveryCount = deliveryCount(policy.makerDelivery);
    val makerCancellation = parties.makerCancellation;
    val makerCancellationIsValid = makerCancellation == null ||
        makerCancellation.load().isValidFor(parties.makerWallets);

    var makerHasConsideration = terms.makerItemCount > 0;
    var takerHasConsideration = terms.takerItemCount > 0;
    val paymentCell = terms.payment;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        makerHasConsideration = makerHasConsideration || payment.payer == OfferSide.Maker;
        takerHasConsideration = takerHasConsideration || payment.payer == OfferSide.Taker;
    }
    val makerHasOnchainObligation = terms.makerItemCount != makerDeliveryCount ||
        terms.makerTonFee > 0 ||
        (paymentCell != null && paymentCell.load().payer == OfferSide.Maker);
    val custodiedCancellationIsValid = policy.custodiedCancellationByCertifier
        ? !makerHasOnchainObligation && parties.makerWallets.isEmpty() && makerCancellation == null
        : parties.makerWallets.isValid(false);

    return terms.makerItemCount + terms.takerItemCount <= MAX_CERTIFIED_OFFER_ITEMS &&
        makerProgress.isWithinLimit &&
        makerProgress.promisedCount + makerDeliveryCount == terms.makerItemCount &&
        fixedProgress.isWithinLimit &&
        fixedProgress.isDisjoint &&
        fixedProgress.depositedCount == 0 &&
        fixedProgress.promisedCount <= terms.takerItemCount &&
        (policy.makerDelivery != null || fixedProgress.promisedCount < terms.takerItemCount) &&
        makerHasConsideration &&
        takerHasConsideration &&
        paymentTermsAreValid(
            paymentCell,
            terms.makerTonFee > 0 || terms.takerTonFee > 0,
            terms.makerItemCount,
            terms.takerItemCount,
        ) &&
        custodiedCancellationIsValid &&
        parties.makerSettlementWallet.getWorkchain() == BASECHAIN &&
        parties.addresseeWallets.isValid(true) &&
        parties.hasIndependentTakerWallets(parties.addresseeWallets) &&
        storage.makerItems.refundRecipientsAreAllowedBy(parties.makerWallets, false) &&
        policy.fixedTakerItems.refundRecipientsAreAllowedBy(parties.addresseeWallets, true) &&
        makerCancellationIsValid &&
        storage.executionAttemptTtl > 0 &&
        storage.executionAttemptTtl <= MAX_CERTIFIED_EXECUTION_ATTEMPT_TTL &&
        storage.certifierPublicKey != 0;
}

fun selectedItemsAreValid(
    selected: ItemDeposits,
    fixed: ItemDeposits,
    makerItems: ItemDeposits,
    contributorWallets: OfferWallets,
    takerItemCount: int,
    takerDeliveryCount: int,
): bool {
    val selectedProgress = inspectDisjointItems(selected, makerItems, takerItemCount);
    if (
        !selectedProgress.isWithinLimit || !selectedProgress.isDisjoint ||
        selectedProgress.depositedCount != 0 ||
        !selected.refundRecipientsAreAllowedBy(contributorWallets, false) ||
        selectedProgress.promisedCount + takerDeliveryCount != takerItemCount
    ) {
        return false;
    }

    var fixedItem = fixed.findFirst();
    while (fixedItem.isFound) {
        if (!selected.exists(fixedItem.getKey())) {
            return false;
        }
        fixedItem = fixed.iterateNext(fixedItem);
    }
    return true;
}

fun certificateIsValid(
    storage: CertifiedOfferEscrowStorage,
    certificate: CertifiedExecutionCertificate,
    signature: bits512,
    signedHash: uint256,
): bool {
    val terms = lazy storage.terms.load();
    val policy = lazy terms.policy.load();
    val details = lazy certificate.details.load();
    val now = blockchain.now();
    val latestAdmissionEnd = min(now + storage.executionAttemptTtl, storage.expiresAt);
    val takerDeliveryCount = deliveryCount(details.delivery);
    val hasOnchainSettlement = !storage.makerItems.isEmpty() || !details.items.isEmpty() ||
        terms.payment != null ||
        terms.makerTonFee > 0 ||
        details.takerTonFee > 0;

    return hasOnchainSettlement && details.takerTonFee <= terms.takerTonFee &&
        isSignatureValid(signedHash, signature as slice, storage.certifierPublicKey) &&
        certificate.escrow == contract.getAddress() &&
        certificate.offerId == terms.offerId &&
        certificate.offerExecutionNumber == storage.offerExecutionNumber &&
        certificate.requirementCommitment == policy.takerRequirementCommitment &&
        certificate.validUntil > now &&
        certificate.validUntil <= latestAdmissionEnd &&
        details.contributorWallets.isAllowedBy(terms.parties.load().addresseeWallets) &&
        terms.parties.load().hasIndependentTakerWallets(details.contributorWallets) &&
        !terms.parties.load().isMakerWallet(details.takerSettlementWallet) &&
        details.takerSettlementWallet.getWorkchain() == BASECHAIN &&
        selectedItemsAreValid(
            details.items,
            policy.fixedTakerItems,
            storage.makerItems,
            details.contributorWallets,
            terms.takerItemCount,
            takerDeliveryCount,
        );
}

fun startOfferExecution(
    sender: address,
    signature: bits512,
    signed: cell,
    excessRecipient: address? = null,
) {
    var storage = lazy CertifiedOfferEscrowStorage.load();
    // Execution may itself deploy a fully backed custody offer and deposit its reserve.
    openIfMakerReady(mutate storage);
    assert (
        storage.status == CertifiedOfferEscrowStatus.Open ||
        storage.status == CertifiedOfferEscrowStatus.CollectingTaker
    ) throw CertifiedOfferEscrowErrors.NotOpen;
    assert (blockchain.now() < storage.expiresAt) throw CertifiedOfferEscrowErrors.OfferExpired;
    assert (
        hasCertifiedExecutionDomain(signed)
    ) throw CertifiedOfferEscrowErrors.WrongCertificateDomain;

    val signedHash = signed.hash();
    if (storage.status == CertifiedOfferEscrowStatus.CollectingTaker) {
        val executionAttemptCell = storage.executionAttempt;
        assert (executionAttemptCell != null) throw CertifiedOfferEscrowErrors.NotOpen;
        var executionAttempt = executionAttemptCell.load();
        assert (
            executionAttempt.certificateHash == signedHash
        ) throw CertifiedOfferEscrowErrors.InvalidCertificate;
        assert (
            blockchain.now() < executionAttempt.validUntil
        ) throw CertifiedOfferEscrowErrors.OfferExpired;

        val details = lazy executionAttempt.details.load();
        assert (
            details.contributorWallets.exists(sender)
        ) throw CertifiedOfferEscrowErrors.InvalidContributorSet;

        // Первый StartCertifiedOfferExecution уже проверил подпись всей certificate cell. Совпадение hash
        // связывает повтор с той же неизменяемой certificate без повторной дорогой Ed25519-проверки.
        executionAttempt.confirmedContributorWallets.set(sender, true);
        storage.executionAttempt = executionAttempt.toCell();
        storage.save();
        advanceIfReady(mutate storage);
        return;
    }

    val certificate = CertifiedExecutionCertificate.fromCell(signed);
    assert (
        certificateIsValid(storage, certificate, signature, signedHash)
    ) throw CertifiedOfferEscrowErrors.InvalidCertificate;
    val certified = lazy certificate.details.load();
    // Новая попытка не должна накапливать NFT-обязательства поверх незавершённых возвратов.
    assert (
        storage.deposits.load().nftDeliveries.isEmpty()
    ) throw CertifiedOfferEscrowErrors.NftDeliveryPending;
    assert (
        certified.contributorWallets.exists(sender)
    ) throw CertifiedOfferEscrowErrors.InvalidContributorSet;

    storage.status = CertifiedOfferEscrowStatus.CollectingTaker;
    storage.executionAttempt = CertifiedOfferExecutionAttempt {
        excessRecipient,
        number: certificate.offerExecutionNumber,
        certificateHash: signedHash,
        // Admission expiry does not consume the collection period after the first commitment.
        validUntil: min(blockchain.now() + storage.executionAttemptTtl, storage.expiresAt),
        confirmedContributorWallets: singleOfferWallet(sender),
        deposits: { total: 0, contributions: [] },
        details: CertifiedExecutionAttemptDetails {
            contributorWallets: certified.contributorWallets,
            takerSettlementWallet: certified.takerSettlementWallet,
            items: certified.items,
            delivery: certified.delivery,
            executionAgreementId: certified.executionAgreementId,
            takerTonFee: certified.takerTonFee,
        }.toCell(),
    }.toCell();
    storage.save();
    advanceIfReady(mutate storage);
}

// Sale — одна бизнес-операция: certificate и полная TON-оплата либо принимаются вместе, либо
// целиком откатываются. Для чисто provider-delivered лота escrow впервые финансирует покупатель,
// поэтому именно он получает остаток над выплатами и storage reserve.
fun buyWithTon(
    sender: address,
    msgValue: coins,
    amount: coins,
    signature: bits512,
    signed: cell,
) {
    val initial = lazy CertifiedOfferEscrowStorage.load();
    val terms = lazy initial.terms.load();
    val paymentCell = terms.payment;
    assert (paymentCell != null) throw CertifiedOfferEscrowErrors.InvalidTerms;
    val payment = lazy paymentCell.load();
    assert (
        (initial.status == CertifiedOfferEscrowStatus.CollectingMaker ||
            initial.status == CertifiedOfferEscrowStatus.Open) &&
        payment.asset == PaymentAsset.Ton &&
        payment.payer == OfferSide.Taker &&
        terms.takerItemCount == 0 &&
        amount == payment.amount &&
        msgValue >= amount &&
        contract.getOriginalBalance() >= initial.requiredSettlementBalance(true)
    ) throw CertifiedOfferEscrowErrors.NotEnoughValue;

    val policy = lazy terms.policy.load();
    val buyerFundsEscrow = initial.makerItems.isEmpty() && policy.makerDelivery != null;
    startOfferExecution(
        sender,
        signature,
        signed,
        buyerFundsEscrow ? sender : null,
    );
    applyTonDeposit(sender, msgValue, initial.offerExecutionNumber, amount);

    val completed = lazy CertifiedOfferEscrowStorage.load();
    assert (
        completed.status == CertifiedOfferEscrowStatus.AwaitingApproval ||
        completed.status == CertifiedOfferEscrowStatus.Settled
    ) throw CertifiedOfferEscrowErrors.InvalidTerms;
}

// NFT уже принадлежит escrow, поэтому непринимаемый депозит возвращается previousOwner вместо
// throw. Сертификат один раз связывает конкретные NFT и wallets; transfer payload ничего не
// авторизует и намеренно игнорируется.
fun applyItemDeposit(item: address, depositor: address, forwardPayload: slice) {
    var storage = lazy CertifiedOfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    if (storage.deposits.load().nftDeliveries.exists(item)) {
        val delivery = storage.deposits.load().nftDeliveries.get(item).loadValue();
        if (delivery.recipient == depositor) {
            returnStrayNftWithComment(item, depositor, delivery.comment);
        }
        return;
    }

    if (storage.status == CertifiedOfferEscrowStatus.CollectingMaker) {
        val parties = lazy terms.parties.load();
        val slot = storage.makerItems.get(item);
        if (
            blockchain.now() >= storage.expiresAt || !termsAreValid(storage) ||
            !parties.makerWallets.exists(depositor) ||
            !slot.isFound ||
            !slot.loadValue().acceptsDepositor(depositor)
        ) {
            returnStrayNft(item, depositor, storage.itemRefundReason());
            return;
        }

        var makerDeposit = slot.loadValue();
        makerDeposit.depositor = depositor;
        storage.makerItems.set(item, makerDeposit);
        storage.save();
        openIfMakerReady(mutate storage);
        return;
    }

    val executionCell = readExecutionCommitment(forwardPayload);
    if (
        executionCell != null &&
        (storage.status == CertifiedOfferEscrowStatus.Open ||
            storage.status == CertifiedOfferEscrowStatus.CollectingTaker)
    ) {
        if (!tryStartCertifiedExecutionFromNftCommitment(item, depositor, executionCell)) {
            returnStrayNft(item, depositor, storage.itemRefundReason());
            return;
        }
        storage = CertifiedOfferEscrowStorage.load();
    }

    if (storage.status != CertifiedOfferEscrowStatus.CollectingTaker) {
        returnStrayNft(item, depositor, storage.itemRefundReason());
        return;
    }

    val executionAttemptCell = storage.executionAttempt;
    if (executionAttemptCell == null) {
        returnStrayNft(item, depositor, storage.itemRefundReason());
        return;
    }

    var executionAttempt = executionAttemptCell.load();
    var details = executionAttempt.details.load();
    val slot = details.items.get(item);
    if (
        blockchain.now() >= executionAttempt.validUntil ||
        !executionAttempt.confirmedContributorWallets.exists(depositor) ||
        !slot.isFound ||
        !slot.loadValue().acceptsDepositor(depositor)
    ) {
        returnStrayNft(item, depositor, storage.itemRefundReason());
        return;
    }

    var takerDeposit = slot.loadValue();
    takerDeposit.depositor = depositor;
    details.items.set(item, takerDeposit);
    executionAttempt.details = details.toCell();
    storage.executionAttempt = executionAttempt.toCell();
    storage.save();
    advanceIfReady(mutate storage);
}

fun tryStartCertifiedExecutionFromNftCommitment(
    item: address,
    sender: address,
    executionCell: cell,
): bool {
    try {
        val execution = StartCertifiedOfferExecution.fromCell(executionCell);
        assert (
            execution.paymentAmount == 0 && execution.sideFeeAmount == 0
        ) throw CertifiedOfferEscrowErrors.InvalidTerms;
        val certificate = lazy CertifiedExecutionCertificate.fromCell(execution.signed);
        val slot = certificate.details.load().items.get(item);
        assert (
            slot.isFound && slot.loadValue().acceptsDepositor(sender)
        ) throw CertifiedOfferEscrowErrors.InvalidTerms;
        startOfferExecution(sender, execution.signature, execution.signed);
        return true;
    } catch (_, _) {
        return false;
    }
}

fun tryStartCertifiedExecutionFromUsdtCommitment(sender: address, executionCell: cell): bool {
    try {
        val execution = StartCertifiedOfferExecution.fromCell(executionCell);
        assert (
            execution.paymentAmount == 0 && execution.sideFeeAmount == 0
        ) throw CertifiedOfferEscrowErrors.InvalidTerms;
        startOfferExecution(sender, execution.signature, execution.signed);
        return true;
    } catch (_, _) {
        return false;
    }
}

fun CertifiedOfferEscrowStorage.assertExecutionStartsWithCommitment(
    self,
    signed: cell,
    paymentAmount: coins,
    sideFeeAmount: coins,
) {
    if (self.status == CertifiedOfferEscrowStatus.CollectingTaker) {
        return;
    }
    val terms = lazy self.terms.load();
    val paymentCell = terms.payment;
    var hasFullNativePayment = false;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        hasFullNativePayment = payment.asset == PaymentAsset.Ton &&
            payment.payer == OfferSide.Taker &&
            paymentAmount == payment.amount;
    }
    val certificate = lazy CertifiedExecutionCertificate.fromCell(signed);
    val details = lazy certificate.details.load();
    val hasFullSideFee = details.takerTonFee > 0 && sideFeeAmount == details.takerTonFee;
    val hasProviderCommitment = details.items.isEmpty() && details.delivery != null &&
        (paymentCell == null || paymentCell.load().payer == OfferSide.Maker);
    assert (
        hasFullNativePayment || hasFullSideFee || hasProviderCommitment
    ) throw CertifiedOfferEscrowErrors.NotEnoughValue;
}

fun openIfMakerReady(mutate storage: CertifiedOfferEscrowStorage) {
    if (storage.status != CertifiedOfferEscrowStatus.CollectingMaker) {
        return;
    }

    val terms = lazy storage.terms.load();
    val makerProgress = storage.makerItems.progressWithin(MAX_CERTIFIED_OFFER_ITEMS);
    val paymentCell = terms.payment;
    var makerPaymentReady = true;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        makerPaymentReady = payment.payer != OfferSide.Maker ||
            storage.deposits.load().maker.total == payment.amount;
    }

    if (
        blockchain.now() < storage.expiresAt && termsAreValid(storage) &&
        makerProgress.isComplete &&
        makerPaymentReady &&
        (terms.makerTonFee == 0 || storage.deposits.load().makerFeePayer != null) &&
        contract.getOriginalBalance() >= storage.requiredSettlementBalance(false)
    ) {
        storage.status = CertifiedOfferEscrowStatus.Open;
        storage.save();
    }
}

fun CertifiedOfferEscrowStorage.itemRefundReason(self): RefundReason {
    val reason = self.paymentRefundReason();
    return reason == RefundReason.OfferUnavailable ? RefundReason.InvalidItem : reason;
}

fun CertifiedOfferEscrowStorage.paymentRefundReason(self): RefundReason {
    if (self.status == CertifiedOfferEscrowStatus.Cancelled) {
        return RefundReason.OfferCancelled;
    }
    if (self.status == CertifiedOfferEscrowStatus.Settled) {
        return RefundReason.OfferUnavailable;
    }
    if (self.status == CertifiedOfferEscrowStatus.Expired || blockchain.now() >= self.expiresAt) {
        return RefundReason.OfferExpired;
    }
    val execution = self.executionAttempt;
    if (
        (self.status == CertifiedOfferEscrowStatus.CollectingTaker ||
            self.status == CertifiedOfferEscrowStatus.AwaitingApproval) &&
        execution != null &&
        blockchain.now() >= execution.load().validUntil
    ) {
        return RefundReason.ExecutionExpired;
    }
    return RefundReason.OfferUnavailable;
}

fun applyTonDeposit(
    sender: address,
    msgValue: coins,
    offerExecutionNumber: uint32,
    amount: coins,
    reserveValue: coins = 0,
): bool {
    var storage = lazy CertifiedOfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    val paymentCell = terms.payment;
    if (paymentCell == null) {
        refundTon(sender, storage.paymentRefundReason().comment());
        return false;
    }
    val payment = lazy paymentCell.load();
    if (payment.asset != PaymentAsset.Ton) {
        refundTon(sender, RefundReason.InvalidAsset.comment());
        return false;
    }
    if (amount <= 0) {
        refundTon(sender, RefundReason.InvalidPayment.comment());
        return false;
    }
    if (msgValue < amount) {
        refundTon(sender, RefundReason.AmountTooLow.comment());
        return false;
    }

    if (
        storage.status == CertifiedOfferEscrowStatus.CollectingMaker &&
        payment.payer == OfferSide.Maker &&
        blockchain.now() <
        storage.expiresAt &&
        parties.makerWallets.exists(sender) &&
        offerExecutionNumber == storage.offerExecutionNumber &&
        storage.deposits.load().maker.total + amount <= payment.amount
    ) {
        storage.deposits.addMakerTonDeposit(sender, amount);
        storage.recordMakerReservePayer(sender, reserveValue);
        storage.save();
        openIfMakerReady(mutate storage);
        return true;
    }

    val executionAttemptCell = storage.executionAttempt;
    if (
        storage.status == CertifiedOfferEscrowStatus.CollectingTaker &&
        payment.payer == OfferSide.Taker &&
        executionAttemptCell != null
    ) {
        var executionAttempt = executionAttemptCell.load();
        if (
            executionAttempt.number == offerExecutionNumber &&
            executionAttempt.confirmedContributorWallets.exists(sender) &&
            blockchain.now() <
            executionAttempt.validUntil &&
            executionAttempt.deposits.total + amount <= payment.amount
        ) {
            executionAttempt.deposits.total += amount;
            executionAttempt.deposits.contributions.add(sender, amount);
            storage.executionAttempt = executionAttempt.toCell();
            storage.save();
            advanceIfReady(mutate storage);
            return true;
        }
    }

    refundTon(sender, storage.paymentRefundReason().comment());
    return false;
}

fun applyUsdtDepositNotification(wallet: address, notification: JettonTransferNotification) {
    val payer = notification.transferInitiator;
    assert (payer != null) throw CertifiedOfferEscrowErrors.InvalidMessage;
    refundJettonViaSender(wallet, payer, notification.jettonAmount);
}

fun applyUsdtDeposit(sender: address, depositCell: Cell<UsdtDepositTerms>) {
    authenticateUsdtDeposit(sender, depositCell);
    val deposit = depositCell.load();
    var storage = CertifiedOfferEscrowStorage.load();
    var deposits = storage.deposits.load().usdt;
    if (deposits.entries.exists(sender)) {
        return;
    }
    val terms = storage.terms.load();
    val paymentCell = terms.payment;
    if (paymentCell == null || blockchain.now() >= storage.expiresAt) {
        return;
    }
    val payment = paymentCell.load();
    if (payment.asset != PaymentAsset.Usdt || !deposits.canAccept(deposit, payment)) {
        return;
    }
    val parties = terms.parties.load();
    if (
        storage.status == CertifiedOfferEscrowStatus.CollectingMaker &&
        payment.payer == OfferSide.Maker &&
        deposit.offerExecutionNumber == 0 &&
        parties.makerWallets.exists(deposit.contributor)
    ) {
        deposits.add(depositCell);
        storage.deposits.applyMakerUsdtDeposits(deposits);
        openIfMakerReady(mutate storage);
        storage.save();
        return;
    }

    if (
        storage.status == CertifiedOfferEscrowStatus.Open && payment.payer == OfferSide.Taker &&
        deposit.offerExecutionNumber == storage.offerExecutionNumber &&
        deposit.purpose == UsdtDepositPurpose.Principal &&
        deposit.amount == payment.amount - payment.marketplaceFee &&
        deposit.execution != null &&
        parties.addresseeWallets.allows(deposit.contributor)
    ) {
        if (
            !tryStartCertifiedExecutionFromUsdtCommitment(
                deposit.contributor,
                deposit.execution,
            )
        ) {
            return;
        }
        storage = CertifiedOfferEscrowStorage.load();
    }

    val executionAttemptCell = storage.executionAttempt;
    if (
        storage.status != CertifiedOfferEscrowStatus.CollectingTaker ||
        payment.payer != OfferSide.Taker ||
        executionAttemptCell == null
    ) {
        return;
    }
    var executionAttempt = executionAttemptCell.load();
    if (
        deposit.offerExecutionNumber != executionAttempt.number ||
        blockchain.now() >= executionAttempt.validUntil ||
        !executionAttempt.confirmedContributorWallets.exists(deposit.contributor)
    ) {
        return;
    }
    // Подготовка определяет получателя остатка TON, но не владельца execution: principal с
    // действующим certificate может первым внести и ранее подготовившийся покупатель.
    if (
        payment.payer == OfferSide.Taker && deposit.purpose == UsdtDepositPurpose.Principal &&
        deposit.amount == payment.amount - payment.marketplaceFee &&
        storage.makerItems.isEmpty() &&
        terms.policy.load().custodiedCancellationByCertifier
    ) {
        assert (
            storage.reserveRefundRecipient != null
        ) throw CertifiedOfferEscrowErrors.InvalidContributorSet;
        executionAttempt.excessRecipient = storage.reserveRefundRecipient;
    }
    deposits.add(depositCell);
    storage.deposits.setUsdtDeposits(deposits);
    executionAttempt.deposits.total = deposits.principal + deposits.fee;
    storage.executionAttempt = executionAttempt.toCell();
    storage.save();
    advanceIfReady(mutate storage);
}

fun depositSideFee(
    sender: address,
    msgValue: coins,
    offerExecutionNumber: uint32,
    reserveValue: coins = 0,
): bool {
    var storage = CertifiedOfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    if (
        storage.status == CertifiedOfferEscrowStatus.CollectingMaker && blockchain.now() <
        storage.expiresAt &&
        offerExecutionNumber == storage.offerExecutionNumber &&
        parties.makerWallets.exists(sender) &&
        terms.makerTonFee > 0 &&
        storage.deposits.load().makerFeePayer == null &&
        msgValue >= terms.makerTonFee
    ) {
        var deposits = storage.deposits.load();
        deposits.makerFeePayer = sender;
        storage.recordMakerReservePayer(sender, reserveValue);
        storage.deposits = deposits.toCell();
        storage.save();
        openIfMakerReady(mutate storage);
        return true;
    }

    val executionAttemptCell = storage.executionAttempt;
    if (
        storage.status == CertifiedOfferEscrowStatus.CollectingTaker && executionAttemptCell != null
    ) {
        var executionAttempt = executionAttemptCell.load();
        if (
            blockchain.now() < storage.expiresAt && blockchain.now() <
            executionAttempt.validUntil &&
            executionAttempt.number == offerExecutionNumber &&
            executionAttempt.confirmedContributorWallets.exists(sender) &&
            executionAttempt.details.load().takerTonFee > 0 &&
            executionAttempt.feePayer == null &&
            msgValue >= executionAttempt.details.load().takerTonFee
        ) {
            executionAttempt.feePayer = sender;
            storage.executionAttempt = executionAttempt.toCell();
            storage.save();
            advanceIfReady(mutate storage);
            return true;
        }
    }
    refundTon(sender, storage.paymentRefundReason().comment());
    return false;
}

fun CertifiedOfferEscrowStorage.recordMakerReservePayer(
    mutate self,
    sender: address,
    reserveValue: coins,
): bool {
    if (
        self.reserveRefundRecipient != null || reserveValue <= 0 ||
        (self.status != CertifiedOfferEscrowStatus.CollectingMaker &&
            self.status != CertifiedOfferEscrowStatus.Open)
    ) {
        return false;
    }
    val terms = self.terms.load();
    if (!terms.parties.load().makerWallets.exists(sender)) {
        return false;
    }
    val payment = terms.payment;
    val makerPrincipal = payment != null && payment.load().payer == OfferSide.Maker &&
        payment.load().asset == PaymentAsset.Ton
        ? payment.load().amount
        : (0 as coins);
    val requiredReserve = self.requiredExecutionBalance(false) + MIN_TONS_FOR_STORAGE -
        makerPrincipal -
        terms.makerTonFee;
    // Мелкие deployment nudges и NFT forward value не дают права на чужой основной резерв.
    if (reserveValue >= requiredReserve) {
        self.reserveRefundRecipient = sender;
        return true;
    }
    return false;
}

// Без maker-депозита сетевой резерв приносит участник исполнения. Пополнение само по себе
// не даёт права исполнения; до обязательства новый полный плательщик возвращает прежний резерв.
fun CertifiedOfferEscrowStorage.recordUncommittedTakerReservePayer(
    mutate self,
    sender: address,
    reserveValue: coins,
): bool {
    if (
        (self.status != CertifiedOfferEscrowStatus.CollectingMaker &&
            self.status != CertifiedOfferEscrowStatus.Open) ||
        self.executionAttempt != null ||
        !self.makerItems.isEmpty() ||
        sender == contract.getAddress() ||
        blockchain.now() >= self.expiresAt
    ) {
        return false;
    }
    val terms = self.terms.load();
    val payment = terms.payment;
    val deposits = self.deposits.load();
    if (
        !terms.parties.load().makerWallets.isEmpty() || terms.makerTonFee > 0 ||
        (payment != null && payment.load().payer == OfferSide.Maker) ||
        deposits.maker.total > 0 ||
        deposits.makerFeePayer != null ||
        deposits.usdt.count > 0 ||
        !deposits.nftDeliveries.isEmpty() ||
        reserveValue <
        self.requiredSettlementBalance(false) + NFT_TRANSFER_VALUE * terms.takerItemCount
    ) {
        return false;
    }
    val previousPayer = self.reserveRefundRecipient;
    if (previousPayer != null && previousPayer == sender) {
        return false;
    }
    if (previousPayer != null) {
        // Возвращается только предшествующий баланс: новый взнос и бюджеты recovery не отдаются.
        val previousBalance = max(0, contract.getOriginalBalance() - reserveValue);
        val retainedBalance = min(
            previousBalance,
            closedEscrowStorageReserve(self) + self.automaticRecoveryBudget,
        );
        val refund = previousBalance - retainedBalance;
        if (refund > 0) {
            val reserveRefund = createMessage({
                bounce: BounceMode.NoBounce,
                value: refund,
                dest: previousPayer,
            });
            reserveRefund.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }
    }
    self.reserveRefundRecipient = sender;
    return true;
}

fun CertifiedOfferEscrowStorage.reserveChangeRecipient(self): address {
    return self.reserveRefundRecipient == null
        ? self.terms.load().parties.load().makerSettlementWallet
        : self.reserveRefundRecipient;
}

fun depositEscrowReserve(sender: address, reserveValue: coins) {
    var storage = lazy CertifiedOfferEscrowStorage.load();
    if (storage.isClosed()) {
        if (sender == contract.getAddress()) {
            return;
        }
        refundTon(sender, GAS_REFUND_COMMENT);
        return;
    }
    if (
        storage.recordMakerReservePayer(sender, reserveValue) ||
        storage.recordUncommittedTakerReservePayer(sender, reserveValue)
    ) {
        storage.save();
    }
    if (storage.status == CertifiedOfferEscrowStatus.CollectingMaker) {
        openIfMakerReady(mutate storage);
        return;
    }
    if (storage.status == CertifiedOfferEscrowStatus.CollectingTaker) {
        advanceIfReady(mutate storage);
    }
}

fun executionRequiresApproval(
    policy: CertifiedOfferPolicy,
    details: CertifiedExecutionAttemptDetails,
): bool {
    return policy.finalizationPolicy == FinalizationPolicy.CertifierGated ||
        policy.makerDelivery != null ||
        details.delivery != null;
}

fun advanceIfReady(mutate storage: CertifiedOfferEscrowStorage) {
    if (storage.status != CertifiedOfferEscrowStatus.CollectingTaker) {
        return;
    }
    val executionAttemptCell = storage.executionAttempt;
    if (executionAttemptCell == null) {
        return;
    }

    val executionAttempt = lazy executionAttemptCell.load();
    if (blockchain.now() >= executionAttempt.validUntil || blockchain.now() >= storage.expiresAt) {
        return;
    }
    val details = lazy executionAttempt.details.load();
    val itemProgress = details.items.progressWithin(MAX_CERTIFIED_OFFER_ITEMS);
    val terms = lazy storage.terms.load();
    val paymentCell = terms.payment;
    var takerPaymentReady = true;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        takerPaymentReady = payment.payer != OfferSide.Taker ||
            executionAttempt.deposits.total == payment.amount;
    }
    if (
        !itemProgress.isWithinLimit || !itemProgress.isComplete || !takerPaymentReady ||
        (details.takerTonFee > 0 && executionAttempt.feePayer == null)
    ) {
        return;
    }
    if (contract.getOriginalBalance() < storage.requiredSettlementBalance(true)) {
        return;
    }

    val policy = lazy terms.policy.load();
    if (executionRequiresApproval(policy, details)) {
        storage.status = CertifiedOfferEscrowStatus.AwaitingApproval;
        storage.save();
        return;
    }
    startSettlement(mutate storage);
}

fun deliveryCommitmentMatches(
    commitment: Cell<DeliveryCommitment>?,
    expectedHash: uint256?,
): bool {
    if (commitment == null) {
        return expectedHash == null;
    }
    if (expectedHash == null) {
        return false;
    }
    val delivery = lazy commitment.load();
    return delivery.hash == expectedHash;
}

fun applySignedSettlementApproval(
    signature: bits512,
    signedCell: Cell<CertifiedSettlementApprovalAuthorization>,
) {
    val storage = lazy CertifiedOfferEscrowStorage.load();
    assertSignedSettlementApproval(
        storage.terms,
        storage.executionAttempt,
        storage.status,
        storage.certifierPublicKey,
        signature,
        signedCell,
    );

    applyVerifiedSettlementApproval(storage, signedCell);
}

fun applyVerifiedSettlementApproval(
    storage: CertifiedOfferEscrowStorage,
    signedCell: Cell<CertifiedSettlementApprovalAuthorization>,
) {
    val signed = lazy signedCell.load();
    val evidence = lazy signed.evidence.load();

    applySettlementApproval(
        storage,
        signed.offerExecutionNumber,
        evidence.certificateHash,
        evidence.makerDeliveryCommitment,
        evidence.takerDeliveryCommitment,
    );
}

@inline
fun assertSignedSettlementApproval(
    termsCell: Cell<CertifiedOfferTerms>,
    executionAttemptCell: Cell<CertifiedOfferExecutionAttempt>?,
    status: CertifiedOfferEscrowStatus,
    certifierPublicKey: uint256,
    signature: bits512,
    signedCell: Cell<CertifiedSettlementApprovalAuthorization>,
) {
    assertSettlementApprovalAuthorizationMatches(
        termsCell,
        executionAttemptCell,
        status,
        signedCell,
    );
    assert (
        isSignatureValid(signedCell.hash(), signature as slice, certifierPublicKey)
    ) throw CertifiedOfferEscrowErrors.InvalidSettlementAuthorization;
}

@inline
fun assertSettlementApprovalAuthorizationMatches(
    termsCell: Cell<CertifiedOfferTerms>,
    executionAttemptCell: Cell<CertifiedOfferExecutionAttempt>?,
    status: CertifiedOfferEscrowStatus,
    signedCell: Cell<CertifiedSettlementApprovalAuthorization>,
) {
    val terms = lazy termsCell.load();
    val (signedNumber, evidenceCell) = validateSettlementApprovalEnvelope(
        terms.offerId,
        signedCell,
    );
    val evidence = lazy evidenceCell.load();
    assertSettlementApprovalMatches(
        termsCell,
        executionAttemptCell,
        status,
        signedNumber,
        evidence.certificateHash,
        evidence.makerDeliveryCommitment,
        evidence.takerDeliveryCommitment,
    );
}

@inline
fun validateSettlementApprovalEnvelope(
    offerId: uint128,
    signedCell: Cell<CertifiedSettlementApprovalAuthorization>,
): (uint32, Cell<CertifiedSettlementApprovalEvidence>) {
    val signed = lazy signedCell.load();
    assert (
        signed.domain == CERTIFIED_SETTLEMENT_APPROVAL_DOMAIN &&
        signed.schemaVersion == CERTIFIED_SETTLEMENT_AUTHORIZATION_SCHEMA_VERSION
    ) throw CertifiedOfferEscrowErrors.WrongSettlementAuthorizationDomain;
    assert (
        signed.escrow == contract.getAddress() && signed.offerId == offerId
    ) throw CertifiedOfferEscrowErrors.InvalidSettlementAuthorization;
    assert (
        signed.issuedAt <= blockchain.now() && blockchain.now() < signed.validUntil &&
        signed.validUntil <= signed.issuedAt + MAX_CERTIFIED_SETTLEMENT_AUTHORIZATION_TTL
    ) throw CertifiedOfferEscrowErrors.SettlementAuthorizationExpired;
    return (signed.offerExecutionNumber, signed.evidence);
}

fun applySettlementApproval(
    original: CertifiedOfferEscrowStorage,
    offerExecutionNumber: uint32,
    certificateHash: uint256,
    makerCommitment: uint256?,
    takerCommitment: uint256?,
) {
    var storage = original;
    assertSettlementApprovalMatches(
        storage.terms,
        storage.executionAttempt,
        storage.status,
        offerExecutionNumber,
        certificateHash,
        makerCommitment,
        takerCommitment,
    );

    startSettlement(mutate storage);
}

@inline
fun assertSettlementApprovalMatches(
    termsCell: Cell<CertifiedOfferTerms>,
    executionAttemptCell: Cell<CertifiedOfferExecutionAttempt>?,
    status: CertifiedOfferEscrowStatus,
    offerExecutionNumber: uint32,
    certificateHash: uint256,
    makerCommitment: uint256?,
    takerCommitment: uint256?,
) {
    assert (
        status == CertifiedOfferEscrowStatus.AwaitingApproval
    ) throw CertifiedOfferEscrowErrors.NotAwaitingApproval;

    assert (executionAttemptCell != null) throw CertifiedOfferEscrowErrors.NotAwaitingApproval;
    val executionAttempt = lazy executionAttemptCell.load();
    val details = lazy executionAttempt.details.load();
    val terms = lazy termsCell.load();
    val policy = lazy terms.policy.load();
    assertSettlementApprovalEvidence(
        executionAttempt.number,
        executionAttempt.certificateHash,
        policy.makerDelivery,
        details.delivery,
        offerExecutionNumber,
        certificateHash,
        makerCommitment,
        takerCommitment,
    );
}

@inline
fun assertSettlementApprovalEvidence(
    actualNumber: uint32,
    actualCertificateHash: uint256,
    makerDelivery: Cell<DeliveryCommitment>?,
    takerDelivery: Cell<DeliveryCommitment>?,
    offerExecutionNumber: uint32,
    certificateHash: uint256,
    makerCommitment: uint256?,
    takerCommitment: uint256?,
) {
    assert (
        actualNumber == offerExecutionNumber && actualCertificateHash == certificateHash
    ) throw CertifiedOfferEscrowErrors.ExecutionAttemptMoved;
    assert (
        deliveryCommitmentMatches(makerDelivery, makerCommitment) &&
        deliveryCommitmentMatches(takerDelivery, takerCommitment)
    ) throw CertifiedOfferEscrowErrors.WrongDeliveryCommitment;
    // Certificate/publication expiry governs admission, never a funded provider handover.
    // A fresh signed decision remains required, including after a disputed delivery deadline.
}

fun startSettlement(mutate storage: CertifiedOfferEscrowStorage) {
    val terms = lazy storage.terms.load();
    val paymentCell = terms.payment;
    if (paymentCell != null && paymentCell.load().asset == PaymentAsset.Usdt) {
        startUsdtPayout(mutate storage);
        return;
    }
    finishSettlement(storage);
}

fun executionAttemptSettlementWallet(storage: CertifiedOfferEscrowStorage): address {
    val executionAttempt = storage.executionAttempt;
    assert (executionAttempt != null) throw CertifiedOfferEscrowErrors.InvalidTerms;
    return executionAttempt.load().details.load().takerSettlementWallet;
}

fun paymentRecipient(storage: CertifiedOfferEscrowStorage, payment: PaymentTerms): address {
    val parties = lazy storage.terms.load().parties.load();
    return payment.payer == OfferSide.Maker
        ? executionAttemptSettlementWallet(storage)
        : parties.makerSettlementWallet;
}

fun startUsdtPayout(mutate storage: CertifiedOfferEscrowStorage) {
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    var deposits = storage.deposits.load().usdt;
    assert (
        deposits.count > 0 && deposits.principal == payment.amount - payment.marketplaceFee &&
        deposits.fee == payment.marketplaceFee
    ) throw CertifiedOfferEscrowErrors.InvalidTerms;

    storage.status = CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation;
    storage.payoutQueryId = ((storage.offerExecutionNumber as uint64) << 32) + 1;
    storage.automaticRecoveryBudget = automaticUsdtSettlementRetryReserve(
        deposits.count,
        deposits.termsPayloadBits,
        deposits.termsPayloadCells,
    );
    deposits.assignRetryable(
        paymentRecipient(storage, payment),
        terms.config.load().feeTreasury,
        true,
    );
    storage.deposits.setUsdtDeposits(deposits);
    storage.save();
}

fun selectFundedUsdtHolding(
    sender: address,
    msgValue: coins,
    depositCell: Cell<UsdtDepositTerms>,
    attempt: uint64,
) {
    authenticateUsdtHolding(sender, depositCell, attempt);
    var storage = CertifiedOfferEscrowStorage.load();
    val deposit = depositCell.load();
    val isCommitting = storage.status == CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation ||
        storage.status == CertifiedOfferEscrowStatus.PayoutConfirmed ||
        storage.status == CertifiedOfferEscrowStatus.Settled;
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - msgValue),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    if (!isCommitting) {
        assert (
            storage.isClosed() ||
            (deposit.side == OfferSide.Taker && deposit.offerExecutionNumber <
                storage.offerExecutionNumber)
        ) throw UsdtDepositVaultErrors.DecisionPending;
        refundUsdtHolding(depositCell, attempt, storage.paymentRefundReason(), msgValue);
        return;
    }
    var deposits = storage.deposits.load().usdt;
    val isSelected = deposits.selectHolding(sender, depositCell, attempt);
    storage.deposits.setUsdtDeposits(deposits);
    // Persist the winner before any child can become beneficiary-owned. A lost parent, receipt,
    // or assignment message can only restore this same winner, never select a second principal.
    storage.save();
    if (!isSelected) {
        refundUsdtHolding(depositCell, attempt, RefundReason.InvalidPayment, msgValue);
        return;
    }
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    selectUsdtHolding(
        depositCell,
        attempt,
        usdtDepositBeneficiary(
            deposit,
            paymentRecipient(storage, payment),
            terms.config.load().feeTreasury,
        ),
        msgValue,
    );
}

fun confirmUsdtDeposit(
    sender: address,
    depositCell: Cell<UsdtDepositTerms>,
    beneficiary: address,
    holdingAttempt: uint64,
) {
    authenticateUsdtHolding(sender, depositCell, holdingAttempt);
    var storage = CertifiedOfferEscrowStorage.load();
    if (
        storage.status == CertifiedOfferEscrowStatus.PayoutConfirmed ||
        storage.status == CertifiedOfferEscrowStatus.Settled
    ) {
        return;
    }
    assert (
        storage.status == CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation
    ) throw CertifiedOfferEscrowErrors.WrongPayoutConfirmation;
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    assert (
        beneficiary ==
        usdtDepositBeneficiary(
            depositCell.load(),
            paymentRecipient(storage, payment),
            terms.config.load().feeTreasury,
        )
    ) throw CertifiedOfferEscrowErrors.WrongPayoutConfirmation;
    var deposits = storage.deposits.load().usdt;
    deposits.confirmAssignment(sender, depositCell, holdingAttempt);
    storage.deposits.setUsdtDeposits(deposits);
    if (deposits.assignedCount == deposits.count) {
        storage.status = CertifiedOfferEscrowStatus.PayoutConfirmed;
    }
    storage.save();
    if (storage.status == CertifiedOfferEscrowStatus.PayoutConfirmed) {
        scheduleSettlementResume(storage.payoutQueryId);
    }
}

fun resolveUsdtDeposit(msgValue: coins, depositCell: Cell<UsdtDepositTerms>) {
    val deposit = depositCell.load();
    assert (
        deposit.escrow == contract.getAddress() && deposit.amount > 0
    ) throw UsdtDepositVaultErrors.InvalidTerms;
    assert (msgValue >= USDT_DEPOSIT_RESOLVE_VALUE) throw CertifiedOfferEscrowErrors.NotEnoughValue;
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - msgValue),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    val storage = CertifiedOfferEscrowStorage.load();
    val deposits = storage.deposits.load().usdt;
    val isRecorded = deposits.entries.exists(usdtDepositInit(depositCell).calculateAddress());
    val isCommitting = storage.status == CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation ||
        storage.status == CertifiedOfferEscrowStatus.PayoutConfirmed ||
        storage.status == CertifiedOfferEscrowStatus.Settled;
    if (isCommitting && isRecorded) {
        val terms = storage.terms.load();
        val payment = terms.payment!.load();
        restoreUsdtDepositAssignment(
            depositCell,
            usdtDepositBeneficiary(
                deposit,
                paymentRecipient(storage, payment),
                terms.config.load().feeTreasury,
            ),
            deposits
                .entries
                .get(usdtDepositInit(depositCell).calculateAddress())
                .loadValue()
                .selectedAttempt,
            msgValue - grams("0.03"),
        );
        return;
    }
    // A future/current unrecorded deposit may still be accepted. Returning it now
    // would race that receipt. An old executionAttempt or terminal decision cannot revive it.
    assert (
        storage.isClosed() || isCommitting ||
        (deposit.side == OfferSide.Taker && deposit.offerExecutionNumber <
            storage.offerExecutionNumber)
    ) throw UsdtDepositVaultErrors.DecisionPending;
    refundUsdtDeposit(
        depositCell,
        TextComment { text: storage.paymentRefundReason().comment() }.toCell(),
    );
}

fun scheduleSettlementResume(queryId: uint64) {
    val resume = createMessage({
        bounce: BounceMode.NoBounce,
        dest: contract.getAddress(),
        value: grams("0"),
        body: ResumeCertifiedSettlement { queryId },
    });
    resume.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun finishSettlement(original: CertifiedOfferEscrowStorage) {
    var storage = original;
    val executionAttemptCell = storage.executionAttempt;
    assert (executionAttemptCell != null) throw CertifiedOfferEscrowErrors.InvalidTerms;
    val executionAttempt = lazy executionAttemptCell.load();
    val details = lazy executionAttempt.details.load();
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    val paymentCell = terms.payment;
    var deposits = storage.deposits.load();

    storage.status = CertifiedOfferEscrowStatus.Settled;
    storage.closedAt = blockchain.now();
    storage.automaticRecoveryBudget = automaticNftDeliveryRetryReserve(
        storage.maximumOnchainItemCount(),
    );
    deposits
        .nftDeliveries
        .deliverDepositedTo(
            storage.makerItems,
            details.takerSettlementWallet,
        );
    deposits.nftDeliveries.deliverDepositedTo(details.items, parties.makerSettlementWallet);
    storage.deposits = deposits.toCell();
    storage.save();

    var treasuryAmount = (terms.makerTonFee + details.takerTonFee) as coins;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        if (payment.asset == PaymentAsset.Ton) {
            sendCoins(
                paymentRecipient(storage, payment),
                payment.amount - payment.marketplaceFee,
                SETTLEMENT_PAYMENT_COMMENT,
            );
            treasuryAmount += payment.marketplaceFee;
        }
    }
    if (treasuryAmount > 0) {
        val config = lazy terms.config.load();
        sendCoins(
            config.feeTreasury,
            treasuryAmount,
            MARKETPLACE_FEE_COMMENT,
        );
    }
    returnChange(
        executionAttempt.excessRecipient == null
            ? (storage.reserveRefundRecipient == null
                ? parties.makerSettlementWallet
                : storage.reserveRefundRecipient)
            : executionAttempt.excessRecipient,
        paymentCell != null && paymentCell.load().asset == PaymentAsset.Usdt
            ? usdtRecoveryStorageReserve() + storage.automaticRecoveryBudget
            : MIN_TONS_FOR_STORAGE + storage.automaticRecoveryBudget,
    );
    commitContractDataAndActions();
}

// После approval storage уже однозначно задаёт стороны, получателя и сумму. Разрешение на
// permissionless retry не расширяет полномочия caller, зато убирает зависимость liveness от backend.
fun resumeSettlement(msgValue: coins) {
    var storage = CertifiedOfferEscrowStorage.load();
    if (storage.status == CertifiedOfferEscrowStatus.PayoutConfirmed) {
        finishSettlement(storage);
        return;
    }
    assert (
        storage.status == CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation
    ) throw CertifiedOfferEscrowErrors.SettlementNotResumable;
    var deposits = storage.deposits.load().usdt;
    val retryableCount = deposits.retryableAssignmentCount(false);
    assert (retryableCount > 0) throw CertifiedOfferEscrowErrors.SettlementNotResumable;
    val requiredValue = USDT_DEPOSIT_ASSIGN_VALUE * retryableCount +
        executionCost(GAS_ESCROW_SETTLEMENT, retryableCount);
    assert (msgValue >= requiredValue) throw CertifiedOfferEscrowErrors.NotEnoughValue;
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - msgValue),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    deposits.assignRetryable(
        paymentRecipient(storage, payment),
        terms.config.load().feeTreasury,
        false,
    );
    storage.deposits.setUsdtDeposits(deposits);
    storage.save();
}

@inline
fun CertifiedOfferEscrowStorage.assertMayExternallyResumeSettlement(
    self,
    expectedOfferId: uint128,
    expectedPayoutQueryId: uint64,
    vault: address,
) {
    assert (
        self.terms.load().offerId == expectedOfferId && self.payoutQueryId == expectedPayoutQueryId
    ) throw CertifiedOfferEscrowErrors.InvalidTerms;
    val deposit = self.deposits.load().usdt.entries.get(vault);
    assert (deposit.isFound) throw CertifiedOfferEscrowErrors.InvalidTerms;
    if (self.status == CertifiedOfferEscrowStatus.PayoutConfirmed) {
        assertExternalTransitionReserveForTerms(
            self.terms,
            self.deposits,
            self.automaticRecoveryBudget,
            self.executionAttempt,
            self.status,
            self.makerItems,
            false,
        );
        return;
    }
    assert (
        self.status == CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation
    ) throw CertifiedOfferEscrowErrors.SettlementNotResumable;
    val record = deposit.loadValue();
    assert (record.isRetryable(true)) throw CertifiedOfferEscrowErrors.AutomaticRecoveryUnavailable;
    assert (
        self.automaticRecoveryBudget >=
        automaticUsdtSettlementRetryReserve(1, record.termsPayloadBits, record.termsPayloadCells) &&
        contract.getOriginalBalance() >= self.automaticRecoveryBudget + self.externalPaidTonFees()
    ) throw CertifiedOfferEscrowErrors.AutomaticRecoveryUnavailable;
}

fun resumeSettlementFromReserve(original: CertifiedOfferEscrowStorage, vault: address) {
    var storage = original;
    if (storage.status == CertifiedOfferEscrowStatus.PayoutConfirmed) {
        finishSettlement(storage);
        return;
    }
    var deposits = storage.deposits.load().usdt;
    val record = deposits.entries.get(vault).loadValue();
    val retryBudget = automaticUsdtSettlementRetryReserve(
        1,
        record.termsPayloadBits,
        record.termsPayloadCells,
    );
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - storage.automaticRecoveryBudget),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    storage.automaticRecoveryBudget -= retryBudget;
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    deposits.assignOne(
        vault,
        paymentRecipient(storage, payment),
        terms.config.load().feeTreasury,
        true,
    );
    storage.deposits.setUsdtDeposits(deposits);
    storage.save();
}

fun releaseOfferExecutionAttempt(sender: address, expectedNumber: uint32) {
    val storage = lazy CertifiedOfferEscrowStorage.load();
    assert (
        storage.status == CertifiedOfferEscrowStatus.CollectingTaker ||
        storage.status == CertifiedOfferEscrowStatus.AwaitingApproval
    ) throw CertifiedOfferEscrowErrors.NotOpen;
    assert (
        expectedNumber == storage.offerExecutionNumber
    ) throw CertifiedOfferEscrowErrors.ExecutionAttemptMoved;

    val executionAttemptCell = storage.executionAttempt;
    assert (executionAttemptCell != null) throw CertifiedOfferEscrowErrors.NotOpen;
    val executionAttempt = lazy executionAttemptCell.load();
    assert (!isFinalizationLocked(storage)) throw CertifiedOfferEscrowErrors.FinalizationLocked;
    assert (blockchain.now() < storage.expiresAt) throw CertifiedOfferEscrowErrors.OfferExpired;
    if (blockchain.now() < executionAttempt.validUntil) {
        assert (
            executionAttempt.confirmedContributorWallets.exists(sender)
        ) throw CertifiedOfferEscrowErrors.NotAllowedToRelease;
    }
    assert (
        storage.offerExecutionNumber < 0xFFFFFFFF
    ) throw CertifiedOfferEscrowErrors.OfferExecutionNumberExhausted;

    releaseCurrentExecutionAttempt(storage);
}

@inline
fun CertifiedOfferEscrowStorage.assertMayExternallyReleaseExecution(
    self,
    expectedOfferId: uint128,
    expectedNumber: uint32,
) {
    assert (
        self.terms.load().offerId == expectedOfferId
    ) throw CertifiedOfferEscrowErrors.InvalidTerms;
    assert (
        self.status == CertifiedOfferEscrowStatus.CollectingTaker ||
        self.status == CertifiedOfferEscrowStatus.AwaitingApproval
    ) throw CertifiedOfferEscrowErrors.NotOpen;
    assert (
        expectedNumber == self.offerExecutionNumber
    ) throw CertifiedOfferEscrowErrors.ExecutionAttemptMoved;
    assert (!isFinalizationLocked(self)) throw CertifiedOfferEscrowErrors.FinalizationLocked;
    assert (blockchain.now() < self.expiresAt) throw CertifiedOfferEscrowErrors.OfferExpired;
    assert (
        self.offerExecutionNumber < 0xFFFFFFFF
    ) throw CertifiedOfferEscrowErrors.OfferExecutionNumberExhausted;

    val executionAttemptCell = self.executionAttempt;
    assert (executionAttemptCell != null) throw CertifiedOfferEscrowErrors.NotOpen;
    val executionAttempt = lazy executionAttemptCell.load();
    assert (
        blockchain.now() >= executionAttempt.validUntil
    ) throw CertifiedOfferEscrowErrors.NotAllowedToRelease;
}

fun releaseCurrentExecutionAttempt(original: CertifiedOfferEscrowStorage) {
    var storage = original;
    val executionAttemptCell = storage.executionAttempt;
    // Оба entrypoint доказывают наличие execution attempt до общего перехода.
    assert (executionAttemptCell != null) throw CertifiedOfferEscrowErrors.NotOpen;
    val executionAttempt = lazy executionAttemptCell.load();
    val details = lazy executionAttempt.details.load();
    reopenAfterRejectedExecutionAttempt(
        mutate storage,
        executionAttempt,
        details,
        RefundReason.ExecutionExpired,
    );
}

fun applySignedExecutionRejection(
    signature: bits512,
    signedCell: Cell<CertifiedExecutionRejectionAuthorization>,
) {
    val storage = lazy CertifiedOfferEscrowStorage.load();
    storage.assertSignedExecutionRejection(signature, signedCell);

    applyVerifiedExecutionRejection(storage, signedCell);
}

fun applyVerifiedExecutionRejection(
    storage: CertifiedOfferEscrowStorage,
    signedCell: Cell<CertifiedExecutionRejectionAuthorization>,
) {
    val signed = lazy signedCell.load();

    applyExecutionRejection(
        storage,
        signed.offerExecutionNumber,
        signed.certificateHash,
    );
}

fun applySignedExecutionRejectionAndClose(
    signature: bits512,
    signedCell: Cell<CertifiedExecutionRejectionAndCloseAuthorization>,
) {
    val storage = lazy CertifiedOfferEscrowStorage.load();
    storage.assertSignedExecutionRejectionAndClose(signature, signedCell);

    applyVerifiedExecutionRejectionAndClose(storage, signedCell);
}

fun applyVerifiedExecutionRejectionAndClose(
    storage: CertifiedOfferEscrowStorage,
    signedCell: Cell<CertifiedExecutionRejectionAndCloseAuthorization>,
) {
    val signed = lazy signedCell.load();
    storage.assertExecutionRejectionAttemptMatches(
        signed.offerExecutionNumber,
        signed.certificateHash,
    );
    closeOffer(storage, CertifiedOfferEscrowStatus.Cancelled);
}

@inline
fun CertifiedOfferEscrowStorage.assertSignedExecutionRejectionAndClose(
    self,
    signature: bits512,
    signedCell: Cell<CertifiedExecutionRejectionAndCloseAuthorization>,
) {
    self.assertExecutionRejectionAndCloseAuthorizationMatches(signedCell);
    assert (
        isSignatureValid(signedCell.hash(), signature as slice, self.certifierPublicKey)
    ) throw CertifiedOfferEscrowErrors.InvalidSettlementAuthorization;
}

@inline
fun CertifiedOfferEscrowStorage.assertExternallyRelayedExecutionRejectionAndClose(
    self,
    signature: bits512,
    signedCell: Cell<CertifiedExecutionRejectionAndCloseAuthorization>,
) {
    self.assertSignedExecutionRejectionAndClose(signature, signedCell);
}

@inline
fun CertifiedOfferEscrowStorage.assertExecutionRejectionAndCloseAuthorizationMatches(
    self,
    signedCell: Cell<CertifiedExecutionRejectionAndCloseAuthorization>,
) {
    val terms = lazy self.terms.load();
    val signed = lazy signedCell.load();
    assert (
        signed.domain == CERTIFIED_EXECUTION_REJECTION_AND_CLOSE_DOMAIN &&
        signed.schemaVersion == CERTIFIED_SETTLEMENT_AUTHORIZATION_SCHEMA_VERSION
    ) throw CertifiedOfferEscrowErrors.WrongSettlementAuthorizationDomain;
    assert (
        signed.escrow == contract.getAddress() && signed.offerId == terms.offerId
    ) throw CertifiedOfferEscrowErrors.InvalidSettlementAuthorization;
    assert (
        signed.issuedAt <= blockchain.now() && blockchain.now() < signed.validUntil &&
        signed.validUntil <= signed.issuedAt + MAX_CERTIFIED_SETTLEMENT_AUTHORIZATION_TTL
    ) throw CertifiedOfferEscrowErrors.SettlementAuthorizationExpired;
    self.assertExecutionRejectionAttemptMatches(
        signed.offerExecutionNumber,
        signed.certificateHash,
    );
}

@inline
fun CertifiedOfferEscrowStorage.assertSignedExecutionRejection(
    self,
    signature: bits512,
    signedCell: Cell<CertifiedExecutionRejectionAuthorization>,
) {
    self.assertExecutionRejectionAuthorizationMatches(signedCell);
    assert (
        isSignatureValid(signedCell.hash(), signature as slice, self.certifierPublicKey)
    ) throw CertifiedOfferEscrowErrors.InvalidSettlementAuthorization;
}

@inline
fun CertifiedOfferEscrowStorage.assertExternallyRelayedExecutionRejection(
    self,
    signature: bits512,
    signedCell: Cell<CertifiedExecutionRejectionAuthorization>,
) {
    self.assertSignedExecutionRejection(signature, signedCell);
}

@inline
fun CertifiedOfferEscrowStorage.assertExecutionRejectionAuthorizationMatches(
    self,
    signedCell: Cell<CertifiedExecutionRejectionAuthorization>,
) {
    val terms = lazy self.terms.load();
    val signed = lazy signedCell.load();
    assert (
        signed.domain == CERTIFIED_EXECUTION_REJECTION_DOMAIN &&
        signed.schemaVersion == CERTIFIED_SETTLEMENT_AUTHORIZATION_SCHEMA_VERSION
    ) throw CertifiedOfferEscrowErrors.WrongSettlementAuthorizationDomain;
    assert (
        signed.escrow == contract.getAddress() && signed.offerId == terms.offerId
    ) throw CertifiedOfferEscrowErrors.InvalidSettlementAuthorization;
    assert (
        signed.issuedAt <= blockchain.now() && blockchain.now() < signed.validUntil &&
        signed.validUntil <= signed.issuedAt + MAX_CERTIFIED_SETTLEMENT_AUTHORIZATION_TTL
    ) throw CertifiedOfferEscrowErrors.SettlementAuthorizationExpired;
    self.assertExecutionRejectionMatches(
        signed.offerExecutionNumber,
        signed.certificateHash,
    );
}

fun applyExecutionRejection(
    original: CertifiedOfferEscrowStorage,
    expectedNumber: uint32,
    expectedCertificateHash: uint256,
) {
    var storage = original;
    storage.assertExecutionRejectionMatches(expectedNumber, expectedCertificateHash);

    val executionAttempt = lazy storage.executionAttempt!.load();
    val details = lazy executionAttempt.details.load();
    reopenAfterRejectedExecutionAttempt(
        mutate storage,
        executionAttempt,
        details,
        RefundReason.ExecutionRejected,
    );
}

@inline
fun CertifiedOfferEscrowStorage.assertExecutionRejectionMatches(
    self,
    expectedNumber: uint32,
    expectedCertificateHash: uint256,
) {
    self.assertExecutionRejectionAttemptMatches(expectedNumber, expectedCertificateHash);
    assert (
        self.offerExecutionNumber < 0xFFFFFFFF
    ) throw CertifiedOfferEscrowErrors.OfferExecutionNumberExhausted;
}

@inline
fun CertifiedOfferEscrowStorage.assertExecutionRejectionAttemptMatches(
    self,
    expectedNumber: uint32,
    expectedCertificateHash: uint256,
) {
    assert (isFinalizationLocked(self)) throw CertifiedOfferEscrowErrors.NotAwaitingApproval;

    val executionAttemptCell = self.executionAttempt;
    assert (executionAttemptCell != null) throw CertifiedOfferEscrowErrors.NotAwaitingApproval;
    val executionAttempt = lazy executionAttemptCell.load();
    assert (
        executionAttempt.number == expectedNumber &&
        executionAttempt.certificateHash == expectedCertificateHash
    ) throw CertifiedOfferEscrowErrors.ExecutionAttemptMoved;
}

fun reopenAfterRejectedExecutionAttempt(
    mutate storage: CertifiedOfferEscrowStorage,
    executionAttempt: CertifiedOfferExecutionAttempt,
    details: CertifiedExecutionAttemptDetails,
    reason: RefundReason,
) {
    assert (
        storage.offerExecutionNumber < 0xFFFFFFFF
    ) throw CertifiedOfferEscrowErrors.OfferExecutionNumberExhausted;

    val releasedStorage = storage;
    val reserveRefundRecipient = storage.reserveRefundRecipient;
    var deposits = storage.deposits.load();
    deposits.nftDeliveries.returnDeposits(details.items, reason);
    storage.deposits = deposits.toCell();
    storage.status = CertifiedOfferEscrowStatus.Open;
    storage.offerExecutionNumber += 1;
    storage.executionAttempt = null;
    val makerFundedReserve = reserveRefundRecipient != null &&
        storage.terms.load().parties.load().makerWallets.exists(reserveRefundRecipient);
    if (!makerFundedReserve) {
        storage.reserveRefundRecipient = null;
    }
    val payment = storage.terms.load().payment;
    if (payment != null && payment.load().payer == OfferSide.Taker) {
        storage.deposits.setUsdtDeposits(UsdtDeposits {});
    }
    storage.save();
    var nativeRefunds: MoneyContributions = [];
    collectExecutionAttemptPaymentRefunds(
        releasedStorage,
        executionAttempt,
        mutate nativeRefunds,
        reason,
    );
    refundNativeContributions(nativeRefunds, reason);
    if (
        !makerFundedReserve &&
        (executionAttempt.excessRecipient != null || reserveRefundRecipient != null)
    ) {
        returnChange(
            executionAttempt.excessRecipient == null
                ? reserveRefundRecipient!
                : executionAttempt.excessRecipient,
        );
    }
}

fun collectExecutionAttemptPaymentRefunds(
    storage: CertifiedOfferEscrowStorage,
    executionAttempt: CertifiedOfferExecutionAttempt,
    mutate nativeRefunds: MoneyContributions,
    reason: RefundReason,
) {
    val terms = lazy storage.terms.load();
    val paymentCell = terms.payment;
    if (paymentCell != null && executionAttempt.deposits.total > 0) {
        val payment = lazy paymentCell.load();
        if (payment.payer == OfferSide.Taker) {
            if (payment.asset == PaymentAsset.Usdt) {
                storage.deposits.load().usdt.refund(reason);
            } else {
                nativeRefunds.addAll(executionAttempt.deposits.contributions);
            }
        }
    }
    if (executionAttempt.feePayer != null && executionAttempt.details.load().takerTonFee > 0) {
        nativeRefunds.add(executionAttempt.feePayer, executionAttempt.details.load().takerTonFee);
    }
}

fun cancelOffer(sender: address) {
    val storage = lazy CertifiedOfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    assert (parties.makerWallets.exists(sender)) throw CertifiedOfferEscrowErrors.NotMaker;
    storage.assertMayCancel();
    closeOffer(storage, CertifiedOfferEscrowStatus.Cancelled);
}

@inline
fun CertifiedOfferEscrowStorage.assertMakerCancellation(
    self,
    signature: bits512,
    signed: Cell<TonConnectMakerCancellation>,
) {
    assertMakerCancellationForTerms(self.terms, signature, signed);
}

@inline
fun assertMakerCancellationForTerms(
    termsCell: Cell<CertifiedOfferTerms>,
    signature: bits512,
    signed: Cell<TonConnectMakerCancellation>,
) {
    val terms = lazy termsCell.load();
    assertMakerCancellationForParties(terms.offerId, terms.parties, signature, signed);
}

@inline
fun assertMakerCancellationForParties(
    offerId: uint128,
    partiesCell: Cell<OfferEscrowParties>,
    signature: bits512,
    signed: Cell<TonConnectMakerCancellation>,
) {
    val parties = lazy partiesCell.load();
    val policy = parties.makerCancellation;
    assert (policy != null) throw CertifiedOfferEscrowErrors.MakerCancellationUnavailable;
    assert (
        policy.load().accepts(signature, signed, offerId)
    ) throw CertifiedOfferEscrowErrors.InvalidMakerCancellation;
}

@inline
fun assertCertifiedCustodiedCancellation(
    termsCell: Cell<CertifiedOfferTerms>,
    certifierPublicKey: uint256,
    signature: bits512,
    signedCell: Cell<CertifiedCustodiedCancellationAuthorization>,
): (uint16, int) {
    val terms = lazy termsCell.load();
    val policy = lazy terms.policy.load();
    val parties = lazy terms.parties.load();
    val paymentCell = terms.payment;
    var paymentAsset = -1;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        assert (
            payment.payer != OfferSide.Maker
        ) throw CertifiedOfferEscrowErrors.MakerCancellationUnavailable;
        paymentAsset = payment.asset as int;
    }
    assert (
        policy.custodiedCancellationByCertifier && parties.makerWallets.isEmpty() &&
        parties.makerCancellation == null &&
        terms.makerItemCount == deliveryCount(policy.makerDelivery) &&
        terms.makerTonFee == 0
    ) throw CertifiedOfferEscrowErrors.MakerCancellationUnavailable;
    val signed = lazy signedCell.load();
    assert (
        signed.domain == CERTIFIED_CUSTODIED_CANCELLATION_DOMAIN &&
        signed.schemaVersion == CERTIFIED_SETTLEMENT_AUTHORIZATION_SCHEMA_VERSION &&
        signed.escrow == contract.getAddress() &&
        signed.offerId == terms.offerId &&
        signed.issuedAt <= blockchain.now() &&
        blockchain.now() <
        signed.validUntil &&
        signed.validUntil <= signed.issuedAt + MAX_CERTIFIED_SETTLEMENT_AUTHORIZATION_TTL &&
        isSignatureValid(signedCell.hash(), signature as slice, certifierPublicKey)
    ) throw CertifiedOfferEscrowErrors.InvalidMakerCancellation;
    return (terms.takerItemCount, paymentAsset);
}

@inline
fun CertifiedOfferEscrowStorage.assertMayCancel(self) {
    assertMayCancelStatus(self.status);
}

@inline
fun assertMayCancelStatus(status: CertifiedOfferEscrowStatus) {
    if ((status as int) <= (CertifiedOfferEscrowStatus.CollectingTaker as int)) {
        return;
    }
    assert (
        status != CertifiedOfferEscrowStatus.Settled &&
        status != CertifiedOfferEscrowStatus.Cancelled &&
        status != CertifiedOfferEscrowStatus.Expired
    ) throw CertifiedOfferEscrowErrors.AlreadyClosed;
    assert (!status.isFinalizationLocked()) throw CertifiedOfferEscrowErrors.FinalizationLocked;
    assert (
        status != CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation &&
        status != CertifiedOfferEscrowStatus.PayoutFailed &&
        status != CertifiedOfferEscrowStatus.PayoutConfirmed
    ) throw CertifiedOfferEscrowErrors.SettlementInProgress;
}

fun expireOffer() {
    val storage = lazy CertifiedOfferEscrowStorage.load();
    storage.assertMayExpire();
    closeOffer(storage, CertifiedOfferEscrowStatus.Expired);
}

@inline
fun CertifiedOfferEscrowStorage.assertMayExpire(self) {
    assert (!self.isClosed()) throw CertifiedOfferEscrowErrors.AlreadyClosed;
    assert (blockchain.now() >= self.expiresAt) throw CertifiedOfferEscrowErrors.OfferNotExpired;
    assert (!isFinalizationLocked(self)) throw CertifiedOfferEscrowErrors.FinalizationLocked;
    assert (
        self.status != CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation &&
        self.status != CertifiedOfferEscrowStatus.PayoutFailed &&
        self.status != CertifiedOfferEscrowStatus.PayoutConfirmed
    ) throw CertifiedOfferEscrowErrors.SettlementInProgress;
}

@inline
fun CertifiedOfferEscrowStorage.assertMayExternallyExpire(
    self,
    expectedOfferId: uint128,
    expectedExpiresAt: uint32,
) {
    assert (
        self.terms.load().offerId == expectedOfferId && self.expiresAt == expectedExpiresAt
    ) throw CertifiedOfferEscrowErrors.InvalidTerms;
    self.assertMayExpire();
}

@inline
fun isFinalizationLocked(storage: CertifiedOfferEscrowStorage): bool {
    // AwaitingApproval is entered only after all on-chain obligations are funded and either
    // provider delivery or certifier gating requires a decision. No wall-clock timeout can
    // distinguish an undelivered channel from ownership lost to an unexpected recipient.
    return storage.status.isFinalizationLocked();
}

fun closeOffer(original: CertifiedOfferEscrowStorage, closedAs: CertifiedOfferEscrowStatus) {
    var storage = original;
    val reason = closedAs == CertifiedOfferEscrowStatus.Expired
        ? RefundReason.OfferExpired
        : RefundReason.OfferCancelled;
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    val paymentCell = terms.payment;
    val executionAttemptCell = storage.executionAttempt;
    var deposits = storage.deposits.load();

    storage.status = closedAs;
    storage.closedAt = blockchain.now();
    var deliveryCount = deposits.nftDeliveries.returnEachToItsDepositor(storage.makerItems, reason);
    if (executionAttemptCell != null) {
        deliveryCount += deposits
            .nftDeliveries
            .returnEachToItsDepositor(executionAttemptCell.load().details.load().items, reason);
    }
    storage.automaticRecoveryBudget = automaticNftDeliveryRetryReserve(
        deliveryCount,
    );
    storage.deposits = deposits.toCell();
    storage.save();

    var nativeRefunds: MoneyContributions = [];
    val makerFeePayer = storage.deposits.load().makerFeePayer;
    if (makerFeePayer != null && terms.makerTonFee > 0) {
        nativeRefunds.add(makerFeePayer, terms.makerTonFee);
    }
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        if (payment.payer == OfferSide.Maker && storage.deposits.load().maker.total > 0) {
            if (payment.asset == PaymentAsset.Usdt) {
                storage.deposits.load().usdt.refund(reason);
            } else {
                nativeRefunds.addAll(storage.deposits.load().maker.contributions);
            }
        }
    }
    if (executionAttemptCell != null) {
        val executionAttempt = lazy executionAttemptCell.load();
        collectExecutionAttemptPaymentRefunds(
            storage,
            executionAttempt,
            mutate nativeRefunds,
            reason,
        );
    }
    refundNativeContributions(nativeRefunds, reason);
    var excessRecipient = storage.reserveRefundRecipient == null
        ? parties.makerSettlementWallet
        : storage.reserveRefundRecipient;
    if (executionAttemptCell != null) {
        val executionAttempt = lazy executionAttemptCell.load();
        if (executionAttempt.excessRecipient != null) {
            excessRecipient = executionAttempt.excessRecipient;
        }
    }
    returnChange(
        excessRecipient,
        closedEscrowStorageReserve(storage) + storage.automaticRecoveryBudget,
    );
}

fun refundContributions(
    asset: PaymentAsset,
    contributions: MoneyContributions,
    reason: RefundReason,
) {
    if (asset == PaymentAsset.Ton) {
        refundNativeContributions(contributions, reason);
        return;
    }
    var contribution = contributions.findFirst();
    while (contribution.isFound) {
        val source = contribution.getKey();
        val amount = contribution.loadValue();
        sendJetton(
            deriveUsdtWalletFor(contract.getAddress()),
            source,
            amount,
            source,
            reason.comment(),
        );
        contribution = contributions.iterateNext(contribution);
    }
}

fun refundNativeContributions(contributions: MoneyContributions, reason: RefundReason) {
    val comment = reason.comment();
    var contribution = contributions.findFirst();
    while (contribution.isFound) {
        sendCoins(contribution.getKey(), contribution.loadValue(), comment);
        contribution = contributions.iterateNext(contribution);
    }
}

fun depositedBy(items: ItemDeposits, nft: address): address? {
    val entry = items.get(nft);
    if (!entry.isFound) {
        return null;
    }
    val deposit = entry.loadValue();
    return deposit.depositor != null ? deposit.depositor : deposit.refundRecipient;
}

fun nftRecoveryRecipient(storage: CertifiedOfferEscrowStorage, nft: address): address? {
    val makerDepositor = depositedBy(storage.makerItems, nft);
    if (makerDepositor != null) {
        if (!storage.isClosed()) {
            return null;
        }
        return storage.status == CertifiedOfferEscrowStatus.Settled
            ? executionAttemptSettlementWallet(storage)
            : makerDepositor;
    }

    val executionAttemptCell = storage.executionAttempt;
    if (executionAttemptCell == null) {
        val refund = storage.deposits.load().nftDeliveries.get(nft);
        return refund.isFound ? refund.loadValue().recipient : null;
    }
    val takerDepositor = depositedBy(executionAttemptCell.load().details.load().items, nft);
    if (takerDepositor != null) {
        if (!storage.isClosed()) {
            return null;
        }
        val parties = lazy storage.terms.load().parties.load();
        return storage.status == CertifiedOfferEscrowStatus.Settled
            ? parties.makerSettlementWallet
            : takerDepositor;
    }
    val refund = storage.deposits.load().nftDeliveries.get(nft);
    return refund.isFound ? refund.loadValue().recipient : null;
}

fun retryNftDelivery(sender: address, msgValue: coins, nft: address) {
    var storage = lazy CertifiedOfferEscrowStorage.load();
    var deposits = storage.deposits.load();
    val deliveryEntry = deposits.nftDeliveries.get(nft);
    var delivery: NftDelivery;
    if (deliveryEntry.isFound) {
        delivery = deliveryEntry.loadValue();
        assert (
            delivery.status == NftDeliveryStatus.Failed
        ) throw CertifiedOfferEscrowErrors.NftDeliveryPending;
    } else {
        // Удалённая после доставки запись не отменяет immutable NFT/refund commitment.
        val recipient = nftRecoveryRecipient(storage, nft);
        assert (recipient != null) throw CertifiedOfferEscrowErrors.NotRecoverableNft;
        delivery = {
            recipient,
            queryId: 0,
            comment: storage.status == CertifiedOfferEscrowStatus.Settled
                ? null
                : TextComment { text: storage.paymentRefundReason().comment() }.toCell(),
        };
    }
    assert (msgValue >= requiredNftRetryValue()) throw CertifiedOfferEscrowErrors.NotEnoughValue;
    delivery.queryId = blockchain.logicalTime() as uint64;
    delivery.sponsor = sender;
    delivery.hasReceipt = false;
    delivery.status = NftDeliveryStatus.Pending;
    deposits.nftDeliveries.set(nft, delivery);
    storage.deposits = deposits.toCell();
    storage.save();
    sendFundedNftRetry(
        nft,
        delivery.recipient,
        sender,
        msgValue,
        contract.getAddress(),
        delivery.comment,
    );
}

@inline
fun CertifiedOfferEscrowStorage.assertMayExternallyRetryNftDelivery(
    self,
    expectedOfferId: uint128,
    nft: address,
    expectedDeliveryQueryId: uint64,
) {
    assert (
        self.terms.load().offerId == expectedOfferId
    ) throw CertifiedOfferEscrowErrors.InvalidTerms;
    assert (self.isClosed()) throw CertifiedOfferEscrowErrors.NotClosed;
    val delivery = self.deposits.load().nftDeliveries.get(nft);
    assert (delivery.isFound) throw CertifiedOfferEscrowErrors.NotRecoverableNft;
    val pending = delivery.loadValue();
    assert (
        pending.queryId == expectedDeliveryQueryId && pending.status == NftDeliveryStatus.Failed &&
        !pending.hasReceipt &&
        pending.automaticAttempts <
        MAX_AUTOMATIC_NFT_DELIVERY_ATTEMPTS
    ) throw CertifiedOfferEscrowErrors.AutomaticRecoveryUnavailable;
    val retryBudget = requiredNftRetryValue();
    assert (
        self.automaticRecoveryBudget >= retryBudget &&
        contract.getOriginalBalance() >= self.automaticRecoveryBudget + self.externalPaidTonFees()
    ) throw CertifiedOfferEscrowErrors.AutomaticRecoveryUnavailable;
}

fun retryNftDeliveryFromReserve(original: CertifiedOfferEscrowStorage, nft: address) {
    var storage = original;
    val retryBudget = requiredNftRetryValue();
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - storage.automaticRecoveryBudget),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    var deposits = storage.deposits.load();
    var delivery = deposits.nftDeliveries.get(nft).loadValue();
    storage.automaticRecoveryBudget -= retryBudget;
    delivery.queryId = blockchain.logicalTime() as uint64;
    delivery.sponsor = null;
    delivery.hasReceipt = false;
    delivery.automaticAttempts += 1;
    delivery.status = NftDeliveryStatus.Pending;
    deposits.nftDeliveries.set(nft, delivery);
    storage.deposits = deposits.toCell();
    storage.save();
    sendNft(nft, delivery.recipient, contract.getAddress(), delivery.comment);
}

fun confirmNftTransfer(nft: address, queryId: uint64) {
    var storage = CertifiedOfferEscrowStorage.load();
    var deposits = storage.deposits.load();
    val refund = deposits.nftDeliveries.get(nft);
    if (!refund.isFound || queryId == 0 || refund.loadValue().queryId != queryId) {
        return;
    }
    var pending = refund.loadValue();
    pending.hasReceipt = true;
    deposits.nftDeliveries.set(nft, pending);
    storage.deposits = deposits.toCell();
    storage.save();
    requestNftDeliveryFence(nft, queryId);
}

fun finishNftDeliveryFence(nft: address, queryId: uint64) {
    var storage = CertifiedOfferEscrowStorage.load();
    var deposits = storage.deposits.load();
    val refund = deposits.nftDeliveries.get(nft);
    if (!refund.isFound || queryId == 0 || refund.loadValue().queryId != queryId) {
        return;
    }
    var pending = refund.loadValue();
    val releaseUnusedAutomaticBudget = pending.hasReceipt && pending.sponsor == null;
    if (pending.hasReceipt) {
        deposits.nftDeliveries.delete(nft);
        // Автоматический retry уже списал budget до отправки: повторно его не уменьшаем.
        if (releaseUnusedAutomaticBudget && pending.automaticAttempts == 0) {
            storage.automaticRecoveryBudget = max(
                0,
                storage.automaticRecoveryBudget - requiredNftRetryValue(),
            );
        }
    } else {
        pending.queryId = 0;
        deposits.nftDeliveries.set(nft, pending);
    }
    storage.deposits = deposits.toCell();
    storage.save();
    if (releaseUnusedAutomaticBudget) {
        returnChange(
            certifiedRecoveryChangeRecipient(storage),
            closedEscrowStorageReserve(storage) + storage.automaticRecoveryBudget,
        );
    } else if (pending.sponsor != null) {
        refundTon(pending.sponsor, GAS_REFUND_COMMENT);
    }
}

fun certifiedRecoveryChangeRecipient(storage: CertifiedOfferEscrowStorage): address {
    val executionAttempt = storage.executionAttempt;
    if (executionAttempt != null && executionAttempt.load().excessRecipient != null) {
        return executionAttempt.load().excessRecipient!;
    }
    return storage.reserveChangeRecipient();
}

fun closedEscrowStorageReserve(storage: CertifiedOfferEscrowStorage): coins {
    val payment = storage.terms.load().payment;
    return payment != null && payment.load().asset == PaymentAsset.Usdt
        ? usdtRecoveryStorageReserve()
        : MIN_TONS_FOR_STORAGE;
}

fun failNftDelivery(nft: address, queryId: uint64) {
    var storage = CertifiedOfferEscrowStorage.load();
    var deposits = storage.deposits.load();
    val delivery = deposits.nftDeliveries.get(nft);
    if (!delivery.isFound || queryId == 0 || delivery.loadValue().queryId != queryId) {
        return;
    }
    var failed = delivery.loadValue();
    failed.hasReceipt = false;
    failed.status = NftDeliveryStatus.Failed;
    deposits.nftDeliveries.set(nft, failed);
    storage.deposits = deposits.toCell();
    storage.save();
    if (failed.sponsor != null) {
        refundTon(failed.sponsor, GAS_REFUND_COMMENT);
    } else if (failed.automaticAttempts > 0) {
        // Bounce вернул неистраченный transfer value. Остальным NFT сохраняем их retry budget,
        // а остаток завершённой автоматической попытки возвращаем плательщику резерва.
        returnChange(
            certifiedRecoveryChangeRecipient(storage),
            closedEscrowStorageReserve(storage) + storage.automaticRecoveryBudget,
        );
    }
}

fun confirmNftDeliveryReceipt(sender: address, nft: address) {
    var storage = CertifiedOfferEscrowStorage.load();
    var deposits = storage.deposits.load();
    val refund = deposits.nftDeliveries.get(nft);
    assert (refund.isFound) throw CertifiedOfferEscrowErrors.NotRecoverableNft;
    assert (
        sender == refund.loadValue().recipient
    ) throw CertifiedOfferEscrowErrors.NotNftDeliveryRecipient;
    assert (
        refund.loadValue().status == NftDeliveryStatus.Failed
    ) throw CertifiedOfferEscrowErrors.NftDeliveryPending;
    deposits.nftDeliveries.delete(nft);
    storage.deposits = deposits.toCell();
    storage.save();
    refundTon(sender, GAS_REFUND_COMMENT);
}

fun recoverUnexpectedNft(
    sender: address,
    msgValue: coins,
    recoveryId: uint64,
    nft: address,
    recipient: address,
) {
    var storage = lazy CertifiedOfferEscrowStorage.load();
    val config = lazy storage.terms.load().config.load();
    assert (
        sender == config.unexpectedNftRecoveryAuthority
    ) throw CertifiedOfferEscrowErrors.NotUnexpectedNftRecoveryAuthority;
    assert (storage.isClosed()) throw CertifiedOfferEscrowErrors.NotClosed;
    assert (
        storage.closedAt > 0 && blockchain.now() >= storage.closedAt + UNEXPECTED_NFT_RECOVERY_DELAY
    ) throw CertifiedOfferEscrowErrors.UnexpectedNftRecoveryLocked;
    assert (
        recoveryId > storage.lastUnexpectedNftRecoveryId
    ) throw CertifiedOfferEscrowErrors.RecoveryReplay;
    assert (msgValue >= requiredNftRetryValue()) throw CertifiedOfferEscrowErrors.NotEnoughValue;

    val policy = storage.terms.load().policy.load();
    var isRecorded = storage.makerItems.exists(nft) || policy.fixedTakerItems.exists(nft) ||
        storage.deposits.load().nftDeliveries.exists(nft);
    val executionAttemptCell = storage.executionAttempt;
    if (!isRecorded && executionAttemptCell != null) {
        isRecorded = executionAttemptCell.load().details.load().items.exists(nft);
    }
    assert (!isRecorded) throw CertifiedOfferEscrowErrors.NftAlreadyRecorded;

    var deposits = storage.deposits.load();
    deposits
        .nftDeliveries
        .set(
            nft,
            {
                recipient,
                comment: TextComment { text: NFT_RECOVERY_COMMENT }.toCell(),
                queryId: blockchain.logicalTime() as uint64,
                sponsor: sender,
            },
        );
    storage.deposits = deposits.toCell();
    storage.lastUnexpectedNftRecoveryId = recoveryId;
    storage.save();
    sendFundedNftRetry(
        nft,
        recipient,
        sender,
        msgValue,
        contract.getAddress(),
        TextComment { text: NFT_RECOVERY_COMMENT }.toCell(),
    );
}

fun onBouncedMessage(in: InMessageBounced) {
    val originalBody = bouncedOriginalBody(in.bouncedBody);
    if (originalBody == null) {
        return;
    }
    var body = originalBody;
    if (body.remainingBitsCount() < 32) {
        return;
    }
    val opcode = body.loadUint(32);
    if (opcode == ASSIGN_USDT_DEPOSIT_OP) {
        failUsdtDepositAssignment(in.senderAddress);
        return;
    }
    if (opcode != NFT_TRANSFER_OP || body.remainingBitsCount() < 64) {
        return;
    }
    val queryId = body.loadUint(64);
    val storage = CertifiedOfferEscrowStorage.load();
    val refund = storage.deposits.load().nftDeliveries.get(in.senderAddress);
    if (!refund.isFound || queryId == 0 || refund.loadValue().queryId != queryId) {
        return;
    }
    failNftDelivery(in.senderAddress, queryId);
}

fun failUsdtDepositAssignment(vault: address) {
    var storage = CertifiedOfferEscrowStorage.load();
    if (storage.status != CertifiedOfferEscrowStatus.AwaitingPayoutConfirmation) {
        return;
    }
    var deposits = storage.deposits.load().usdt;
    deposits.failAssignment(vault);
    storage.deposits.setUsdtDeposits(deposits);
    storage.save();
}

get fun status(): CertifiedOfferEscrowStatus {
    return CertifiedOfferEscrowStorage.load().status;
}

get fun nft_deliveries(): NftDeliveries {
    return CertifiedOfferEscrowStorage.load().deposits.load().nftDeliveries;
}

get fun nft_recovery_recipient(nft: address): address? {
    return nftRecoveryRecipient(CertifiedOfferEscrowStorage.load(), nft);
}

get fun offer_id(): int {
    return CertifiedOfferEscrowStorage.load().terms.load().offerId;
}

get fun offer_execution_number(): int {
    return CertifiedOfferEscrowStorage.load().offerExecutionNumber;
}

get fun execution_attempt(): CertifiedOfferExecutionAttempt? {
    val executionAttempt = CertifiedOfferEscrowStorage.load().executionAttempt;
    return executionAttempt == null ? null : executionAttempt.load();
}

get fun certifier_public_key(): uint256 {
    return CertifiedOfferEscrowStorage.load().certifierPublicKey;
}

get fun maker_items(): ItemDeposits {
    return CertifiedOfferEscrowStorage.load().makerItems;
}

get fun required_maker_balance(): coins {
    return CertifiedOfferEscrowStorage.load().requiredSettlementBalance(false);
}

get fun usdt_wallet(): address {
    return deriveUsdtWalletFor(contract.getAddress());
}

get fun usdt_deposits(): UsdtDeposits {
    return CertifiedOfferEscrowStorage.load().deposits.load().usdt;
}

get fun usdt_recovery_storage_reserve(): coins {
    return usdtRecoveryStorageReserve();
}

// Paid side fees are still obligations while USDT payout is pending, never automatic retry gas.
@inline
fun CertifiedOfferEscrowStorage.externalPaidTonFees(self): coins {
    if (self.isClosed()) {
        return grams("0");
    }
    val terms = lazy self.terms.load();
    val deposits = lazy self.deposits.load();
    val makerFee = terms.makerTonFee == 0 || deposits.makerFeePayer == null
        ? (grams("0") as coins)
        : terms.makerTonFee;
    val attempt = self.executionAttempt;
    val takerFee = terms.takerTonFee == 0 || attempt == null || attempt.load().feePayer == null
        ? (grams("0") as coins)
        : attempt.load().details.load().takerTonFee;
    return makerFee + takerFee;
}

// Conservative O(1) bound includes both returned and retained maker obligations. An underfunded
// partial lot uses the caller-funded internal path; no principal/fee pays for an external failure.
@inline
fun assertExternalTransitionReserveForTerms(
    termsCell: Cell<CertifiedOfferTerms>,
    depositsCell: Cell<OfferEscrowDeposits>,
    automaticBudget: coins,
    executionAttemptCell: Cell<CertifiedOfferExecutionAttempt>?,
    status: CertifiedOfferEscrowStatus,
    makerItemsMap: ItemDeposits,
    assignsUsdt: bool,
) {
    val terms = lazy termsCell.load();
    assertExternalTransitionReserve(
        terms.makerItemCount,
        terms.takerItemCount,
        terms.payment,
        terms.makerTonFee,
        terms.takerTonFee,
        depositsCell,
        automaticBudget,
        executionAttemptCell,
        status,
        makerItemsMap,
        assignsUsdt,
    );
}

@inline
fun assertExternalTransitionReserve(
    makerItemCount: uint16,
    takerItemCount: uint16,
    paymentCell: Cell<PaymentTerms>?,
    makerTonFee: coins,
    maximumTakerTonFee: coins,
    depositsCell: Cell<OfferEscrowDeposits>,
    automaticBudget: coins,
    executionAttemptCell: Cell<CertifiedOfferExecutionAttempt>?,
    status: CertifiedOfferEscrowStatus,
    makerItemsMap: ItemDeposits,
    assignsUsdt: bool,
) {
    val deposits = lazy depositsCell.load();
    val makerItems = makerItemsMap.isEmpty() ? 0 : makerItemCount as int;
    var takerItems = 0;
    var nativePrincipal = grams("0") as coins;
    var paymentAsset = -1;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        paymentAsset = payment.asset as int;
    }
    if (paymentAsset == (PaymentAsset.Ton as int)) {
        nativePrincipal = deposits.maker.total;
    }
    val makerFee = makerTonFee == 0 || deposits.makerFeePayer == null
        ? (grams("0") as coins)
        : makerTonFee;
    var takerFee = grams("0") as coins;
    if (executionAttemptCell != null) {
        val attempt = lazy executionAttemptCell.load();
        val details = lazy attempt.details.load();
        if (!details.items.isEmpty()) {
            takerItems = takerItemCount as int;
        }
        if (paymentAsset == (PaymentAsset.Ton as int)) {
            nativePrincipal += attempt.deposits.total;
        }
        if (maximumTakerTonFee > 0 && attempt.feePayer != null) {
            takerFee = details.takerTonFee;
        }
    }
    val nftCount = makerItems + takerItems;
    val usdtCount = paymentAsset != (PaymentAsset.Usdt as int) ||
        status == CertifiedOfferEscrowStatus.PayoutConfirmed
        ? 0
        : deposits.usdt.count as int;
    val obligations = nativePrincipal + makerFee + takerFee;
    val required = usdtCount > 0
        ? requiredExternalEscrowBalance(
            obligations,
            automaticBudget,
            nftCount,
            usdtCount,
            assignsUsdt,
            deposits.usdt.termsPayloadBits,
            deposits.usdt.termsPayloadCells,
        )
        : requiredExternalEscrowBalance(
            obligations,
            automaticBudget,
            nftCount,
            0,
            assignsUsdt,
            0,
            0,
        );
    assert (
        contract.getOriginalBalance() >= required
    ) throw CertifiedOfferEscrowErrors.AutomaticRecoveryUnavailable;
}

// This state is reachable only with the immutable payment and both exact fees funded.
// Keep one lazy view across authority and reserve admission to stay within external gas credit.
@inline
fun assertExternalSettlementApproval(
    termsCell: Cell<CertifiedOfferTerms>,
    depositsCell: Cell<OfferEscrowDeposits>,
    automaticBudget: coins,
    executionAttemptCell: Cell<CertifiedOfferExecutionAttempt>?,
    status: CertifiedOfferEscrowStatus,
    makerItemsMap: ItemDeposits,
    certifierPublicKey: uint256,
    signature: bits512,
    signedCell: Cell<CertifiedSettlementApprovalAuthorization>,
) {
    val terms = lazy termsCell.load();
    val (signedNumber, evidenceCell) = validateSettlementApprovalEnvelope(
        terms.offerId,
        signedCell,
    );
    assert (
        status == CertifiedOfferEscrowStatus.AwaitingApproval
    ) throw CertifiedOfferEscrowErrors.NotAwaitingApproval;
    assert (executionAttemptCell != null) throw CertifiedOfferEscrowErrors.NotAwaitingApproval;
    val attempt = lazy executionAttemptCell.load();
    val details = lazy attempt.details.load();
    val policy = lazy terms.policy.load();
    val evidence = lazy evidenceCell.load();
    assertSettlementApprovalEvidence(
        attempt.number,
        attempt.certificateHash,
        policy.makerDelivery,
        details.delivery,
        signedNumber,
        evidence.certificateHash,
        evidence.makerDeliveryCommitment,
        evidence.takerDeliveryCommitment,
    );
    assert (
        isSignatureValid(signedCell.hash(), signature as slice, certifierPublicKey)
    ) throw CertifiedOfferEscrowErrors.InvalidSettlementAuthorization;
    val paymentCell = terms.payment;
    var nativePrincipal = grams("0") as coins;
    var paymentIsUsdt = false;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        paymentIsUsdt = payment.asset == PaymentAsset.Usdt;
        if (!paymentIsUsdt) {
            nativePrincipal = payment.amount;
        }
    }
    val nftCount = (makerItemsMap.isEmpty() ? 0 : terms.makerItemCount as int) +
        (details.items.isEmpty() ? 0 : terms.takerItemCount as int);
    val obligations = nativePrincipal + terms.makerTonFee + details.takerTonFee;
    val deposits = lazy depositsCell.load();
    val required = paymentIsUsdt
        ? requiredExternalEscrowBalance(
            obligations,
            automaticBudget,
            nftCount,
            deposits.usdt.count,
            true,
            deposits.usdt.termsPayloadBits,
            deposits.usdt.termsPayloadCells,
        )
        : requiredExternalEscrowBalance(
            obligations,
            automaticBudget,
            nftCount,
            0,
            true,
            0,
            0,
        );
    assert (
        contract.getOriginalBalance() >= required
    ) throw CertifiedOfferEscrowErrors.AutomaticRecoveryUnavailable;
}

// Keep the eager transition decode behind ACCEPT; automatic inlining would move its loads into
// the same validation scope and exhaust gas_credit on a signed maximal-lot cancellation.
@noinline
fun closeExternallyVerifiedOffer(closedAs: CertifiedOfferEscrowStatus) {
    closeOffer(CertifiedOfferEscrowStorage.load(), closedAs);
}

@inline
fun CertifiedOfferEscrowStatus.isFinalizationLocked(self): bool {
    return self == CertifiedOfferEscrowStatus.AwaitingApproval;
}

// Эти wrappers отделяют разрешение внешнего вызова от полной загрузки изменяемого storage.
// @noinline не позволяет compiler перенести transition decode в gas_credit до ACCEPT.
@noinline
fun applyExternallyVerifiedSettlementApproval(
    signed: Cell<CertifiedSettlementApprovalAuthorization>,
) {
    applyVerifiedSettlementApproval(CertifiedOfferEscrowStorage.load(), signed);
}

@noinline
fun applyExternallyVerifiedExecutionRejection(
    signed: Cell<CertifiedExecutionRejectionAuthorization>,
) {
    applyVerifiedExecutionRejection(CertifiedOfferEscrowStorage.load(), signed);
}

@noinline
fun applyExternallyVerifiedExecutionRejectionAndClose(
    signed: Cell<CertifiedExecutionRejectionAndCloseAuthorization>,
) {
    applyVerifiedExecutionRejectionAndClose(CertifiedOfferEscrowStorage.load(), signed);
}

@noinline
fun releaseExternallyVerifiedExecutionAttempt() {
    releaseCurrentExecutionAttempt(CertifiedOfferEscrowStorage.load());
}

@noinline
fun resumeExternallyVerifiedSettlement(vault: address) {
    resumeSettlementFromReserve(CertifiedOfferEscrowStorage.load(), vault);
}

@noinline
fun retryExternallyVerifiedNftDelivery(nft: address) {
    retryNftDeliveryFromReserve(CertifiedOfferEscrowStorage.load(), nft);
}
