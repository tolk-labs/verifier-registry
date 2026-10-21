// uint72 max: 4_722_366_482_869_645 USDT

struct ExtraFieldsUsdt {
    timestamp: uint64
    clientAmountInit: uint72
    providerDepositInit: uint72
    royaltyInit: uint72
    adminAddress: address
    completed: bool
    percent: int8
    errMode: int8
    errModeAt: uint64
    mode: int8
}

struct StorageUsdt {
    clientAddress: address
    providerAddress: address
    clientAmount: uint72
    providerDeposit: uint72
    extra: Cell<ExtraFieldsUsdt>
}

fun StorageUsdt.load(): StorageUsdt {
    return StorageUsdt.fromCell(contract.getData());
}

fun StorageUsdt.save(self) {
    contract.setData(self.toCell());
}

struct WalletStorage {
    jettonBalance: coins
    ownerAddress: address
    minterAddress: address
}
