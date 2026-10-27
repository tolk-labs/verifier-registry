enum CertifiedOfferEscrowStatus: uint8 {
    CollectingMaker = 0
    Open = 1
    CollectingTaker = 2
    AwaitingApproval = 3
    AwaitingPayoutConfirmation = 4
    PayoutFailed = 5
    PayoutConfirmed = 6
    Settled = 7
    Cancelled = 8
    Expired = 9
}

enum FinalizationPolicy: uint8 {
    Revocable = 0
    CertifierGated = 1
}

enum CertifiedOfferEscrowErrors {
    NotMaker = 401
    AlreadyClosed = 402
    NotClosed = 403
    NotUnexpectedNftRecoveryAuthority = 405
    NotOpen = 406
    ExecutionAttemptMoved = 407
    NotAllowedToRelease = 408
    OfferExecutionNumberExhausted = 409
    OfferExpired = 410
    OfferNotExpired = 411
    InvalidTerms = 412
    InvalidContributorSet = 413
    WrongCertificateDomain = 414
    InvalidCertificate = 415
    InvalidCertifiedItems = 416
    NotAwaitingApproval = 417
    WrongDeliveryCommitment = 418
    WrongPayoutConfirmation = 419
    SettlementNotResumable = 420
    PayoutSequenceExhausted = 421
    CertifierGraceTooLong = 422
    RecoveryReplay = 423
    NotRecoverableNft = 424
    NftAlreadyRecorded = 425
    SettlementInProgress = 426
    FinalizationLocked = 427
    NotEnoughValue = 428
    NftDeliveryPending = 429
    NotNftDeliveryRecipient = 430
    WrongSettlementAuthorizationDomain = 431
    InvalidSettlementAuthorization = 432
    SettlementAuthorizationExpired = 433
    MakerCancellationUnavailable = 434
    InvalidMakerCancellation = 435
    AutomaticRecoveryUnavailable = 436
    UnexpectedNftRecoveryLocked = 437
    InvalidMessage = 0xFFFF
}
