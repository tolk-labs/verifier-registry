struct (0x911e3651) Transfer {
    sender: address?
}

struct (0xd43d636a) RefundTon {
    tonAmount: uint75
    addressRefund: address?
}

// AfterHalfYear: drain all booked TON (clientAmount + providerDeposit).
struct (0x0accb5c4) ErrRefund {
    addressRefund: address?
}

struct (0xa1b2c3d4) RefundBounce {
    queryId: uint8 // QueryRole
    tonAmount: uint75
}
