// decompiled by @fiscaldev
import "payout-config"

type PoolForwardPayload = cell | RemainingBitsAndRefs

// Keep the empty slice's explicit union slot; current flow analysis narrows it.
fun emptyPoolForwardPayload(): PoolForwardPayload
    asm "x{} PUSHSLICE 4 PUSHINT"

fun PoolForwardPayload.packToBuilder(self, mutate b: builder) {
    if (self is cell) { b.storeBool(true).storeRef(self); }
    else { b.storeBool(false).storeSlice(self); }
}

struct (0xe8db4696) PoolPaymentResult {
    exitCode: int32
    payload: cell?
}

@inline
fun poolNotificationPayload(payload: cell?, wrapPayload: bool, exitCode: int32): PoolForwardPayload {
    var result = emptyPoolForwardPayload();
    if (payload != null || wrapPayload) {
        if (wrapPayload) { result = PoolPaymentResult { exitCode, payload }.toCell(); }
        else { result = payload ?? result; }
    }
    return result;
}

@overflow1023_policy("suppress")
struct (0x0f8a7ea5) PoolJettonTransfer {
    queryId: uint64
    amount: coins
    recipient: any_address
    excessesTo: any_address
    customPayload: cell?
    forwardGas: coins
    forwardPayload: PoolForwardPayload
}

// Returns native principal spent and SENDMSG's forwarding-fee estimate.
@inline_ref
fun sendPoolPayment(
    asset: any_address,
    wallet: any_address,
    amount: coins,
    options: PoolPayoutOptions,
    excessesTo: any_address,
    queryId: uint64,
    exitCode: int32,
): (coins, coins) {
    if (asset.isNone()) {
        val value = amount + options.extraGas;
        val message = beginCell().storeUint(0x10, 6).storeSlice(options.destination as slice).storeCoins(value)
            .storeUint(0x3216ca09, 139).storeUint(queryId, 64).storeCoins(amount)
            .storeInt(exitCode, 32).storeDict(options.payload).endCell();
        return (amount, OutMessage { messageCell: message }.sendAndEstimateFee(17));
    }
    if (asset.isInternal()) {
        val forwardPayload = poolNotificationPayload(options.payload, options.wrapPayload, exitCode);
        val value = 50000000 + options.extraGas;
        val customPayload: cell? = null;
        var transfer = beginCell().storeUint(0x0f8a7ea5, 32).storeUint(queryId, 64).storeCoins(amount)
            .storeSlice(options.destination as slice).storeSlice(excessesTo as slice)
            .storeDict(customPayload).storeCoins(options.extraGas);
        forwardPayload.packToBuilder(mutate transfer);
        val body = transfer.endCell();
        val message = beginCell().storeUint(0x10, 6).storeSlice(wallet as slice).storeCoins(value)
            .storeUint(1, 107).storeRef(body).endCell();
        return (0, OutMessage { messageCell: message }.sendAndEstimateFee(17));
    }
    throw 31;
}
