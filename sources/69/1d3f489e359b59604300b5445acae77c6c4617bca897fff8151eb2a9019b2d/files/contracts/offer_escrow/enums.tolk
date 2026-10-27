enum OfferEscrowStatus: uint8 {
    CollectingMaker = 0
    Open = 1
    CollectingTaker = 2
    AwaitingPayoutConfirmation = 3
    PayoutFailed = 4
    PayoutConfirmed = 5
    Settled = 6
    Cancelled = 7
    Expired = 8
}

enum OfferEscrowErrors {
    NotMaker = 301
    AlreadyClosed = 302
    WrongAsset = 303
    NotEnoughValue = 304
    NotClosed = 305
    NotUnexpectedNftRecoveryAuthority = 307
    NotOpen = 308
    ExecutionAttemptMoved = 309
    Reserved310 = 310
    NotAllowedToRelease = 311
    OfferExecutionNumberExhausted = 312
    OfferExpired = 313
    OfferNotExpired = 314
    InvalidTerms = 315
    WrongPayoutConfirmation = 316
    SettlementNotResumable = 317
    PayoutSequenceExhausted = 318
    InvalidContributorSet = 319
    RecoveryReplay = 320
    NotRecoverableNft = 321
    NftAlreadyRecorded = 322
    SettlementInProgress = 323
    NftDeliveryPending = 324
    NotNftDeliveryRecipient = 325
    MakerCancellationUnavailable = 326
    InvalidMakerCancellation = 327
    AutomaticRecoveryUnavailable = 328
    UnexpectedNftRecoveryLocked = 329
    InvalidMessage = 0xFFFF
}
