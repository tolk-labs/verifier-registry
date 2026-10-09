// decompiled by @fiscaldev
// Import order preserves the existing address and incoming-message union layout.
import "addresses"
import "messages"
import "storage"
import "wallets"
import "compat-address"

get fun get_position_address(owner: any_address): address {
    return positionDeployment(owner).calculateArchivedAddress();
}

get fun get_pool_data(): PoolData {
    val storage = PoolStorage.fromCell(contract.getData(), { assertEndAfterReading: false });
    val config = PoolConfig.fromCell(storage.config);
    val fees = PoolFees.fromCell(storage.fees);
    val extra = PoolExtra.fromCell(storage.extra);
    return {
        status: match (storage.status) {
            PoolUninitialized => 0,
            PoolInitializing => 1,
            PoolInitialized => 2,
        },
        depositActive: storage.depositActive, swapActive: storage.swapActive,
        assetX: config.assetX, assetY: config.assetY,
        walletsByAssets: extra.wallets.walletsByAssets,
        assetsByWallets: extra.wallets.assetsByWallets,
        resolutions: extra.wallets.resolutions,
        baseFee: config.baseFee, reserveX: storage.reserveX, reserveY: storage.reserveY,
        liquidity: storage.liquidity, protocolX: fees.protocolX, protocolY: fees.protocolY,
        creatorX: fees.creatorX, creatorY: fees.creatorY,
        xCheckpoint: fees.xCheckpoint, yCheckpoint: fees.yCheckpoint,
        rewards: storage.rewards,
    };
}

// Public method name is unknown; the method ID is recovered from the dictionary.
@method_id(112421)
fun estimateWithdrawal(liquidity: int): (int, int) {
    val storage = lazy PoolStorage.fromCell(contract.getData(), { assertEndAfterReading: false });
    return storage.liquidity > 0
        ? (mulDivFloor(storage.reserveX, liquidity, storage.liquidity),
            mulDivFloor(storage.reserveY, liquidity, storage.liquidity))
        : (0, 0);
}
