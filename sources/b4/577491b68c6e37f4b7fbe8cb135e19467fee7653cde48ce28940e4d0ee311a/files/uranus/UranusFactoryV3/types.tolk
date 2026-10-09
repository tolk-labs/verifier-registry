// decompiled by @fiscaldev
struct Partner {
    id: uint256
    share: uint16
}

struct Referrer {
    id: uint256
    share: uint16
}

struct (0x6ff416dc) DeployPreset {
    queryId: uint64
    preset: uint4
    metadata: cell
    initialBuy: coins
    partner: Partner?
    referrer: Referrer?
}

@overflow1023_policy("suppress")
struct (0x632f5d1c) DeployCustom {
    queryId: uint64
    supplyPreset: uint4
    feePreset: uint4
    raisingFunds: coins
    onSellPercent: uint8
    partnerAddress: address
    partnerFee: uint16
    poolPartnerFee: uint16
    poolFeePreset: uint16
    liquidityOwner: address?
    metadata: cell
    initialBuy: coins
    partner: Cell<Partner>?
    referrer: Cell<Referrer>?
}

type Incoming = DeployPreset | DeployCustom

struct (0x796f5a0c) InitializeMeme {
    queryId: uint64
    initialBuy: coins
    partner: Partner?
    referrer: Referrer?
}

struct FactoryStorage {
    controller: address
}

struct MemeConfig {
    creator: address
    controller: address
    metadata: cell
    raisingFunds: coins
    liquidityTokens: coins
    seed: uint128
}

struct Curve {
    graduated: bool
    alpha: coins
    beta: coins
    onSellSupply: coins
    raisedFunds: coins
    currentSupply: coins
}

struct MigrationConfig {
    partner: address
    partnerShare: uint16
    baseFee: uint16
    liquidityOwner: address
}

@overflow1023_policy("suppress")
struct MemeStorage {
    initialized: bool
    migrated: bool
    config: cell
    baseFee: uint16
    curve: Curve
    totalSupply: coins
    creatorFee: coins
    partnerFee: coins
    partnerShare: uint16
    migration: cell
}
