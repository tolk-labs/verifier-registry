// The official Tolk NFT storage (ton-blockchain/tolk-bench, contracts_Tolk/02_nft), with one addition: CatBirth,
// and the `birth` field of an item.

struct RoyaltyParams {
    numerator: uint16
    denominator: uint16
    royaltyAddress: address
}

struct NftCollectionStorage {
    adminAddress: address
    nextItemIndex: uint64
    content: Cell<CollectionContent>
    nftItemCode: cell
    royaltyParams: Cell<RoyaltyParams>
}

struct CollectionContent {
    collectionMetadata: cell
    commonContent: string
}

// Chilled Cat's addition to the official item: what a cat is and where it came from, written once when it is
// minted and never changed afterwards, whoever owns the cat later.
struct CatBirth {
    builder: address      // the wallet the cat was minted to: whoever built it
    serial: uint64        // its place in the order of minting: 1 for the first cat ever minted
    mintedAt: uint32      // unix time of the mint
    recipe: string        // every piece on the cat, slot by slot, each with its own number: enough to draw the cat again
}

struct NftItemStorage {
    itemIndex: uint64
    collectionAddress: address
    ownerAddress: address
    content: string
    birth: Cell<CatBirth>
}

struct NftItemStorageNotInitialized {
    itemIndex: uint64
    collectionAddress: address
}


fun NftCollectionStorage.load() {
    return NftCollectionStorage.fromCell(contract.getData())
}

fun NftCollectionStorage.save(self) {
    contract.setData(self.toCell())
}


// actual storage of an NFT item is tricky: it's either initialized or not;
// after NFT has been inited, it's represented as `NftItemStorage`;
// before initialization, it has only itemIndex and collectionAddress: `NftItemStorageNotInitialized`;
// hence, we start parsing it, that then we detect, whether it's inited or not
struct NftItemStorageMaybeNotInitialized {
    contractData: slice
}

// how do we detect whether it's initialized or not?
// the answer: when "inited", we store `content` (cell),
// so, we have a ref, and for uninited, we don't have a ref
fun NftItemStorageMaybeNotInitialized.isInitialized(self) {
    val hasContent = self.contractData.remainingRefsCount() != 0;
    return hasContent
}

fun NftItemStorageMaybeNotInitialized.parseNotInitialized(self) {
    return NftItemStorageNotInitialized.fromSlice(self.contractData)
}

fun NftItemStorageMaybeNotInitialized.parseInitialized(self) {
    return NftItemStorage.fromSlice(self.contractData)
}

fun startLoadingNftItemStorage(): NftItemStorageMaybeNotInitialized {
    return {
        contractData: contract.getData().beginParse()
    }
}

fun NftItemStorage.save(self) {
    contract.setData(self.toCell())
}


fun calcDeployedNftItem(itemIndex: uint64, collectionAddress: address, nftItemCode: cell): AutoDeployAddress {
    val emptyNftItemStorage: NftItemStorageNotInitialized = {
        itemIndex,
        collectionAddress,
    };

    return {
        stateInit: {
            code: nftItemCode,
            data: emptyNftItemStorage.toCell()
        }
    }
}
