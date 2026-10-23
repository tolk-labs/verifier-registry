// SPDX-License-Identifier: BUSL-1.1

const USD_PER_TOKEN_UPDATED_TOPIC: int = stringCrc32("UsdPerTokenUpdated");
struct UsdPerTokenUpdated {
    sourceToken: address
    usdPerToken: uint224
    timestamp: uint64
}

const USD_PER_UNIT_GAS_UPDATED: int = stringCrc32("UsdPerUnitGasUpdated");
struct UsdPerUnitGasUpdated {
    destChainSelector: uint64
    executionGasPrice: uint112
    dataAvailabilityGasPrice: uint112
    timestamp: uint64
}
