import "@contracts/sharding"
import "@contracts/contract_TON/storage"
import "@contracts/contract_USDT/storage"

fun calcDeployedTonContract(
    contractTonCode: cell,
    clientAddress: address,
    providerAddress: address,
    adminAddress: address,
    clientAmountInit: uint75,
    providerDepositInit: uint75,
    royaltyInit: uint75,
    timestamp: uint64,
    mode: int8,
): AutoDeployAddress {
    val emptyStorageTon: StorageTon = {
        clientAddress,
        providerAddress,
        clientAmount: 0,
        providerDeposit: 0,
        extra: ({
            timestamp,
            clientAmountInit,
            providerDepositInit,
            royaltyInit,
            adminAddress,
            completed: false,
            percent: 100,
            errMode: 0,
            errModeAt: 0,
            mode,
        } as ExtraFieldsTon).toCell(),
    };

    return {
        workchain: MY_WORKCHAIN,
        stateInit: { code: contractTonCode, data: emptyStorageTon.toCell() },
        toShard: { fixedPrefixLength: SHARD_DEPTH, closeTo: clientAddress },
    };
}

fun calcDeployedUsdtContract(
    contractUsdtCode: cell,
    clientAddress: address,
    providerAddress: address,
    adminAddress: address,
    clientAmountInit: uint72,
    providerDepositInit: uint72,
    royaltyInit: uint72,
    timestamp: uint64,
    mode: int8,
): AutoDeployAddress {
    val emptyStorageUsdt: StorageUsdt = {
        clientAddress,
        providerAddress,
        clientAmount: 0,
        providerDeposit: 0,
        extra: ({
            timestamp,
            clientAmountInit,
            providerDepositInit,
            royaltyInit,
            adminAddress,
            completed: false,
            percent: 100,
            errMode: 0,
            errModeAt: 0,
            mode,
        } as ExtraFieldsUsdt).toCell(),
    };

    return {
        workchain: MY_WORKCHAIN,
        stateInit: { code: contractUsdtCode, data: emptyStorageUsdt.toCell() },
        toShard: { fixedPrefixLength: SHARD_DEPTH, closeTo: clientAddress },
    };
}
