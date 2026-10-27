// Immutable deployment network: TON Mainnet. It is not configurable at runtime.
// SAFETY: GLOBALID reads the chain identifier without consuming arguments.
fun releaseGlobalId(): int
    asm "GLOBALID"

fun requireMainnet() {
    assert (releaseGlobalId() == -239) throw 913;
}
