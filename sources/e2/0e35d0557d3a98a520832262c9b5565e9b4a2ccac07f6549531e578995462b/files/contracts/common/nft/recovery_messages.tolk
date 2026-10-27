// Повторяет доставку конкретного NFT. Получателя команда не принимает: escrow неизменно выводит
// его из стороны депозита и результата сделки.
struct (0x524e4654) RetryNftDelivery {
    queryId: uint64
    nft: address
}

struct (0x584e4652) TriggerNftDeliveryRetry {
    // "XNFR"
    offerId: uint128
    nft: address
    deliveryQueryId: uint64
}

// The recipient can acknowledge an already received refund after its NFT receipt was lost.
// An unanswered transfer must first complete or bounce; acknowledgement cannot race a transfer.
struct (0x434e4652) ConfirmNftDelivery {
    nft: address
}

// Узкий аварийный вывод неизвестного NFT, который оказался у уже закрытого escrow без TEP-62
// notification. Threshold recovery authority выбирает получателя после timelock; контракт сам
// строит единственный canonical NFT transfer и не даёт этой команде доступа к штатным активам.
struct (0x52554e58) RecoverUnexpectedNft {
    // "RUNX"
    recoveryId: uint64
    nft: address
    recipient: address
}
