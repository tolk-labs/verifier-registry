import "@contracts/common/gas/constants"
import "@contracts/common/gas/costs"
import "@contracts/common/nft/constants"
import "@contracts/common/nft/deposits"
import "@contracts/common/nft/transfers"
import "@contracts/common/offer/deposits"
import "@contracts/common/offer/enums"
import "@contracts/common/offer/terms"
import "@contracts/common/offer/wallets"
import "@contracts/common/usdt/network_constants"
import "constants"
import "enums"

struct DeliveryCommitment {
    itemCount: uint16
    hash: uint256
}

// Exact taker NFT перечислены здесь и поэтому не могут быть заменены certifier. Commitment
// разрешает подписи лишь для конкретизации оставшейся criterion/provider-delivery части.
struct CertifiedOfferPolicy {
    fixedTakerItems: ItemDeposits = []
    makerDelivery: Cell<DeliveryCommitment>?
    takerRequirementCommitment: uint256
    finalizationPolicy: FinalizationPolicy = FinalizationPolicy.Revocable
    custodiedCancellationByCertifier: bool = false
}

struct CertifiedOfferTerms {
    offerId: uint128
    makerItemCount: uint16
    takerItemCount: uint16
    parties: Cell<OfferEscrowParties>
    payment: Cell<PaymentTerms>?
    makerTonFee: coins
    // Максимум сбора участника; точный сбор фиксируется подписанным execution schema v3.
    takerTonFee: coins = grams("0")
    policy: Cell<CertifiedOfferPolicy>
    config: Cell<EscrowConfig>
}

struct CertifiedExecutionAttemptDetails {
    contributorWallets: OfferWallets
    takerSettlementWallet: address
    items: ItemDeposits = []
    delivery: Cell<DeliveryCommitment>?
    executionAgreementId: uint128? = null
    // Точный сбор подписан для выбранного состава; terms.takerTonFee ограничивает его сверху.
    takerTonFee: coins
}

struct CertifiedOfferExecutionAttempt {
    feePayer: address? = null
    excessRecipient: address? = null
    number: uint32
    certificateHash: uint256
    validUntil: uint32
    confirmedContributorWallets: OfferWallets
    deposits: PaymentDeposits
    details: Cell<CertifiedExecutionAttemptDetails>
}

struct CertifiedOfferEscrowStorage {
    status: CertifiedOfferEscrowStatus
    expiresAt: uint32
    executionAttemptTtl: uint32
    deposits: Cell<OfferEscrowDeposits>
    offerExecutionNumber: uint32
    payoutQueryId: uint64
    closedAt: uint32 = 0
    lastUnexpectedNftRecoveryId: uint64 = 0
    automaticRecoveryBudget: coins = grams("0")
    certifierPublicKey: uint256
    terms: Cell<CertifiedOfferTerms>
    makerItems: ItemDeposits = []
    executionAttempt: Cell<CertifiedOfferExecutionAttempt>?
    reserveRefundRecipient: address? = null
}

fun CertifiedOfferEscrowStorage.load(): CertifiedOfferEscrowStorage {
    return CertifiedOfferEscrowStorage.fromCell(contract.getData());
}

fun CertifiedOfferEscrowStorage.save(self) {
    contract.setData(self.toCell());
}

@inline
fun CertifiedOfferEscrowStorage.isClosed(self): bool {
    return self.status.isClosed();
}

@inline
fun CertifiedOfferEscrowStatus.isClosed(self): bool {
    return self == CertifiedOfferEscrowStatus.Settled ||
        self == CertifiedOfferEscrowStatus.Cancelled ||
        self == CertifiedOfferEscrowStatus.Expired;
}

fun CertifiedOfferEscrowStorage.maximumOnchainItemCount(self): int {
    val makerOnchainItems = self.makerItems.progressWithin(MAX_CERTIFIED_OFFER_ITEMS).promisedCount;
    val executionAttempt = self.executionAttempt;
    if (executionAttempt != null) {
        val takerOnchainItems = executionAttempt
            .load()
            .details
            .load()
            .items
            .progressWithin(MAX_CERTIFIED_OFFER_ITEMS)
            .promisedCount;
        return makerOnchainItems + takerOnchainItems;
    }

    // До execution taker ещё ничего не внёс, поэтому maker не должен авансировать его будущие
    // NFT transfers. После certificate точный on-chain набор берётся из executionAttempt, а каждый
    // NFT deposit приносит собственный transfer reserve входящим сообщением.
    return makerOnchainItems;
}

// До выбора экземпляров резерв оценивается сверху; принятое исполнение хранит точную сумму.
fun CertifiedOfferEscrowStorage.executionTakerTonFee(self): coins {
    val attempt = self.executionAttempt;
    return attempt == null
        ? self.terms.load().takerTonFee
        : attempt.load().details.load().takerTonFee;
}

fun CertifiedOfferEscrowStorage.requiredSettlementBalance(self, includeTakerPayment: bool): coins {
    val payment = self.terms.load().payment;
    val hasJettonMessages = payment != null && payment.load().asset == PaymentAsset.Usdt &&
        (payment.load().marketplaceFee > 0 || self.deposits.load().usdt.count > 0);
    val storageReserve = hasJettonMessages ? usdtRecoveryStorageReserve() : MIN_TONS_FOR_STORAGE;
    return self.requiredExecutionBalance(includeTakerPayment) + storageReserve;
}

fun CertifiedOfferEscrowStorage.requiredExecutionBalance(self, includeTakerPayment: bool): coins {
    val terms = lazy self.terms.load();
    val paymentCell = terms.payment;
    var makerTon = grams("0") as coins;
    var takerTon = grams("0") as coins;
    var jettonMessages = 0;
    if (paymentCell != null) {
        val payment = lazy paymentCell.load();
        makerTon = payment.asset == PaymentAsset.Ton && payment.payer == OfferSide.Maker
            ? payment.amount
            : (grams("0") as coins);
        takerTon = includeTakerPayment && payment.asset == PaymentAsset.Ton &&
            payment.payer == OfferSide.Taker
            ? payment.amount
            : (grams("0") as coins);
        jettonMessages = payment.asset == PaymentAsset.Usdt
            ? max(self.deposits.load().usdt.count, payment.marketplaceFee > 0 ? 2 : 1)
            : 0;
    }

    val maximumOnchainItems = self.maximumOnchainItemCount();
    return (makerTon + takerTon + terms.makerTonFee +
        (includeTakerPayment ? self.executionTakerTonFee() : (grams("0") as coins)) +
        NFT_TRANSFER_VALUE * maximumOnchainItems +
        automaticNftDeliveryRetryReserve(maximumOnchainItems) +
        USDT_DEPOSIT_ASSIGN_VALUE * jettonMessages +
        automaticUsdtSettlementRetryReserve(
            jettonMessages,
            self.deposits.load().usdt.termsPayloadBits,
            self.deposits.load().usdt.termsPayloadCells,
        ) +
        escrowSettlementFees(maximumOnchainItems)) as coins;
}

fun CertifiedOfferEscrowStorage.requiredUsdtSettlementFinalizationBalance(self): coins {
    val terms = lazy self.terms.load();
    val itemCount = self.maximumOnchainItemCount();
    return (terms.makerTonFee + self.executionTakerTonFee() + NFT_TRANSFER_VALUE * itemCount +
        automaticNftDeliveryRetryReserve(itemCount) +
        escrowSettlementFees(itemCount) +
        usdtRecoveryStorageReserve()) as coins;
}
