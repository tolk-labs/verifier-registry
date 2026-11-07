struct (0xa0a0a001) CreateLaunch {
    queryId: uint64
    metadata: cell
    salt: uint64
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

struct (0xa0a0a006) DepositProtocolFees {
    queryId: uint64
    amount: coins
    creator: address
    salt: uint64
}

struct (0xa0a0a014) ReinitializeCurve {
    queryId: uint64
    creator: address
    salt: uint64
    metadata: cell
}

struct (0xa0a0a015) TreasuryPayout {
    queryId: uint64
    amount: coins
}

struct (0xa0a0a010) InitializeCurve {
    queryId: uint64
    jettonMinter: address
    refundTo: address?
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

const TOPIC_LAUNCH_ROLLED_BACK: int = 0xa0a0a007

struct BuyEvent {
    buyer: address
    tonInNet: coins
    jettonsOut: coins
    feeAccrued: coins
    realTonReserve: coins
    curveJettonBalance: coins
}

struct SellEvent {
    seller: address
    jettonsIn: coins
    tonOut: coins
    feeAccrued: coins
    realTonReserve: coins
    curveJettonBalance: coins
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
