import "errors"

/// Storage of an initialized wallet. It starts with the fields of
/// `AgenticWalletStorageNotInitialized`.
struct AgenticWalletStorage {
    /// Replay counter of signed requests. Owner and delegate key changes also increment it.
    seqno: uint32
    /// Index of this wallet in the collection.
    readonly walletIndex: uint64
    /// Collection that deployed this wallet. Only it can send the deploy and content edits.
    readonly collectionAddress: address
    /// Owner: sends owner actions, transfers the wallet and sets the delegate key.
    ownerAddress: address
    /// Public key of the agent that can sign requests; 0 means none.
    delegatePublicKey: uint256
    /// Individual content, expanded by the collection's `get_nft_content`.
    content: cell
}

/// Starts to load the storage of a wallet that is possibly not initialized.
fun AgenticWalletStorage.startLoading(): AgenticWalletStorageLoader {
    return AgenticWalletStorageLoader.fromCell(contract.getData());
}

/// Saves the storage of an initialized wallet.
fun AgenticWalletStorage.save(self) {
    contract.setData(self.toCell());
}

/// Wallet storage changes shape on deploy:
/// `AgenticWalletStorageNotInitialized` becomes `AgenticWalletStorage`.
/// Use `startLoading` + `isInitialized` + `endLoading`,
/// or `loadInitialized` (throws `NotInitialized`).
struct AgenticWalletStorageLoader {
    readonly seqno: uint32
    readonly walletIndex: uint64
    readonly collectionAddress: address
    /// Fields after `collectionAddress`; empty until the wallet is initialized.
    private rest: RemainingBitsAndRefs
}

/// Whether the collection's deploy message has initialized the wallet.
fun AgenticWalletStorageLoader.isInitialized(self): bool {
    return !self.rest.isEmpty();
}

/// Loads the rest of an initialized wallet's storage.
fun AgenticWalletStorageLoader.endLoading(mutate self): AgenticWalletStorage {
    val (ownerAddress, delegatePublicKey, content) = self.rest.loadAny<(address, uint256, cell)>();

    return {
        seqno: self.seqno,
        walletIndex: self.walletIndex,
        collectionAddress: self.collectionAddress,
        ownerAddress,
        delegatePublicKey,
        content,
    };
}

/// Loads the storage of an initialized wallet. Otherwise, throws `NotInitialized`.
fun AgenticWalletStorage.loadInitialized(): AgenticWalletStorage {
    var loadingStorage = AgenticWalletStorage.startLoading();

    assert (loadingStorage.isInitialized()) throw Errors.NotInitialized;

    return loadingStorage.endLoading();
}

/// TEP-62 `get_nft_data` result.
struct NftDataReply {
    /// Whether the collection's deploy message has initialized the wallet.
    isInitialized: bool
    walletIndex: uint64
    collectionAddress: address
    /// Null until the wallet is initialized.
    ownerAddress: address? = null
    /// Individual content; null until the wallet is initialized.
    content: cell? = null
}
