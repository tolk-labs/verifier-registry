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

struct OfferEscrowItems {
    maker: ItemDeposits = []
    taker: ItemDeposits = []
    // Снимок до первого депозита: release восстанавливает карту за O(1), сохраняя обещанные ключи.
    takerTemplate: ItemDeposits = []
}

struct OfferEscrowTerms {
    offerId: uint128
    makerItemCount: uint16
    takerItemCount: uint16
    parties: Cell<OfferEscrowParties>
    payment: Cell<PaymentTerms>?
    makerTonFee: coins
    takerTonFee: coins = grams("0")
    config: Cell<EscrowConfig>
}

struct OfferExecutionAttempt {
    feePayer: address? = null
    number: uint32
    allowedContributorWallets: OfferWallets
    confirmedContributorWallets: OfferWallets
    takerSettlementWallet: address
    validUntil: uint32
    deposits: PaymentDeposits
}

struct OfferEscrowStorage {
    status: OfferEscrowStatus
    areTermsValidated: bool = false
    expiresAt: uint32
    executionAttemptTtl: uint32
    deposits: Cell<OfferEscrowDeposits>
    offerExecutionNumber: uint32
    payoutQueryId: uint64
    closedAt: uint32 = 0
    lastUnexpectedNftRecoveryId: uint64 = 0
    automaticRecoveryBudget: coins = grams("0")
    settledTakerWallet: address? = null
    terms: Cell<OfferEscrowTerms>
    items: Cell<OfferEscrowItems>
    executionAttempt: Cell<OfferExecutionAttempt>?
    reserveRefundRecipient: address? = null
}

struct OfferItemProgress {
    isValid: bool
    isMakerComplete: bool
    isTakerComplete: bool
}

// Оба map проверяются одним ограниченным проходом. Проверка пересечения встроена в проход maker-
// стороны, поэтому финальный депозит не оплачивает третий обход только ради shape validation.
fun OfferEscrowItems.progress(
    self,
    expectedMaker: int,
    expectedTaker: int,
): OfferItemProgress {
    if (
        expectedMaker < 0 || expectedTaker < 0 || expectedMaker + expectedTaker <= 0 ||
        expectedMaker + expectedTaker > MAX_OFFER_ESCROW_ITEMS
    ) {
        return {
            isValid: false,
            isMakerComplete: false,
            isTakerComplete: false,
        };
    }

    var makerPromised = 0;
    var makerDeposited = 0;
    var makerEntry = self.maker.findFirst();
    while (makerEntry.isFound) {
        makerPromised += 1;
        if (makerPromised > expectedMaker || self.taker.get(makerEntry.getKey()).isFound) {
            return {
                isValid: false,
                isMakerComplete: false,
                isTakerComplete: false,
            };
        }
        if (makerEntry.loadValue().isDeposited()) {
            makerDeposited += 1;
        }
        makerEntry = self.maker.iterateNext(makerEntry);
    }

    var takerPromised = 0;
    var takerDeposited = 0;
    var takerEntry = self.taker.findFirst();
    while (takerEntry.isFound) {
        takerPromised += 1;
        if (takerPromised > expectedTaker) {
            return {
                isValid: false,
                isMakerComplete: false,
                isTakerComplete: false,
            };
        }
        if (takerEntry.loadValue().isDeposited()) {
            takerDeposited += 1;
        }
        takerEntry = self.taker.iterateNext(takerEntry);
    }

    val isValid = makerPromised == expectedMaker && takerPromised == expectedTaker;
    return {
        isValid,
        isMakerComplete: isValid && makerDeposited == makerPromised,
        isTakerComplete: isValid && takerDeposited == takerPromised,
    };
}

fun OfferEscrowStorage.load(): OfferEscrowStorage {
    return OfferEscrowStorage.fromCell(contract.getData());
}

fun OfferEscrowStorage.save(self) {
    contract.setData(self.toCell());
}

@inline
fun OfferEscrowStorage.isClosed(self): bool {
    return self.status.isClosed();
}

@inline
fun OfferEscrowStatus.isClosed(self): bool {
    return self == OfferEscrowStatus.Settled || self == OfferEscrowStatus.Cancelled ||
        self == OfferEscrowStatus.Expired;
}

fun OfferEscrowStorage.totalItemCount(self): int {
    val terms = lazy self.terms.load();
    return terms.makerItemCount + terms.takerItemCount;
}

fun OfferEscrowStorage.requiredSettlementBalance(self, includeTakerPayment: bool): coins {
    val payment = self.terms.load().payment;
    val hasJettonMessages = payment != null && payment.load().asset == PaymentAsset.Usdt &&
        (payment.load().marketplaceFee > 0 || self.deposits.load().usdt.count > 0);
    val storageReserve = hasJettonMessages ? usdtRecoveryStorageReserve() : MIN_TONS_FOR_STORAGE;
    return self.requiredExecutionBalance(includeTakerPayment) + storageReserve;
}

fun OfferEscrowStorage.requiredExecutionBalance(self, includeTakerPayment: bool): coins {
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
    val itemCount = self.totalItemCount();

    return (makerTon + takerTon + terms.makerTonFee +
        (includeTakerPayment ? terms.takerTonFee : (grams("0") as coins)) +
        NFT_TRANSFER_VALUE * itemCount +
        automaticNftDeliveryRetryReserve(itemCount) +
        USDT_DEPOSIT_ASSIGN_VALUE * jettonMessages +
        automaticUsdtSettlementRetryReserve(
            jettonMessages,
            self.deposits.load().usdt.termsPayloadBits,
            self.deposits.load().usdt.termsPayloadCells,
        ) +
        escrowSettlementFees(itemCount)) as coins;
}

fun OfferEscrowStorage.requiredUsdtSettlementFinalizationBalance(self): coins {
    val terms = lazy self.terms.load();
    val itemCount = self.totalItemCount();
    return (terms.makerTonFee + terms.takerTonFee + NFT_TRANSFER_VALUE * itemCount +
        automaticNftDeliveryRetryReserve(itemCount) +
        escrowSettlementFees(itemCount) +
        usdtRecoveryStorageReserve()) as coins;
}
