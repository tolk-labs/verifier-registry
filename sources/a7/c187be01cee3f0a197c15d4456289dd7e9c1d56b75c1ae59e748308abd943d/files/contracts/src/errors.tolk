// most codes are the same as in the FunC reference implementation
// (which is why some numeric values are shared between names)

enum Errors {
    /// sender is not a basechain address (mint sender, new owner, or excesses receiver)
    InvalidWorkchain = 333
    /// collection: sender is not the collection admin
    NotFromAdmin = 401
    /// item: sender is not the item owner
    NotFromOwner = 401
    /// item: initialization message did not come from the collection
    NotFromCollection = 405
    /// item: not enough balance left to cover a transfer with its forward amounts
    TooSmallRestAmount = 402
    /// collection: attached value is less than mintPrice + MINT_OVERHEAD
    InsufficientMintValue = 410
    /// collection: maxSupply is set and nextItemIndex is past it (indexes start at 1, so a cap of
    /// N allows items 1..N)
    SoldOut = 411
    /// collection: mintUntil is set and the current time is past it
    MintClosed = 412
    /// collection: content can no longer be edited because at least one item has been minted
    /// (nextItemIndex > 1)
    CollectionSealed = 413
    /// collection: the EditContent content cell is not a well-formed CollectionContent
    InvalidContent = 414
    /// item: forward payload is not a valid Either (inline bit or exactly one ref)
    IncorrectForwardPayload = 708
}
