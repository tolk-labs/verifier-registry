enum UsdtDepositStatus: uint2 {
    Collecting = 0
    Deposited = 1
    Assigned = 2
    Refunded = 3
}

enum UsdtDepositPurpose: uint1 {
    Principal = 0
    MarketplaceFee = 1
}

enum UsdtDepositVaultErrors {
    NotEnoughValue = 801
    InvalidAmount = 802
    InvalidStatus = 803
    InvalidNotification = 804
    NotEscrow = 805
    BeneficiaryAlreadyAssigned = 806
    InvalidTerms = 820
    InvalidVault = 821
    DuplicateDeposit = 822
    UnknownDeposit = 823
    DecisionPending = 824
    InvalidMessage = 0xFFFF
}
