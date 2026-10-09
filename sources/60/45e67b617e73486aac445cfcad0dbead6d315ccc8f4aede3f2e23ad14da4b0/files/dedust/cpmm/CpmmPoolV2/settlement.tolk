// decompiled by @fiscaldev
import "@stdlib/gas-payments"
import "payment"
import "payout-config"
import "transfers"
import "wallets"

@pure
fun poolIncomingCoins(): coins asm "INCOMINGVALUE" "FIRST"

// Materialize the shared send context before the asset arguments. These typed
// identities emit no opcode; their variable lifetimes preserve archived calls.
fun copyPoolPaymentContext(options: PoolPayoutOptions, excessesTo: any_address, queryId: uint64): (PoolPayoutOptions, any_address, uint64)
    asm "NOP"

fun copyPoolExcessesContext(excessesTo: any_address, queryId: uint64): (any_address, uint64)
    asm "NOP"

// Settle both assets, preserve pre-message funds and return remaining gas.
// Config decoding deliberately reads only the first two asset addresses.
@method_id(19)
@inline_ref
fun settlePoolAssetsEntry(
    queryId: uint64,
    config: cell,
    wallets: PoolWallets,
    amountX: coins,
    amountY: coins,
    options: PoolPayoutOptions,
    excessesTo: any_address,
    skipExcesses: bool,
) {
    var reserved = contract.getOriginalBalance() + contract.getStoragePaidPayment() - poolIncomingCoins();
    var assets = config.beginParse();
    val assetX = assets.loadAddressAny();
    val assetY = assets.loadAddressAny();
    if (amountX > 0) {
        val wallet = poolWalletForAsset(wallets, assetX);
        val (payout, excesses, query) = copyPoolPaymentContext(options, excessesTo, queryId);
        val (principal, fee) = sendPoolPayment(assetX, wallet, amountX, payout, excesses, query, 0);
        reserved += fee - principal;
    }
    if (amountY > 0) {
        val wallet = poolWalletForAsset(wallets, assetY);
        val (excesses, query) = copyPoolExcessesContext(excessesTo, queryId);
        val (principal, fee) = sendPoolPayment(assetY, wallet, amountY, options, excesses, query, 0);
        reserved += fee - principal;
    }
    reserveToncoinsOnBalance(reserved, 2);
    if (skipExcesses) { return; }
    sendPoolExcesses(excessesTo, queryId, 130);
}

// Keep the public dictionary call while placing its implementation in a reference.
fun settlePoolAssets(queryId: uint64, config: cell, wallets: PoolWallets,
    amountX: coins, amountY: coins, options: PoolPayoutOptions,
    excessesTo: any_address, skipExcesses: bool): void asm "19 CALLDICT"
