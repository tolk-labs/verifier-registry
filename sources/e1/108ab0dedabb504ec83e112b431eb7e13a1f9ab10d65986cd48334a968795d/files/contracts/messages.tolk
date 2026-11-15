import "storage"

/// TEP-62 forward payload stored inline with nothing in it: only the prefix bit.
struct (0b0) EmptyPayload {}

/// TEP-62 forward payload stored inline (prefix bit 0).
struct (0b0) PayloadInline {
    value: RemainingBitsAndRefs
}

/// TEP-62 forward payload stored in a ref (prefix bit 1).
struct (0b1) PayloadInRef {
    value: Cell<RemainingBitsAndRefs>
}

/// TEP-62 `ownership_assigned`: wallet → new owner.
struct (0x05138d91) NotificationForNewOwner {
    queryId: uint64
    /// Previous owner; the collection on deploy.
    oldOwnerAddress: address
    /// Forward payload of the transfer or deploy, passed as is.
    @abi.clientType(PayloadInline | PayloadInRef)
    forwardPayload: RemainingBitsAndRefs
}

/// TEP-62 `excesses`: returns unused value to the response address.
struct (0xd53276db) ReturnExcessesBack {
    queryId: uint64
}

/// Text comment: op 0 followed by the text.
struct (0x00000000) TextComment {
    text: RemainingBitsAndRefs
}

/// Raw OutActionList (TL-B `OutList`), the format of c5.
type OutActionsCell = cell

/// TL-B `action_send_msg#0ec3c86d mode:(## 8) out_msg:^(MessageRelaxed Any)`.
struct (0x0ec3c86d) OutActionWithSendMessageOnly {
    /// The rest of the list.
    prev: Cell<OutActionWithSendMessageOnlyOrEmpty>
    sendMode: uint8
    outMsg: cell
}

/// The previous action, or the end of the list.
type OutActionWithSendMessageOnlyOrEmpty = OutActionWithSendMessageOnly | void

/// Anyone → collection: deploys the next wallet for the sender. The value pays the deploy price,
/// and the wallet gets the rest.
struct (0xe2736064) RelayPublicDeployWallet {
    queryId: uint64
    /// Gets `referralBps` of the deploy price; null: no reward.
    referralAddress: address?
}

/// Admin → collection: deploys the next wallet, or retries an allocated one.
struct (0xdb6169ee) RelayDeployWallet {
    queryId: uint64
    /// Allocated index to retry; null: the next index.
    walletIndex: uint64?
    /// Value sent to the wallet with its deploy message.
    attachAmount: coins
    /// Relayed to the wallet as is.
    initParams: Cell<AgenticWalletInitParams>
}

/// Wallet initialization data, relayed from the collection on deploy.
struct AgenticWalletInitParams {
    /// First owner of the wallet.
    ownerAddress: address
    /// Individual content, expanded by the collection's `get_nft_content`.
    content: cell
    /// Public key of the agent that can sign requests; 0 means none.
    delegatePublicKey: uint256
    /// Value sent to the owner with `ownership_assigned`; 0: no notification.
    forwardAmount: coins
    /// Payload of that notification.
    @abi.clientType(PayloadInline | PayloadInRef)
    forwardPayload: RemainingBitsAndRefs
}

/// Admin → collection: replaces the content of wallet `walletIndex`.
struct (0x3d0bfff2) RelayEditWalletContent {
    queryId: uint64
    /// Index of the wallet to edit.
    walletIndex: uint64
    /// Replaces the wallet's individual content.
    newContent: cell
}

/// Admin → collection: replaces the collection content and royalty params.
struct (0xf30285b3) EditCollectionContent {
    queryId: uint64
    /// Replaces the collection content.
    newContent: Cell<CollectionContent>
    /// Replaces the royalty params.
    newRoyaltyParams: Cell<RoyaltyParams>
}

/// Admin → collection: replaces the collection settings.
struct (0x182a9e0a) EditCollectionSettings {
    queryId: uint64
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
}

/// Admin → collection: withdraws the collection balance.
struct (0xddf389ab) WithdrawCollectionBalance {
    queryId: uint64
}

/// Admin → collection: sets a new admin.
struct (0x2f48d4a1) ChangeCollectionAdmin {
    queryId: uint64
    /// Replaces the admin.
    newAdminAddress: address
}

/// TEP-66 `get_royalty_params`: anyone → collection.
struct (0x693d3950) RequestRoyaltyParams {
    queryId: uint64
}

/// TEP-66 `report_royalty_params`: collection → requester.
struct (0xa8cb00ad) ResponseRoyaltyParams {
    queryId: uint64
    royaltyParams: RoyaltyParams
}

/// Signed request in an external message.
struct (0x90879ba8) ExternalSignedRequest {
    /// Address of the wallet this request is signed for.
    walletAddress: address
    /// Unix time the request expires at.
    validUntil: uint32
    /// Must equal the wallet seqno.
    seqno: uint32
    /// OutActionList the wallet sends.
    @abi.clientType(Cell<OutActionWithSendMessageOnly>)
    outActions: OutActionsCell
    /// Delegate signature of the request without this field.
    signature: bits512
}

/// Signed request in an internal message.
struct (0xc369a095) InternalSignedRequest {
    /// Address of the wallet this request is signed for.
    walletAddress: address
    /// Unix time the request expires at.
    validUntil: uint32
    /// Must equal the wallet seqno.
    seqno: uint32
    /// OutActionList the wallet sends.
    @abi.clientType(Cell<OutActionWithSendMessageOnly>)
    outActions: OutActionsCell
    /// Delegate signature of the request without this field.
    signature: bits512
}

/// Owner → wallet: sends the given OutActionList from the wallet.
struct (0x7f97334d) OwnerActionRequest {
    queryId: uint64
    /// OutActionList the wallet sends.
    @abi.clientType(Cell<OutActionWithSendMessageOnly>)
    outActions: OutActionsCell
}

/// TEP-62 `transfer`: owner → wallet. Removes the delegate key and increments the seqno.
struct (0x5fcc3d14) ChangeWalletOwner {
    queryId: uint64
    /// Replaces the owner.
    newOwnerAddress: address
    /// Gets the excess value with `excesses`; null: the wallet keeps it.
    sendExcessesTo: address?
    /// Ignored.
    customPayload: cell?
    /// Value sent to the new owner with `ownership_assigned`; 0: no notification.
    forwardAmount: coins
    /// Payload of that notification.
    @abi.clientType(PayloadInline | PayloadInRef)
    forwardPayload: RemainingBitsAndRefs
}

/// Owner → wallet: sets the delegate public key and increments the seqno.
struct (0xc7966b87) ChangeWalletDelegate {
    queryId: uint64
    /// Replaces the delegate public key; 0 removes it.
    newDelegatePublicKey: uint256
}

/// Collection → wallet: initializes the wallet.
struct (0x9f1096d7) DeployWallet {
    queryId: uint64
    /// Initialization data from `RelayDeployWallet` or the public deploy.
    initParams: Cell<AgenticWalletInitParams>
}

/// Collection → wallet: replaces the wallet content.
struct (0x8e19ab92) EditWalletContent {
    queryId: uint64
    /// Replaces the wallet's individual content.
    newContent: cell
}

/// TEP-62 `get_static_data`: anyone → wallet.
struct (0x2fcb26a2) RequestStaticData {
    queryId: uint64
}

/// TEP-62 `report_static_data`: wallet → requester.
struct (0x8b771735) ResponseStaticData {
    queryId: uint64
    /// TEP-62 `index` of this wallet.
    walletIndex: uint256
    /// Collection that deployed this wallet.
    collectionAddress: address
}
