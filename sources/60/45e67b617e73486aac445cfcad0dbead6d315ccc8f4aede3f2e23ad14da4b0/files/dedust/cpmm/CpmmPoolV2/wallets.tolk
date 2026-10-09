// decompiled by @fiscaldev
// Wallet/asset registries and resolver scheduling shared by both Pool revisions.
type AddressLookup = map<uint256, any_address>

struct PoolWallets {
    walletsByAssets: AddressLookup
    assetsByWallets: AddressLookup
    resolutions: AddressLookup
}

// Compatibility primitives preserve the old checked stack layouts.
fun assertWalletBasechain(workchain: int): void
    asm "0 EQINT 32 THROWIFNOT"

fun basechainAssetHash(identity: (int8, uint256)): uint256
    asm "OVER 0 EQINT 1 2 BLKDROP2 32 THROWIFNOT"

fun findWalletAddress(dictionary: AddressLookup, key: uint256): MapLookupResult<any_address>
    asm(key dictionary) "8 PUSHPOW2 DICTUGET NULLSWAPIFNOT"

fun AddressLookup.takeResolution(mutate self, key: uint256): MapLookupResult<any_address>
    asm(key self) "8 PUSHPOW2 DICTUDELGET NULLSWAPIFNOT"

@inline
fun allocateWalletResolution(
    resolutions: AddressLookup,
    asset: any_address,
    customResolvers: AddressLookup,
): (AddressLookup, bool, any_address) {
    val assetHash = basechainAssetHash(asset.getWorkchainAndHash());
    var resolver = asset;
    var resolverHash = assetHash;
    val custom = customResolvers.get(assetHash);
    if (custom.isFound) {
        resolver = custom.loadValue();
        val (resolverWorkchain, hash) = resolver.getWorkchainAndHash();
        assertWalletBasechain(resolverWorkchain);
        resolverHash = hash;
    }
    var updated = resolutions;
    val previous = updated.setAndGetPrevious(resolverHash, asset);
    return (updated, !previous.isFound, resolver);
}

@inline_ref
fun scheduleWalletResolution(resolutions:AddressLookup,asset:any_address,customResolvers:AddressLookup):(AddressLookup,bool,any_address) {
    return allocateWalletResolution(resolutions,asset,customResolvers);
}

// The production caller passes all three wallet maps. Unchanged maps stay
// below the resolver's three working slots and are returned by mutate.
@inline_ref
fun schedulePoolWallets(mutate wallets:PoolWallets,asset:any_address,customResolvers:AddressLookup):(bool,any_address) {
    val (updated,isNew,resolver)=allocateWalletResolution(wallets.resolutions,asset,customResolvers);
    wallets.resolutions=updated;
    return (isNew,resolver);
}

@inline_ref
fun registerPoolWallet(
    walletsByAssets: AddressLookup,
    assetsByWallets: AddressLookup,
    resolutions: AddressLookup,
    asset: any_address,
    wallet: any_address,
): PoolWallets {
    val (assetWorkchain, assetHash) = asset.getWorkchainAndHash();
    assertWalletBasechain(assetWorkchain);
    val previousWallet = walletsByAssets.setAndGetPrevious(assetHash, wallet);
    assert (!previousWallet.isFound) throw 39;
    val (walletWorkchain, walletHash) = wallet.getWorkchainAndHash();
    assertWalletBasechain(walletWorkchain);
    val previousAsset = assetsByWallets.setAndGetPrevious(walletHash, asset);
    assert (!previousAsset.isFound) throw 39;
    return { walletsByAssets, assetsByWallets, resolutions };
}

@inline_ref
fun assetForRegisteredWallet(wallets: PoolWallets, wallet: any_address): any_address {
    val (workchain, walletHash) = wallet.getWorkchainAndHash();
    assertWalletBasechain(workchain);
    val asset = findWalletAddress(wallets.assetsByWallets, walletHash);
    assert (asset.isFound) throw 40;
    return asset.loadValue();
}

@inline_ref
fun finishWalletResolution(wallets: PoolWallets, resolver: any_address, wallet: any_address): PoolWallets {
    val (workchain, resolverHash) = resolver.getWorkchainAndHash();
    assertWalletBasechain(workchain);
    val pending = wallets.resolutions.takeResolution(resolverHash);
    assert (pending.isFound) throw 41;
    val asset = pending.loadValue();
    return registerPoolWallet(wallets.walletsByAssets, wallets.assetsByWallets, wallets.resolutions, asset, wallet);
}
