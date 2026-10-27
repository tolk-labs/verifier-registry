// Общие TEP-74 сообщения и представление forward payload через стандартный Either.

struct (0b0) PayloadInline {
    value: RemainingBitsAndRefs
}

struct (0b1) PayloadInRef {
    value: Cell<RemainingBitsAndRefs>
}

type ForwardPayload = PayloadInline | PayloadInRef

// Собственный jetton wallet уведомляет escrow о входящем переводе.
struct (0x7362d09c) JettonTransferNotification {
    queryId: uint64
    jettonAmount: coins
    transferInitiator: address?
    @abi.clientType(ForwardPayload)
    forwardPayload: RemainingBitsAndRefs
}

// Команда собственному jetton wallet выполнить выплату, комиссию или возврат.
struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    jettonAmount: coins
    transferRecipient: address
    sendExcessesTo: address?
    customPayload: cell? = null
    forwardTonAmount: coins = grams("0")
    forwardPayload: RemainingBitsAndRefs
}

// Возврат остатка TON. Любой отправитель может повторить queryId в другом переводе: без суммы
// и источника это сообщение НЕ доказывает исполнение конкретной выплаты.
struct (0xd53276db) JettonExcesses {
    queryId: uint64
}
