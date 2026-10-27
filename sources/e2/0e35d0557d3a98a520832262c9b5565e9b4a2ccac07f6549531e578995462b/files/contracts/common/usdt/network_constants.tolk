// Mainnet master Tether USDT.
const USDT_MASTER_RAW = "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"

// Внутренний hash зафиксированной эпохи кода USDT wallet.
const USDT_WALLET_CODE_HASH = 0x8f452d7a4dfd74066b682365177259ed05734435be76b5fd4bd5d8af2b7c3d68

// TON budgets for the isolated USDT deposit lifecycle. These are spending allowances, not fees:
// each handler reserves recovery storage first and carries or returns the remaining value.
const USDT_DEPOSIT_PREPARE_VALUE = grams("0.05")
const USDT_DEPOSIT_ASSIGN_VALUE = grams("0.25")
const USDT_DEPOSIT_REFUND_VALUE = grams("0.06")
const USDT_DEPOSIT_RESOLVE_VALUE = grams("0.28")
const USDT_DEPOSIT_REPORT_VALUE = grams("0.02")
const USDT_HOLDING_FUND_FORWARD_VALUE = grams("0.15")
const USDT_HOLDING_ASSIGN_VALUE = grams("0.10")
