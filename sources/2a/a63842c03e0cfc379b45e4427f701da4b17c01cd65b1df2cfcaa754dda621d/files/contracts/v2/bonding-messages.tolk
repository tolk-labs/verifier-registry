import "bonding-storage"

struct (0xa0a0b001) CreateLaunch {
    queryId: uint64
    metadata: cell
    salt: uint64
    options: Cell<LaunchOptions>
}

struct (0xa0a0a002) ChangeMasterAdmin {
    queryId: uint64
    newAdmin: address
}

struct (0xa0a0a003) ClaimMasterAdmin {
    queryId: uint64
}

struct (0xa0a0a004) ChangeTreasury {
    queryId: uint64
    newTreasury: address
}

struct (0xa0a0a005) WithdrawProtocolFees {
    queryId: uint64
    amount: coins
}

struct (0xa0a0b006) DepositProtocolFees {
    queryId: uint64
    amount: coins
    creator: address
    salt: uint64
    options: Cell<LaunchOptions>
}

struct (0xa0a0a014) ReinitializeCurve {
    queryId: uint64
    creator: address
    salt: uint64
    metadata: cell
    options: Cell<LaunchOptions>
}

struct (0xa0a0a015) TreasuryPayout {
    queryId: uint64
    amount: coins
}

struct (0xa0a0a010) InitializeCurve {
    queryId: uint64
    jettonMinter: address
    refundTo: address?
    protocolTreasury: address
}

struct (0xa0a0a011) BuyJettons {
    queryId: uint64
    minJettonsOut: coins
}

struct (0xa0a0a013) FlushFees {
    queryId: uint64
}

struct (0xa0a0a012) Graduate {
    queryId: uint64
}

struct (0xce185bd7) InitPoolResultMessage {
    queryId: uint64
    exitCode: int32
    customPayload: cell?
}

struct (0xa0a0a020) SellPayload {
    queryId: uint64
    minTonOut: coins
}

struct (0xde8402ce) DedustInit {
    queryId: uint64
    customPayload: cell?
}

struct (0xc9a015da) DedustDepositPayload {
    amountX: coins
    amountY: coins
    minimalLiquidity: coins
    lockedLiquidityShare: uint16
}

struct (0xa5a7cbf8) DedustPayNative {
    queryId: uint64
    amount: coins
    paymentPayload: Cell<DedustDepositPayload>
    payoutConfig: cell
}

struct (0xbe3e3179) DedustClaimCreatorFees {
    queryId: uint64
    to: address
    excessesTo: address
}

const TOPIC_BUY: int = 0xa0a0a011
const TOPIC_SELL: int = 0xa0a0a020
const TOPIC_GRADUATE: int = 0xa0a0a012
const TOPIC_LAUNCH_CREATED: int = 0xa0a0a001
const TOPIC_LAUNCH_INITIALIZED: int = 0xa0a0b070

struct LaunchInitializedEvent {
    status: LaunchStatus
    realTonReserve: coins
    curveJettonBalance: coins
}

const TOPIC_LAUNCH_ROLLED_BACK: int = 0xa0a0a007

struct BuyEvent {
    buyer: address
    tonInNet: coins
    jettonsOut: coins
    feeTon: coins
    realTonReserve: coins
    curveJettonBalance: coins
    tonInGross: coins
    migrationStarted: bool
}

struct SellEvent {
    seller: address
    jettonsIn: coins
    tonOutNet: coins
    feeTon: coins
    realTonReserve: coins
    curveJettonBalance: coins
    tonOutGross: coins
}

struct GraduateEvent {
    poolAddress: address
    poolSeedTon: coins
    poolSeedJettons: coins
    migrationFee: coins
    strandedJettons: coins
}

struct LaunchCreatedEvent {
    creator: address
    salt: uint64
    curveAddress: address
    minterAddress: address

    virtualTonReserve: coins
}

struct LaunchRolledBackEvent {
    refundTo: address
    curveAddress: address
    refundSent: bool
    refundAmount: coins
}

const TOPIC_SLIPPAGE_PARSE_FAILED: int = 0xa0a0a008

struct SlippageParseFailedEvent {
    seller: address
    jettonAmount: coins
}

struct (0xa0a0b030) LaunchMintFailed {
    queryId: uint64
}

struct (0xa0a0b031) ClaimCurveCreatorFees {
    queryId: uint64
}

struct (0xa0a0b034) FlushCreatorFees {
    queryId: uint64
}

struct (0xa0a0b032) CancelLaunchFees {
    queryId: uint64
    creator: address
    salt: uint64
    options: Cell<LaunchOptions>
}

struct (0xa0a0b033) ConfirmLaunch {
    queryId: uint64
    creator: address
    salt: uint64
    options: Cell<LaunchOptions>
}

struct (0xa0a0b060) RetryMigration {
    queryId: uint64
}

struct (0xa0a0b061) ConfirmMigration {
    queryId: uint64
}

struct (0x63554160) DepositNotification {
    queryId: uint64
    liquidity: coins
    lockedLiquidity: coins
    payload: cell?
}

struct (0x9e0c2428) ProvidePositionState {
    queryId: uint64
    includePoolAddress: bool
    includeOwnerAddress: bool
    includeFees: bool
    includeRewards: bool
}

struct (0x52e659c0) TakePositionState {
    queryId: uint64
    liquidity: coins
    lockedLiquidity: coins
    rest: RemainingBitsAndRefs
}
