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

contract OfferEscrow {
    author: "Gettran"
    version: "1.0.0"
    description: "Bilateral Offer escrow: concrete NFT sets and the money leg are committed by StateInit; no certificate can alter settlement"
    storage: OfferEscrowStorage
    incomingMessages: AllowedMessage
    incomingExternal: AllowedExternalMessage
}

type AllowedExternalMessage =
    | TriggerExactOfferExpiry
    | TriggerExactExpiredExecutionRelease
    | TriggerSettlementResume
    | TriggerNftDeliveryRetry
    | RelayMakerCancellation

fun onExternalMessage(inMsgBody: slice) {
    val msg = lazy AllowedExternalMessage.fromSlice(inMsgBody);
    match (msg) {
        RelayMakerCancellation => {
            val storage = lazy OfferEscrowStorage.load();
            assertMayCancelStatus(storage.status);
            assertMakerCancellationForTerms(storage.terms, msg.signature, msg.signed);

            assertExternalTransitionReserve(
                storage.terms,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                false,
            );
            acceptExternalMessage();
            closeExternallyVerifiedOffer(OfferEscrowStatus.Cancelled);
        }
        TriggerExactOfferExpiry => {
            val storage = lazy OfferEscrowStorage.load();
            storage.assertMayExternallyExpire(msg.offerId, msg.expiresAt);

            assertExternalTransitionReserve(
                storage.terms,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                false,
            );
            acceptExternalMessage();
            closeExternallyVerifiedOffer(OfferEscrowStatus.Expired);
        }
        TriggerExactExpiredExecutionRelease => {
            val storage = lazy OfferEscrowStorage.load();
            storage.assertMayExternallyReleaseExecution(
                msg.offerId,
                msg.offerExecutionNumber,
            );

            assertExternalTransitionReserve(
                storage.terms,
                storage.deposits,
                storage.automaticRecoveryBudget,
                storage.executionAttempt,
                storage.status,
                false,
            );
            acceptExternalMessage();
            releaseCurrentExecutionAttempt(OfferEscrowStorage.load());
        }
        TriggerSettlementResume => {
            val storage = lazy OfferEscrowStorage.load();
            storage.assertMayExternallyResumeSettlement(
                msg.offerId,
                msg.payoutQueryId,
                msg.vault,
            );

            acceptExternalMessage();
            resumeSettlementFromReserve(OfferEscrowStorage.load(), msg.vault);
        }
        TriggerNftDeliveryRetry => {
            val storage = lazy OfferEscrowStorage.load();
            storage.assertMayExternallyRetryNftDelivery(
                msg.offerId,
                msg.nft,
                msg.deliveryQueryId,
            );

            acceptExternalMessage();
            retryNftDeliveryFromReserve(OfferEscrowStorage.load(), msg.nft);
        }
        else => {
            throw OfferEscrowErrors.InvalidMessage;
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
    | StartOfferExecution
    | DepositOfferPayment
    | BuyOffer
    | ReleaseOfferExecutionAttempt
    | ExpireOffer
    | ResumeSettlement
    | Cancel
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
            // Полная side fee уже является economic commitment. Без неё execution остаётся только
            // в immutable vault terms и получит эксклюзивность после реального USDT receipt.
            if (msg.execution != null && msg.sideFeeAmount > 0) {
                val executionAttempt = StartOfferExecution.fromCell(msg.execution);
                assert (
                    executionAttempt.paymentAmount == 0 && executionAttempt.sideFeeAmount == 0
                ) throw OfferEscrowErrors.InvalidTerms;
                OfferEscrowStorage.load().assertExecutionStartsWithCommitment(0, msg.sideFeeAmount);
                startOfferExecution(
                    in.senderAddress,
                    executionAttempt.offerExecutionNumber,
                    executionAttempt.allowedContributorWallets,
                    executionAttempt.takerRefundRecipients,
                    executionAttempt.takerSettlementWallet,
                );
            }
            if (msg.sideFeeAmount > 0) {
                assert (
                    depositSideFee(
                        in.senderAddress,
                        msg.sideFeeAmount,
                        msg.offerExecutionNumber,
                    )
                ) throw OfferEscrowErrors.InvalidTerms;
            }
            val storage = OfferEscrowStorage.load();
            assert (!storage.isClosed()) throw OfferEscrowErrors.AlreadyClosed;
            assert (
                storage.status == OfferEscrowStatus.CollectingMaker ||
                storage.status == OfferEscrowStatus.Open ||
                storage.status == OfferEscrowStatus.CollectingTaker
            ) throw OfferEscrowErrors.SettlementInProgress;
            val payment = storage.terms.load().payment;
            assert (payment != null) throw OfferEscrowErrors.InvalidTerms;
            assert (
                payment.load().payer != OfferSide.Taker ||
                !storage.terms.load().parties.load().isMakerWallet(in.senderAddress)
            ) throw OfferEscrowErrors.InvalidContributorSet;
            assert (
                msg.offerExecutionNumber ==
                (payment.load().payer == OfferSide.Maker
                    ? (0 as uint32)
                    : storage.offerExecutionNumber)
            ) throw OfferEscrowErrors.ExecutionAttemptMoved;
            assert (in.valueCoins >= msg.sideFeeAmount) throw OfferEscrowErrors.NotEnoughValue;
            prepareUsdtPayment(
                in.senderAddress,
                in.valueCoins - msg.sideFeeAmount,
                payment.load(),
                msg,
            );
            var fundedStorage = OfferEscrowStorage.load();
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
            val storage = OfferEscrowStorage.load();
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
        StartOfferExecution => {
            assert (
                in.valueCoins >= msg.paymentAmount + msg.sideFeeAmount
            ) throw OfferEscrowErrors.NotEnoughValue;
            OfferEscrowStorage
                .load()
                .assertExecutionStartsWithCommitment(
                    msg.paymentAmount,
                    msg.sideFeeAmount,
                );
            startOfferExecution(
                in.senderAddress,
                msg.offerExecutionNumber,
                msg.allowedContributorWallets,
                msg.takerRefundRecipients,
                msg.takerSettlementWallet,
            );
            if (msg.sideFeeAmount > 0) {
                assert (
                    depositSideFee(
                        in.senderAddress,
                        msg.sideFeeAmount,
                        msg.offerExecutionNumber,
                    )
                ) throw OfferEscrowErrors.InvalidTerms;
            }
            if (msg.paymentAmount > 0) {
                assert (
                    applyTonDeposit(
                        in.senderAddress,
                        msg.paymentAmount,
                        msg.offerExecutionNumber,
                        msg.paymentAmount,
                    )
                ) throw OfferEscrowErrors.InvalidTerms;
            }
        }
        DepositOfferPayment => {
            assert (
                msg.paymentAmount + msg.sideFeeAmount > 0 &&
                in.valueCoins >= msg.paymentAmount + msg.sideFeeAmount
            ) throw OfferEscrowErrors.NotEnoughValue;
            if (msg.sideFeeAmount > 0 && msg.paymentAmount > 0) {
                assert (
                    depositSideFee(
                        in.senderAddress,
                        msg.sideFeeAmount,
                        msg.offerExecutionNumber,
                        in.valueCoins - msg.paymentAmount - msg.sideFeeAmount,
                    )
                ) throw OfferEscrowErrors.InvalidTerms;
                assert (
                    applyTonDeposit(
                        in.senderAddress,
                        msg.paymentAmount,
                        msg.offerExecutionNumber,
                        msg.paymentAmount,
                        in.valueCoins - msg.paymentAmount - msg.sideFeeAmount,
                    )
                ) throw OfferEscrowErrors.InvalidTerms;
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
        BuyOffer => {
            buyWithTon(
                in.senderAddress,
                in.valueCoins,
                msg.offerExecutionNumber,
                msg.paymentAmount,
                msg.allowedContributorWallets,
                msg.takerSettlementWallet,
            );
        }
        ReleaseOfferExecutionAttempt => {
            releaseOfferExecutionAttempt(in.senderAddress, msg.offerExecutionNumber);
        }
        ExpireOffer => {
            expireOffer();
        }
        ResumeSettlement => {
            resumeSettlement(in.valueCoins);
        }
        Cancel => {
            cancelOffer(in.senderAddress);
        }
        DepositSideFee => {
            depositSideFee(
                in.senderAddress,
                in.valueCoins,
                msg.offerExecutionNumber,
                max(0, in.valueCoins - OfferEscrowStorage.load().terms.load().makerTonFee),
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
                acceptSaleWithTonTransfer(in.senderAddress, in.valueCoins);
            }
        }
        else => {
            assert (in.body.isEmpty()) throw OfferEscrowErrors.InvalidMessage;
            acceptSaleWithTonTransfer(in.senderAddress, in.valueCoins);
        }
    }
}

fun termsAreValid(storage: OfferEscrowStorage, progress: OfferItemProgress): bool {
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    val paymentCell = terms.payment;
    var makerHasConsideration = terms.makerItemCount > 0;
    var takerHasConsideration = terms.takerItemCount > 0;
    var paymentShapeIsValid = true;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        makerHasConsideration = makerHasConsideration || payment.payer == OfferSide.Maker;
        takerHasConsideration = takerHasConsideration || payment.payer == OfferSide.Taker;
        val hasSwapFee = terms.makerTonFee > 0 || terms.takerTonFee > 0;
        paymentShapeIsValid = payment.amount > 0 && payment.marketplaceFee < payment.amount &&
            (!hasSwapFee || (terms.makerItemCount > 0 && terms.takerItemCount > 0));
    }

    val makerWalletsAreValid = parties.makerWallets.isValid(false) &&
        parties.makerSettlementWallet.getWorkchain() == BASECHAIN;
    val addresseeWalletsAreValid = parties.addresseeWallets.isValid(true) &&
        parties.hasIndependentTakerWallets(parties.addresseeWallets);
    val makerCancellation = parties.makerCancellation;
    val makerCancellationIsValid = makerCancellation == null ||
        makerCancellation.load().isValidFor(parties.makerWallets);
    val items = lazy storage.items.load();

    return progress.isValid && makerHasConsideration && takerHasConsideration &&
        paymentShapeIsValid &&
        storage.executionAttemptTtl > 0 &&
        storage.executionAttemptTtl <= MAX_EXECUTION_ATTEMPT_TTL &&
        makerWalletsAreValid &&
        addresseeWalletsAreValid &&
        items.maker.refundRecipientsAreAllowedBy(parties.makerWallets, false) &&
        items.taker.refundRecipientsAreAllowedBy(parties.addresseeWallets, true) &&
        makerCancellationIsValid;
}

// NFT уже принадлежит escrow к моменту уведомления; любой непринимаемый депозит возвращается, а
// не откатывается throw-ом в застрявший предмет.
fun applyItemDeposit(item: address, depositor: address, forwardPayload: slice) {
    var storage = lazy OfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    if (storage.deposits.load().nftDeliveries.exists(item)) {
        val delivery = storage.deposits.load().nftDeliveries.get(item).loadValue();
        if (delivery.recipient == depositor) {
            // A late ownership_assigned proves that escrow owns the item now. Return it using the
            // notification's own value even if an earlier no-notification recovery is unresolved.
            returnStrayNftWithComment(item, depositor, delivery.comment);
        }
        return;
    }

    var items = storage.items.load();

    if (storage.status == OfferEscrowStatus.CollectingMaker) {
        val makerSlot = items.maker.get(item);
        val parties = lazy terms.parties.load();
        if (
            blockchain.now() >= storage.expiresAt || !parties.makerWallets.exists(depositor) ||
            !makerSlot.isFound ||
            !makerSlot.loadValue().acceptsDepositor(depositor)
        ) {
            returnStrayNft(item, depositor, storage.itemRefundReason());
            return;
        }

        var makerDeposit = makerSlot.loadValue();
        makerDeposit.depositor = depositor;
        items.maker.set(item, makerDeposit);
        val progress = items.progress(terms.makerItemCount, terms.takerItemCount);
        if (!storage.areTermsValidated && !termsAreValid(storage, progress)) {
            returnStrayNft(item, depositor, storage.itemRefundReason());
            return;
        }
        if (!storage.areTermsValidated) {
            items.takerTemplate = items.taker;
        }
        storage.areTermsValidated = true;
        storage.items = items.toCell();
        val paymentCell = terms.payment;
        var makerPaymentReady = true;
        if (paymentCell != null) {
            val payment = lazy paymentCell.load();
            makerPaymentReady = payment.payer != OfferSide.Maker ||
                storage.deposits.load().maker.total == payment.amount;
        }
        if (
            progress.isMakerComplete && makerPaymentReady &&
            (terms.makerTonFee == 0 || storage.deposits.load().makerFeePayer != null) &&
            contract.getOriginalBalance() >= storage.requiredSettlementBalance(false)
        ) {
            storage.status = OfferEscrowStatus.Open;
        }
        storage.save();
        return;
    }

    val executionCell = readExecutionCommitment(forwardPayload);
    if (
        executionCell != null &&
        (storage.status == OfferEscrowStatus.Open ||
            storage.status == OfferEscrowStatus.CollectingTaker)
    ) {
        if (!tryStartOfferExecutionFromNftCommitment(item, depositor, executionCell)) {
            returnStrayNft(item, depositor, storage.itemRefundReason());
            return;
        }
        storage = OfferEscrowStorage.load();
        items = storage.items.load();
    }

    if (storage.status == OfferEscrowStatus.Open) {
        val parties = lazy terms.parties.load();
        val takerSlot = items.taker.get(item);
        if (
            !storage.areTermsValidated || blockchain.now() >= storage.expiresAt ||
            !parties.addresseeWallets.allows(depositor) ||
            parties.isMakerWallet(depositor) ||
            !takerSlot.isFound ||
            !takerSlot.loadValue().acceptsDepositor(depositor)
        ) {
            returnStrayNft(item, depositor, storage.itemRefundReason());
            return;
        }

        val paymentCell = terms.payment;
        if (terms.makerItemCount == 0 && terms.takerItemCount == 1 && paymentCell != null) {
            val payment = lazy paymentCell.load();
            if (
                payment.payer == OfferSide.Maker && payment.asset == PaymentAsset.Ton &&
                storage.deposits.load().maker.total == payment.amount &&
                contract.getOriginalBalance() >= storage.requiredSettlementBalance(true)
            ) {
                var takerDeposit = takerSlot.loadValue();
                takerDeposit.depositor = depositor;
                items.taker.set(item, takerDeposit);
                storage.items = items.toCell();
                finishSingleNftTonPurchase(
                    storage,
                    terms,
                    parties,
                    payment,
                    item,
                    depositor,
                );
                return;
            }
        }

        val progress = items.progress(terms.makerItemCount, terms.takerItemCount);
        if (!progress.isValid || !progress.isMakerComplete) {
            returnStrayNft(item, depositor, storage.itemRefundReason());
            return;
        }
        var takerDeposit = takerSlot.loadValue();
        takerDeposit.depositor = depositor;
        items.taker.set(item, takerDeposit);
        storage.items = items.toCell();
        if (
            terms.takerItemCount == 1 && storage.canSettleFromFirstTakerItem() &&
            contract.getOriginalBalance() >= storage.requiredSettlementBalance(true)
        ) {
            finishSettlementTo(storage, depositor);
            return;
        }

        storage.bindTaker(
            depositor,
            depositor,
            parties.addresseeWallets.isEmpty()
                ? singleOfferWallet(depositor)
                : parties.addresseeWallets,
            { total: 0, contributions: [] },
        );
        storage.save();
        settleIfReady(mutate storage);
        return;
    }

    if (storage.status != OfferEscrowStatus.CollectingTaker) {
        returnStrayNft(item, depositor, storage.itemRefundReason());
        return;
    }

    val executionAttemptCell = storage.executionAttempt;
    if (executionAttemptCell == null) {
        returnStrayNft(item, depositor, storage.itemRefundReason());
        return;
    }
    val executionAttempt = lazy executionAttemptCell.load();
    val progress = items.progress(terms.makerItemCount, terms.takerItemCount);
    val takerSlot = items.taker.get(item);
    if (
        blockchain.now() >= executionAttempt.validUntil ||
        !executionAttempt.confirmedContributorWallets.exists(depositor) ||
        !progress.isValid ||
        !takerSlot.isFound ||
        !takerSlot.loadValue().acceptsDepositor(depositor)
    ) {
        returnStrayNft(item, depositor, storage.itemRefundReason());
        return;
    }

    var takerDeposit = takerSlot.loadValue();
    takerDeposit.depositor = depositor;
    items.taker.set(item, takerDeposit);
    storage.items = items.toCell();
    storage.save();
    settleIfReady(mutate storage);
}

fun tryStartOfferExecutionFromNftCommitment(
    item: address,
    sender: address,
    executionCell: cell,
): bool {
    try {
        val execution = StartOfferExecution.fromCell(executionCell);
        assert (
            execution.paymentAmount == 0 && execution.sideFeeAmount == 0
        ) throw OfferEscrowErrors.InvalidTerms;
        val refund = execution.takerRefundRecipients.get(item);
        assert (
            refund.isFound && refund.loadValue() == sender
        ) throw OfferEscrowErrors.InvalidTerms;
        startOfferExecution(
            sender,
            execution.offerExecutionNumber,
            execution.allowedContributorWallets,
            execution.takerRefundRecipients,
            execution.takerSettlementWallet,
        );
        return true;
    } catch (_, _) {
        return false;
    }
}

fun tryStartOfferExecutionFromUsdtCommitment(sender: address, executionCell: cell): bool {
    try {
        val execution = StartOfferExecution.fromCell(executionCell);
        assert (
            execution.paymentAmount == 0 && execution.sideFeeAmount == 0
        ) throw OfferEscrowErrors.InvalidTerms;
        startOfferExecution(
            sender,
            execution.offerExecutionNumber,
            execution.allowedContributorWallets,
            execution.takerRefundRecipients,
            execution.takerSettlementWallet,
        );
        return true;
    } catch (_, _) {
        return false;
    }
}

fun OfferEscrowStorage.assertExecutionStartsWithCommitment(
    self,
    paymentAmount: coins,
    sideFeeAmount: coins,
) {
    if (self.status == OfferEscrowStatus.CollectingTaker) {
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
    val hasFullSideFee = terms.takerTonFee > 0 && sideFeeAmount == terms.takerTonFee;
    assert (hasFullNativePayment || hasFullSideFee) throw OfferEscrowErrors.NotEnoughValue;
}

// Самый частый exact purchase не нуждается ни в executionAttempt cell, ни в повторных обходах maps:
// единственный заранее известный NFT сам аутентифицирует продавца через previousOwner. Остальные
// формы сделки идут через общий settlement ниже.
fun finishSingleNftTonPurchase(
    original: OfferEscrowStorage,
    terms: OfferEscrowTerms,
    parties: OfferEscrowParties,
    payment: PaymentTerms,
    item: address,
    seller: address,
) {
    var storage = original;
    var deposits = storage.deposits.load();
    storage.status = OfferEscrowStatus.Settled;
    storage.closedAt = blockchain.now();
    storage.automaticRecoveryBudget = automaticNftDeliveryRetryReserve(1);
    deposits
        .nftDeliveries
        .deliver(
            item,
            parties.makerSettlementWallet,
            null,
        );
    storage.deposits = deposits.toCell();
    storage.settledTakerWallet = seller;
    storage.save();

    sendCoins(seller, payment.amount - payment.marketplaceFee, SETTLEMENT_PAYMENT_COMMENT);
    if (payment.marketplaceFee > 0) {
        sendCoins(
            terms.config.load().feeTreasury,
            payment.marketplaceFee,
            MARKETPLACE_FEE_COMMENT,
        );
    }
    returnChange(
        storage.reserveChangeRecipient(),
        MIN_TONS_FOR_STORAGE + storage.automaticRecoveryBudget,
    );
}

fun openIfMakerReady(mutate storage: OfferEscrowStorage): bool {
    if (storage.status != OfferEscrowStatus.CollectingMaker) {
        return false;
    }

    val terms = lazy storage.terms.load();
    var items = storage.items.load();
    val progress = items.progress(terms.makerItemCount, terms.takerItemCount);
    val justValidated = !storage.areTermsValidated;
    if (justValidated) {
        if (!termsAreValid(storage, progress)) {
            return false;
        }
        items.takerTemplate = items.taker;
        storage.items = items.toCell();
        storage.areTermsValidated = true;
    }
    val paymentCell = terms.payment;
    var makerPaymentReady = true;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        makerPaymentReady = payment.payer != OfferSide.Maker ||
            storage.deposits.load().maker.total == payment.amount;
    }
    if (
        blockchain.now() < storage.expiresAt && progress.isMakerComplete && makerPaymentReady &&
        (terms.makerTonFee == 0 || storage.deposits.load().makerFeePayer != null) &&
        contract.getOriginalBalance() >= storage.requiredSettlementBalance(false)
    ) {
        storage.status = OfferEscrowStatus.Open;
        return true;
    }
    return justValidated;
}

fun startOfferExecution(
    sender: address,
    expectedNumber: uint32,
    allowedContributorWallets: OfferWallets,
    takerRefundRecipients: ItemRefundRecipients,
    takerSettlementWallet: address,
) {
    var storage = lazy OfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    assert (
        storage.status == OfferEscrowStatus.Open ||
        storage.status == OfferEscrowStatus.CollectingTaker
    ) throw OfferEscrowErrors.NotOpen;
    assert (storage.areTermsValidated) throw OfferEscrowErrors.InvalidTerms;
    assert (blockchain.now() < storage.expiresAt) throw OfferEscrowErrors.OfferExpired;
    assert (
        expectedNumber == storage.offerExecutionNumber
    ) throw OfferEscrowErrors.ExecutionAttemptMoved;
    assert (
        allowedContributorWallets.isAllowedBy(parties.addresseeWallets) &&
        parties.hasIndependentTakerWallets(allowedContributorWallets) &&
        !parties.isMakerWallet(takerSettlementWallet) &&
        allowedContributorWallets.exists(sender) &&
        takerSettlementWallet.getWorkchain() == BASECHAIN
    ) throw OfferEscrowErrors.InvalidContributorSet;

    if (storage.status == OfferEscrowStatus.Open) {
        var items = storage.items.load();
        assert (
            !storage.deposits.load().nftDeliveries.containsAny(items.taker)
        ) throw OfferEscrowErrors.NftDeliveryPending;
        assert (
            items.taker.commitRefundRecipients(takerRefundRecipients, allowedContributorWallets)
        ) throw OfferEscrowErrors.InvalidContributorSet;
        storage.items = items.toCell();
        storage.bindTaker(
            takerSettlementWallet,
            sender,
            allowedContributorWallets,
            { total: 0, contributions: [] },
        );
        storage.save();
        return;
    }

    val executionAttemptCell = storage.executionAttempt;
    assert (executionAttemptCell != null) throw OfferEscrowErrors.NotOpen;
    var executionAttempt = executionAttemptCell.load();
    assert (blockchain.now() < executionAttempt.validUntil) throw OfferEscrowErrors.OfferExpired;
    assert (
        executionAttempt.takerSettlementWallet == takerSettlementWallet &&
        executionAttempt.allowedContributorWallets.equals(allowedContributorWallets) &&
        storage.items.load().taker.hasRefundRecipients(takerRefundRecipients)
    ) throw OfferEscrowErrors.InvalidContributorSet;
    if (executionAttempt.confirmedContributorWallets.exists(sender)) {
        return;
    }

    executionAttempt.confirmedContributorWallets.set(sender, true);
    storage.executionAttempt = executionAttempt.toCell();
    storage.save();
    settleIfReady(mutate storage);
}

// Независимый taker recipient не должен превращать одну покупку в частично применённые Start и
// Deposit. Полная TON-оплата exact sale связывает получателя и рассчитывается атомарно.
fun buyWithTon(
    sender: address,
    msgValue: coins,
    offerExecutionNumber: uint32,
    amount: coins,
    allowedContributorWallets: OfferWallets,
    takerSettlementWallet: address,
) {
    val initial = lazy OfferEscrowStorage.load();
    val terms = lazy initial.terms.load();
    val paymentCell = terms.payment;
    assert (paymentCell != null) throw OfferEscrowErrors.InvalidTerms;
    val payment = lazy paymentCell.load();
    assert (
        initial.status == OfferEscrowStatus.Open && payment.asset == PaymentAsset.Ton &&
        payment.payer == OfferSide.Taker &&
        terms.takerItemCount == 0 &&
        offerExecutionNumber == initial.offerExecutionNumber &&
        amount == payment.amount &&
        msgValue >= amount &&
        contract.getOriginalBalance() >= initial.requiredSettlementBalance(true)
    ) throw OfferEscrowErrors.NotEnoughValue;

    startOfferExecution(
        sender,
        offerExecutionNumber,
        allowedContributorWallets,
        [],
        takerSettlementWallet,
    );
    applyTonDeposit(sender, msgValue, offerExecutionNumber, amount);

    assert (
        OfferEscrowStorage.load().status == OfferEscrowStatus.Settled
    ) throw OfferEscrowErrors.InvalidTerms;
}

// Денежная-only встречная сторона с одним кошельком не требует отдельного binding-сообщения:
// источник платежа уже аутентифицирован самой транзакцией. Явный StartOfferExecution остаётся для
// multi-wallet и NFT-встречных сторон.
fun OfferEscrowStorage.canSettleFromFirstTakerItem(self): bool {
    val terms = lazy self.terms.load();
    if (terms.takerTonFee > 0) {
        return false;
    }
    val paymentCell = terms.payment;
    if (paymentCell == null) {
        return true;
    }
    val payment = lazy paymentCell.load();
    return payment.payer == OfferSide.Maker && payment.asset == PaymentAsset.Ton;
}

fun OfferEscrowStorage.bindTaker(
    mutate self,
    takerSettlementWallet: address,
    firstConfirmedWallet: address,
    allowedContributorWallets: OfferWallets,
    deposits: PaymentDeposits,
) {
    val executionAttemptEnd = blockchain.now() + self.executionAttemptTtl;

    self.status = OfferEscrowStatus.CollectingTaker;
    self.executionAttempt = OfferExecutionAttempt {
        number: self.offerExecutionNumber,
        allowedContributorWallets,
        confirmedContributorWallets: singleOfferWallet(firstConfirmedWallet),
        takerSettlementWallet,
        validUntil: (executionAttemptEnd < self.expiresAt
            ? executionAttemptEnd
            : self.expiresAt) as uint32,
        deposits,
    }.toCell();
}

fun OfferEscrowStorage.itemRefundReason(self): RefundReason {
    val reason = self.paymentRefundReason();
    return reason == RefundReason.OfferUnavailable ? RefundReason.InvalidItem : reason;
}

fun OfferEscrowStorage.paymentRefundReason(self): RefundReason {
    if (self.status == OfferEscrowStatus.Cancelled) {
        return RefundReason.OfferCancelled;
    }
    if (self.status == OfferEscrowStatus.Settled) {
        return RefundReason.OfferUnavailable;
    }
    if (self.status == OfferEscrowStatus.Expired || blockchain.now() >= self.expiresAt) {
        return RefundReason.OfferExpired;
    }
    val execution = self.executionAttempt;
    if (
        (self.status == OfferEscrowStatus.CollectingTaker) && execution != null &&
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
    var storage = lazy OfferEscrowStorage.load();
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
        storage.status == OfferEscrowStatus.CollectingMaker && payment.payer == OfferSide.Maker &&
        blockchain.now() <
        storage.expiresAt &&
        parties.makerWallets.exists(sender) &&
        offerExecutionNumber == storage.offerExecutionNumber &&
        storage.deposits.load().maker.total + amount <= payment.amount
    ) {
        storage.deposits.addMakerTonDeposit(sender, amount);
        storage.recordMakerReservePayer(sender, reserveValue);
        openIfMakerReady(mutate storage);
        storage.save();
        return true;
    }

    if (
        storage.status == OfferEscrowStatus.Open && payment.payer == OfferSide.Taker &&
        storage.areTermsValidated &&
        terms.takerItemCount == 0 &&
        offerExecutionNumber == storage.offerExecutionNumber &&
        blockchain.now() <
        storage.expiresAt &&
        parties.addresseeWallets.allows(sender) &&
        !parties.isMakerWallet(sender) &&
        amount <= payment.amount
    ) {
        if (
            amount == payment.amount &&
            contract.getOriginalBalance() >= storage.requiredSettlementBalance(true)
        ) {
            finishSettlementTo(storage, sender);
            return true;
        }
        var contributions: MoneyContributions = [];
        contributions.add(sender, amount);
        storage.bindTaker(
            sender,
            sender,
            parties.addresseeWallets.isEmpty()
                ? singleOfferWallet(sender)
                : parties.addresseeWallets,
            { total: amount, contributions },
        );
        storage.save();
        return true;
    }

    val executionAttemptCell = storage.executionAttempt;
    if (
        storage.status == OfferEscrowStatus.CollectingTaker && payment.payer == OfferSide.Taker &&
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
            settleIfReady(mutate storage);
            return true;
        }
    }

    refundTon(sender, storage.paymentRefundReason().comment());
    return false;
}

// Полная TON-оплата exact sale не создаёт executionAttempt, которая умерла бы в той же транзакции.
// Структурированный DepositOfferPayment остаётся для частичного и multi-wallet deposits.
fun acceptSaleWithTonTransfer(sender: address, msgValue: coins) {
    val storage = lazy OfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    val paymentCell = terms.payment;
    if (paymentCell == null) {
        refundTon(sender, storage.paymentRefundReason().comment());
        return;
    }
    val payment = lazy paymentCell.load();
    val parties = lazy terms.parties.load();
    val itemCount = terms.makerItemCount;
    val requiredBalance = (payment.amount + NFT_TRANSFER_VALUE * itemCount +
        escrowSettlementFees(itemCount) +
        MIN_TONS_FOR_STORAGE) as coins;
    if (
        storage.status != OfferEscrowStatus.Open || !storage.areTermsValidated ||
        payment.asset != PaymentAsset.Ton ||
        payment.payer != OfferSide.Taker ||
        terms.takerItemCount != 0 ||
        blockchain.now() >= storage.expiresAt ||
        !parties.addresseeWallets.allows(sender) ||
        parties.isMakerWallet(sender) ||
        msgValue <
        payment.amount ||
        contract.getOriginalBalance() <
        requiredBalance
    ) {
        var reason = storage.paymentRefundReason();
        if (reason == RefundReason.OfferUnavailable) {
            if (payment.asset != PaymentAsset.Ton) {
                reason = RefundReason.InvalidAsset;
            } else if (msgValue < payment.amount) {
                reason = RefundReason.AmountTooLow;
            }
        }
        refundTon(sender, reason.comment());
        return;
    }

    if (itemCount == 1) {
        finishSingleNftTonSale(storage, terms, parties, payment, sender);
    } else {
        finishWholeTonPayment(storage, terms, parties, payment, sender);
    }
}

// Самый частый sale не оплачивает общий цикл по map, когда валидированный лот заведомо состоит из
// одного уже депонированного NFT. Экономический и storage-переход остаются теми же.
fun finishSingleNftTonSale(
    original: OfferEscrowStorage,
    terms: OfferEscrowTerms,
    parties: OfferEscrowParties,
    payment: PaymentTerms,
    takerSettlementWallet: address,
) {
    var storage = original;
    val makerDeposit = storage.items.load().maker.findFirst();
    var deposits = storage.deposits.load();

    storage.status = OfferEscrowStatus.Settled;
    storage.closedAt = blockchain.now();
    storage.automaticRecoveryBudget = automaticNftDeliveryRetryReserve(1);
    deposits
        .nftDeliveries
        .deliver(
            makerDeposit.getKey(),
            takerSettlementWallet,
            null,
        );
    storage.deposits = deposits.toCell();
    storage.settledTakerWallet = takerSettlementWallet;
    storage.save();

    sendCoins(
        parties.makerSettlementWallet,
        payment.amount - payment.marketplaceFee,
        SETTLEMENT_PAYMENT_COMMENT,
    );
    if (payment.marketplaceFee > 0) {
        val config = lazy terms.config.load();
        sendCoins(config.feeTreasury, payment.marketplaceFee, MARKETPLACE_FEE_COMMENT);
    }
    returnChange(
        storage.reserveChangeRecipient(),
        MIN_TONS_FOR_STORAGE + storage.automaticRecoveryBudget,
    );
}

fun finishWholeTonPayment(
    original: OfferEscrowStorage,
    terms: OfferEscrowTerms,
    parties: OfferEscrowParties,
    payment: PaymentTerms,
    takerSettlementWallet: address,
) {
    var storage = original;
    val items = lazy storage.items.load();
    var deposits = storage.deposits.load();

    storage.status = OfferEscrowStatus.Settled;
    storage.closedAt = blockchain.now();
    storage.automaticRecoveryBudget = automaticNftDeliveryRetryReserve(terms.makerItemCount);
    deposits.nftDeliveries.deliverDepositedTo(items.maker, takerSettlementWallet);
    storage.deposits = deposits.toCell();
    storage.settledTakerWallet = takerSettlementWallet;
    storage.save();

    if (payment.marketplaceFee > 0) {
        val config = lazy terms.config.load();
        sendCoins(config.feeTreasury, payment.marketplaceFee, MARKETPLACE_FEE_COMMENT);
    }
    sendCoins(
        parties.makerSettlementWallet,
        payment.amount - payment.marketplaceFee,
        SETTLEMENT_PAYMENT_COMMENT,
    );
    returnChange(
        storage.reserveChangeRecipient(),
        MIN_TONS_FOR_STORAGE + storage.automaticRecoveryBudget,
    );
}

fun applyUsdtDepositNotification(wallet: address, notification: JettonTransferNotification) {
    val payer = notification.transferInitiator;
    assert (payer != null) throw OfferEscrowErrors.InvalidMessage;
    refundJettonViaSender(wallet, payer, notification.jettonAmount);
}

fun applyUsdtDeposit(sender: address, depositCell: Cell<UsdtDepositTerms>) {
    authenticateUsdtDeposit(sender, depositCell);
    val deposit = depositCell.load();
    var storage = OfferEscrowStorage.load();
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
        storage.status == OfferEscrowStatus.CollectingMaker && payment.payer == OfferSide.Maker &&
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
        storage.status == OfferEscrowStatus.Open &&
        deposit.offerExecutionNumber == storage.offerExecutionNumber &&
        payment.payer == OfferSide.Taker &&
        terms.takerItemCount == 0 &&
        storage.areTermsValidated &&
        parties.addresseeWallets.allows(deposit.contributor) &&
        !parties.isMakerWallet(deposit.contributor)
    ) {
        val isFullPrincipal = deposit.purpose == UsdtDepositPurpose.Principal &&
            deposit.amount == payment.amount - payment.marketplaceFee;
        if (deposit.execution != null && isFullPrincipal) {
            if (
                !tryStartOfferExecutionFromUsdtCommitment(
                    deposit.contributor,
                    deposit.execution,
                )
            ) {
                return;
            }
            storage = OfferEscrowStorage.load();
        } else if (deposit.execution == null && isFullPrincipal) {
            storage.bindTaker(
                deposit.contributor,
                deposit.contributor,
                parties.addresseeWallets.isEmpty()
                    ? singleOfferWallet(deposit.contributor)
                    : parties.addresseeWallets,
                { total: 0, contributions: [] },
            );
        } else {
            return;
        }
    }
    val executionAttemptCell = storage.executionAttempt;
    if (
        storage.status != OfferEscrowStatus.CollectingTaker || payment.payer != OfferSide.Taker ||
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
    deposits.add(depositCell);
    storage.deposits.setUsdtDeposits(deposits);
    executionAttempt.deposits.total = deposits.principal + deposits.fee;
    storage.executionAttempt = executionAttempt.toCell();
    storage.save();
    settleIfReady(mutate storage);
}

fun depositSideFee(
    sender: address,
    msgValue: coins,
    offerExecutionNumber: uint32,
    reserveValue: coins = 0,
): bool {
    var storage = OfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    if (
        storage.status == OfferEscrowStatus.CollectingMaker && blockchain.now() <
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
        storage.save();
        return true;
    }

    val executionAttemptCell = storage.executionAttempt;
    if (storage.status == OfferEscrowStatus.CollectingTaker && executionAttemptCell != null) {
        var executionAttempt = executionAttemptCell.load();
        if (
            blockchain.now() < storage.expiresAt && blockchain.now() <
            executionAttempt.validUntil &&
            executionAttempt.number == offerExecutionNumber &&
            executionAttempt.confirmedContributorWallets.exists(sender) &&
            terms.takerTonFee > 0 &&
            executionAttempt.feePayer == null &&
            msgValue >= terms.takerTonFee
        ) {
            executionAttempt.feePayer = sender;
            storage.executionAttempt = executionAttempt.toCell();
            storage.save();
            settleIfReady(mutate storage);
            return true;
        }
    }
    refundTon(sender, storage.paymentRefundReason().comment());
    return false;
}

fun OfferEscrowStorage.recordMakerReservePayer(
    mutate self,
    sender: address,
    reserveValue: coins,
): bool {
    if (
        self.reserveRefundRecipient != null || reserveValue <= 0 ||
        (self.status != OfferEscrowStatus.CollectingMaker && self.status != OfferEscrowStatus.Open)
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

fun OfferEscrowStorage.reserveChangeRecipient(self): address {
    return self.reserveRefundRecipient == null
        ? self.terms.load().parties.load().makerSettlementWallet
        : self.reserveRefundRecipient;
}

fun depositEscrowReserve(sender: address, reserveValue: coins) {
    var storage = lazy OfferEscrowStorage.load();
    if (storage.isClosed()) {
        if (sender == contract.getAddress()) {
            return;
        }
        refundTon(sender, GAS_REFUND_COMMENT);
        return;
    }
    if (storage.recordMakerReservePayer(sender, reserveValue)) {
        storage.save();
    }
    if (storage.status == OfferEscrowStatus.CollectingMaker) {
        // До первого maker-депозита DepositEscrowReserve физически не может открыть canonical escrow. После
        // валидации terms этот путь используется, если для открытия не хватило reserve.
        if (storage.areTermsValidated && openIfMakerReady(mutate storage)) {
            storage.save();
        }
        return;
    }
    settleIfReady(mutate storage);
}

fun settleIfReady(mutate storage: OfferEscrowStorage) {
    if (storage.status != OfferEscrowStatus.CollectingTaker || !storage.areTermsValidated) {
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
    val terms = lazy storage.terms.load();
    val items = lazy storage.items.load();
    val progress = items.progress(terms.makerItemCount, terms.takerItemCount);
    val paymentCell = terms.payment;
    var takerPaymentReady = true;
    var paymentIsUsdt = false;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        takerPaymentReady = payment.payer != OfferSide.Taker ||
            executionAttempt.deposits.total == payment.amount;
        paymentIsUsdt = payment.asset == PaymentAsset.Usdt;
    }
    if (
        !progress.isValid || !progress.isTakerComplete || !takerPaymentReady ||
        (terms.takerTonFee > 0 && executionAttempt.feePayer == null)
    ) {
        return;
    }
    if (contract.getOriginalBalance() < storage.requiredSettlementBalance(true)) {
        return;
    }

    if (paymentIsUsdt) {
        startUsdtPayout(mutate storage);
        return;
    }
    finishSettlement(storage);
}

fun executionAttemptSettlementWallet(storage: OfferEscrowStorage): address {
    val executionAttempt = storage.executionAttempt;
    assert (executionAttempt != null) throw OfferEscrowErrors.InvalidTerms;
    return executionAttempt.load().takerSettlementWallet;
}

fun paymentRecipient(
    parties: OfferEscrowParties,
    payment: PaymentTerms,
    takerSettlementWallet: address,
): address {
    return payment.payer == OfferSide.Maker ? takerSettlementWallet : parties.makerSettlementWallet;
}

fun currentPaymentRecipient(storage: OfferEscrowStorage, payment: PaymentTerms): address {
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    return paymentRecipient(parties, payment, executionAttemptSettlementWallet(storage));
}

fun startUsdtPayout(mutate storage: OfferEscrowStorage) {
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    var deposits = storage.deposits.load().usdt;
    assert (
        deposits.count > 0 && deposits.principal == payment.amount - payment.marketplaceFee &&
        deposits.fee == payment.marketplaceFee
    ) throw OfferEscrowErrors.InvalidTerms;

    storage.status = OfferEscrowStatus.AwaitingPayoutConfirmation;
    storage.payoutQueryId = ((storage.offerExecutionNumber as uint64) << 32) + 1;
    storage.automaticRecoveryBudget = automaticUsdtSettlementRetryReserve(
        deposits.count,
        deposits.termsPayloadBits,
        deposits.termsPayloadCells,
    );
    deposits.assignRetryable(
        currentPaymentRecipient(storage, payment),
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
    var storage = OfferEscrowStorage.load();
    val deposit = depositCell.load();
    val isCommitting = storage.status == OfferEscrowStatus.AwaitingPayoutConfirmation ||
        storage.status == OfferEscrowStatus.PayoutConfirmed ||
        storage.status == OfferEscrowStatus.Settled;
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
            currentPaymentRecipient(storage, payment),
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
    var storage = OfferEscrowStorage.load();
    if (
        storage.status == OfferEscrowStatus.PayoutConfirmed ||
        storage.status == OfferEscrowStatus.Settled
    ) {
        return;
    }
    assert (
        storage.status == OfferEscrowStatus.AwaitingPayoutConfirmation
    ) throw OfferEscrowErrors.WrongPayoutConfirmation;
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    assert (
        beneficiary ==
        usdtDepositBeneficiary(
            depositCell.load(),
            currentPaymentRecipient(storage, payment),
            terms.config.load().feeTreasury,
        )
    ) throw OfferEscrowErrors.WrongPayoutConfirmation;
    var deposits = storage.deposits.load().usdt;
    deposits.confirmAssignment(sender, depositCell, holdingAttempt);
    storage.deposits.setUsdtDeposits(deposits);
    if (deposits.assignedCount == deposits.count) {
        storage.status = OfferEscrowStatus.PayoutConfirmed;
    }
    storage.save();
    if (storage.status == OfferEscrowStatus.PayoutConfirmed) {
        scheduleSettlementResume(storage.payoutQueryId);
    }
}

fun resolveUsdtDeposit(msgValue: coins, depositCell: Cell<UsdtDepositTerms>) {
    val deposit = depositCell.load();
    assert (
        deposit.escrow == contract.getAddress() && deposit.amount > 0
    ) throw UsdtDepositVaultErrors.InvalidTerms;
    assert (msgValue >= USDT_DEPOSIT_RESOLVE_VALUE) throw OfferEscrowErrors.NotEnoughValue;
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - msgValue),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    val storage = OfferEscrowStorage.load();
    val deposits = storage.deposits.load().usdt;
    val isRecorded = deposits.entries.exists(usdtDepositInit(depositCell).calculateAddress());
    val isCommitting = storage.status == OfferEscrowStatus.AwaitingPayoutConfirmation ||
        storage.status == OfferEscrowStatus.PayoutConfirmed ||
        storage.status == OfferEscrowStatus.Settled;
    if (isCommitting && isRecorded) {
        val terms = storage.terms.load();
        val payment = terms.payment!.load();
        restoreUsdtDepositAssignment(
            depositCell,
            usdtDepositBeneficiary(
                deposit,
                currentPaymentRecipient(storage, payment),
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
        body: ResumeSettlement { queryId },
    });
    resume.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun finishSettlement(original: OfferEscrowStorage) {
    finishSettlementTo(original, executionAttemptSettlementWallet(original));
}

fun finishSettlementTo(original: OfferEscrowStorage, takerSettlementWallet: address) {
    var storage = original;
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    val items = lazy storage.items.load();
    val paymentCell = terms.payment;
    var deposits = storage.deposits.load();

    storage.status = OfferEscrowStatus.Settled;
    storage.closedAt = blockchain.now();
    storage.automaticRecoveryBudget = automaticNftDeliveryRetryReserve(storage.totalItemCount());
    deposits.nftDeliveries.deliverDepositedTo(items.maker, takerSettlementWallet);
    deposits.nftDeliveries.deliverDepositedTo(items.taker, parties.makerSettlementWallet);
    storage.deposits = deposits.toCell();
    storage.settledTakerWallet = takerSettlementWallet;
    storage.save();

    var treasuryAmount = (terms.makerTonFee + terms.takerTonFee) as coins;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        if (payment.asset == PaymentAsset.Ton) {
            sendCoins(
                paymentRecipient(parties, payment, takerSettlementWallet),
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
        storage.reserveChangeRecipient(),
        paymentCell != null && paymentCell.load().asset == PaymentAsset.Usdt
            ? usdtRecoveryStorageReserve() + storage.automaticRecoveryBudget
            : MIN_TONS_FOR_STORAGE + storage.automaticRecoveryBudget,
    );
    commitContractDataAndActions();
}

// Получатель и сумма уже зафиксированы storage, поэтому продолжить расчёт может любой вызвавший.
// Caller оплачивает доставку сообщения, но не получает права изменить ни один параметр выплаты.
fun resumeSettlement(msgValue: coins) {
    var storage = OfferEscrowStorage.load();
    if (storage.status == OfferEscrowStatus.PayoutConfirmed) {
        finishSettlement(storage);
        return;
    }
    assert (
        storage.status == OfferEscrowStatus.AwaitingPayoutConfirmation
    ) throw OfferEscrowErrors.SettlementNotResumable;
    var deposits = storage.deposits.load().usdt;
    val retryableCount = deposits.retryableAssignmentCount(false);
    assert (retryableCount > 0) throw OfferEscrowErrors.SettlementNotResumable;
    val requiredValue = USDT_DEPOSIT_ASSIGN_VALUE * retryableCount +
        executionCost(GAS_ESCROW_SETTLEMENT, retryableCount);
    assert (msgValue >= requiredValue) throw OfferEscrowErrors.NotEnoughValue;
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - msgValue),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    deposits.assignRetryable(
        currentPaymentRecipient(storage, payment),
        terms.config.load().feeTreasury,
        false,
    );
    storage.deposits.setUsdtDeposits(deposits);
    storage.save();
}

@inline
fun OfferEscrowStorage.assertMayExternallyResumeSettlement(
    self,
    expectedOfferId: uint128,
    expectedPayoutQueryId: uint64,
    vault: address,
) {
    assert (
        self.terms.load().offerId == expectedOfferId && self.payoutQueryId == expectedPayoutQueryId
    ) throw OfferEscrowErrors.InvalidTerms;
    val deposit = self.deposits.load().usdt.entries.get(vault);
    assert (deposit.isFound) throw OfferEscrowErrors.InvalidTerms;
    if (self.status == OfferEscrowStatus.PayoutConfirmed) {
        assertExternalTransitionReserve(
            self.terms,
            self.deposits,
            self.automaticRecoveryBudget,
            self.executionAttempt,
            self.status,
            false,
        );
        return;
    }
    assert (
        self.status == OfferEscrowStatus.AwaitingPayoutConfirmation
    ) throw OfferEscrowErrors.SettlementNotResumable;
    val record = deposit.loadValue();
    assert (record.isRetryable(true)) throw OfferEscrowErrors.AutomaticRecoveryUnavailable;
    assert (
        self.automaticRecoveryBudget >=
        automaticUsdtSettlementRetryReserve(
            1,
            record.termsPayloadBits,
            record.termsPayloadCells,
        ) &&
        contract.getOriginalBalance() >= self.automaticRecoveryBudget + self.externalPaidTonFees()
    ) throw OfferEscrowErrors.AutomaticRecoveryUnavailable;
}

fun resumeSettlementFromReserve(original: OfferEscrowStorage, vault: address) {
    var storage = original;
    if (storage.status == OfferEscrowStatus.PayoutConfirmed) {
        finishSettlement(storage);
        return;
    }
    val retriedDeposit = storage.deposits.load().usdt.entries.get(vault).loadValue();
    val retryBudget = automaticUsdtSettlementRetryReserve(
        1,
        retriedDeposit.termsPayloadBits,
        retriedDeposit.termsPayloadCells,
    );
    reserveGramsOnBalance(
        max(0, contract.getOriginalBalance() - storage.automaticRecoveryBudget),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    storage.automaticRecoveryBudget -= retryBudget;
    val terms = storage.terms.load();
    val payment = terms.payment!.load();
    var deposits = storage.deposits.load().usdt;
    deposits.assignOne(
        vault,
        currentPaymentRecipient(storage, payment),
        terms.config.load().feeTreasury,
        true,
    );
    storage.deposits.setUsdtDeposits(deposits);
    storage.save();
}

fun releaseOfferExecutionAttempt(sender: address, expectedNumber: uint32) {
    val storage = lazy OfferEscrowStorage.load();
    assert (storage.status == OfferEscrowStatus.CollectingTaker) throw OfferEscrowErrors.NotOpen;
    assert (
        expectedNumber == storage.offerExecutionNumber
    ) throw OfferEscrowErrors.ExecutionAttemptMoved;
    assert (blockchain.now() < storage.expiresAt) throw OfferEscrowErrors.OfferExpired;

    val executionAttemptCell = storage.executionAttempt;
    assert (executionAttemptCell != null) throw OfferEscrowErrors.NotOpen;
    val executionAttempt = lazy executionAttemptCell.load();
    if (blockchain.now() < executionAttempt.validUntil) {
        assert (
            executionAttempt.confirmedContributorWallets.exists(sender)
        ) throw OfferEscrowErrors.NotAllowedToRelease;
    }
    assert (
        storage.offerExecutionNumber < 0xFFFFFFFF
    ) throw OfferEscrowErrors.OfferExecutionNumberExhausted;

    releaseCurrentExecutionAttempt(storage);
}

fun OfferEscrowStorage.assertMayExternallyReleaseExecution(
    self,
    expectedOfferId: uint128,
    expectedNumber: uint32,
) {
    assert (self.terms.load().offerId == expectedOfferId) throw OfferEscrowErrors.InvalidTerms;
    assert (self.status == OfferEscrowStatus.CollectingTaker) throw OfferEscrowErrors.NotOpen;
    assert (
        expectedNumber == self.offerExecutionNumber
    ) throw OfferEscrowErrors.ExecutionAttemptMoved;
    assert (blockchain.now() < self.expiresAt) throw OfferEscrowErrors.OfferExpired;
    assert (
        self.offerExecutionNumber < 0xFFFFFFFF
    ) throw OfferEscrowErrors.OfferExecutionNumberExhausted;
    val executionAttempt = self.executionAttempt;
    assert (executionAttempt != null) throw OfferEscrowErrors.NotOpen;
    assert (
        blockchain.now() >= executionAttempt.load().validUntil
    ) throw OfferEscrowErrors.NotAllowedToRelease;
}

fun releaseCurrentExecutionAttempt(original: OfferEscrowStorage) {
    var storage = original;
    val executionAttemptCell = storage.executionAttempt;
    // Оба entrypoint доказывают наличие execution attempt до общего перехода.
    assert (executionAttemptCell != null) throw OfferEscrowErrors.NotOpen;
    val executionAttempt = lazy executionAttemptCell.load();

    val releasedStorage = storage;
    var items = storage.items.load();
    var deposits = storage.deposits.load();
    deposits.nftDeliveries.returnDeposits(items.taker, RefundReason.ExecutionExpired);
    items.taker = items.takerTemplate;
    storage.deposits = deposits.toCell();
    storage.items = items.toCell();
    storage.status = OfferEscrowStatus.Open;
    storage.offerExecutionNumber += 1;
    storage.executionAttempt = null;
    val payment = storage.terms.load().payment;
    if (payment != null && payment.load().payer == OfferSide.Taker) {
        storage.deposits.setUsdtDeposits(UsdtDeposits {});
    }
    storage.save();
    var nativeRefunds: MoneyContributions = [];
    collectExecutionAttemptMoneyRefunds(
        releasedStorage.terms,
        deposits.usdt,
        executionAttempt,
        mutate nativeRefunds,
        RefundReason.ExecutionExpired,
    );
    refundNativeContributions(nativeRefunds, RefundReason.ExecutionExpired);
}

fun collectExecutionAttemptMoneyRefunds(
    termsCell: Cell<OfferEscrowTerms>,
    usdtDeposits: UsdtDeposits,
    executionAttempt: OfferExecutionAttempt,
    mutate nativeRefunds: MoneyContributions,
    reason: RefundReason,
) {
    val terms = lazy termsCell.load();
    val paymentCell = terms.payment;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        if (payment.payer == OfferSide.Taker && executionAttempt.deposits.total > 0) {
            if (payment.asset == PaymentAsset.Usdt) {
                usdtDeposits.refund(reason);
            } else {
                nativeRefunds.addAll(executionAttempt.deposits.contributions);
            }
        }
    }
    if (executionAttempt.feePayer != null && terms.takerTonFee > 0) {
        nativeRefunds.add(executionAttempt.feePayer, terms.takerTonFee);
    }
}

fun cancelOffer(sender: address) {
    val storage = lazy OfferEscrowStorage.load();
    val terms = lazy storage.terms.load();
    val parties = lazy terms.parties.load();
    assert (parties.makerWallets.exists(sender)) throw OfferEscrowErrors.NotMaker;
    storage.assertMayCancel();
    closeOffer(storage, OfferEscrowStatus.Cancelled);
}

@inline
fun OfferEscrowStorage.assertMakerCancellation(
    self,
    signature: bits512,
    signed: Cell<TonConnectMakerCancellation>,
) {
    assertMakerCancellationForTerms(self.terms, signature, signed);
}

@inline
fun assertMakerCancellationForTerms(
    termsCell: Cell<OfferEscrowTerms>,
    signature: bits512,
    signed: Cell<TonConnectMakerCancellation>,
) {
    val terms = lazy termsCell.load();
    val parties = lazy terms.parties.load();
    val policy = parties.makerCancellation;
    assert (policy != null) throw OfferEscrowErrors.MakerCancellationUnavailable;
    assert (
        policy.load().accepts(signature, signed, terms.offerId)
    ) throw OfferEscrowErrors.InvalidMakerCancellation;
}

@inline
fun OfferEscrowStorage.assertMayCancel(self) {
    assertMayCancelStatus(self.status);
}

@inline
fun assertMayCancelStatus(status: OfferEscrowStatus) {
    assert (!status.isClosed()) throw OfferEscrowErrors.AlreadyClosed;
    assert (
        status != OfferEscrowStatus.AwaitingPayoutConfirmation &&
        status != OfferEscrowStatus.PayoutFailed &&
        status != OfferEscrowStatus.PayoutConfirmed
    ) throw OfferEscrowErrors.SettlementInProgress;
}

fun expireOffer() {
    val storage = lazy OfferEscrowStorage.load();
    storage.assertMayExpire();
    closeOffer(storage, OfferEscrowStatus.Expired);
}

fun OfferEscrowStorage.assertMayExpire(self) {
    assert (!self.isClosed()) throw OfferEscrowErrors.AlreadyClosed;
    assert (blockchain.now() >= self.expiresAt) throw OfferEscrowErrors.OfferNotExpired;
    assert (
        self.status != OfferEscrowStatus.AwaitingPayoutConfirmation &&
        self.status != OfferEscrowStatus.PayoutFailed &&
        self.status != OfferEscrowStatus.PayoutConfirmed
    ) throw OfferEscrowErrors.SettlementInProgress;
}

fun OfferEscrowStorage.assertMayExternallyExpire(
    self,
    expectedOfferId: uint128,
    expectedExpiresAt: uint32,
) {
    assert (
        self.terms.load().offerId == expectedOfferId && self.expiresAt == expectedExpiresAt
    ) throw OfferEscrowErrors.InvalidTerms;
    self.assertMayExpire();
}

fun closeOffer(original: OfferEscrowStorage, closedAs: OfferEscrowStatus) {
    var storage = original;
    val reason = closedAs == OfferEscrowStatus.Expired
        ? RefundReason.OfferExpired
        : RefundReason.OfferCancelled;
    val terms = lazy storage.terms.load();
    val items = lazy storage.items.load();
    val paymentCell = terms.payment;
    val executionAttempt = storage.executionAttempt;
    var deposits = storage.deposits.load();

    storage.status = closedAs;
    storage.closedAt = blockchain.now();
    val deliveryCount = deposits.nftDeliveries.returnEachToItsDepositor(items.maker, reason) +
        deposits.nftDeliveries.returnEachToItsDepositor(items.taker, reason);
    storage.automaticRecoveryBudget = automaticNftDeliveryRetryReserve(
        deliveryCount,
    );
    storage.deposits = deposits.toCell();
    storage.save();

    var nativeRefunds: MoneyContributions = [];
    val makerFeePayer = deposits.makerFeePayer;
    if (makerFeePayer != null && terms.makerTonFee > 0) {
        nativeRefunds.add(makerFeePayer, terms.makerTonFee);
    }
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        if (payment.payer == OfferSide.Maker && deposits.maker.total > 0) {
            if (payment.asset == PaymentAsset.Usdt) {
                deposits.usdt.refund(reason);
            } else {
                nativeRefunds.addAll(deposits.maker.contributions);
            }
        }
    }
    if (executionAttempt != null) {
        collectExecutionAttemptMoneyRefunds(
            storage.terms,
            deposits.usdt,
            executionAttempt.load(),
            mutate nativeRefunds,
            reason,
        );
    }
    refundNativeContributions(nativeRefunds, reason);
    returnChange(
        storage.reserveChangeRecipient(),
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

fun nftRecoveryRecipient(storage: OfferEscrowStorage, nft: address): address? {
    val items = lazy storage.items.load();
    val makerDepositor = depositedBy(items.maker, nft);
    if (makerDepositor != null) {
        if (!storage.isClosed()) {
            return null;
        }
        if (storage.status != OfferEscrowStatus.Settled) {
            return makerDepositor;
        }
        return storage.settledTakerWallet;
    }

    val takerDepositor = depositedBy(items.taker, nft);
    if (takerDepositor != null) {
        if (!storage.isClosed()) {
            return null;
        }
        val parties = lazy storage.terms.load().parties.load();
        return storage.status == OfferEscrowStatus.Settled
            ? parties.makerSettlementWallet
            : takerDepositor;
    }
    val refund = storage.deposits.load().nftDeliveries.get(nft);
    return refund.isFound ? refund.loadValue().recipient : null;
}

fun retryNftDelivery(sender: address, msgValue: coins, nft: address) {
    var storage = lazy OfferEscrowStorage.load();
    var deposits = storage.deposits.load();
    val deliveryEntry = deposits.nftDeliveries.get(nft);
    var delivery: NftDelivery;
    if (deliveryEntry.isFound) {
        delivery = deliveryEntry.loadValue();
        assert (
            delivery.status == NftDeliveryStatus.Failed
        ) throw OfferEscrowErrors.NftDeliveryPending;
    } else {
        // После подтверждённой доставки запись удаляется, но commitment остаётся. Случайный
        // повторный deposit без notification возвращаем только на прежний разрешённый адрес.
        val recipient = nftRecoveryRecipient(storage, nft);
        assert (recipient != null) throw OfferEscrowErrors.NotRecoverableNft;
        delivery = {
            recipient,
            queryId: 0,
            comment: storage.status == OfferEscrowStatus.Settled
                ? null
                : TextComment { text: storage.paymentRefundReason().comment() }.toCell(),
        };
    }
    assert (msgValue >= requiredNftRetryValue()) throw OfferEscrowErrors.NotEnoughValue;
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

fun OfferEscrowStorage.assertMayExternallyRetryNftDelivery(
    self,
    expectedOfferId: uint128,
    nft: address,
    expectedDeliveryQueryId: uint64,
) {
    assert (self.terms.load().offerId == expectedOfferId) throw OfferEscrowErrors.InvalidTerms;
    assert (self.isClosed()) throw OfferEscrowErrors.NotClosed;
    val delivery = self.deposits.load().nftDeliveries.get(nft);
    assert (delivery.isFound) throw OfferEscrowErrors.NotRecoverableNft;
    val pending = delivery.loadValue();
    assert (
        pending.queryId == expectedDeliveryQueryId && pending.status == NftDeliveryStatus.Failed &&
        !pending.hasReceipt &&
        pending.automaticAttempts <
        MAX_AUTOMATIC_NFT_DELIVERY_ATTEMPTS
    ) throw OfferEscrowErrors.AutomaticRecoveryUnavailable;
    val retryBudget = requiredNftRetryValue();
    assert (
        self.automaticRecoveryBudget >= retryBudget &&
        contract.getOriginalBalance() >= self.automaticRecoveryBudget + self.externalPaidTonFees()
    ) throw OfferEscrowErrors.AutomaticRecoveryUnavailable;
}

fun retryNftDeliveryFromReserve(original: OfferEscrowStorage, nft: address) {
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
    var storage = OfferEscrowStorage.load();
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
    var storage = OfferEscrowStorage.load();
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
            storage.reserveChangeRecipient(),
            closedEscrowStorageReserve(storage) + storage.automaticRecoveryBudget,
        );
    } else if (pending.sponsor != null) {
        refundTon(pending.sponsor, GAS_REFUND_COMMENT);
    }
}

fun closedEscrowStorageReserve(storage: OfferEscrowStorage): coins {
    val terms = lazy storage.terms.load();
    val payment = terms.payment;
    return payment != null && payment.load().asset == PaymentAsset.Usdt
        ? usdtRecoveryStorageReserve()
        : MIN_TONS_FOR_STORAGE;
}

fun failNftDelivery(nft: address, queryId: uint64) {
    var storage = OfferEscrowStorage.load();
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
            storage.reserveChangeRecipient(),
            closedEscrowStorageReserve(storage) + storage.automaticRecoveryBudget,
        );
    }
}

fun confirmNftDeliveryReceipt(sender: address, nft: address) {
    var storage = OfferEscrowStorage.load();
    var deposits = storage.deposits.load();
    val refund = deposits.nftDeliveries.get(nft);
    assert (refund.isFound) throw OfferEscrowErrors.NotRecoverableNft;
    assert (sender == refund.loadValue().recipient) throw OfferEscrowErrors.NotNftDeliveryRecipient;
    assert (
        refund.loadValue().status == NftDeliveryStatus.Failed
    ) throw OfferEscrowErrors.NftDeliveryPending;
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
    var storage = lazy OfferEscrowStorage.load();
    val config = lazy storage.terms.load().config.load();
    assert (
        sender == config.unexpectedNftRecoveryAuthority
    ) throw OfferEscrowErrors.NotUnexpectedNftRecoveryAuthority;
    assert (storage.isClosed()) throw OfferEscrowErrors.NotClosed;
    assert (
        storage.closedAt > 0 && blockchain.now() >= storage.closedAt + UNEXPECTED_NFT_RECOVERY_DELAY
    ) throw OfferEscrowErrors.UnexpectedNftRecoveryLocked;
    assert (
        recoveryId > storage.lastUnexpectedNftRecoveryId
    ) throw OfferEscrowErrors.RecoveryReplay;
    assert (msgValue >= requiredNftRetryValue()) throw OfferEscrowErrors.NotEnoughValue;

    val items = lazy storage.items.load();
    assert (
        !items.maker.exists(nft) && !items.taker.exists(nft) &&
        !storage.deposits.load().nftDeliveries.exists(nft)
    ) throw OfferEscrowErrors.NftAlreadyRecorded;

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
    val storage = OfferEscrowStorage.load();
    val refund = storage.deposits.load().nftDeliveries.get(in.senderAddress);
    if (!refund.isFound || queryId == 0 || refund.loadValue().queryId != queryId) {
        return;
    }
    failNftDelivery(in.senderAddress, queryId);
}

fun failUsdtDepositAssignment(vault: address) {
    var storage = OfferEscrowStorage.load();
    if (storage.status != OfferEscrowStatus.AwaitingPayoutConfirmation) {
        return;
    }
    var deposits = storage.deposits.load().usdt;
    deposits.failAssignment(vault);
    storage.deposits.setUsdtDeposits(deposits);
    storage.save();
}

get fun status(): OfferEscrowStatus {
    return OfferEscrowStorage.load().status;
}

get fun nft_deliveries(): NftDeliveries {
    return OfferEscrowStorage.load().deposits.load().nftDeliveries;
}

get fun nft_recovery_recipient(nft: address): address? {
    return nftRecoveryRecipient(OfferEscrowStorage.load(), nft);
}

get fun offer_id(): int {
    return OfferEscrowStorage.load().terms.load().offerId;
}

get fun offer_execution_number(): int {
    return OfferEscrowStorage.load().offerExecutionNumber;
}

get fun execution_attempt(): OfferExecutionAttempt? {
    val executionAttempt = OfferEscrowStorage.load().executionAttempt;
    return executionAttempt == null ? null : executionAttempt.load();
}

get fun items(): OfferEscrowItems {
    return OfferEscrowStorage.load().items.load();
}

get fun required_maker_balance(): coins {
    return OfferEscrowStorage.load().requiredSettlementBalance(false);
}

get fun usdt_wallet(): address {
    return deriveUsdtWalletFor(contract.getAddress());
}

get fun usdt_deposits(): UsdtDeposits {
    return OfferEscrowStorage.load().deposits.load().usdt;
}

get fun usdt_recovery_storage_reserve(): coins {
    return usdtRecoveryStorageReserve();
}

// Paid side fees are still obligations while USDT payout is pending, never automatic retry gas.
fun OfferEscrowStorage.externalPaidTonFees(self): coins {
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
        : terms.takerTonFee;
    return makerFee + takerFee;
}

// Conservative O(1) bound includes both returned and retained maker obligations. An underfunded
// partial lot uses the caller-funded internal path; no principal/fee pays for an external failure.
@inline
fun assertExternalTransitionReserve(
    termsCell: Cell<OfferEscrowTerms>,
    depositsCell: Cell<OfferEscrowDeposits>,
    automaticBudget: coins,
    executionAttemptCell: Cell<OfferExecutionAttempt>?,
    status: OfferEscrowStatus,
    assignsUsdt: bool,
) {
    val terms = lazy termsCell.load();
    val deposits = lazy depositsCell.load();
    val nftCount = (terms.makerItemCount + terms.takerItemCount) as int;
    var nativePrincipal = grams("0") as coins;
    val paymentCell = terms.payment;
    var paymentAsset = -1;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        paymentAsset = payment.asset as int;
    }
    if (paymentAsset == (PaymentAsset.Ton as int)) {
        nativePrincipal = deposits.maker.total;
    }
    val makerFee = terms.makerTonFee == 0 || deposits.makerFeePayer == null
        ? (grams("0") as coins)
        : terms.makerTonFee;
    var takerFee = grams("0") as coins;
    val attemptCell = executionAttemptCell;
    if (
        attemptCell != null && (paymentAsset == (PaymentAsset.Ton as int) || terms.takerTonFee > 0)
    ) {
        val attempt = lazy attemptCell.load();
        if (paymentAsset == (PaymentAsset.Ton as int)) {
            nativePrincipal += attempt.deposits.total;
        }
        takerFee = terms.takerTonFee == 0 || attempt.feePayer == null
            ? (grams("0") as coins)
            : terms.takerTonFee;
    }
    var required = grams("0") as coins;
    if (paymentAsset == (PaymentAsset.Usdt as int) && status != OfferEscrowStatus.PayoutConfirmed) {
        val usdt = deposits.usdt;
        required = requiredExternalEscrowBalance(
            nativePrincipal + makerFee + takerFee,
            automaticBudget,
            nftCount,
            usdt.count,
            assignsUsdt,
            usdt.termsPayloadBits,
            usdt.termsPayloadCells,
        );
    } else {
        // Literal zero keeps USDT payload decoding and fee accounting out of the native gas
        // credit path. The same canonical formula still prices every transition.
        required = requiredExternalEscrowBalance(
            nativePrincipal + makerFee + takerFee,
            automaticBudget,
            nftCount,
            0,
            assignsUsdt,
            0,
            0,
        );
    }
    assert (
        contract.getOriginalBalance() >= required
    ) throw OfferEscrowErrors.AutomaticRecoveryUnavailable;
}

// Keep the eager transition decode behind ACCEPT; automatic inlining would move its loads into
// the same validation scope and exhaust gas_credit on a signed maximal-lot cancellation.
@noinline
fun closeExternallyVerifiedOffer(closedAs: OfferEscrowStatus) {
    closeOffer(OfferEscrowStorage.load(), closedAs);
}
