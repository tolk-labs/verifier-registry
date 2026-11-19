import "@stdlib/gas-payments"
import "fee-wallet-fees"
import "sharding"
import "token-fees"

const FEE_TOKEN_STATE_BITS = 46095
const FEE_TOKEN_STATE_CELLS = 95

const GAS_FEE_TOKEN_START = 29000

fun feeTransferForwardFee(): coins {
    return calculateForwardFee(MY_WORKCHAIN, MESSAGE_TRANSFER_BITS, MESSAGE_TRANSFER_CELLS);
}

fun firstFeeMintValue(): coins {
    return feeWalletMinimalTransferAmount(1, feeTransferForwardFee());
}
