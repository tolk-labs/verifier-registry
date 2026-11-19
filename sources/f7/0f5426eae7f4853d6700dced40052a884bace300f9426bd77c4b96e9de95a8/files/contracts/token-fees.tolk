import "@stdlib/gas-payments"
import "fees-management"
import "sharding"

const RENT_TOKEN_SECONDS = 5 * 365 * 24 * 3600
const METADATA_MAX_CELLS = 128

const TOKEN_FIXED_STATE_BITS = 18362
const TOKEN_FIXED_STATE_CELLS = 38
const TOKEN_MINTABLE_STATE_BITS = 28898
const TOKEN_MINTABLE_STATE_CELLS = 61

const GAS_TOKEN_FIXED_START = 24000
const GAS_TOKEN_MINTABLE_START = 24500

const MESSAGE_TRANSFER_BITS = 879
const MESSAGE_TRANSFER_CELLS = 1
const MESSAGE_STARTED_BITS = 1225
const MESSAGE_STARTED_CELLS = 2

fun tokenRent(stateBits: int, stateCells: int): coins {
    return calculateStorageFee(MY_WORKCHAIN, RENT_TOKEN_SECONDS, stateBits, stateCells);
}

fun transferForwardFee(): coins {
    return calculateForwardFee(MY_WORKCHAIN, MESSAGE_TRANSFER_BITS, MESSAGE_TRANSFER_CELLS);
}

fun firstMintValue(): coins {
    return calcMinimalTransferAmount(1, transferForwardFee());
}
