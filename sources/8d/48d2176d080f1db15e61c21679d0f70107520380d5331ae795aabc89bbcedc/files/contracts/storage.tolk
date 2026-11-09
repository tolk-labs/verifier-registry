/// Offer lifecycle. Offers are deployed in `Funding`, and the contract sets every later phase.
/// The contract doesn't check the deployed phase; indexers recognise only an address whose
/// state init has `Funding`.
enum Phase: uint8 {
    /// Deployed; waits for the buyer to fund the price, the fee and the storage reserve.
    Funding = 0
    /// Funded; accepts the NFT from the seller until expiry.
    Active = 1
    /// The seller got the price and the NFT transfer to the recipient was sent. If the NFT item
    /// rejects that transfer, the NFT stays with the offer.
    Sold = 2
    /// Cancelled by the buyer, cancelled with the offer key, or cancelled after expiry.
    Closed = 3
}

/// Addresses that take part in the offer.
struct Parties {
    /// Funds the offer and gets the balance back on a cancel.
    buyer: address
    /// Gets the NFT after a sale.
    recipient: address
    /// The only previous owner whose NFT the offer buys.
    seller: address
}

/// Marketplace fee terms.
struct Fee {
    /// Gets the cancel fee, the excess of the NFT transfer, and the rest of the balance after a
    /// sale: the funded fee and any surplus.
    feeAddress: address
    /// Fee in basis points of the price, which the buyer funds on top of the price.
    feeBps: uint16
    /// Sets the fee for a buyer cancel before expiry: the larger of this value in basis points
    /// of the price and a minimum fee that is proportional to this value.
    cancelFee: uint16
}

/// Offer terms. They don't change after deployment.
struct OfferConfig {
    /// The NFT item the offer buys.
    nft: address
    /// Amount paid to the seller.
    price: coins
    /// Any value. It makes the offer address unique.
    salt: uint64
    /// Unix time from which the offer no longer accepts funding or the NFT. From then on, a buyer
    /// cancel has no fee and an external cancel needs no signature.
    expiresAt: uint32
    /// Buyer, recipient and seller.
    parties: Cell<Parties>
    /// Fee address and rates.
    fee: Cell<Fee>
}

/// Contract data. Only `phase` changes after deployment.
struct Storage {
    /// Offer terms.
    config: Cell<OfferConfig>
    /// Ed25519 key that can cancel the offer with an external before expiry.
    publicKey: uint256
    /// Current lifecycle phase.
    phase: Phase
}

/// Loads the full storage. Fails if data is left over, or with exit code 5 on an unknown phase.
fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

/// Writes the storage to the contract data.
fun Storage.save(self) {
    contract.setData(self.toCell());
}
