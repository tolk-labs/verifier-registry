// Floors from acton gas snapshot + calculateStorageFee / calculateGasFee / calculateForwardFee
// on a live ContractUSDT account (tests/usdt.test.tolk --snapshot, 5y storage).
// Recommended = measured minimum * 2, rounded up.
//
// measured (basechain default config):
//   storage 5y ≈ 0.011368 TON (35 cells / 17625 bits) → x2 ≈ 0.02274
//   max opcode gas fee (9583 gas, RefundUsdt) ≈ 0.000639 TON → x2 ≈ 0.001278
//   AskToTransfer forward (~2048 bits / 4 cells) ≈ 0.000230 TON → x2 ≈ 0.000460
//   forwardTonAmount (notify gas 5438 + notify fwd) ≈ 0.000511 TON → x2 ≈ 0.001022
// Recommended values:
// const MIN_TONS_FOR_STORAGE_THIS_CONTRACT: coins = grams("0.023")
// const CONTRACT_GAS_CONSUMPTION: coins = grams("0.0013")
// const MIN_MESSAGE_VALUE_BOUND = grams("0.0005")
// const MIN_FORWARD_TON_AMOUNT = grams("0.0011")

// Actual values (extra headroom, same style as ContractTON fees_management):
const MIN_TONS_FOR_STORAGE_THIS_CONTRACT: coins = grams("0.07")
const CONTRACT_GAS_CONSUMPTION: coins = grams("0.004")
const MIN_MESSAGE_VALUE_BOUND = grams("0.002")
const MIN_FORWARD_TON_AMOUNT = grams("0.003")
