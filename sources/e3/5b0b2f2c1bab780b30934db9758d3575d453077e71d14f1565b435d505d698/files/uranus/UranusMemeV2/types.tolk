// decompiled by @fiscaldev
@overflow1023_policy("suppress")
struct Partner {
    id: uint256
    share: uint16
}

@overflow1023_policy("suppress")
struct Referrer {
    id: uint256
    share: uint16
}

@overflow1023_policy("suppress")
struct AttributionSnapshot {
    id: uint256?
    share: uint16?
}

@overflow1023_policy("suppress")
struct AffiliateStorage {
    initialized: bool
    authority: any_address
    kind: uint1
    metadata: cell?
    id: uint256
    share: uint16
    owner: any_address
}

@overflow1023_policy("suppress")
struct PoolConfig {
    assetX: any_address
    assetY: any_address
    creator: any_address
    baseFee: uint16
    creatorFee: uint16
    depositActivation: cell?
    swapActivation: cell?
    // Two bits of the CPMM FeeFromX (0b01) selector.
    feeSelectorHigh: bool
    feeSelectorLow: bool
    customResolvers: cell?
    allowedRewards: dict
}

@overflow1023_policy("suppress")
struct PoolBalances {
    // Each byte packs two empty Coins fields, retaining the original stores.
    emptyProtocolFees: uint8
    emptyCreatorFees: uint8
    xCheckpoint: varuint32
    yCheckpoint: varuint32
}

@overflow1023_policy("suppress")
struct PoolAdmin {
    controller: any_address
    walletsByAssets: cell?
    assetsByWallets: cell?
    resolutions: cell?
}

@overflow1023_policy("suppress")
struct PoolRoot {
    config: cell
    fees: cell
    extra: cell
    rewards: cell?
    // status(2), deposit/swap activity(2), three empty Coins fields(12).
    emptyStatusAndBalances: uint16
}

@overflow1023_policy("suppress")
struct WalletCredit {
    opcode: uint32
    queryId: uint64
    amount: coins
    from: any_address
    response: any_address
    forwardTon: coins
    referenced: bool
    payload: RemainingBitsAndRefs
}

@overflow1023_policy("suppress")
struct MigrationPayout {
    owner: any_address
    flags: uint4
    firstPayload: cell?
    firstRequired: bool
    recipient: any_address
    flags2: uint4
    secondPayload: cell?
    secondRequired: bool
    excesses: any_address
}

@overflow1023_policy("suppress")
struct MigrationPair {
    opcode: uint32
    amounts: cell
    payout: cell
}

@overflow1023_policy("suppress")
struct WalletCreditRef {
    opcode: uint32
    queryId: uint64
    amount: coins
    from: any_address
    response: any_address
    forwardTon: coins
    referenced: bool
    payload: cell
}

@overflow1023_policy("suppress")
struct (0x796f5a0c) Initialize {
    queryId: uint64
    amount: coins
    partner: Partner?
    referrer: Referrer?
}

@overflow1023_policy("suppress")
struct (0x94826557) Buy {
    queryId: uint64
    amount: coins
    minOut: coins
    receiver: any_address
    partner: Cell<Partner>?
    referrer: Cell<Referrer>?
}

@overflow1023_policy("suppress")
struct (0x646ad424) Sell {
    queryId: uint64
    amount: coins
    minOut: coins
    owner: any_address
    receiver: any_address
    partner: Cell<Partner>?
    referrer: Cell<Referrer>?
}

@overflow1023_policy("suppress")
struct (0x7bdd97de) Burn {
    queryId: uint64
    amount: coins
    owner: any_address
    receiver: any_address
}

@overflow1023_policy("suppress")
struct (0x2c76b973) ResolveWallet {
    queryId: uint64
    owner: any_address
    includeOwner: bool
}

@overflow1023_policy("suppress")
struct (0xad7269a8) ClaimCreator {
    queryId: uint64
    to: any_address
    receiver: any_address
}

@overflow1023_policy("suppress")
struct (0xf14b54f3) SweepController {
    queryId: uint64
    to: any_address
}

@overflow1023_policy("suppress")
struct (0xd53276db) Excesses {
    queryId: uint64
}

@overflow1023_policy("suppress")
struct (0xce185bd7) PoolInitialized {
    queryId: uint64
    exitCode: int32
    payload: cell?
}

type Incoming =
    | Initialize
    | Buy
    | Sell
    | Burn
    | ResolveWallet
    | ClaimCreator
    | SweepController
    | Excesses
    | PoolInitialized

@overflow1023_policy("suppress")
struct Curve {
    graduated: bool
    alpha: coins
    beta: coins
    onSellSupply: coins
    raisedFunds: coins
    currentSupply: coins
}

@overflow1023_policy("suppress")
struct Runtime {
    initialized: bool
    migrated: bits1
    config: cell
    baseFee: uint16
    curve: Curve
    totalSupply: coins
    creatorFee: coins
}
