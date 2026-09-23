message(0xb803b08d) IncrementSuccessfulTx {
    wallet: Address;
}
// Регистрация/обновление партнёра
message(0x50525247) RegisterPartnerShare {  // "PPRG"
    wallet: Address;
    shareBps: Int?;
}

// Удаление партнёра
message(0x5052554E) UnregisterPartnerShare { // "PPUN"
    wallet: Address;
}

// ===== Seller whitelist =====
message(0x1a2b3c01) AddSeller {
    seller: Address;
}

message(0x1a2b3c02) RemoveSeller {
    seller: Address;
}

message(0x1a2b3c03) RegisterSeller {
    deadline: Int as uint64;
    signature: Slice as remaining;
}

// ===== Admin setters =====
message(0x1a2b3c04) SetPartnerCollection {
    collection: Address;
}

message(0x1a2b3c05) SetMinimalPlatformCommission {
    amount: Int as coins;
}

// WithdrawAllJettons moved to payment/PaymentMessages.tact (op 0x1a2b3c0c, layout changed)

message(0x1a2b3c07) SetOwnerWithKey {
    newOwner: Address;
    newPublicKey: Int as uint256;
}

message(0x1a2b3c08) SetIncrementGas {
    amount: Int as coins;
}

message(0x1a2b3c09) SetJettonWallet {
    wallet: Address;
}

// ===== Events (emitted as external out messages) =====
struct PaymentProcessed {
    buyer: Address;
    seller: Address;
    amount: Int as coins;
    commission: Int as coins;
    partnerWallet: Address?;
    partnerShare: Int as coins;
}

struct SellerWhitelistChanged {
    seller: Address;
    added: Bool;
}

// Partner payout dispatched (async on TON: a later OptionalWalletTransferFailed
// for the same wallet means this payout bounced and went to the platform instead)
struct OptionalWalletPaid {
    wallet: Address;
    amount: Int as coins;
}

// Partner payout bounced; funds redirected to mainCommissionWallet.
// amount is the bounced value, i.e. the payout minus forward fees.
struct OptionalWalletTransferFailed {
    wallet: Address;
    amount: Int as coins;
}

// IncrementSuccessfulTx to the collection bounced. wallet is null because a TON
// bounce truncates the body to 256 bits and an Address does not fit.
struct PartnerCounterFailed {
    wallet: Address?;
}

struct CommissionBpsUpdated {
    oldBps: Int;
    newBps: Int;
}

struct MinimalCommissionUpdated {
    oldMinimal: Int as coins;
    newMinimal: Int as coins;
}

struct NftCollectionUpdated {
    oldCollection: Address;
    newCollection: Address;
}

// jettonWallet = null means a native TON withdrawal (Solidity: token == address(0)).
// Emitted when the transfer is REGISTERED (intent); a later JettonTransferFailed with the
// same queryId means the jetton wallet bounced it.
struct Withdrawn {
    jettonWallet: Address?;
    to: Address;
    amount: Int as coins;
}

// An outgoing TokenTransfer bounced (refund, payout or sweep failed on the jetton wallet).
// Only queryId survives bounce-body truncation.
struct JettonTransferFailed {
    queryId: Int as uint64;
}

// A RegisterPartnerShare/UnregisterPartnerShare push from the collection bounced on a
// processor. wallet is null: a TON bounce truncates the body and the address is lost —
// resync manually via SetWalletWhitelist(wallet, true) or SyncPartnerShare.
struct PartnerSyncFailed {
    wallet: Address?;
}

// ===== Collection events (DefNFT parity) =====
struct PartnerNftMinted {
    to: Address;
    tokenId: Int;
    shareBps: Int;
}

struct PartnerNftBurned {
    owner: Address;
    tokenId: Int;
}

struct WalletWhitelistUpdated {
    wallet: Address;
    isWhitelisted: Bool;
}

struct TxProcessorUpdated {
    processor: Address;
    allowed: Bool;
}

struct SuccessfulTxIncremented {
    wallet: Address;
    tokenId: Int;
    newCount: Int;
}

// IncrementSuccessfulTx arrived from a sender that is not a registered processor —
// either the registries are desynced (the counter silently freezes) or someone is probing.
struct UnauthorizedIncrement {
    processor: Address;
    wallet: Address;
}

// Owner pushed a manual per-wallet share (re)sync to a processor via SyncPartnerShare
struct PartnerShareSynced {
    processor: Address;
    wallet: Address;
}