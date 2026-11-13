/// TEP-62 `ownership_assigned`: NFT → sale. The NFT tells the sale that it is the new owner.
struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    /// Owner of the NFT before the transfer.
    prevOwner: address
    /// Forward payload of the transfer. The sale ignores it.
    forwardPayload: RemainingBitsAndRefs
}

/// Anyone → sale: buys the NFT.
struct (0x474d0001) Buy {
    queryId: uint64
    /// Maximum price that the buyer accepts.
    maxPrice: coins
    /// Gets the NFT.
    newOwner: address
}

/// Seller → sale: sets a new price.
struct (0x474d0002) ChangePrice {
    /// New price. It must be more than 0.
    newPrice: coins
}

/// Seller → sale: cancels the sale and sends the NFT back to the seller.
struct (0x474d0003) Cancel {
    queryId: uint64
    /// Gets the excess of the NFT transfer.
    responseDestination: address
}

/// Messages that the sale accepts.
type AllowedMessage = OwnershipAssigned | ChangePrice | Buy | Cancel

/// TEP-62 `transfer`: sale → NFT.
struct (0x5fcc3d14) TransferNft {
    queryId: uint64
    /// Gets the NFT.
    newOwner: address
    /// Gets the excess of the transfer.
    responseDestination: address?
    /// Payload for the NFT item. The sale sends none.
    customPayload: cell?
    /// Value for the `ownership_assigned` notification. The sale sends 0.
    forwardAmount: coins
    /// Payload for the `ownership_assigned` notification.
    forwardPayload: RemainingBitsAndRefs
}

/// TEP-62 forward payload: inline and empty (only the prefix bit 0).
const EMPTY_FORWARD_PAYLOAD = "4_".hexToSlice()
