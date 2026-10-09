// decompiled by @fiscaldev
import "payment"

struct PoolSwapPartner { identity: uint256; fee: uint16 }
struct PoolSwapReferrer { identity: uint256; fee: uint16 }

type PoolOptionalPartner = PoolSwapPartner?
type PoolOptionalReferrer = PoolSwapReferrer?

// Select the tag of each three-slot nullable record. Separate NIP primitives
// let the optimizer remove unused copies; the explicit EQINT preserves the
// archived null-first branch order.
fun poolPartnerTag(value: PoolOptionalPartner): int asm "NIP" "NIP"
fun poolReferrerTag(value: PoolOptionalReferrer): int asm "NIP" "NIP"
fun poolRouteTagIsAbsent(value: int): bool asm "0 EQINT"

fun PoolOptionalPartner.packToBuilder(self, mutate b: builder) {
    if (poolRouteTagIsAbsent(poolPartnerTag(self))) { b.storeBool(false); }
    else { b.storeBool(true).storeUint(self!.identity, 256).storeUint(self!.fee, 16); }
}

fun PoolOptionalReferrer.packToBuilder(self, mutate b: builder) {
    if (poolRouteTagIsAbsent(poolReferrerTag(self))) { b.storeBool(false); }
    else { b.storeBool(true).storeUint(self!.identity, 256).storeUint(self!.fee, 16); }
}

struct (0xc442500f) PoolSwapPayload {
    minimalAmountOut: coins
    deadline: uint40
    next: cell?
    partner: PoolOptionalPartner
    referrer: PoolOptionalReferrer
}

fun PoolSwapPayload.packToBuilder(self, mutate b: builder) {
    b.storeUint(0xc442500f, 32).storeCoins(self.minimalAmountOut)
        .storeUint(self.deadline, 40).storeDict(self.next);
    self.partner.packToBuilder(mutate b);
    self.referrer.packToBuilder(mutate b);
}

struct (0xa5a7cbf8) PoolRoutedNativePayment {
    queryId: uint64
    amount: coins
    payment: cell
    payout: cell
}

struct (0xcbc33949) PoolRoutedJettonPayment { payment: cell; payout: cell }

// Continue a swap with the carried balance. The jetton transfer reserves
// 50,000,000 from the requested forward gas for the wallet's processing.
@inline_ref
fun routePoolSwap(
    asset: any_address,
    nextPool: any_address,
    poolWallet: any_address,
    excessesTo: any_address,
    queryId: uint64,
    amount: coins,
    payload: PoolSwapPayload,
    payout: cell,
    forwardGas: coins,
) {
    if (asset.isNone()) {
        val payment = payload.toCell();
        val body = PoolRoutedNativePayment { queryId, amount, payment, payout }.toCell();
        val message = beginCell().storeUint(0x10, 6).storeSlice(nextPool as slice)
            .storeUint(1, 111).storeRef(body).endCell();
        OutMessage { messageCell: message }.send(144);
        return;
    }
    if (asset.isInternal()) {
        val gas = forwardGas - 50000000;
        val customPayload: cell? = null;
        val payment = payload.toCell();
        val notification = PoolRoutedJettonPayment { payment, payout }.toCell();
        var transfer = beginCell().storeUint(0x0f8a7ea5, 32).storeUint(queryId, 64).storeCoins(amount)
            .storeSlice(nextPool as slice).storeSlice(excessesTo as slice)
            .storeDict(customPayload).storeCoins(gas).storeBool(true).storeRef(notification);
        val body = transfer.endCell();
        val message = beginCell().storeUint(0x10, 6).storeSlice(poolWallet as slice)
            .storeUint(1, 111).storeRef(body).endCell();
        OutMessage { messageCell: message }.send(144);
        return;
    }
    throw 31;
}
