import "@contracts/common/comments/messages"
import "@contracts/common/comments/refund_reason"
import "constants"
import "messages"

fun sendJetton(
    jettonWallet: address,
    recipient: address,
    amount: coins,
    excessesTo: address,
    comment: slice?,
) {
    sendJettonWithQuery(
        jettonWallet,
        recipient,
        amount,
        excessesTo,
        comment,
        0,
    );
}

fun sendJettonWithQuery(
    jettonWallet: address,
    recipient: address,
    amount: coins,
    excessesTo: address,
    comment: slice?,
    queryId: uint64,
) {
    var forwardTonAmount: coins = grams("0");
    var forwardPayload = beginCell().storeUint(0, 1).toSlice();
    if (comment != null) {
        forwardTonAmount = JETTON_COMMENT_NOTIFY_VALUE;
        forwardPayload = TextComment { text: comment }.toCell().forwardPayload();
    }

    val body = JettonTransfer {
        queryId,
        jettonAmount: amount,
        transferRecipient: recipient,
        sendExcessesTo: excessesTo,
        customPayload: null,
        forwardTonAmount,
        forwardPayload,
    };
    val jettonTransferMessage = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: jettonWallet,
        value: JETTON_TRANSFER_VALUE,
        body,
    });
    jettonTransferMessage.send(
        SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
    );
}

// Непринимаемый Jetton payment возвращается через wallet, приславший notification, и за счёт его
// forwarded TON. Иначе дешёвые dust-платежи выжгли бы TON-баланс escrow на refund-сообщениях.
fun refundJettonViaSender(claimedWallet: address, recipient: address, amount: coins) {
    val body = JettonTransfer {
        queryId: 0,
        jettonAmount: amount,
        transferRecipient: recipient,
        sendExcessesTo: recipient,
        customPayload: null,
        forwardTonAmount: JETTON_COMMENT_NOTIFY_VALUE,
        forwardPayload: beginCell()
            .storeBool(true)
            .storeRef(TextComment { text: RefundReason.InvalidPayment.comment() }.toCell())
            .toSlice(),
    };
    val jettonRefundMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: claimedWallet,
        value: grams("0"),
        body,
    });
    jettonRefundMessage.send(
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
    );
}
