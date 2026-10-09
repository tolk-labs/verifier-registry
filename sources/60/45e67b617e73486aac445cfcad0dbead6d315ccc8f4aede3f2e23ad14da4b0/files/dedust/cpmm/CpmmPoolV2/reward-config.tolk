// decompiled by @fiscaldev
import "storage"

@method_id(21)
@inline_ref
fun findAllowedPoolRewardEntry(config: PoolConfig, asset: any_address): (PoolRewardConfig, uint2) {
    var entry = config.allowedRewards.findFirst();
    while (entry.isFound) {
        val reward = entry.loadValue();
        if ((reward.asset as slice).bitsEqual(asset as slice)) {
            return (reward, entry.getKey());
        }
        entry = config.allowedRewards.iterateNext(entry);
    }
    throw 42;
}

fun findAllowedPoolReward(config: PoolConfig, asset: any_address): (PoolRewardConfig, uint2)
    asm "21 CALLDICT"
