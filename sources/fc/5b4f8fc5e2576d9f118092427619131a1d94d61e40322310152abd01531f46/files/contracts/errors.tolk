/// Exit codes of the contract. The values are the same as in the deployed bytecode.
enum Errors {
    /// The text bet is not "Long" or "Short", or the body has refs.
    InvalidBetText = 400
    /// The message value is less than `minOpValue`.
    NotEnoughValue = 401
    /// The sender cannot do this operation. For a bet: the sender is not in the basechain,
    /// or it is the contract itself.
    SenderNotAllowed = 402
    /// The message value minus `betFee` is not one of the permitted bet sizes.
    InvalidBetAmount = 403
    /// The round is not in the rounds map.
    RoundNotFound = 404
    /// The round state does not permit this operation.
    InvalidRoundState = 405
    /// The round time is not correct for a price update.
    InvalidRoundTime = 406
    /// The price is 0, or the oracle signature is not correct.
    InvalidPriceProof = 407
    /// The limit of active rounds, or the limit of bettors in the round, is reached.
    LimitReached = 408
    /// There are no protocol fees to withdraw.
    NoFees = 409
    /// The refund delay of the round is not complete.
    RefundTooEarly = 410
    /// The contract has active rounds, locked funds or bettors.
    ContractNotIdle = 412
    /// A value in the new configuration, or the new oracle key, is not correct.
    InvalidConfig = 413
    /// The treasury cannot change while there are protocol fees to withdraw.
    TreasuryChangeWithFees = 414
    /// A paid bettor is not in the open bet counts map.
    BettorNotFound = 415
}
