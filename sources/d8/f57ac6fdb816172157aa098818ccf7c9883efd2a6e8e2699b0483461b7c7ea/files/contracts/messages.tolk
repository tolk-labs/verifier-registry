// Copyright (C) 2026 MENA
// SPDX-License-Identifier: AGPL-3.0-or-later
// Incoming binary messages for the escrow

struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    previousOwner: address
    forwardPayload: RemainingBitsAndRefs
}

// Opcodes for the supervisor messages. Assigned explicitly rather than
// derived from the struct signature, so that they stay stable when fields
// change.
struct (0x6d5f0001) SupervisorAssetReceived {
    assetAddr: address
}

struct (0x6d5f0002) RescueNft {
    nftAddr: address
}

// Rescue-only withdrawal of jettons from OUR jetton wallet.
// Acton 1.1.0 toolchain bug (the same one that affects MintMock below — see
// the comment there): the straightforward {jettonWallet: address, amount:
// coins} layout (two fields, address+coins) empirically fails with "Cannot
// send message: cell overflow" in createMessage/net.send. Workaround: a
// queryId field comes first (the same workaround as MintMock).
struct (0x6d5f0003) RescueJetton {
    queryId: uint64
    jettonWallet: address // OUR jetton wallet to withdraw from
    amount: coins
}

// ── Batch distribution ──
// Self-trigger for the next batch. Accepted ONLY from myAddress — this is a
// self-trigger, and no other sender should be able to drive the batch chain.
// queryId = cursor value at send time (for diagnostics in the explorer).
struct (0x6d5f0004) ContinueDistribution {
    queryId: uint64
}

// Supervisor-triggered delivery of a stuck asset (the "permanently stuck
// asset" case).
// fallback=true marks it abandoned (excludes it from delivery waiting).
struct (0x6d5f0005) ForceDeliver {
    queryId: uint64
    assetIndex: uint16
    fallback: bool
}

type EscrowBinaryMessage =
    | OwnershipAssigned
    | TakeWalletAddress
    | SupervisorAssetReceived
    | RescueNft
    | RescueJetton
    | JettonTransferNotification
    | Excesses
    | ContinueDistribution
    | ForceDeliver

// Outgoing TIP-4 transfer. Field order on the wire:
// op, queryId, newOwner, responseDestination, maybe-custom (0), coins 0, either tag (0)
// The trailing field is a full forwardPayload:RemainingBitsAndRefs, as in
// JettonTransfer and real TIP-4 items, rather than a bare tag bit. The
// escrow's own outgoing transfers set zeroBitSlice() — either bit 0 with an
// empty inline payload, which is a single 0 bit on the wire.
// A deposit carrying a hint sets either-0 + uint16 asset_index — the same
// format as the jetton hint; the mock passes the payload straight through in
// OwnershipAssigned, and handleNftReceived reads it via parseAssetIndexHint.
struct (0x5fcc3d14) NftTransfer {
    queryId: uint64
    newOwner: address
    responseDestination: address
    customPayload: cell?
    forwardAmount: coins
    forwardPayload: RemainingBitsAndRefs
}

// ── TEP-89 (jetton wallet discovery) ──

struct (0x2c76b973) ProvideWalletAddress {
    queryId: uint64
    ownerAddress: address
    includeAddress: bool
}

struct (0xd1735400) TakeWalletAddress {
    queryId: uint64
    walletAddress: address
    rest: RemainingBitsAndRefs // owner_address:(Maybe ^MsgAddress) — not read
}

// ── TEP-74 (jettons) ──
// forwardPayload: RemainingBitsAndRefs = either bit + content (Either Cell ^Cell).
// The escrow's outgoing transfers set zeroBitSlice() — either 0, empty inline payload.

struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    amount: coins
    destination: address
    responseDestination: address
    customPayload: cell?
    forwardTonAmount: coins
    forwardPayload: RemainingBitsAndRefs
}

struct (0x178d4519) JettonInternalTransfer {
    queryId: uint64
    amount: coins
    from: address
    responseAddress: address
    forwardTonAmount: coins
    forwardPayload: RemainingBitsAndRefs
}

struct (0x7362d09c) JettonTransferNotification {
    queryId: uint64
    amount: coins
    sender: address // the DEPOSITOR (owner of the sending wallet), not our wallet
    forwardPayload: RemainingBitsAndRefs
}

struct (0xd53276db) Excesses {
    queryId: uint64
}

// Test-only issuance for the mock minter (a custom op in the 0x6d5f00xx
// space, like SupervisorAssetReceived/RescueNft).
// Added a queryId field (the straightforward layout would be just
// to:address + amount:coins). Reason: an empirically discovered Acton 1.1.0
// toolchain bug — a message structure with EXACTLY two fields (address,
// coins), in any order and with no other fields, fails with "Cannot send
// message: cell overflow" when built via createMessage/net.send, even though
// the total size (op 32 + address 267 + coins <=124 ~= 423 bits) is well
// under the cell's 1023-bit limit. Confirmed with a minimal repro: structures
// with the SAME field types but a THIRD field (bool/uint64/uint32, any kind)
// build fine; the project's existing address+coins structures always have 3+
// fields (NftTransfer, JettonTransfer, etc.) and never trigger the bug.
// Adding queryId is both a workaround and a useful field going forward
// (matching the convention of the other TEP messages).
struct (0x6d5f00a1) MintMock {
    queryId: uint64
    to: address
    amount: coins
}

// A slice consisting of a single zero bit: the either tag "inline, empty"
// for forward_payload, and the maybe tag "none" for owner_address in
// TakeWalletAddress.
fun zeroBitSlice(): slice {
    return beginCell().storeUint(0, 1).endCell().beginParse();
}

// ── Test-only opcodes for the NFT mock (ONLY the mock's union, NOT EscrowBinaryMessage) ──

// TEST-ONLY mock opcode: toggle refusal to accept transfers (bounce scenarios).
struct (0x6d5f00a2) SetNftReject {
    queryId: uint64
    reject: bool
}

// TEST-ONLY mock opcode: change the owner without a TIP-4 transfer (breaks
// the circular escrow/mock address dependency in mid-state fixtures).
struct (0x6d5f00a3) SetNftOwner {
    queryId: uint64
    newOwner: address
}
