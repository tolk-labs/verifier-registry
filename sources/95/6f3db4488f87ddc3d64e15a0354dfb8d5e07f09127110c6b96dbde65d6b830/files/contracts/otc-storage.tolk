import "otc-messages"

// Immutable once the order is initialised.
struct OrderTerms {
    jettonMaster: address
    feeWallet: address
    amountTotal: coins
    totalPrice: coins
    minFill: coins
    expiresAt: uint32
}

// Changes during the order's life.
struct OrderLive {
    jettonWallet: address?
    amountLeft: coins
    privateTaker: address?
}

// Initial data (status 0, refs null) fixes the order address = f(code, factory, maker, nonce).
struct OrderStorage {
    status: uint8
    factory: address
    maker: address
    nonce: uint64
    terms: Cell<OrderTerms>?
    live: Cell<OrderLive>?
}

fun OrderStorage.load(): OrderStorage {
    return OrderStorage.fromCell(contract.getData());
}

fun OrderStorage.save(self) {
    contract.setData(self.toCell());
}

struct FactoryStorage {
    admin: address
    pendingAdmin: address?
    feeWallet: address   // house fee wallet; no setter exists
    maxOrderNano: coins  // per-order cap; can only be raised
    paused: bool         // blocks new orders only
}

fun FactoryStorage.load(): FactoryStorage {
    return FactoryStorage.fromCell(contract.getData());
}

fun FactoryStorage.save(self) {
    contract.setData(self.toCell());
}

fun initialOrderStorage(factory: address, maker: address, nonce: uint64): OrderStorage {
    return {
        status: 0,
        factory,
        maker,
        nonce,
        terms: null,
        live: null,
    };
}

// Getter shapes
struct OrderDataReply {
    status: uint8
    factory: address
    maker: address
    nonce: uint64
    jettonMaster: address?
    feeWallet: address?
    jettonWallet: address?
    amountTotal: coins
    amountLeft: coins
    totalPrice: coins
    minFill: coins
    expiresAt: uint32
    privateTaker: address?
}

struct FillQuoteReply {
    cost: coins      // goes to maker before maker fee
    takerFee: coins
    makerFee: coins
    takerPays: coins // cost + takerFee (attach FILL_GAS on top)
    makerGets: coins // cost - makerFee
}
