import "storage"

/// Global ID of the current network (config param 19): -239 mainnet, -3 testnet.
/// SAFETY: pushes one signed 32-bit int; throws only if config param 19 is missing or malformed.
@pure
fun blockchain.globalId(): int
    asm "GLOBALID"

/// Collection storage.
struct AgenticCollectionStorage {
    /// Index of the next new wallet. All lower indexes are allocated.
    nextWalletIndex: uint64
    /// Highest index that a new wallet can get.
    maxWalletIndex: uint64
    /// Whether public deploys are accepted.
    publicDeployEnabled: bool
    /// Price of every public deploy, kept by the collection.
    deployPrice: coins
    /// Share of `deployPrice` paid to the referral, in basis points.
    referralBps: uint16
    /// Number of trait sets a public deploy draws from.
    traitSetCount: uint16
    /// Global ID of the network this collection deploys wallets on.
    readonly networkId: int32
    /// Sends the admin messages: admin deploys, content and settings edits, withdrawals and admin
    /// changes.
    adminAddress: address
    /// Collection metadata and the prefix of wallet content URLs.
    content: Cell<CollectionContent>
    /// Code of the wallets this collection deploys.
    readonly walletCode: cell
    /// TEP-66 royalty, returned by `royalty_params` and `RequestRoyaltyParams`.
    royaltyParams: Cell<RoyaltyParams>
}

/// Loads the collection storage.
fun AgenticCollectionStorage.load(): AgenticCollectionStorage {
    return AgenticCollectionStorage.fromCell(contract.getData());
}

/// Saves the collection storage.
fun AgenticCollectionStorage.save(self) {
    contract.setData(self.toCell());
}

/// StateInit and address of wallet `walletIndex`. Its data holds seqno 0, the index and the
/// collection.
fun calcDeployedAgenticWallet(
    walletIndex: uint64,
    collectionAddress: address,
    walletCode: cell,
): AutoDeployAddress {
    val emptyWalletStorage: AgenticWalletStorageNotInitialized = {
        seqno: 0,
        walletIndex,
        collectionAddress,
    };

    return {
        workchain: BASECHAIN,
        stateInit: { code: walletCode, data: emptyWalletStorage.toCell() },
    };
}

/// TEP-62 `get_collection_data` result.
struct CollectionDataReply {
    /// Index the next new wallet gets.
    nextWalletIndex: uint64
    /// TEP-64 collection metadata.
    collectionMetadata: cell
    /// Collection admin, the TEP-62 `owner_address`.
    adminAddress: address
}

/// `get_collection_settings` result. The fields are the same as in `AgenticCollectionStorage`.
struct CollectionSettingsReply {
    maxWalletIndex: uint64
    publicDeployEnabled: bool
    deployPrice: coins
    referralBps: uint16
    traitSetCount: uint16
}
