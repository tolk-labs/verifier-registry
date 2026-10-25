type ForwardPayloadRemainder = RemainingBitsAndRefs

struct (0b0) PayloadInline {
    value: RemainingBitsAndRefs
}

struct (0b1) PayloadInRef {
    value: Cell<RemainingBitsAndRefs>
}

struct (0x7362d09c) TransferNotificationForRecipient {
    queryId: uint64
    jettonAmount: coins
    transferInitiator: address?
    @abi.clientType(PayloadInline | PayloadInRef)
    forwardPayload: ForwardPayloadRemainder
}

struct (0xd43d636a) RefundUsdt {
    jettonAmount: uint72
    addressRefund: address?
}

// Emergency path for jettons that arrived without TransferNotification.
// Does not decrement accounting; bounce of the outgoing AskToTransfer uses QueryRole.None.
struct (0x0accb5c4) ErrRefund {
    jettonAmount: uint72
    addressRefund: address?
}

struct (0x0f8a7ea5) AskToTransfer {
    queryId: uint64                         // QueryRole; jetton standard field, not a correlation id
    jettonAmount: coins                     // how many jettons to take from the sender and give to the receiver
    transferRecipient: address              // address of the owner (not the jetton wallet) who will get the jettons
    sendExcessesTo: address?                // where to return the excess TON after execution (often: the initiator's address)
    customPayload: cell?
    forwardTonAmount: coins                 // how many TON to forward to the recipient's wallet owner together with the notification
    @abi.clientType(PayloadInline | PayloadInRef)
    forwardPayload: ForwardPayloadRemainder // payload for the recipient's notification (processed as "remaining bits/refs")
}

// Bounce of AskToTransfer is Only256BitsOfBody: opcode + queryId + jettonAmount fit;
// destination and the rest are truncated. `rest` makes that remainder explicit.
struct (0x0f8a7ea5) TransferBounce {
    queryId: uint64
    jettonAmount: coins
    rest: RemainingBitsAndRefs
}
