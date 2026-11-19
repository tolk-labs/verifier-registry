struct (0x7c0d5e20) LockMinting {
    queryId: uint64
    until: uint32
}

struct (0x7c0d5e24) TakeGram {
    queryId: uint64
}

struct (0x7c0d5e25) TakeTokens {
    queryId: uint64
    wallet: address
    amount: coins
}
