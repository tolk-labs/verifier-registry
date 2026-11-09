// Exit codes. Kept stable: the app maps them to human-readable errors.

enum Errors {
    NotFromOwner = 401
    NotFromAdmin = 402
    NotFromMinter = 403
    NotFromCollection = 405
    InvalidWorkchain = 333
    MintPaused = 411
    NotEnoughValue = 412
    FixedPrefixNotAllowed = 413
    InvalidIndex = 414
    InvalidClaim = 415
    InvalidCommonContent = 416
    DestroyModeForbidden = 420
    TooManyActions = 421
    EmptyActionList = 422
    TransferToSelf = 423
    ForbiddenOpcode = 424
    InvalidRoyalty = 430
    InvalidSignature = 440
    VoucherExpired = 441
    WrongCollection = 442
    InvalidVoucher = 443
    NotFromUpgradeAuthority = 450
    NoPendingUpgrade = 451
    UpgradeTimelocked = 452
    ProposalMismatch = 453
    EmptyProposal = 454
    InvalidUpgradeDelay = 455
    NotFromItem = 456
    ItemCodeMismatch = 457
    NotFromSelf = 458
    UpgradeNotRequested = 459
    IncorrectForwardPayload = 708
    UnknownOp = 0xFFFF
}
