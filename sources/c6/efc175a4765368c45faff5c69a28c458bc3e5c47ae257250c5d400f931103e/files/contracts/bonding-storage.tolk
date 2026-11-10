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

    // SISU v3: creator's share of curve fees not yet paid out (Classic mode). Same slot
    // that was the always-zero reserved field in v1/v2, so the layout is unchanged.
    creatorAccrued: coins
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
    // SISU v3: creator fees accrued and not yet paid (see BondingCurveStorage.creatorAccrued).
    creatorAccrued: coins
}
