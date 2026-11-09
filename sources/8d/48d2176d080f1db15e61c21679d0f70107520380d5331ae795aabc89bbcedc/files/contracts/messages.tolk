/// TEP-62 `ownership_assigned`: NFT item → new owner.
struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    /// Owner before the transfer. The offer pays this address when it is the seller.
    prevOwner: address
    /// Ignored.
    forwardPayload: RemainingBitsAndRefs
}

/// TEP-62 `transfer`: owner → NFT item. The offer sends it with no custom payload, no forward
/// amount and an empty inline forward payload.
struct (0x5fcc3d14) NftTransfer {
    queryId: uint64
    newOwner: address
    /// Gets the excess of the transfer value.
    responseDestination: address?
    customPayload: cell? = null
    forwardAmount: coins = 0
    forwardPayload: RemainingBitsAndRefs = "4_".hexToSlice()
}

/// Buyer → offer: closes the offer in any phase and sends the balance to the buyer. Before
/// expiry, a cancel fee goes to the fee address first.
struct (0x69cc5721) CancelByBuyer {}

/// External cancel of an Active offer. Sends the balance to the buyer and closes the offer.
struct (0x474d0200) CancelOffer {
    /// Ed25519 signature by the offer key over the hash part of the offer address. Required
    /// before expiry; null works only after expiry. A replay does nothing, because the offer is
    /// then no longer Active.
    signature: bits512?
}
