// decompiled by @fiscaldev
@overflow1023_policy("suppress")
struct ExtendedPayoutConfig {
    recipient: any_address
    notifyExtraGas: coins
    payload: cell?
    forwardAll: bool
    refundRecipient: any_address
    refundNotifyExtraGas: coins
    refundPayload: cell?
    refundForwardAll: bool
    excesses: any_address
}

struct DepositConfig {
    targetX: coins
    targetY: coins
    minLiquidity: coins
    lockedShare: uint16
    payoutConfig: Cell<ExtendedPayoutConfig>
}

@overflow1023_policy("suppress")
struct DepositStorage {
    config: Cell<DepositConfig>
    pool: any_address
    initiator: any_address
    balanceX: coins
    balanceY: coins
}

struct (0xdc5ddba1) CreditAsset {
    queryId: uint64
    isX: bool
    amount: coins
}

struct (0x3db5f13a) CancelDeposit {
    queryId: uint64
}

@overflow1023_policy("suppress")
struct (0x25251ee0) JoinLiquidity {
    queryId: uint64
    config: Cell<DepositConfig>
    balanceX: coins
    balanceY: coins
    initiator: any_address
}

@overflow1023_policy("suppress")
struct (0x0d299e12) RefundDeposit {
    queryId: uint64
    config: Cell<DepositConfig>
    balanceX: coins
    balanceY: coins
    initiator: any_address
}

struct (0xd53276db) Excesses {
    queryId: uint64
}

type DepositMessage = CreditAsset | CancelDeposit
