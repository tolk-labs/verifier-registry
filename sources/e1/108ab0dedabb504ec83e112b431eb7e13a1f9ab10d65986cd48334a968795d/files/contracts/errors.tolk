/// Exit codes, grouped as wallet, NFT, project-specific and unknown opcode.
enum Errors {
    /// The request seqno is not equal to the wallet seqno.
    InvalidSeqno = 133
    /// The request is signed for another wallet address.
    InvalidWalletAddress = 134
    /// The signature is invalid, or no delegate key is set.
    InvalidSignature = 135
    /// The request `validUntil` time is not later than the current time.
    Expired = 136
    /// An external request has a send action without ignore-errors mode (+2).
    ExternalSendMessageMustHaveIgnoreErrorsSendMode = 137
    /// The external message is not a signed request.
    InvalidMessageOperation = 138
    /// The action list is empty or malformed, has a non-send action or has more than 255 actions.
    InvalidC5 = 147

    /// An address is not in the basechain.
    InvalidWorkchain = 333
    /// The sender is not the collection admin.
    NotFromAdmin = 401
    /// The wallet index of a deploy retry or a content edit is not allocated yet.
    InvalidWalletIndex = 402
    /// The sender is not the current owner of the wallet.
    NotFromOwner = 403
    /// The sender is not the collection of this wallet.
    NotFromCollection = 405
    /// The balance can not pay the storage reserve, the forward amount and the fees.
    TooSmallRestAmount = 406
    /// The forward payload does not have a valid inline or ref encoding.
    IncorrectForwardPayload = 708

    /// The network ID in the collection storage is not the ID of the current network.
    WrongNetwork = 800
    /// Public deploys are disabled.
    PublicDeployDisabled = 801
    /// A new wallet index is past the collection's max wallet index.
    WalletLimitReached = 802
    /// The value can not pay the deploy price and the storage reserve of the wallet.
    TooSmallDeployValue = 803
    /// A deploy message reached an already initialized wallet.
    AlreadyInitialized = 804
    /// The wallet is not initialized yet.
    NotInitialized = 805
    /// A wallet action can not use the destroy send mode (+32).
    DestroyNotAllowed = 806
    /// The incoming value can not pay the forward amount and the forward fees.
    TooSmallFunding = 807

    /// The message is not a known operation.
    UnknownOperation = 0xFFFF
}
