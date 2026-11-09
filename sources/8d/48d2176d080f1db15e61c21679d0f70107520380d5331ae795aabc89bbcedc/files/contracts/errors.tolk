/// Exit codes of NftOffer. Not listed: a wrong external prefix exits with the compiler's
/// opcode-mismatch code, and a missing signature before expiry with a type-check error.
enum Errors {
    /// The funding doesn't cover the price, the fee and the storage reserve.
    NotEnoughFunds = 453
    /// `ownership_assigned` didn't come from the offer NFT, or names a previous owner outside the
    /// basechain.
    InvalidOwnershipAssigned = 455
    /// The offer expired.
    Expired = 457
    /// Unknown opcode (a text comment included), wrong sender, wrong phase or bad signature.
    Forbidden = 0xFFFF
}
