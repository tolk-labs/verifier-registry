// decompiled by @fiscaldev
// Read transaction context where each handler needs it, without extra stack slots.
struct PoolInboundContext {}

@pure
fun PoolInboundContext.senderAddress(self): any_address asm "INMSG_SRC"

@pure
fun PoolInboundContext.valueCoins(self): coins asm "INMSG_VALUE"

@pure
fun poolOriginalForwardFee(): coins asm "3 INMSGPARAM" "0 PUSHINT" "GETORIGINALFWDFEE"
