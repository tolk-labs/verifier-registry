// decompiled by @fiscaldev
import "types"

@pure
fun initPrefix(mutate s: slice): bool
    asm "x{796F5A0C} SDBEGINSQ"

@pure
fun buyPrefix(mutate s: slice): bool
    asm "x{94826557} SDBEGINSQ"

@pure
fun sellPrefix(mutate s: slice): bool
    asm "x{646AD424} SDBEGINSQ"

@pure
fun burnPrefix(mutate s: slice): bool
    asm "x{7BDD97DE} SDBEGINSQ"

@pure
fun resolvePrefix(mutate s: slice): bool
    asm "x{2C76B973} SDBEGINSQ"

@pure
fun claimPrefix(mutate s: slice): bool
    asm "x{AD7269A8} SDBEGINSQ"

@pure
fun sweepPrefix(mutate s: slice): bool
    asm "x{F14B54F3} SDBEGINSQ"

@pure
fun excessPrefix(mutate s: slice): bool
    asm "x{D53276DB} SDBEGINSQ"

@pure
fun poolPrefix(mutate s: slice): bool
    asm "x{CE185BD7} SDBEGINSQ"

// Preserve the old compiler's right-aligned union slots for this three-field
// callback. This codec contains only wire loads and null padding, no handler logic.
fun unpackLegacyPoolInitialized(mutate s: slice): Incoming
    asm( -> 8 0 1 2 3 4 5 6 7 9)
        "64 LDU 32 LDI LDDICT PUSHNULL s0 s3 s4 XCHG3 PUSHNULL PUSHNULL SWAP2 PUSHNULL PUSHNULL s0 s0 s3 XCHG3 141 PUSHINT"

fun Incoming.unpackFromSlice(mutate s: slice): Incoming {
    var result: Incoming;
    if (initPrefix(mutate s)) {
        result = Initialize {
            queryId: s.loadUint(64),
            amount: s.loadCoins(),
            partner: s.loadAny<Partner?>(),
            referrer: s.loadAny<Referrer?>(),
        };
    } else if (buyPrefix(mutate s)) {
        result = Buy {
            queryId: s.loadUint(64),
            amount: s.loadCoins(),
            minOut: s.loadCoins(),
            receiver: s.loadAddressAny(),
            partner: s.loadAny<Cell<Partner>?>(),
            referrer: s.loadAny<Cell<Referrer>?>(),
        };
    } else if (sellPrefix(mutate s)) {
        result = Sell {
            queryId: s.loadUint(64),
            amount: s.loadCoins(),
            minOut: s.loadCoins(),
            owner: s.loadAddressAny(),
            receiver: s.loadAddressAny(),
            partner: s.loadAny<Cell<Partner>?>(),
            referrer: s.loadAny<Cell<Referrer>?>(),
        };
    } else if (burnPrefix(mutate s)) {
        result = Burn {
            queryId: s.loadUint(64),
            amount: s.loadCoins(),
            owner: s.loadAddressAny(),
            receiver: s.loadAddressAny(),
        };
    } else if (resolvePrefix(mutate s)) {
        result = ResolveWallet {
            queryId: s.loadUint(64),
            owner: s.loadAddressAny(),
            includeOwner: s.loadBool(),
        };
    } else if (claimPrefix(mutate s)) {
        result = ClaimCreator {
            queryId: s.loadUint(64),
            to: s.loadAddressAny(),
            receiver: s.loadAddressAny(),
        };
    } else if (sweepPrefix(mutate s)) {
        result = SweepController {
            queryId: s.loadUint(64),
            to: s.loadAddressAny(),
        };
    } else if (excessPrefix(mutate s)) {
        result = Excesses { queryId: s.loadUint(64) };
    } else {
        if (!poolPrefix(mutate s)) {
            throw 65535;
        }
        // Register tag 141 after the eight preceding incoming variants.
        val layoutAnchor: Incoming = PoolInitialized {
            queryId: 0,
            exitCode: 0,
            payload: null,
        };
        result = unpackLegacyPoolInitialized(mutate s);
    }
    return result;
}
