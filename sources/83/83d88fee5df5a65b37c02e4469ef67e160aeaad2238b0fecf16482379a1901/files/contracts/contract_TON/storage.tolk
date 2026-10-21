struct ExtraFieldsTon {
    timestamp: uint64
    clientAmountInit: uint75
    providerDepositInit: uint75
    royaltyInit: uint75
    adminAddress: address
    completed: bool
    percent: int8
    errMode: int8
    errModeAt: uint64
    mode: int8
}

struct StorageTon {
    clientAddress: address
    providerAddress: address
    clientAmount: uint75
    providerDeposit: uint75
    extra: Cell<ExtraFieldsTon>
}

fun StorageTon.load(): StorageTon {
    return StorageTon.fromCell(contract.getData());
}

fun StorageTon.save(self) {
    contract.setData(self.toCell());
}
