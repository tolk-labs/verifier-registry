struct TaxRule {
    permille: uint16
    to: address
}

struct FeeRules {
    burnPermille: uint16
    tax1: TaxRule?
    tax2: TaxRule?
    tax3: TaxRule?
    forGood: Cell<ExcludedForGood>
}

struct ExcludedForGood {
    creator: address
    named1: address?
    named2: address?
}

struct Fees {
    burned: coins
    tax1: coins
    tax2: coins
    tax3: coins
}

fun taxPart(rule: TaxRule?, amount: coins): coins {
    if (rule == null) {
        return 0;
    }
    return amount * rule.permille / 1000;
}

fun taxGoesTo(rule: TaxRule?, account: address): bool {
    return rule != null && rule.to == account;
}

fun isNamed(named: address?, account: address): bool {
    return named != null && named == account;
}

fun FeeRules.isExcludedForGood(self, account: address): bool {
    if (
        taxGoesTo(self.tax1, account) || taxGoesTo(self.tax2, account) ||
        taxGoesTo(self.tax3, account)
    ) {
        return true;
    }
    val forGood = self.forGood.load();
    return account == forGood.creator || isNamed(forGood.named1, account) ||
        isNamed(forGood.named2, account);
}

fun FeeRules.feesOf(self, amount: coins, excluded: bool): Fees {
    if (excluded) {
        return {
            burned: 0,
            tax1: 0,
            tax2: 0,
            tax3: 0,
        };
    }
    return {
        burned: amount * self.burnPermille / 1000,
        tax1: taxPart(self.tax1, amount),
        tax2: taxPart(self.tax2, amount),
        tax3: taxPart(self.tax3, amount),
    };
}

fun Fees.total(self): coins {
    return self.burned + self.tax1 + self.tax2 + self.tax3;
}

fun Fees.taxCount(self): int {
    return (self.tax1 != 0 ? 1 : 0) + (self.tax2 != 0 ? 1 : 0) + (self.tax3 != 0 ? 1 : 0);
}
