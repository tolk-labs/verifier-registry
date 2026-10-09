// decompiled by @fiscaldev
// Archived external-out event format; the helper methods return the SENDMSG fee.
@overflow1023_policy("suppress")
struct (0x78e79ba4) PoolSwapEvent {
    xToY: bool
    amountIn: coins
    amountOut: coins
    initiator: any_address
    recipient: any_address
    nextState: cell
    fees: cell
}

@overflow1023_policy("suppress")
struct (0x35df2e12) PoolDepositEvent {
    amountX: coins
    amountY: coins
    liquidity: coins
    initiator: any_address
    recipient: any_address
    nextState: cell
}

@overflow1023_policy("suppress")
struct (0xc0d77b54) PoolWithdrawalEvent {
    liquidity: coins
    amountX: coins
    amountY: coins
    initiator: any_address
    recipient: any_address
    nextState: cell
}

fun poolEventDestination(): any_address
    asm "b{00} PUSHSLICE"

@method_id(22)
@inline_ref
fun emitPoolSwapEntry(event: PoolSwapEvent): coins {
    val destination = poolEventDestination();
    val body = event.toCell();
    val message = beginCell().storeUint(0xc, 4).storeSlice(destination as slice)
        .storeUint(1, 98).storeRef(body).endCell();
    return OutMessage { messageCell: message }.sendAndEstimateFee(1);
}

@method_id(23)
@inline_ref
fun emitPoolDepositEntry(event: PoolDepositEvent): coins {
    val destination = poolEventDestination();
    val body = event.toCell();
    val message = beginCell().storeUint(0xc, 4).storeSlice(destination as slice)
        .storeUint(1, 98).storeRef(body).endCell();
    return OutMessage { messageCell: message }.sendAndEstimateFee(1);
}

@method_id(24)
@inline_ref
fun emitPoolWithdrawalEntry(event: PoolWithdrawalEvent): coins {
    val destination = poolEventDestination();
    val body = event.toCell();
    val message = beginCell().storeUint(0xc, 4).storeSlice(destination as slice)
        .storeUint(1, 98).storeRef(body).endCell();
    return OutMessage { messageCell: message }.sendAndEstimateFee(1);
}

fun emitPoolSwap(event: PoolSwapEvent): coins asm "22 CALLDICT"
fun emitPoolDeposit(event: PoolDepositEvent): coins asm "23 CALLDICT"
fun emitPoolWithdrawal(event: PoolWithdrawalEvent): coins asm "24 CALLDICT"
