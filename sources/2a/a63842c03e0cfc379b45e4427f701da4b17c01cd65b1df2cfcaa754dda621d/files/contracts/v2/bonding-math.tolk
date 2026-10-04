import "bonding-storage"
import "fee-storage"
import "../v1/bonding-config"

fun computeBuyOut(
    tonIn: coins,
    virtualTon: coins,
    realTon: coins,
    jettonBalance: coins,
    creatorFeeBps: int = 0,
): (coins, coins) {
    val feeTon = tonIn * PROTOCOL_FEE_BPS / BPS_DENOMINATOR +
        tonIn * creatorFeeBps / BPS_DENOMINATOR;
    val tonInNet = tonIn - feeTon;

    val xBefore = virtualTon + realTon;
    val yBefore = jettonBalance;
    val xAfter = xBefore + tonInNet;

    val yAfter = (xBefore * yBefore) / xAfter;
    val jettonsOut = yBefore - yAfter;

    return (jettonsOut, feeTon);
}

fun computeSellOut(
    jettonIn: coins,
    virtualTon: coins,
    realTon: coins,
    jettonBalance: coins,
    creatorFeeBps: int = 0,
): (coins, coins) {
    val xBefore = virtualTon + realTon;
    val yBefore = jettonBalance;
    val yAfter = yBefore + jettonIn;

    val gross = xBefore - (xBefore * yBefore) / yAfter;
    val feeTon = gross * PROTOCOL_FEE_BPS / BPS_DENOMINATOR +
        gross * creatorFeeBps / BPS_DENOMINATOR;

    val xAfter = (xBefore * yBefore) / yAfter;
    val tonOutGross = xBefore - xAfter;
    val tonOut = tonOutGross - feeTon;

    return (tonOut, feeTon);
}

fun shouldGraduate(realTon: coins, threshold: coins): bool {
    return realTon >= threshold;
}

fun maxSafeSellJettons(virtualTon: coins, realTon: coins, jettonBalance: coins): coins {
    val xBefore = virtualTon + realTon;

    val safeFloor = virtualTon + 1;
    val yAfterMax = (xBefore * jettonBalance) / safeFloor;
    if (yAfterMax <= jettonBalance) {
        return 0;
    }
    return yAfterMax - jettonBalance;
}

fun validateLaunchOptions(o: LaunchOptions) {
    assert (
        o.supply == 100000000 * 1000000000 || o.supply == 1000000000 * 1000000000 ||
        o.supply == 10000000000 * 1000000000
    ) throw 49;
    assert (
        o.creatorFeeBps == 0 || o.creatorFeeBps == 10 || o.creatorFeeBps == 50 ||
        o.creatorFeeBps == 100 ||
        o.creatorFeeBps == 200
    ) throw 49;
    assert (
        o.graduationThreshold == ton("1000") || o.graduationThreshold == ton("2000") ||
        o.graduationThreshold == ton("3000")
    ) throw 49;
    assert (o.reserveRatio == 3 || o.reserveRatio == 5 || o.reserveRatio == 8) throw 49;
    assert (o.minBuyBps <= BPS_DENOMINATOR && o.maxBuyBps <= BPS_DENOMINATOR) throw 49;
    assert (o.maxBuyBps == 0 || o.minBuyBps < o.maxBuyBps) throw 49;
    val virtual = initialVirtualReserve(o);
    val remainingAtGraduation = virtual * o.supply / (virtual + o.graduationThreshold);
    val (minTokens, _) = buyTokenLimits(o);
    assert (minTokens <= remainingAtGraduation - o.supply / 10) throw 49;
    assert (!o.buybackBurn || (o.beneficiaries == null && o.creatorFeeBps > 0)) throw 49;
    validateBeneficiaries(o.beneficiaries);
}

fun buyTokenLimits(o: LaunchOptions): (coins, coins) {
    return (
        (o.supply * o.minBuyBps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR,
        o.supply * o.maxBuyBps / BPS_DENOMINATOR,
    );
}

fun initialVirtualReserve(o: LaunchOptions): coins {
    return o.graduationThreshold / o.reserveRatio;
}

fun previewLaunch(o: LaunchOptions): LaunchPreview {
    validateLaunchOptions(o);
    val virtual = initialVirtualReserve(o);
    val x = virtual + o.graduationThreshold;
    val remaining = virtual * o.supply / x;
    val poolTon = o.graduationThreshold - MIGRATION_FEE;
    val poolTokens = poolTon * remaining / x;
    val (minBuyTokens, maxBuyTokens) = buyTokenLimits(o);
    return {
        minBuyTokens,
        maxBuyTokens,
        virtualTonReserve: virtual,
        graduationThreshold: o.graduationThreshold,
        soldTokens: o.supply - remaining,
        poolTon,
        poolTokens,
        remainingTokens: remaining - poolTokens,
        initialPriceNanoPerBillion: virtual * 1000000000000000000 / o.supply,
        graduationPriceNanoPerBillion: x * 1000000000000000000 / remaining,
    };
}
