// decompiled by @fiscaldev
struct PoolPayoutOptions {
    destination: any_address
    extraGas: coins
    payload: cell?
    wrapPayload: bool
}

@overflow1023_policy("suppress")
struct PoolExtendedPayout {
    fulfill: PoolPayoutOptions
    reject: PoolPayoutOptions
    excessesTo: any_address
}

@inline_ref
fun normalizePoolPayout(payout: PoolExtendedPayout, fallback: any_address): PoolExtendedPayout {
    if (!payout.fulfill.destination.isInternal()) { payout.fulfill.destination = fallback; }
    if (!payout.reject.destination.isInternal()) { payout.reject.destination = fallback; }
    if (!payout.excessesTo.isInternal()) { payout.excessesTo = fallback; }
    return payout;
}
