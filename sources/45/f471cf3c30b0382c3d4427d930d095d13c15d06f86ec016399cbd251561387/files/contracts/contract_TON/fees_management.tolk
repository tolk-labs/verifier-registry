// Floors from acton gas snapshot + calculateStorageFee / calculateGasFee / calculateForwardFee
// on a live ContractTON account (tests/ton.test.tolk --snapshot, 5y storage).
// Values below are measured minimum * 2, rounded up.
//
// measured (basechain default config):
//   storage 5y ≈ 0.005522 TON  → x2 ≈ 0.01104
//   max opcode gas fee (7441 gas, RefundTon path) ≈ 0.000496 TON → x2 ≈ 0.000992
//   refund out forward (~1024 bits / 2 cells) ≈ 0.000148 TON → x2 ≈ 0.000297
// Recommended values:
// const MIN_TONS_FOR_STORAGE_THIS_CONTRACT: coins = grams("0.012")
// const CONTRACT_GAS_CONSUMPTION: coins = grams("0.001")
// const MIN_MESSAGE_VALUE_BOUND = grams("0.0003")

// Actual values:
const MIN_TONS_FOR_STORAGE_THIS_CONTRACT: coins = grams("0.05")
const CONTRACT_GAS_CONSUMPTION: coins = grams("0.002")
const MIN_MESSAGE_VALUE_BOUND: coins = grams("0.001")
