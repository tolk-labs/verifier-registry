const CURVE_STATE_INITIALIZING: uint8 = 0
const CURVE_STATE_TRADING: uint8 = 1
const CURVE_STATE_GRADUATING: uint8 = 2
const CURVE_STATE_MIGRATED: uint8 = 3
const CURVE_STATE_FROZEN: uint8 = 4

struct MasterStorage {
    admin: address
    nextAdmin: address?
    treasury: address
    totalLaunches: uint64
    feesBalance: coins
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

    // RESERVED, always 0. Retained for storage/getter ABI stability with existing
    // off-chain consumers. A bounced buy is compensated on the jetton side only
    // (see BondingCurve.onBouncedMessage); no TON-side rollback state is tracked.
    pendingBuyTonInNet: coins
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
    // RESERVED, always 0 (see BondingCurveStorage.pendingBuyTonInNet).
    pendingBuyTonInNet: coins
}
