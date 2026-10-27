struct (0x43414e43) Cancel {
    queryId: uint64
}

// Явный body для деплоя и пополнения: пустое сообщение exact sale трактует как полную TON-оплату.
struct (0x45525356) DepositEscrowReserve {
    queryId: uint64
}

// External triggers never carry TON and never accept a beneficiary. Exact and certified escrows
// bind the request to their current Offer/payout state before accepting gas.
struct (0x58534d52) TriggerSettlementResume {
    // "XSMR"
    offerId: uint128
    payoutQueryId: uint64
    vault: address
}

// Комиссию стороны вносит один из её вносителей целиком, отдельно от principal и gas reserve.
// При отмене она возвращается этому плательщику, а не получателю встречных активов.
struct (0x46464545) DepositSideFee {
    queryId: uint64
    offerExecutionNumber: uint32
}
