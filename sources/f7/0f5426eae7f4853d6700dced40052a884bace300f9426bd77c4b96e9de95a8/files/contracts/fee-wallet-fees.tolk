import "@stdlib/gas-payments"
import "errors"
import "sharding"

const FEE_WALLET_STORAGE_SIZE_MAX_WALLET_BITS = 19098
const FEE_WALLET_STORAGE_SIZE_MAX_WALLET_CELLS = 32
const FEE_WALLET_STORAGE_SIZE_INIT_STATE_WALLET_BITS = 18788
const FEE_WALLET_STORAGE_SIZE_INIT_STATE_WALLET_CELLS = 32

const FEE_WALLET_MESSAGE_SIZE_BURN_NOTIFICATION_BITS = 754
const FEE_WALLET_MESSAGE_SIZE_BURN_NOTIFICATION_CELLS = 1

const FEE_WALLET_MIN_STORAGE_DURATION = 365 * 24 * 3600

const FEE_WALLET_GAS_JETTON_TRANSFER = 15716
const FEE_WALLET_GAS_JETTON_RECEIVE = 7620
const FEE_WALLET_GAS_BURN_REQUEST = 4331
const FEE_WALLET_GAS_BURN_NOTIFICATION = 5390
const FEE_WALLET_GAS_MARK = 1911

// SAFETY: Uses TVM's read-only GETPRECOMPILEDGAS primitive; callers handle `null` fallback safely.
fun feeWalletPrecompiledGas(): int?
    asm "GETPRECOMPILEDGAS"

fun feeWalletMinStorageFee(): coins {
    return calculateStorageFee(
        MY_WORKCHAIN,
        FEE_WALLET_MIN_STORAGE_DURATION,
        FEE_WALLET_STORAGE_SIZE_MAX_WALLET_BITS,
        FEE_WALLET_STORAGE_SIZE_MAX_WALLET_CELLS,
    );
}

fun feeWalletMarkAmount(): coins {
    return calculateGasFee(MY_WORKCHAIN, FEE_WALLET_GAS_MARK) + feeWalletMinStorageFee();
}

fun feeWalletInitStateOverhead(): coins {
    return calculateForwardFeeWithoutLumpPrice(
        MY_WORKCHAIN,
        FEE_WALLET_STORAGE_SIZE_INIT_STATE_WALLET_BITS,
        FEE_WALLET_STORAGE_SIZE_INIT_STATE_WALLET_CELLS,
    );
}

fun feeWalletMinimalTransferAmount(forwardTonAmount: int, fwdFee: int): int {
    val fwdCount = forwardTonAmount != 0 ? 2 : 1;

    val jettonWalletGasConsumption = feeWalletPrecompiledGas();
    val sendTransferGasConsumption = (jettonWalletGasConsumption == null)
        ? FEE_WALLET_GAS_JETTON_TRANSFER
        : jettonWalletGasConsumption;
    val receiveTransferGasConsumption = (jettonWalletGasConsumption == null)
        ? FEE_WALLET_GAS_JETTON_RECEIVE
        : jettonWalletGasConsumption;

    return forwardTonAmount + fwdCount * fwdFee + feeWalletInitStateOverhead() +
        calculateGasFee(MY_WORKCHAIN, sendTransferGasConsumption) +
        calculateGasFee(MY_WORKCHAIN, receiveTransferGasConsumption) +
        feeWalletMinStorageFee();
}

fun burnReportValue(): coins {
    return calculateForwardFee(
        MY_WORKCHAIN,
        FEE_WALLET_MESSAGE_SIZE_BURN_NOTIFICATION_BITS,
        FEE_WALLET_MESSAGE_SIZE_BURN_NOTIFICATION_CELLS,
    ) +
        calculateGasFee(MY_WORKCHAIN, FEE_WALLET_GAS_BURN_NOTIFICATION);
}

fun feeWalletMinimalBurnAmount(): coins {
    val jettonWalletGasConsumption = feeWalletPrecompiledGas();
    val sendBurnGasConsumption = (jettonWalletGasConsumption == null)
        ? FEE_WALLET_GAS_BURN_REQUEST
        : jettonWalletGasConsumption;

    return burnReportValue() + calculateGasFee(MY_WORKCHAIN, sendBurnGasConsumption);
}

