enum NftOfferError {
    InvalidConfig = 452
    InsufficientFunds = 453
    InvalidNft = 455
    NotExpired = 456
    Expired = 457
    InvalidMessage = 65535
}

// Execution budgets, not fees. Cancellation always refunds the immutable buyer.
const NFT_OFFER_DEPLOY_BUDGET = grams("0.012")
const NFT_OFFER_EXECUTION_BUDGET = grams("0.008")
const NFT_OFFER_TRANSFER_VALUE = grams("0.0028")
