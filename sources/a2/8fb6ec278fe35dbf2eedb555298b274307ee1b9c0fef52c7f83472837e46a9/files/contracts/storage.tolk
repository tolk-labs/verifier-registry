/// Collection content: its metadata and the prefix of wallet content URLs.
struct CollectionContent {
    /// TEP-64 collection metadata, returned by `get_collection_data`.
    collectionMetadata: cell
    /// Prefix of the wallet content URLs that `get_nft_content` builds. It must end with "/".
    commonContent: string
}

/// TEP-66 royalty: `numerator / denominator` of each sale goes to `royaltyAddress`.
struct RoyaltyParams {
    numerator: uint16
    denominator: uint16
    royaltyAddress: address
}

/// Wallet storage until the collection's deploy message initializes it.
struct AgenticWalletStorageNotInitialized {
    /// Replay counter of signed requests.
    readonly seqno: uint32
    /// Index of this wallet in the collection.
    readonly walletIndex: uint64
    /// Collection that deploys this wallet.
    readonly collectionAddress: address
}
