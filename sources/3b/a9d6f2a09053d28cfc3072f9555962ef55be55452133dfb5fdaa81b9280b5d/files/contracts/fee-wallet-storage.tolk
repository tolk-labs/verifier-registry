import "fee-rules"

struct FeeWalletStorage {
    jettonBalance: coins
    ownerAddress: address
    minterAddress: address
    excluded: bool
    rules: Cell<FeeRules>
}

fun FeeWalletStorage.load(): FeeWalletStorage {
    return FeeWalletStorage.fromCell(contract.getData());
}

fun FeeWalletStorage.save(self) {
    contract.setData(self.toCell());
}
