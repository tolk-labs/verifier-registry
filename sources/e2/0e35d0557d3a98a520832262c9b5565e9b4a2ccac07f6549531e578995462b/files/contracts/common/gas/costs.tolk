// Динамическая оценка TON-резерва для settlement. Цены gas и forwarding читаются из текущей
// конфигурации сети: захардкоженная сумма пережила бы очередное изменение тарифов примерно никак.

import "@stdlib/gas-payments"
import "@contracts/common/nft/constants"
import "@contracts/common/usdt/constants"
import "@contracts/common/usdt/network_constants"
import "constants"
import "types"

fun usdtRecoveryStorageReserve(): coins {
    val accountCells = beginCell()
        .storeRef(contract.getCode())
        .storeRef(contract.getData())
        .endCell();
    val (cells, bits, _) = accountCells.calculateSizeStrict(USDT_STORAGE_SIZE_LIMIT);
    // Include account metadata and a buffer for the last beneficiary/status update.
    return grams("0.01") +
        calculateStorageFee(
            BASECHAIN,
            USDT_RECOVERY_RETENTION_SECONDS,
            bits + 1024,
            cells + 8,
        );
}

fun computeCost(gasUnits: GasUnits): coins {
    return calculateGasFee(BASECHAIN, gasUnits.value) as coins;
}

fun forwardCost(outgoingMessages: int): coins {
    val oneMessage = calculateForwardFee(
        BASECHAIN,
        OUTGOING_MESSAGE_BITS,
        OUTGOING_MESSAGE_CELLS,
    );
    return (oneMessage * outgoingMessages) as coins;
}

fun executionCost(gasUnits: GasUnits, outgoingMessages: int): coins {
    return (computeCost(gasUnits) + forwardCost(outgoingMessages)) as coins;
}

// На settlement уходят сообщения каждому NFT, две потенциальные денежные ноги, комиссия и сдача.
// Неиспользованный запас остаётся change и возвращается зафиксированному плательщику резерва.
fun escrowSettlementFees(itemCount: int): coins {
    return executionCost(
        GAS_ESCROW_SETTLEMENT.add(GAS_PER_ESCROW_ITEM.multiplyBy(itemCount)),
        itemCount + 4,
    );
}

// Initial settlement already funds the first vault assignment. This separate reserve funds exactly
// one automatic retry per vault; later retries remain caller-funded internal messages.
// A multi-vault allocation also covers at most MAX_USDT_DEPOSITS-1 nanoton from summing
// individually rounded fees; the one-record retry itself needs no aggregate cushion.
@inline
fun automaticUsdtSettlementRetryReserve(
    depositCount: int,
    usdtTermsBits: int,
    usdtTermsCells: int,
): coins {
    if (depositCount <= 0) {
        return grams("0");
    }
    return (depositCount *
        (USDT_DEPOSIT_ASSIGN_VALUE + executionCost(GAS_ESCROW_SETTLEMENT, 1) +
            AUTOMATIC_USDT_RETRY_OVERHEAD) +
        usdtStateInitForwardingExtra(depositCount, usdtTermsBits, usdtTermsCells) +
        (depositCount > 1 ? MAX_USDT_DEPOSITS - 1 : 0)) as coins;
}

// The ordinary envelope is already priced by forwardCost. Charge only additional vault code,
// StateInit and immutable terms, with one nanoton per message for independent rounding.
@inline
fun usdtStateInitForwardingExtra(messageCount: int, termsBits: int, termsCells: int): coins {
    if (messageCount <= 0) {
        return grams("0");
    }
    return calculateForwardFeeWithoutLumpPrice(
        BASECHAIN,
        (USDT_STATE_INIT_MESSAGE_BITS - OUTGOING_MESSAGE_BITS) * messageCount + termsBits,
        (USDT_STATE_INIT_MESSAGE_CELLS - OUTGOING_MESSAGE_CELLS) * messageCount + termsCells,
    ) +
        messageCount;
}

// External admission must stay within gas_credit: immutable item counts and stored ledger totals
// bound the work without walking attacker-sized dictionaries before ACCEPT.
@inline
fun requiredExternalEscrowBalance(
    nativeObligations: coins,
    protectedRecovery: coins,
    nftCount: int,
    usdtCount: int,
    assignsUsdt: bool,
    usdtTermsBits: int,
    usdtTermsCells: int,
): coins {
    // 100k includes the base transition plus 34 possible native refunds. Aggregate the initial
    // work and future retries before the two price lookups to stay inside external gas_credit.
    val gas = (nativeObligations > 0 ? 100_000 : 32_000) + 31_600 * nftCount +
        (assignsUsdt ? 23_000 : 7_000) * usdtCount;
    val messageCount = 3 * nftCount + (assignsUsdt ? 2 : 1) * usdtCount +
        (nativeObligations > 0 ? 36 : 2);
    val usdtValue = assignsUsdt
        ? (2 * USDT_DEPOSIT_ASSIGN_VALUE + AUTOMATIC_USDT_RETRY_OVERHEAD) as coins
        : USDT_DEPOSIT_REFUND_VALUE;
    var forwarding = calculateForwardFee(BASECHAIN, OUTGOING_MESSAGE_BITS, OUTGOING_MESSAGE_CELLS) *
        messageCount;
    if (usdtCount > 0) {
        val usdtMessages = (assignsUsdt ? 2 : 1) * usdtCount;
        // The base fee already covers the root and the small envelope. Price the additional
        // StateInit payload in one lookup; one nanoton per message bounds individual rounding.
        forwarding += usdtStateInitForwardingExtra(
            usdtMessages,
            usdtTermsBits * (assignsUsdt ? 2 : 1),
            usdtTermsCells * (assignsUsdt ? 2 : 1),
        );
    }
    return (nativeObligations + protectedRecovery + MIN_TONS_FOR_STORAGE +
        2 * NFT_TRANSFER_VALUE * nftCount +
        usdtValue * usdtCount +
        calculateGasFee(BASECHAIN, gas) +
        forwarding +
        (assignsUsdt && usdtCount > 1 ? MAX_USDT_DEPOSITS : 0)) as coins;
}
