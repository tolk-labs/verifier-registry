// decompiled by @fiscaldev
// Compatibility with the legacy Tolk AutoDeployAddress message encoder.
// The StateInit hashing primitives are attributed in stdlib-legacy-stateinit.tolk.
import "stdlib-legacy-stateinit"

@inline
fun archivedPoolInlineDeploymentHeader(destination: AutoDeployAddress): builder {
    val state = destination.stateInit;
    val shard = destination.toShard;
    var message = beginCell().storeUint(0x18, 6).storeUint(4, 3).storeInt(destination.workchain, 8);
    var stateHash: uint256;
    if (state is ContractState) {
        if (shard is AddressShardingOptions) {
            stateHash = archivedStateHashPrefix(shard.fixedPrefixLength, state.code, state.data);
        } else {
            stateHash = archivedStateHash(state.code, state.data);
        }
    } else {
        stateHash = state.hash();
    }
    if (shard is AddressShardingOptions) {
        val suffix = stateHash & ((1 << (256 - shard.fixedPrefixLength)) - 1);
        val width = 256 - shard.fixedPrefixLength;
        val prefix = (shard.closeTo as slice).getMiddleBits(11, shard.fixedPrefixLength);
        message.storeSlice(prefix).storeUint(suffix, width);
    } else {
        message.storeUint(stateHash, 256);
    }
    // Zero value, empty extra currencies, fees and creation fields.
    message.storeUint(0, 109);
    if (state is ContractState) {
        if (shard is AddressShardingOptions) {
            message.storeUint(0b101, 3).storeUint(shard.fixedPrefixLength, 5).storeUint(0b01100, 5);
        } else {
            message.storeUint(0b10001100, 8);
        }
        message.storeRef(state.code).storeRef(state.data);
    } else {
        message.storeUint(0b110, 3).storeRef(state);
    }
    return message;
}

// Reference-body variant keeps its literal selector in each StateInit arm.
@inline
fun archivedPoolRefDeploymentHeader(destination: AutoDeployAddress): builder {
    val state = destination.stateInit;
    val shard = destination.toShard;
    var message = beginCell().storeUint(0x18, 6).storeUint(4, 3).storeInt(destination.workchain, 8);
    var stateHash: uint256;
    if (state is ContractState) {
        if (shard is AddressShardingOptions) {
            stateHash = archivedStateHashPrefix(shard.fixedPrefixLength, state.code, state.data);
        } else {
            stateHash = archivedStateHash(state.code, state.data);
        }
    } else {
        stateHash = state.hash();
    }
    if (shard is AddressShardingOptions) {
        val suffix = stateHash & ((1 << (256 - shard.fixedPrefixLength)) - 1);
        val width = 256 - shard.fixedPrefixLength;
        val prefix = (shard.closeTo as slice).getMiddleBits(11, shard.fixedPrefixLength);
        message.storeSlice(prefix).storeUint(suffix, width);
    } else {
        message.storeUint(stateHash, 256);
    }
    // Zero value, empty extra currencies, fees and creation fields.
    message.storeUint(0, 109);
    if (state is ContractState) {
        if (shard is AddressShardingOptions) {
            message.storeUint(0b101, 3).storeUint(shard.fixedPrefixLength, 5).storeUint(0b01101, 5);
        } else {
            message.storeUint(0b10001101, 8);
        }
        message.storeRef(state.code).storeRef(state.data);
    } else {
        message.storeUint(0b111, 3).storeRef(state);
    }
    return message;
}
