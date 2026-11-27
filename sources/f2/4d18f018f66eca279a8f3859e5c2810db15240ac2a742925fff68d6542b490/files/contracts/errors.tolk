enum Errors {
    Unauthorized = 401
    WrongState = 402
    PriceChanged = 403
    InvalidNft = 404
    InsufficientFunds = 405
    InvalidRequest = 410
    InvalidMessage = 65535
}

// Includes 0.0028 for the NFT transfer plus 0.002 for sale execution and message fees.
const BUY_GAS = grams("0.0048")
const NFT_TRANSFER_GAS = grams("0.0028")

enum SalePhase: uint8 {
    Waiting = 0
    Active = 1
    Sold = 3
    Cancelled = 5
}
