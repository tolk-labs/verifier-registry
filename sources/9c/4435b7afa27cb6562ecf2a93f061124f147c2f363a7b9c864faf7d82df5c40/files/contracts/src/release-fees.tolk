import "@stdlib/gas-payments"
import "errors"
import "sharding"

// Storage costs
// these constants are used to estimate storage fee (how much we should pay for storing a wallet contract);
// the bounds are checked in tests/state-init.test.tolk

// This project embeds the full wallet code, not a library-reference cell.
// Include code, data and account overhead, with a small conservative margin.
// state-init.test.tolk checks these bounds against the actual compiled wallet.
const STORAGE_SIZE_MAX_WALLET_BITS = 40000
const STORAGE_SIZE_MAX_WALLET_CELLS = 40
const STORAGE_SIZE_INIT_STATE_WALLET_BITS = 15000
const STORAGE_SIZE_INIT_STATE_WALLET_CELLS = 40

const MESSAGE_SIZE_BURN_NOTIFICATION_BITS = 754 // body = 32+64+124+(3+8+256)+(3+8+256)
const MESSAGE_SIZE_BURN_NOTIFICATION_CELLS = 1 // body always in ref

const MIN_STORAGE_DURATION = 5 * 365 * 24 * 3600 // 5 years

// Gas costs
// these constants are used to estimate gas fee (how much we should retain on balance for a transfer to succeed);
// These are estimates for this compiled implementation. Boundary tests must
// verify the whole message chain, not just the sender's first transaction.

const GAS_CONSUMPTION_JETTON_TRANSFER = 10000
const GAS_CONSUMPTION_JETTON_RECEIVE = 14000
const GAS_CONSUMPTION_BURN_REQUEST = 8000
const GAS_CONSUMPTION_BURN_NOTIFICATION = 30000

// SAFETY: Uses TVM's read-only GETPRECOMPILEDGAS primitive; callers handle `null` fallback safely.
fun getPrecompiledGasConsumption(): int?
    asm "GETPRECOMPILEDGAS"

fun calculateJettonWalletMinStorageFee(): coins {
    return calculateStorageFee(
        MY_WORKCHAIN,
        MIN_STORAGE_DURATION,
        STORAGE_SIZE_MAX_WALLET_BITS,
        STORAGE_SIZE_MAX_WALLET_CELLS,
    );
}

fun forwardInitStateOverhead(): coins {
    return calculateForwardFeeWithoutLumpPrice(
        MY_WORKCHAIN,
        STORAGE_SIZE_INIT_STATE_WALLET_BITS,
        STORAGE_SIZE_INIT_STATE_WALLET_CELLS,
    );
}

fun calcMinimalTransferAmount(forwardTonAmount: int, fwdFee: int): int {
    val fwdCount = forwardTonAmount != 0
        ? 2
        : 1;                                      // second sending (forward) will be cheaper than first

    val jettonWalletGasConsumption = getPrecompiledGasConsumption();
    val sendTransferGasConsumption = (jettonWalletGasConsumption == null)
        ? GAS_CONSUMPTION_JETTON_TRANSFER
        : jettonWalletGasConsumption;
    val receiveTransferGasConsumption = (jettonWalletGasConsumption == null)
        ? GAS_CONSUMPTION_JETTON_RECEIVE
        : jettonWalletGasConsumption;

    return forwardTonAmount +
        // 3 messages: wal1->wal2, wal2->owner, wal2->response
        // but last one is optional (it is ok if it fails)
        fwdCount * fwdFee +
        forwardInitStateOverhead() +
        // additional fwd fees related to initstate in internal_transfer
        calculateGasFee(MY_WORKCHAIN, sendTransferGasConsumption) +
        calculateGasFee(MY_WORKCHAIN, receiveTransferGasConsumption) +
        calculateJettonWalletMinStorageFee();
}

fun checkAmountIsEnoughToTransfer(msgValue: int, forwardTonAmount: int, fwdFee: int) {
    val minTransferAmount = calcMinimalTransferAmount(forwardTonAmount, fwdFee);
    assert (msgValue > minTransferAmount) throw Errors.NotEnoughGas;
}

fun calcMinimalBurnAmount(): coins {
    val jettonWalletGasConsumption = getPrecompiledGasConsumption();
    val sendBurnGasConsumption = (jettonWalletGasConsumption == null)
        ? GAS_CONSUMPTION_BURN_REQUEST
        : jettonWalletGasConsumption;

    return calculateForwardFee(
        MY_WORKCHAIN,
        MESSAGE_SIZE_BURN_NOTIFICATION_BITS,
        MESSAGE_SIZE_BURN_NOTIFICATION_CELLS,
    ) +
        calculateGasFee(MY_WORKCHAIN, sendBurnGasConsumption) +
        calculateGasFee(MY_WORKCHAIN, GAS_CONSUMPTION_BURN_NOTIFICATION);
}

fun checkAmountIsEnoughToBurn(msgValue: int) {
    val minBurnAmount = calcMinimalBurnAmount();
    assert (msgValue > minBurnAmount) throw Errors.NotEnoughGas;
}

// Conservative per-operation budgets use the CURRENT network configuration.
// Values are attached budgets, not protocol taxes or guaranteed net fees.
fun releaseReceiptValue(): coins {
    return max(grams("0.01"), calculateGasFee(0, 30000) + calculateForwardFee(0, 2000, 8));
}

fun releaseReceiptRequestBudget(): coins {
    return max(
        grams("0.03"),
        releaseReceiptValue() + calculateGasFee(0, 10000) + calculateForwardFee(0, 2000, 8),
    );
}

fun releaseMintWalletBudget(): coins {
    val forward = calculateForwardFee(0, 30000, 80);
    return max(
        grams("0.15"),
        calcMinimalTransferAmount(0, forward) + releaseReceiptValue() + grams("0.01"),
    );
}

fun releaseMintExecutionBudget(): coins {
    return max(
        grams("0.25"),
        releaseMintWalletBudget() + calculateGasFee(0, 60000) + calculateForwardFee(0, 30000, 80) +
            calculateStorageFee(0, 5 * 365 * 86400, 2000, 8),
    );
}

fun releaseBurnWalletBudget(): coins {
    return max(grams("0.1"), calcMinimalBurnAmount() + releaseReceiptValue() + grams("0.01"));
}

fun releaseBurnExecutionBudget(): coins {
    return max(
        grams("0.15"),
        releaseBurnWalletBudget() + calculateGasFee(0, 20000) + calculateForwardFee(0, 2000, 8),
    );
}
