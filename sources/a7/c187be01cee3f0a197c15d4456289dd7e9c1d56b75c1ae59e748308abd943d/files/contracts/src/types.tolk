struct RoyaltyParams {
    numerator: uint16
    denominator: uint16
    royaltyAddress: address
}

/// Individual content of an NFT item: the generative art seed and the mint timestamp
struct ArtSeed {
    seed: uint256
    mintedAt: uint32
}

/// Data hashed (as a cell representation hash) to derive `ArtSeed.seed` on mint
struct SeedPreimage {
    sender: address
    itemIndex: uint64
    createdLt: uint64
    mintedAt: uint32
    /// TVM randomness drawn in the Mint transaction. The sender controls nothing but their
    /// address; createdLt and mintedAt are network-assigned but roughly predictable, so without
    /// this field a minter could grind wallet addresses to aim for a chosen seed. The block random
    /// seed is set by validators and is unknown before the block exists.
    blockRandom: uint256
}

struct NftCollectionStorage {
    adminAddress: address
    nextItemIndex: uint64
    content: Cell<CollectionContent>
    nftItemCode: cell
    royaltyParams: Cell<RoyaltyParams>
    mintPrice: coins
    /// maximum number of items that can be minted; 0 means unlimited
    maxSupply: uint64
    /// unix time after which minting is closed; 0 means no deadline
    mintUntil: uint32
}

struct CollectionContent {
    collectionMetadata: cell
    commonContent: string
}

struct NftItemStorage {
    itemIndex: uint64
    collectionAddress: address
    ownerAddress: address
    content: Cell<ArtSeed>
}

struct NftItemStorageNotInitialized {
    itemIndex: uint64
    collectionAddress: address
}

struct NftDataReply {
    isInitialized: bool
    itemIndex: int
    collectionAddress: address
    ownerAddress: address? = null
    content: Cell<ArtSeed>? = null
}

fun NftCollectionStorage.load(): NftCollectionStorage {
    return NftCollectionStorage.fromCell(contract.getData());
}

fun NftCollectionStorage.save(self) {
    contract.setData(self.toCell());
}

fun NftItemStorage.startLoading(): NftItemStorageLoader {
    return NftItemStorageLoader.fromCell(contract.getData());
}

fun NftItemStorage.save(self) {
    contract.setData(self.toCell());
}

// storage of an NFT item is tricky: it changes its shape after deployment;
// initially, it has only itemIndex and collectionAddress: `NftItemStorageNotInitialized`;
// after initialization, it becomes a fully filled `NftItemStorage`;
// that's why NftItemStorage doesn't have a `load` method: only `startLoading`,
// which helps detect presence of the rest fields, and `endLoading` called if initialized
struct NftItemStorageLoader {
    itemIndex: uint64
    collectionAddress: address
    private rest: RemainingBitsAndRefs
}

fun NftItemStorageLoader.isNotInitialized(self): bool {
    return self.rest.isEmpty();
}

fun NftItemStorageLoader.endLoading(mutate self): NftItemStorage {
    return {
        itemIndex: self.itemIndex,
        collectionAddress: self.collectionAddress,
        ownerAddress: self.rest.loadAny(),
        content: self.rest.loadAny(),
    };
}

fun calcDeployedNftItem(
    itemIndex: uint64,
    collectionAddress: address,
    nftItemCode: cell,
): AutoDeployAddress {
    val emptyNftItemStorage: NftItemStorageNotInitialized = { itemIndex, collectionAddress };

    return { stateInit: { code: nftItemCode, data: emptyNftItemStorage.toCell() } };
}

struct CollectionDataReply {
    nextItemIndex: int
    collectionMetadata: cell
    adminAddress: address
}

struct MintInfoReply {
    mintPrice: coins
    maxSupply: uint64
    mintUntil: uint32
    nextItemIndex: uint64
}

struct (0x01) OffchainMetadataReply {
    string: string
}
