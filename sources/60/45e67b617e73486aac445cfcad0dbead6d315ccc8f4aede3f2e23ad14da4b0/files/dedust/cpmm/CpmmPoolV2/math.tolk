// decompiled by @fiscaldev
// Integer square root used when the Pool first mints liquidity.
// The original early return includes negative values; callers supply coin products.
fun checkedRootCorrection(condition: bool): int
    asm "1 PUSHINT 0 PUSHINT CONDSELCHK"

@inline_ref
fun poolLiquiditySqrt(value: int): int {
    if (value < 2) { return value; }
    var reduced = value;
    var estimate = 1;
    if (reduced >= (1 << 128)) { reduced >>= 128; estimate = 1 << 64; }
    if (reduced >= (1 << 64)) { reduced >>= 64; estimate <<= 32; }
    if (reduced >= (1 << 32)) { reduced >>= 32; estimate <<= 16; }
    if (reduced >= (1 << 16)) { reduced >>= 16; estimate <<= 8; }
    if (reduced >= (1 << 8)) { reduced >>= 8; estimate <<= 4; }
    if (reduced > 15) { reduced >>= 4; estimate <<= 2; }
    if (reduced > 3) { estimate <<= 1; }
    estimate = (estimate * 3) >> 1;
    // Six unrolled Newton rounds retain the original fixed gas/layout.
    estimate = (estimate + value / estimate) >> 1;
    estimate = (estimate + value / estimate) >> 1;
    estimate = (estimate + value / estimate) >> 1;
    estimate = (estimate + value / estimate) >> 1;
    estimate = (estimate + value / estimate) >> 1;
    estimate = (estimate + value / estimate) >> 1;
    return estimate - checkedRootCorrection(value / estimate < estimate);
}
