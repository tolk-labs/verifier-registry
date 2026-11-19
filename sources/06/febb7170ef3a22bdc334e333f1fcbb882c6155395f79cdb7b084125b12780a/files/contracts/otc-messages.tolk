// Order terms the maker asks for. Kept in its own cell (fits < 1023 bits).
struct OrderRequest {
    jettonMaster: address
    amountTotal: coins   // jetton units to sell
    totalPrice: coins    // nanoGRAM for the whole amount (exact; partial fills are pro-rata)
    minFill: coins       // smallest partial fill in jetton units (last remainder always allowed)
    privateTaker: address? // when set, only this wallet can fill
}

// maker -> factory
struct (0x4f544331) CreateOrder {
    queryId: uint64
    nonce: uint64
    request: Cell<OrderRequest>
}

// factory -> order (deploy message)
struct (0x4f544332) InitOrder {
    queryId: uint64
    feeWallet: address
    request: Cell<OrderRequest>
}

// taker -> order
struct (0x4f544333) FillOrder {
    queryId: uint64
    amount: coins
}

// maker -> order
struct (0x4f544334) CancelOrder {
    queryId: uint64
}

// 0x4f544335 (CloseExpired) belonged to v1, which had order expiry; v2 orders stay open until
// filled or cancelled by the maker, and the op is never reused.

// maker -> order, only when closed: recover stray jettons sent to the order's wallet
struct (0x4f544336) SweepJettons {
    queryId: uint64
    amount: coins
}

// admin -> factory
struct (0x4f544341) SetPaused {
    queryId: uint64
    paused: bool
}

struct (0x4f544342) RaiseCap {
    queryId: uint64
    newMaxOrderNano: coins
}

struct (0x4f544343) ProposeAdmin {
    queryId: uint64
    newAdmin: address
}

struct (0x4f544344) ClaimAdmin {
    queryId: uint64
}
