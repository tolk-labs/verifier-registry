// decompiled by @fiscaldev
// Field order is recovered from the executable cell graph, not guessed from names.
struct PositionFees {
    xCheckpoint: varuint32
    xPending: coins
    xReserved: coins
    yCheckpoint: varuint32
    yPending: coins
    yReserved: coins
}

struct PositionReward {
    pending: coins
    checkpoint: varuint32
}

struct PoolReward {
    remainingTime: uint40
    remainingBudget: coins
    checkpoint: varuint32
    lastUpdate: uint40
}

@overflow1023_policy("suppress")
struct PositionStorage {
    pool: any_address
    owner: any_address
    liquidity: coins
    lockedLiquidity: coins
    fees: Cell<PositionFees>
    rewards: map<uint2, PositionReward>
}

@overflow1023_policy("suppress")
struct (0x855afcbd) CreditLiquidity {
    queryId: uint64
    liquidity: coins
    lockedShare: uint16
    notifyGas: coins
    payload: cell?
    receiver: any_address
    xCheckpoint: varuint32
    yCheckpoint: varuint32
    rewards: map<uint2, PoolReward>
}

@overflow1023_policy("suppress")
struct (0x25f19752) ClaimAvailableFees {
    queryId: uint64
    payout: any_address
    xCheckpoint: varuint32
    yCheckpoint: varuint32
}

struct (0xbc1531a9) WithdrawLiquidity {
    queryId: uint64
    liquidity: coins
    minX: coins
    minY: coins
    xCheckpoint: varuint32
    yCheckpoint: varuint32
    rewards: map<uint2, PoolReward>
    claimFees: bool
    config: cell
}

struct (0x9e0c2428) ProvidePositionState {
    queryId: uint64
    includePool: bool
    includeOwner: bool
    includeFees: bool
    includeRewards: bool
}

@overflow1023_policy("suppress")
struct (0x2e0cccba) ClaimPositionReward {
    queryId: uint64
    rewardId: uint2
    remainingTime: uint40
    remainingBudget: coins
    checkpoint: varuint32
    lastUpdate: uint40
    payout: any_address
}

type PositionMessage =
    | CreditLiquidity
    | ClaimAvailableFees
    | WithdrawLiquidity
    | ProvidePositionState
    | ClaimPositionReward

struct (0x29ff1bcf) BouncedFeeClaim {
    queryId: uint64
    x: coins
    y: coins
    tail: RemainingBitsAndRefs
}

struct (0xf6f6a3aa) BouncedWithdrawal {
    queryId: uint64
    liquidity: coins
    x: coins
    y: coins
    tail: RemainingBitsAndRefs
}

struct (0x9e17fbbe) BouncedRewardClaim {
    queryId: uint64
    amount: coins
    tail: RemainingBitsAndRefs
}

type BouncedPositionMessage = BouncedFeeClaim | BouncedWithdrawal | BouncedRewardClaim

struct RewardSnapshot {
    rewards: map<uint2, PositionReward>
}

type OptionalRewards = RewardSnapshot?

@overflow1023_policy("suppress")
struct (0x52e659c0) PositionState {
    queryId: uint64
    liquidity: coins
    lockedLiquidity: coins
    pool: any_address?
    owner: any_address?
    fees: cell?
    rewards: OptionalRewards
}

struct (0xd53276db) Excesses {
    queryId: uint64
}

struct (0x63554160) DepositNotification {
    queryId: uint64
    liquidity: coins
    lockedLiquidity: coins
    payload: cell?
}
