/// Phase of the sale.
enum Phase: uint8 {
    /// The sale is deployed and waits for the NFT.
    AwaitingNft = 0
    /// The sale holds the NFT. A buyer can buy it.
    Active = 1
    /// The NFT is sent to the buyer.
    Sold = 3
    /// The NFT is sent back to the seller.
    Cancelled = 5
}

/// Fee terms of the sale.
struct FeeConfig {
    /// Gets the fee and the remaining balance after a sale.
    feeAddress: address
    /// Fee in basis points of the price. The maximum is 10000.
    feeBps: uint16
}

/// Terms of the sale. They do not change after deploy.
struct SaleConfig {
    /// Owner of the NFT. Gets the price after a sale.
    seller: address
    /// NFT item for sale.
    nft: address
    /// Price at deploy.
    initialPrice: coins
    /// Makes the sale address unique for equal terms.
    salt: uint64
    /// Fee terms.
    fee: Cell<FeeConfig>
}

/// Persistent data of the sale.
struct Storage {
    /// Terms of the sale.
    config: Cell<SaleConfig>
    /// Current price. The seller can change it while the sale is active.
    price: coins
    /// Current phase.
    phase: Phase
}

/// Loads the persistent data.
fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

/// Saves the persistent data.
fun Storage.save(self) {
    contract.setData(self.toCell());
}
