// decompiled by @fiscaldev
import "@stdlib/gas-payments"
import "wallets"

fun poolNoneAddress(): any_address
    asm "b{00} PUSHSLICE"

@inline_ref
fun sendPoolExcesses(recipient: any_address, queryId: uint64, mode: int) {
    val message = beginCell().storeUint(0x10, 6).storeSlice(recipient as slice)
        .storeUint(0xd53276db, 143).storeUint(queryId, 64).endCell();
    sendRawMessage(message, mode | SEND_MODE_IGNORE_ERRORS);
}

@inline_ref
fun poolWalletForAsset(wallets: PoolWallets, asset: any_address): any_address {
    if (!asset.isInternal()) { return poolNoneAddress(); }
    val (workchain, hash) = asset.getWorkchainAndHash();
    assertWalletBasechain(workchain);
    val wallet = findWalletAddress(wallets.walletsByAssets, hash);
    assert (wallet.isFound) throw 40;
    return wallet.loadValue();
}

@inline_ref
fun requestPoolWalletAddress(resolver: any_address, queryId: uint64) {
    val owner = contract.getAddress();
    val processingFee = max(calculateGasFee(0, 25000), 10000000);
    // Preserve both size estimates exactly as encoded in the archived helper.
    val requestForwardFee = calculateForwardFee(0, 364, 1);
    val secondForwardFee = calculateForwardFee(0, 1, 364);
    val amount = secondForwardFee + (requestForwardFee + processingFee);
    val message = beginCell().storeUint(0x10, 6).storeSlice(resolver as slice).storeCoins(amount)
        .storeUint(0x2c76b973, 139).storeUint(queryId, 64).storeSlice(owner as slice).storeBool(false).endCell();
    sendRawMessage(message, SEND_MODE_PAY_FEES_SEPARATELY);
}
