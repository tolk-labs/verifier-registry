// SPDX-License-Identifier: BUSL-1.1
import "errors";
import "../../lib/utils";
import "../../lib/deployable/types"

// 1-byte length prefixed byte slice (up to 64 bytes)
// Almost all uses need to Cell<> box this type because it can be sized up to 8+512 bits
type CrossChainAddress = slice;

fun CrossChainAddress.packToBuilder(self, mutate b: builder) {
    val nBits = self.remainingBitsCount(); assert(nBits % 8 == 0, Common_Error.CrossChainAddressOutOfRange);
    val nBytes = nBits / 8;
    assert(nBytes <= 64, Common_Error.CrossChainAddressOutOfRange);
    b.storeUint(nBytes, 8);
    b.storeSlice(self);
}

fun CrossChainAddress.unpackFromSlice(mutate s: slice) {
    val nBytes= s.loadUint(8);
    assert(nBytes <= 64, Common_Error.CrossChainAddressOutOfRange);
    return s.loadBits(nBytes * 8);
}

struct RampMessageHeader { // 512
    messageId: uint256;
    sourceChainSelector: uint64;
    destChainSelector: uint64;
    sequenceNumber: uint64;
    nonce: uint64;
}

const LEAF_DOMAIN_SEPARATOR: slice = stringHexToSlice("0000000000000000000000000000000000000000000000000000000000000000");

type ExtraArgs = GenericExtraArgsV2 | SVMExtraArgsV1 | SuiExtraArgsV1;

// nolint:opcode : hex encoded bytes4(keccak256("CCIP EVMExtraArgsV2"))
struct (0x181dcf10) GenericExtraArgsV2 {
    gasLimit: uint256?;
    allowOutOfOrderExecution: bool;
}

// nolint:opcode : hex encoded bytes4(keccak256("CCIP SVMExtraArgsV1"))
struct (0x1f3b3aba) SVMExtraArgsV1 {
	computeUnits: uint32;
	accountIsWritableBitmap: uint64;
	allowOutOfOrderExecution: bool;
	tokenReceiver: uint256;
	accounts: SnakedCell<uint256>; // vec<slice>
}

// nolint:opcode : hex encoded bytes4(keccak256("CCIP SuiExtraArgsV1"))
struct (0x21ea4ca9) SuiExtraArgsV1 {
    gasLimit: uint256;
	allowOutOfOrderExecution: bool;
	tokenReceiver: uint256;
	receiverObjectIds: SnakedCell<uint256>; // vec<slice>
}

struct TokenBalance {
    amount: coins = 0;
    failed: bool = false; // if marked as failed, a retry will allow re-sending these
}

struct TokenAmount {
    amount: coins;
    token: address;
}

