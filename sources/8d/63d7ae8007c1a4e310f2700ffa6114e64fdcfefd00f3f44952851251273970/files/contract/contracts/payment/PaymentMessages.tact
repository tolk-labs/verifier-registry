// Shared messages and structs for all payment processors (TON + Jetton, Safe + Unsafe).
// Single source of truth — do not redeclare these in contract files.

// ===== Payment entry =====
// Opcode bumped from 0x42c20f7a: the deadline field was removed, so stale clients
// sending the old layout hit "unknown opcode" instead of being misparsed.
message(0x42c20f7b) Transfer {
    req: PaymentRequest;
}

struct PaymentRequest {
    buyer: Address;
    seller: Address;
    amount: Int;                        // nanotons (TON) or jetton units (USDT)
    buyerPaysCommission: Bool;
    optionalCommissionWallet: Address?; // None if not used
}

// ===== Admin =====
message(0xeeab28d0) SetPlatformCommissionBps {
    newBps: Int;
}

message(0xe225cbda) WithdrawAll {
    to: Address;
}

message(0x1a2b3c0a) SetPaused {
    paused: Bool;
}

// Plain owner rotation (all variants). Safe variants additionally have SetOwnerWithKey
// (SellerWhitelist) to rotate the owner and the ed25519 signing key atomically.
message(0xc2b41d43) SetOwner {
    newOwner: Address;
}

// Withdraw stuck jettons; jettonWallet = null means the processor's own jetton wallet.
// Replaces the old 0x1a2b3c06 WithdrawAllJettons (layout changed: optional wallet added).
message(0x1a2b3c0c) WithdrawAllJettons {
    to: Address;
    amount: Int as coins;
    jettonWallet: Address?;
}

// Tag message for optional wallet transfer so we can identify its bounce.
// Re-opcoded from 0x1a2b3c09 which collided with SetJettonWallet.
message(0x1a2b3c0b) OptionalWalletTransfer {}

// ===== View structs =====
struct Preview {
    commission: Int;
    totalPay: Int;
}

struct ConfigResponse {
    owner: Address;
    mainCommissionWallet: Address;
    nftCollection: Address;
    platformCommissionBps: Int;
    minimalPlatformCommission: Int;
    paused: Bool;
}

const ZERO_ADDRESS: Address = newAddress(0, 0);
