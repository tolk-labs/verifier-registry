// decompiled by @fiscaldev
type ForwardPayload = cell | RemainingBitsAndRefs

// Consume all inline payload while leaving an empty cursor for the ENDS check.
fun slice.takeRemainder(mutate self): RemainingBitsAndRefs
    asm( -> 1 0) "x{} PUSHSLICE"

fun ForwardPayload.unpackFromSlice(mutate s: slice): ForwardPayload {
    var result: ForwardPayload;
    if (s.loadUint(1) != 0) {
        result = s.loadRef();
    } else {
        result = s.takeRemainder();
    }
    return result;
}

fun ForwardPayload.packToBuilder(self, mutate b: builder) {
    if (self is cell) {
        b.storeBool(true).storeRef(self);
    } else {
        b.storeBool(false).storeSlice(self);
    }
}

@overflow1023_policy("suppress")
struct (0x178d4519) InternalTransfer {
    queryId: uint64
    amount: coins
    from: address?
    excessesTo: address?
    forwardTon: coins
    payload: ForwardPayload
}

@overflow1023_policy("suppress")
struct (0x0f8a7ea5) Transfer {
    queryId: uint64
    amount: coins
    destination: address
    excessesTo: address?
    customPayload: cell?
    forwardTon: coins
    payload: ForwardPayload
}

struct (0x595f07bc) Burn {
    queryId: uint64
    amount: coins
    excessesTo: address?
    customPayload: cell?
}

struct (0xb7459e2c) Sell {
    queryId: uint64
    amount: coins
    minTon: coins
    excessesTo: address?
    partner: cell?
    referrer: cell?
}

type Incoming = InternalTransfer | Transfer | Burn | Sell

struct (0x178d4519) BouncedTransfer {
    queryId: uint64
    amount: coins
    tail: RemainingBitsAndRefs
}

struct (0x7bdd97de) BouncedBurn {
    queryId: uint64
    amount: coins
    tail: RemainingBitsAndRefs
}

struct (0x646ad424) BouncedSell {
    queryId: uint64
    amount: coins
    tail: RemainingBitsAndRefs
}

type Bounced = BouncedTransfer | BouncedBurn | BouncedSell

struct (0x7362d09c) Notification {
    queryId: uint64
    amount: coins
    from: address?
    payload: ForwardPayload
}

struct (0x7bdd97de) BurnNotification {
    queryId: uint64
    amount: coins
    from: address
    excessesTo: address?
}

struct (0x646ad424) SellNotification {
    queryId: uint64
    amount: coins
    minTon: coins
    from: address
    excessesTo: address?
    partner: cell?
    referrer: cell?
}

struct WalletStorage {
    balance: coins
    owner: address
    master: address
}
