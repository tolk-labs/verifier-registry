const TOTAL_SUPPLY: coins = 1000000000 * 1000000000

const CURVE_SUPPLY: coins = 800000000 * 1000000000

const DEX_RESERVE_SUPPLY: coins = 200000000 * 1000000000

const VIRTUAL_TON_RESERVE_INIT: coins = ton("166.666666666")

const GRADUATION_THRESHOLD_TON: coins = ton("500")

const MIGRATION_FEE: coins = ton("5")

const PROTOCOL_FEE_BPS: int = 100

// SISU v2: every curve trade pays at least this much fee.
const MIN_TRADE_FEE: coins = ton("0.03")

// SISU v2: gas kept by the curve when it splits DeDust creator fees 50/50.
const POOL_FEE_SPLIT_GAS: coins = ton("0.02")
const POOL_FEE_CLAIM_MIN_VALUE: coins = ton("0.2")
const BPS_DENOMINATOR: int = 10000

// SISU v3: launch modes. The mode is the top byte of the launch salt (salt >> 56), so it is
// part of the curve's init data and can never change after launch.
const LAUNCH_MODE_CLASSIC: int = 0   // creator gets CREATOR_FEE_SHARE_BPS of every curve fee
const LAUNCH_MODE_HOLDERS: int = 1   // that share stays in the curve reserve and lifts the price
const MAX_LAUNCH_MODE: int = 1
// Share of each curve fee (1% of the trade) that goes to the creator / holders: 30% = 0.3% of the trade.
const CREATOR_FEE_SHARE_BPS: int = 3000
// Creator fees are sent automatically once at least this much has accrued.
const CREATOR_PAYOUT_MIN: coins = ton("0.1")
// Gas attached to the self-burn of jettons left in the curve after DEX seeding.
const STRANDED_BURN_VALUE: coins = ton("0.05")

const MIGRATION_RESERVE_TARGET: coins = ton("1.5")
const MIGRATION_RESERVE_RATIO_BPS: int = 5000

const CREATE_LAUNCH_FEE: coins = ton("1")

const MIN_CREATE_LAUNCH_VALUE: coins = ton("1.3")

const CURVE_TRANSFER_VALUE: coins = ton("0.05")

const CURVE_TRANSFER_NOTIFICATION: coins = ton("0.01")

const REFUND_VALUE_EPSILON: coins = ton("0.005")

const CURVE_STORAGE_RESERVE: coins = ton("0.05")
