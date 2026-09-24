import "types"

struct NftItemInitAtDeployment {
    ownerAddress: address
    content: Cell<ArtSeed>
}

struct (0x693d3950) RequestRoyaltyParams {
    queryId: uint64
}

struct (0xa8cb00ad) ResponseRoyaltyParams {
    queryId: uint64
    royaltyParams: RoyaltyParams
}

/// Public mint: pay `mintPrice + MINT_OVERHEAD` (or more) to receive a new item; excess is refunded
struct (0x4d494e54) Mint {
    queryId: uint64
}

/// Admin only: send the collection balance above MIN_COLLECTION_BALANCE to the admin
struct (0x77697468) Withdraw {
    queryId: uint64
}

struct (0x00000003) ChangeCollectionAdmin {
    queryId: uint64
    newAdminAddress: address
}

/// Admin only, and only before the first mint: replace the collection content. Same opcode as
/// op 4 of the reference nft-collection-editable.fc, but unlike it the body carries only the
/// content cell and never touches the royalty params, which are fixed at deployment.
/// The admin is trusted for the URL and text values: the cell structure is validated
/// (a malformed cell fails with InvalidContent), but the URL semantics are not.
/// The first mint seals whatever content is stored at that moment.
/// Send it with contracts/scripts/edit-content.tolk (`acton run nft-edit-content`).
struct (0x00000004) EditContent {
    queryId: uint64
    content: Cell<CollectionContent>
}

struct (0x2fcb26a2) RequestStaticData {
    queryId: uint64
}

struct (0x8b771735) ResponseStaticData {
    queryId: uint64
    itemIndex: uint256
    collectionAddress: address
}

struct (0b0) PayloadInline {
    value: RemainingBitsAndRefs
}

struct (0b1) PayloadInRef {
    value: Cell<RemainingBitsAndRefs>
}

struct (0x05138d91) NotificationForNewOwner {
    queryId: uint64
    oldOwnerAddress: address
    @abi.clientType(PayloadInline | PayloadInRef)
    payload: RemainingBitsAndRefs
}

struct (0xd53276db) ReturnExcessesBack {
    queryId: uint64
}

struct (0x5fcc3d14) AskToChangeOwnership {
    queryId: uint64
    newOwnerAddress: address
    sendExcessesTo: address?
    customPayload: cell?
    forwardTonAmount: coins
    @abi.clientType(PayloadInline | PayloadInRef)
    forwardPayload: RemainingBitsAndRefs
}
