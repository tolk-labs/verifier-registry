import "@contracts/common/nft/deposits"
import "@contracts/common/offer/wallets"

// Каждый участвующий wallet отправляет одинаковое binding-сообщение перед своими активами. Первый
// создаёт execution, остальные подтверждают себя; порядок независимых wallet-транзакций не важен.
struct (0x4143434f) StartOfferExecution {
    // "ACCO"
    queryId: uint64
    offerExecutionNumber: uint32
    allowedContributorWallets: OfferWallets
    takerRefundRecipients: ItemRefundRecipients
    // Получатель фиксируется первым binding и подтверждается каждым вносителем; сам не подписывает.
    takerSettlementWallet: address
    // GRAM principal и side fee этого signer применяются той же транзакцией, что и binding.
    paymentAmount: coins = 0
    sideFeeAmount: coins = 0
}

struct (0x464e444f) DepositOfferPayment {
    // "FNDO"
    queryId: uint64
    offerExecutionNumber: uint32
    paymentAmount: coins
    sideFeeAmount: coins = 0
}

struct (0x4255594f) BuyOffer {
    // "BUYO": атомарный binding и полная TON-оплата exact sale с отдельным получателем.
    queryId: uint64
    offerExecutionNumber: uint32
    paymentAmount: coins
    allowedContributorWallets: OfferWallets
    takerSettlementWallet: address
}

struct (0x524c5341) ReleaseOfferExecutionAttempt {
    // "RLSA"
    queryId: uint64
    offerExecutionNumber: uint32
}

struct (0x4558504f) ExpireOffer {
    // "EXPO"
    queryId: uint64
}

struct (0x52534d4f) ResumeSettlement {
    // "RSMO"
    queryId: uint64
}

// External liveness использует отдельные opcodes: их оплачивает reserve escrow, поэтому они не
// должны наследовать sender/value-семантику внутренних сообщений.
struct (0x5845584f) TriggerExactOfferExpiry {
    offerId: uint128
    expiresAt: uint32
}

struct (0x58524c4f) TriggerExactExpiredExecutionRelease {
    offerId: uint128
    offerExecutionNumber: uint32
}
