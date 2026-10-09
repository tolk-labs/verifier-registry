// decompiled by @fiscaldev
import "stdlib-legacy-stateinit"

@inline
fun AutoDeployAddress.matchesArchivedAddress(self, addr: address): bool {
    val state = self.stateInit;
    val shard = self.toShard;
    var hash: uint256;
    if (state is ContractState) {
        if (shard is AddressShardingOptions) {
            hash = archivedStateHashPrefix(shard.fixedPrefixLength, state.code, state.data);
        } else {
            hash = archivedStateHash(state.code, state.data);
        }
    } else {
        hash = state.hash();
    }
    if (shard is AddressShardingOptions) {
        hash &= (1 << (256 - shard.fixedPrefixLength)) - 1;
    }
    val (workchain, fullHash) = addr.getWorkchainAndHash();
    var suffix = fullHash;
    if (shard is AddressShardingOptions) {
        suffix &= (1 << (256 - shard.fixedPrefixLength)) - 1;
    }
    return (suffix == hash) & (workchain == self.workchain);
}

fun isStandardAddress(addr: any_address): bool
    asm "x{A_} SDBEGINSQ NIP"
