import "@contracts/env.tolk"
import "@contracts/sharding"
import "@contracts/contract_USDT/storage"

// Tether (mainnet) layout: status:uint4 + balance + owner + minter, no shard.
// Проверено на чейне: data_hash и адрес 0:DC6A8DF… реального кошелька Tether.
fun calcTetherWalletAddress(
    ownerAddress: address,
    minterAddress: address,
): address {
    val storage: TetherWalletStorage = {
        status: 0,
        jettonBalance: 0,
        ownerAddress,
        minterAddress,
    };
    val init: AutoDeployAddress = {
        workchain: MY_WORKCHAIN,
        stateInit: { code: getUsdtWalletCode(), data: storage.toCell() },
    };
    return init.calculateAddress();
}

// Testnet (legacy) layout: balance + owner + minter, sharded by owner.
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
    if (USDT_WALLET_TETHER_LAYOUT) {
        return calcTetherWalletAddress(ownerAddress, USDT_MINTER_ADDRESS);
    }
    val jwDeployed = calcDeployedJettonWallet(ownerAddress);
    return jwDeployed.calculateAddress();
}
