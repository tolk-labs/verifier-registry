struct StorageMinter {
    contractUsdtCode: cell
    contractTonCode: cell
    adminAddress: address
}

fun StorageMinter.load(): StorageMinter {
    return StorageMinter.fromCell(contract.getData());
}
// fun StorageMinter.save(self) {
//     contract.setData(self.toCell());
// }
