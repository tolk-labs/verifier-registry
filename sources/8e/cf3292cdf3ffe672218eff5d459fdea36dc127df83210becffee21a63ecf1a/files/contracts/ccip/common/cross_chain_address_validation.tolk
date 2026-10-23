// SPDX-License-Identifier: BUSL-1.1
// From https://github.com/smartcontractkit/chainlink-ccip/blob/2c65147d933b7c8e7495dc3d96a460c4c9006fbb/chains/evm/contracts/libraries/Internal.sol

import "types"

tolk 1.2

const EVM_PRECOMPILE_SPACE = 1024;
const APTOS_PRECOMPILE_SPACE = 0x0b;
const SUI_PRECOMPILE_SPACE = 0xdee9;

struct EVMAddress {
    value: uint256;
}

const TYPE_UINT160_MAX = (1 << 160) - 1; /* type(uint160).max */

fun CrossChainAddress.validateEVMAddress(self, error: int) {
    var evmAddr: EVMAddress;
    try {
        evmAddr = EVMAddress.fromSlice(self);
    } catch {
        throw error;
    }
    assert (evmAddr.value <= TYPE_UINT160_MAX) throw error;
    assert (evmAddr.value >= EVM_PRECOMPILE_SPACE) throw error;
}

struct a32ByteAddress {
    value: uint256;
}

fun CrossChainAddress.validate32ByteAddress(self, minValue: uint256, error: int) {
    val addr = a32ByteAddress.fromSlice(self, {
        throwIfOpcodeDoesNotMatch: error,
    });
    if (minValue > 0) {
        assert (addr.value >= minValue) throw error;
    }
}
