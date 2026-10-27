import "@contracts/common/comments/constants"
import "@contracts/common/comments/messages"
import "@contracts/common/gas/constants"

// Только короткие тексты из comments: opcode + текст и заголовок TON помещаются в root cell.
// Inline устраняет промежуточную body cell и сохраняет прежний gas budget settlement.
fun sendCoins(recipient: address, amount: coins, comment: slice) {
    val tonTransferMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: recipient,
        value: amount,
        body: UnsafeBodyNoRef { forceInline: TextComment { text: comment } },
    });
    tonTransferMessage.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// Вызывается последним: все обязательства уже поставлены в action list, остаток над storage reserve
// возвращается выбранному плательщику резерва. Маленькая сдача не должна откатить состоявшийся settlement.
fun returnChange(recipient: address, storageReserve: coins = MIN_TONS_FOR_STORAGE) {
    reserveGramsOnBalance(
        storageReserve,
        RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_AT_MOST,
    );
    val changeMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: recipient,
        value: grams("0"),
        body: UnsafeBodyNoRef { forceInline: TextComment { text: GAS_REFUND_COMMENT } },
    });
    // SAFETY: reserve уже удержал storage minimum, а все обязательные actions поставлены раньше;
    // ошибка отправки пыльной сдачи не должна откатывать завершённый settlement.
    changeMessage.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun refundTon(recipient: address, comment: slice) {
    val tonRefundMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: recipient,
        value: grams("0"),
        body: UnsafeBodyNoRef { forceInline: TextComment { text: comment } },
    });
    tonRefundMessage.send(
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
    );
}
