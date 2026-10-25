struct (0x26aa2e5e) CreateTonContract {
    clientAddress: address
    providerAddress: address
    clientAmountInit: uint75
    providerDepositInit: uint75
}

struct (0xf3dac9eb) CreateUsdtContract {
    clientAddress: address
    providerAddress: address
    clientAmountInit: uint72
    providerDepositInit: uint72
}

struct (0xd9b44b24) WithdrawTon {
    dest: address
    amount: coins
}

// Either field may be omitted. At least one must be present:
// newCode only swaps code, newData only swaps storage, both swap together.
struct (0x4d2bfb3f) UpdateCode {
    newCode: cell?
    newData: cell?
}

// Same opcode as ContractTON Transfer. Minter always sends a real sender,
// so bounce refund can use `address` rather than `address?`.
struct (0x911e3651) TransferRefund {
    sender: address
}
