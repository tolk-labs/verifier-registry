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

// Tether (mainnet) jetton wallet data: status:uint4 first, see
// ton-blockchain/stablecoin-contract jetton-utils.fc (pack_jetton_wallet_data).
struct TetherWalletStorage {
    status: uint4
    jettonBalance: coins
    ownerAddress: address
    minterAddress: address
}
