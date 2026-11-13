/// Exit codes of the sale.
enum Errors {
    /// The sender is not the seller, or the seller cancels a sale that is not active.
    NotPermitted = 401
    /// The sale is not active.
    NotActive = 402
    /// The price is not set, or the maximum price of the buyer is lower than the price.
    PriceTooLow = 403
    /// The sender is not the NFT of the sale, or the previous owner is not in the basechain.
    InvalidOwnershipAssigned = 404
    /// The attached value is not sufficient.
    NotEnoughValue = 405
    /// A price, a fee or an address is not valid.
    InvalidParams = 410
    /// The message is not a known operation.
    UnknownOperation = 0xFFFF
}
