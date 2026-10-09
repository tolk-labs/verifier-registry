// decompiled by @fiscaldev
import "wallets"
import "rewards"

struct (0b00) PoolUninitialized {}
struct (0b01) PoolInitializing { initiator: any_address }
struct (0b10) PoolInitialized {}
type PoolStatus = PoolUninitialized | PoolInitializing | PoolInitialized

struct (0b00) FeeFromBoth {}
struct (0b01) FeeFromX {}
struct (0b10) FeeFromY {}
type PoolFeeIn = FeeFromBoth | FeeFromX | FeeFromY

struct PoolRewardConfig {
    asset: any_address
    maxDuration: uint40
}

// A present response may contain an empty rewards dictionary. The wrapper
// distinguishes that case from a response that omits rewards entirely.
struct PoolProvidedRewards { rewards:map<uint2,PoolReward> }

@overflow1023_policy("suppress")
struct PoolConfig {
    assetX: any_address
    assetY: any_address
    creator: any_address
    baseFee: uint16
    creatorFee: uint16
    depositActivation: cell?
    swapActivation: cell?
    feeIn: PoolFeeIn
    customResolvers: AddressLookup
    allowedRewards: map<uint2, PoolRewardConfig>
}

struct PoolFees {
    protocolX: coins
    protocolY: coins
    creatorX: coins
    creatorY: coins
    xCheckpoint: varuint32
    yCheckpoint: varuint32
}

struct PoolExtra {
    controller: any_address
    wallets: PoolWallets
}

struct PoolStorage {
    config: cell
    fees: cell
    extra: cell
    rewards: map<uint2, PoolReward>
    status: PoolStatus
    depositActive: bool
    swapActive: bool
    liquidity: coins
    reserveX: coins
    reserveY: coins
}

struct PoolData {
    status: int8
    depositActive: bool
    swapActive: bool
    assetX: any_address
    assetY: any_address
    walletsByAssets: AddressLookup
    assetsByWallets: AddressLookup
    resolutions: AddressLookup
    baseFee: int
    reserveX: coins
    reserveY: coins
    liquidity: coins
    protocolX: coins
    protocolY: coins
    creatorX: coins
    creatorY: coins
    xCheckpoint: varuint32
    yCheckpoint: varuint32
    rewards: map<uint2, PoolReward>
}
