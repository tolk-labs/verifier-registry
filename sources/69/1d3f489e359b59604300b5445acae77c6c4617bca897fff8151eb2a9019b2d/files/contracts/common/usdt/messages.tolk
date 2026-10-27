import "@contracts/usdt_deposit_vault/storage"

// The caller funds this message. It can recover a decision lost before the vault
// received it, including deposits whose original deposits notification was lost.
struct (0x55445253) ResolveUsdtDeposit {
    terms: Cell<UsdtDepositTerms>
}

// A final escrow decision restores the fixed contributor refund even when a deleted holding
// wallet retains less than the original principal, so an exact custody probe cannot succeed.
struct (0x55485253) ResolveUsdtHolding {
    terms: Cell<UsdtDepositTerms>
    attempt: uint64
}

// One wallet message deploys both contribution owners. Their self-probes recover
// deposits that arrived before owner deployment, without relying on message order.
struct (0x55534450) PrepareUsdtPayment {
    offerExecutionNumber: uint32
    nonce: uint64
    principal: coins
    marketplaceFee: coins
    // Нативная комиссия стороны вносится тем же escrow-call, Jetton transfers остаются отдельно.
    sideFeeAmount: coins = 0
    execution: cell? = null
}
