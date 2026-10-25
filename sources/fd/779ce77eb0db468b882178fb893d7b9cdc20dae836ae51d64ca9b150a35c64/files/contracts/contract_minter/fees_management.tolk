// Floors from acton gas snapshot + calculateStorageFee / calculateGasFee / calculateForwardFee
// (tests/minter-fees-measure.test.tolk, tests/usdt.test.tolk --snapshot, 5y storage).
// Recommended = measured minimum * 2, rounded up.
//
// measured (basechain default config):
//   minter storage 5y ≈ 0.017865 TON (55 cells / 27803 bits) → x2 ≈ 0.03573
//   max create gas fee (CreateTON~7000 / CreateUSDT 6084) ≈ 0.000467 TON → x2 ≈ 0.000933
//   TON outbound bound (deploy fwd + child deploy gas) ≈ 0.001671 TON → x2 ≈ 0.003341
//   USDT deploy value (child storage reserve 0.08 + deployFwd + child gas) ≈ 0.08167 TON → x2 ≈ 0.1633
//
// Why separate USDT constant:
//   CreateTonContract forwards remaining value into the escrow (Transfer).
//   CreateUsdtContract only needs enough on the child for storage/deploy; excess returns to sender.
// Recommended values:
// const MIN_TONS_FOR_STORAGE_THIS_CONTRACT: coins = grams("0.036")
// const CONTRACT_GAS_CONSUMPTION: coins = grams("0.001")
// const MIN_TON_DEPLOY_VALUE = grams("0.0035")
// const MIN_USDT_DEPLOY_VALUE = grams("0.17")

// Actual values (extra headroom, same style as ContractTON / ContractUSDT):
const MIN_TONS_FOR_STORAGE_THIS_CONTRACT: coins = grams("0.1")
const CONTRACT_GAS_CONSUMPTION: coins = grams("0.003")
const MIN_TON_DEPLOY_VALUE = grams("0.01")
const MIN_USDT_DEPLOY_VALUE = grams("0.2")

// 0.4% of clientAmountInit (amount / 250), with a hard cap so large deals do not inflate the platform fee.
const MAX_ROYALTY_INIT_TON: uint75 = grams("15") as uint75
const MAX_ROYALTY_INIT_USDT: uint72 = 20 * 1000000 // 20 USDT, 6 decimals

// Floor so integer percent math (init / 100 * percent) cannot round a 1% share to 0.
const MIN_CLIENT_AMOUNT_TON: uint75 = grams("1") as uint75
const MIN_CLIENT_AMOUNT_USDT: uint72 = 1 * 1000000 // 1 USDT, 6 decimals
