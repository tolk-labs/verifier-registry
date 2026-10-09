// decompiled by @fiscaldev
type ForwardPayload = cell | RemainingBitsAndRefs

fun ForwardPayload.unpackFromSlice(mutate s: slice): ForwardPayload {
    var result: ForwardPayload;
    if (s.loadUint(1) != 0) {
        result = s.loadRef();
    } else {
        result = s as RemainingBitsAndRefs;
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
    from: any_address
    excessesTo: any_address
    forwardTon: coins
    payload: ForwardPayload
}

@overflow1023_policy("suppress")
struct (0x0f8a7ea5) Transfer {
    queryId: uint64
    amount: coins
    destination: any_address
    excessesTo: any_address
    customPayload: cell?
    forwardTon: coins
    payload: ForwardPayload
}

struct (0x595f07bc) Burn {
    queryId: uint64
    amount: coins
    excessesTo: any_address
    customPayload: cell?
}

struct (0xb7459e2c) Sell {
    queryId: uint64
    amount: coins
    minTon: coins
    excessesTo: any_address
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
    from: any_address
    payload: ForwardPayload
}

@overflow1023_policy("suppress")
struct (0x7bdd97de) BurnNotification {
    queryId: uint64
    amount: coins
    from: any_address
    excessesTo: any_address
}

@overflow1023_policy("suppress")
struct (0x646ad424) SellNotification {
    queryId: uint64
    amount: coins
    minTon: coins
    from: any_address
    excessesTo: any_address
    partner: cell?
    referrer: cell?
}

@overflow1023_policy("suppress")
struct WalletStorage {
    balance: coins
    owner: any_address
    master: any_address
}
