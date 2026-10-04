import "fee-storage"

struct MigrationProgress {
    nativeQueryId: uint64
    jettonQueryId: uint64
    tonAmount: coins
    jettonAmount: coins
    nativeRetry: bool
    jettonRetry: bool
}

const CURVE_STATE_MIGRATION_RETRY: uint8 = 6
const CURVE_STATE_AWAITING_LIQUIDITY: uint8 = 7

struct LaunchOptions {
    supply: coins
    creatorFeeBps: uint16
    devBuyAmount: coins
    minDevTokens: coins
    graduationThreshold: coins = ton("2000")
    reserveRatio: uint8 = 5
    minBuyBps: uint16 = 0
    maxBuyBps: uint16 = 0
    beneficiaries: Cell<FeeBeneficiaries>? = null
    buybackBurn: bool = false
}

struct LaunchProgress {
    protocolTreasury: address?
    curveReceived: bool
    devReceived: bool
    devTokens: coins
    creatorAccrued: coins
}

const CURVE_STATE_CANCELLED: uint8 = 5

const CURVE_STATE_INITIALIZING: uint8 = 0
const CURVE_STATE_TRADING: uint8 = 1
const CURVE_STATE_GRADUATING: uint8 = 2
const CURVE_STATE_MIGRATED: uint8 = 3
const CURVE_STATE_FROZEN: uint8 = 4

enum LaunchStatus: uint8 {
    Initializing = 0
    Trading = 1
    Migrating = 2
    Migrated = 3
    Cancelled = 4
}

fun launchStatus(state: uint8): LaunchStatus {
    if (state == CURVE_STATE_INITIALIZING) {
        return LaunchStatus.Initializing;
    }
    if (state == CURVE_STATE_TRADING) {
        return LaunchStatus.Trading;
    }
    if (state == CURVE_STATE_MIGRATED) {
        return LaunchStatus.Migrated;
    }
    if (state == CURVE_STATE_CANCELLED) {
        return LaunchStatus.Cancelled;
    }
    assert (
        state == CURVE_STATE_FROZEN || state == CURVE_STATE_GRADUATING ||
        state == CURVE_STATE_MIGRATION_RETRY ||
        state == CURVE_STATE_AWAITING_LIQUIDITY
    ) throw 49;
    return LaunchStatus.Migrating;
}

struct MasterStorage {
    admin: address
    nextAdmin: address?
    treasury: address
    totalLaunches: uint64
    feesBalance: coins
    launches: map<uint256, uint2> = []
}

fun MasterStorage.load(): MasterStorage {
    return MasterStorage.fromCell(contract.getData());
}

fun MasterStorage.save(self) {
    contract.setData(self.toCell());
}

struct LaunchConfig {
    master: address
    creator: address
    salt: uint64
    curveSupply: coins
    dexReserveSupply: coins
    graduationThreshold: coins
    options: Cell<LaunchOptions>
}

struct BondingCurveStorage {
    state: uint8
    jettonMinter: address?
    virtualTonReserve: coins
    realTonReserve: coins
    curveJettonBalance: coins
    feeAccrued: coins
    migrationReserve: coins
    config: Cell<LaunchConfig>

    dropAdminPending: bool

    // Unused compatibility field; always zero.
    pendingBuyTonInNet: coins
    progress: Cell<LaunchProgress>
    migration: Cell<MigrationProgress>? = null
}

fun BondingCurveStorage.load(): BondingCurveStorage {
    return BondingCurveStorage.fromCell(contract.getData());
}

fun BondingCurveStorage.save(self) {
    contract.setData(self.toCell());
}

struct MasterDataReply {
    admin: address
    nextAdmin: address?
    treasury: address
    totalLaunches: uint64
    feesBalance: coins
}

struct BondingCurveDataReply {
    state: uint8
    creator: address
    salt: uint64
    jettonMinter: address?
    virtualTonReserve: coins
    realTonReserve: coins
    curveJettonBalance: coins
    curveSupply: coins
    dexReserveSupply: coins
    graduationThreshold: coins
    feeAccrued: coins
    migrationReserve: coins
    dropAdminPending: bool
    // Unused compatibility field; always zero.
    pendingBuyTonInNet: coins
}

struct FeeRatesReply {
    curveProtocolBps: int
    curveCreatorBps: int
    poolBaseFeeBps: int
    poolCreatorAllocationBps: int
    // Parts per billion of trade input, rounded down; actual trades round in asset units.
    poolProtocolPpb: int
    poolCreatorPpb: int
    poolLpPpb: int
    dedustPpb: int
}

struct LaunchPreview {
    minBuyTokens: coins
    maxBuyTokens: coins
    virtualTonReserve: coins
    graduationThreshold: coins
    soldTokens: coins
    poolTon: coins
    poolTokens: coins
    remainingTokens: coins
    initialPriceNanoPerBillion: int
    graduationPriceNanoPerBillion: int
}
