// Error codes for the GroypFi OTC desk. Values >= 400 so they never clash with
// the jetton contracts (errors.tolk) or TVM's own codes.
enum OtcErrors {
    NotFactory = 401
    NotMaker = 402
    NotAdmin = 403
    NotJettonMaster = 404
    NotOrderWallet = 405
    WrongStatus = 406
    Expired = 407
    NotExpired = 408
    NotPrivateTaker = 409
    BadAmount = 410
    BelowMinFill = 411
    NotEnoughValue = 412
    Paused = 413
    AboveCap = 414
    BelowMinPrice = 415
    BadExpiry = 416
    WrongWorkchain = 417
    CapCanOnlyRise = 418
    UnknownOp = 0xFFFF
}
