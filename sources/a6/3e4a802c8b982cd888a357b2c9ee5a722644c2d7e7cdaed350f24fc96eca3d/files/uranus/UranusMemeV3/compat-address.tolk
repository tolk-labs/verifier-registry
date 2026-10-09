// decompiled by @fiscaldev
// Preserve the old standard-library StateInit hashes and address representation.
import "stdlib-legacy-stateinit"

fun archivedAddressSlice(b: builder): address
    asm "BTOS"

@inline
fun AutoDeployAddress.calculateArchivedAddressBuilder(self): builder {
    val state = self.stateInit;
    val shard = self.toShard;
    var stateHash: uint256;
    if (state is ContractState) {
        if (shard is AddressShardingOptions) {
            stateHash = archivedStateHashPrefix(shard!.fixedPrefixLength, state.code, state.data);
        } else {
            stateHash = archivedStateHash(state.code, state.data);
        }
    } else {
        stateHash = state.hash();
    }
    var result: builder;
    if (shard is AddressShardingOptions) {
        val depth = shard!.fixedPrefixLength;
        val maskedHash = stateHash & ((1 << (256 - depth)) - 1);
        val suffixWidth = 256 - depth;
        val prefix = (shard!.closeTo as slice).getMiddleBits(11, depth);
        result = beginCell()
            .storeUint(4, 3)
            .storeInt(self.workchain, 8)
            .storeSlice(prefix)
            .storeUint(maskedHash, suffixWidth);
    } else {
        result = beginCell().storeUint(4, 3).storeInt(self.workchain, 8).storeUint(stateHash, 256);
    }
    return result;
}

@inline
fun AutoDeployAddress.calculateArchivedAddress(self): address {
    return archivedAddressSlice(self.calculateArchivedAddressBuilder());
}
