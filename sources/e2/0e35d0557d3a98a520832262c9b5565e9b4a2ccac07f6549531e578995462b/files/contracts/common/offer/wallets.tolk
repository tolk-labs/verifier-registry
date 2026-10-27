import "constants"

// Прямой bounded-набор адресов выбран намеренно: при малом лимите он проще для аудита и дешевле
// proof-протокола. Значение обязано быть `true`, чтобы один логический набор имел одно каноническое
// представление в StateInit и execution.
type OfferWallets = map<address, bool>

// Principal учитывается по фактическому source wallet. Иначе частичную multi-wallet оплату при
// release пришлось бы вернуть одному адресу, который не обязательно вносил эти деньги.
type MoneyContributions = map<address, coins>

fun OfferWallets.isValid(self, allowEmpty: bool): bool {
    var count = 0;
    var entry = self.findFirst();
    while (entry.isFound) {
        count += 1;
        if (
            count > MAX_OFFER_ESCROW_WALLETS || !entry.loadValue() ||
            entry.getKey().getWorkchain() != BASECHAIN
        ) {
            return false;
        }
        entry = self.iterateNext(entry);
    }
    return allowEmpty || count > 0;
}

fun OfferWallets.isAllowedBy(self, allowed: OfferWallets): bool {
    if (!self.isValid(false) || !allowed.isValid(true)) {
        return false;
    }

    var entry = self.findFirst();
    while (entry.isFound) {
        if (!allowed.isEmpty() && !allowed.exists(entry.getKey())) {
            return false;
        }
        entry = self.iterateNext(entry);
    }
    return true;
}

fun OfferWallets.allows(self, wallet: address): bool {
    return self.isEmpty() || self.exists(wallet);
}

fun OfferWallets.equals(self, other: OfferWallets): bool {
    if (!self.isValid(false) || !other.isValid(false)) {
        return false;
    }

    var entry = self.findFirst();
    while (entry.isFound) {
        if (!other.exists(entry.getKey())) {
            return false;
        }
        entry = self.iterateNext(entry);
    }

    entry = other.findFirst();
    while (entry.isFound) {
        if (!self.exists(entry.getKey())) {
            return false;
        }
        entry = other.iterateNext(entry);
    }
    return true;
}

fun singleOfferWallet(wallet: address): OfferWallets {
    var wallets: OfferWallets = [];
    wallets.set(wallet, true);
    return wallets;
}

fun MoneyContributions.add(mutate self, source: address, amount: coins) {
    val current = self.get(source);
    self.set(source, current.isFound ? current.loadValue() + amount : amount);
}

fun MoneyContributions.addAll(mutate self, other: MoneyContributions) {
    if (self.isEmpty()) {
        self = other;
        return;
    }
    var contribution = other.findFirst();
    while (contribution.isFound) {
        self.add(contribution.getKey(), contribution.loadValue());
        contribution = other.iterateNext(contribution);
    }
}
