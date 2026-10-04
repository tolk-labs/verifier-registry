struct FeeBeneficiaries {
    shares: map<address, uint16>
}

struct FeeBalance {
    tonAmount: coins
    tokenAmount: coins
}

struct FeeRecipients {
    creator: address
    protocol: address
    creatorBps: uint16
    curve: address? = null
    beneficiaries: Cell<FeeBeneficiaries>? = null
    buybackBurn: bool = false
}

struct CollectorStorage {
    minter: address
    recipients: Cell<FeeRecipients>
    initialized: bool
    nextId: uint64
    nativeAccrued: coins = 0
}

struct SplitterConfig {
    collector: address
    minter: address
    recipients: Cell<FeeRecipients>
}

struct TokenPayout {
    protocol: bool
    amount: coins
    recipient: address
}

struct SplitterStorage {
    config: Cell<SplitterConfig>
    creatorTon: coins
    protocolTon: coins
    creatorTokens: coins
    protocolTokens: coins
    nextId: uint64
    pending: map<uint64, TokenPayout>
    balances: map<address, FeeBalance> = []
}

struct (0xa0a0b040) CollectPoolFees {
    queryId: uint64
}

struct (0xa0a0b041) SweepCollectedTokens {
    queryId: uint64
    amount: coins
}

struct (0xa0a0b042) CreditNativeFees {
    queryId: uint64
    amount: coins
}

struct (0xa0a0b043) ClaimSplitFees {
    queryId: uint64
    protocol: bool
}

struct (0x3216ca09) DedustNativePayout {
    queryId: uint64
    rest: RemainingBitsAndRefs
}

struct (0xa0a0b044) CreditCurveFees {
    queryId: uint64
    amount: coins
}

struct (0xa0a0b045) RetryCollectedFees {
    queryId: uint64
}

fun beneficiaryShares(r: FeeRecipients): map<address, uint16> {
    if (r.beneficiaries != null) {
        return r.beneficiaries!.load().shares;
    }
    var shares: map<address, uint16> = [];
    shares.set(r.creator, 10000);
    return shares;
}

fun validateBeneficiaries(beneficiaries: Cell<FeeBeneficiaries>?) {
    if (beneficiaries == null) {
        return;
    }
    val shares = beneficiaries!.load().shares;
    var item = shares.findFirst();
    var count = 0;
    var total = 0;
    while (item.isFound) {
        val share = item.loadValue();
        assert (count < 8 && share > 0 && item.getKey().getWorkchain() == 0) throw 49;
        total += share;
        count += 1;
        item = shares.iterateNext(item);
    }
    assert (count > 0 && total == 10000) throw 49;
}