fun checkFeeWalletBurnAmount(msgValue: int) {
    val minBurnAmount = feeWalletMinimalBurnAmount();
    assert (msgValue > minBurnAmount) throw Errors.NotEnoughGas;
}

const FEE_WALLET_GAS_BURN_LEG = 5585
const FEE_WALLET_GAS_TAX_LEG = 3305
const FEE_WALLET_GAS_FEE_ORDER = 5405
const FEE_WALLET_GAS_TAX_RECEIVE = 5444
const FEE_WALLET_GAS_TOKEN_RECEIVE = 6246
const FEE_WALLET_GAS_TOKEN_BURN = 4417

const FEE_WALLET_MESSAGE_SIZE_FEE_ORDER_BITS = 503
const FEE_WALLET_MESSAGE_SIZE_FEE_ORDER_CELLS = 1
const FEE_WALLET_MESSAGE_SIZE_BURN_REQUEST_BITS = 0
const FEE_WALLET_MESSAGE_SIZE_BURN_REQUEST_CELLS = 0
const FEE_WALLET_MESSAGE_SIZE_NOTICE_BITS = 488
const FEE_WALLET_MESSAGE_SIZE_NOTICE_CELLS = 1

fun feeOrderForwardFee(): coins {
    return calculateForwardFee(
        MY_WORKCHAIN,
        FEE_WALLET_MESSAGE_SIZE_FEE_ORDER_BITS,
        FEE_WALLET_MESSAGE_SIZE_FEE_ORDER_CELLS,
    );
}

fun feeOrderDeliveryValue(): coins {
    return feeOrderForwardFee() + feeWalletInitStateOverhead() +
        calculateGasFee(MY_WORKCHAIN, FEE_WALLET_GAS_FEE_ORDER);
}

fun feeNoticeForwardFee(): coins {
    return calculateForwardFee(
        MY_WORKCHAIN,
        FEE_WALLET_MESSAGE_SIZE_NOTICE_BITS,
        FEE_WALLET_MESSAGE_SIZE_NOTICE_CELLS,
    );
}

fun taxOrderValue(): coins {
    return feeOrderDeliveryValue() + calculateGasFee(MY_WORKCHAIN, FEE_WALLET_GAS_TAX_RECEIVE) +
        feeNoticeForwardFee() +
        1;
}

fun tokenWalletBurnAmount(): coins {
    return calculateGasFee(MY_WORKCHAIN, FEE_WALLET_GAS_TOKEN_RECEIVE) + feeWalletMinStorageFee() +
        calculateForwardFee(
            MY_WORKCHAIN,
            FEE_WALLET_MESSAGE_SIZE_BURN_REQUEST_BITS,
            FEE_WALLET_MESSAGE_SIZE_BURN_REQUEST_CELLS,
        ) +
        calculateGasFee(MY_WORKCHAIN, FEE_WALLET_GAS_TOKEN_BURN) +
        burnReportValue();
}

fun burnOrderValue(): coins {
    return feeOrderDeliveryValue() + tokenWalletBurnAmount() + 1;
}

fun burnLegValue(): coins {
    return burnOrderValue() + feeOrderForwardFee() +
        calculateGasFee(MY_WORKCHAIN, FEE_WALLET_GAS_BURN_LEG);
}

fun taxLegValue(): coins {
    return taxOrderValue() + feeOrderForwardFee() +
        calculateGasFee(MY_WORKCHAIN, FEE_WALLET_GAS_TAX_LEG);
}

fun feeLegsValue(burns: bool, taxes: int): coins {
    var value: coins = taxes * taxLegValue();
    if (burns) {
        value += burnLegValue();
    }
    return value;
}

fun checkFeeWalletTransferAmount(
    msgValue: int,
    forwardTonAmount: int,
    fwdFee: int,
    burns: bool,
    taxes: int,
) {
    val minTransferAmount = feeWalletMinimalTransferAmount(forwardTonAmount, fwdFee) +
        feeLegsValue(burns, taxes);
    assert (msgValue > minTransferAmount) throw Errors.NotEnoughGas;
}
