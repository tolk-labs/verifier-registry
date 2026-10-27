import "@contracts/common/maker_cancellation/authorization"
import "enums"
import "wallets"

struct OfferEscrowParties {
    makerWallets: OfferWallets
    // Только получатель: не обязан входить в makerWallets и не получает прав вносителя.
    makerSettlementWallet: address
    addresseeWallets: OfferWallets
    makerCancellation: Cell<MakerCancellationPolicy>? = null
}

// Settlement wallet тоже принадлежит стороне сделки, даже если он не вносит депозит.
// UserId контракту неизвестен: здесь запрещаем пересечение только committed адресов.
fun OfferEscrowParties.isMakerWallet(self, wallet: address): bool {
    return wallet == self.makerSettlementWallet || self.makerWallets.exists(wallet);
}

fun OfferEscrowParties.hasIndependentTakerWallets(self, wallets: OfferWallets): bool {
    var entry = wallets.findFirst();
    while (entry.isFound) {
        if (self.isMakerWallet(entry.getKey())) {
            return false;
        }
        entry = wallets.iterateNext(entry);
    }
    return true;
}

// Условия единственного денежного расчёта между сторонами. Отсутствие PaymentTerms означает,
// что стороны обмениваются только предметами.
struct PaymentTerms {
    asset: PaymentAsset
    payer: OfferSide
    amount: coins
    marketplaceFee: coins
}

// Фактически внесённая сумма и неизменяемая атрибуция principal по кошелькам для возврата.
struct PaymentDeposits {
    total: coins
    contributions: MoneyContributions
}

struct EscrowConfig {
    feeTreasury: address
    unexpectedNftRecoveryAuthority: address
}
