import "@contracts/env.tolk"
import "@contracts/sharding"
import "@contracts/contract_USDT/storage"

fun calcDeployedJettonWallet(
    ownerAddress: address,
): AutoDeployAddress {
    val emptyWalletStorage: WalletStorage = {
        jettonBalance: 0,
        ownerAddress,
        minterAddress: USDT_MINTER_ADDRESS,
    };

    return {
        workchain: MY_WORKCHAIN,
        stateInit: { code: getUsdtWalletCode(), data: emptyWalletStorage.toCell() },
        toShard: { fixedPrefixLength: SHARD_DEPTH, closeTo: ownerAddress },
    };
}

fun calcAddressOfJettonWallet(
    ownerAddress: address,
): address {
    val jwDeployed = calcDeployedJettonWallet(ownerAddress);
    return jwDeployed.calculateAddress();
}
