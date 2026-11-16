// Copyright (C) 2026 MENA
// SPDX-License-Identifier: AGPL-3.0-or-later

// variant:begin
// The storage of SwapEscrowNosup and its error codes. The types it is built
// from are shared with SwapEscrowV2 (shared/types.tolk).
// variant:end
import "../shared/types"

// Error codes. The numeric values are part of the wire contract — integrators
// match on them — so they are pinned by tests and must not be renumbered.
enum Errors {
    NotOwner1 = 401
    NotOwner2 = 402
    NotOwners = 403
    NotRecipient = 405     // claim_asset from anyone but the asset's rightful recipient
    AlreadyFinalized = 410
    NotEnoughTon1 = 420
    NotEnoughTon2 = 421
    ServiceFee1 = 422
    ServiceFee2 = 423
    NftsNotReceived = 424
    InsufficientBalance = 430
    BadAssetIndex = 431    // claim_asset on an index outside the registry
    NotClaimable = 432     // claim_asset on an asset that is not currently claimable
    SideUnderfunded1 = 433 // side 1 has not paid its own costs plus half the shared ones
    SideUnderfunded2 = 434 // the same for side 2
    UnknownOp = 0xFFFF
}

struct Storage {
    swapId: uint64
    phase: uint3
    owner1: address
    owner2: address
    feeWallet: address
    assetsCount: uint16
    required1Count: uint16
    required2Count: uint16
    received1Count: uint16
    received2Count: uint16
    pendingWallets: uint16   // outstanding TEP-89 minter discoveries (0 for NFT-only deals)
    jettonsCount: uint16     // total number of jetton assets (both sides)
    receivedJettons1: uint16 // of those, how many side 1 has received (used by the cancel formulas)
    receivedJettons2: uint16
    assets: map<uint16, Asset>
    grams: Cell<GramState>   // ref: 8 coins fields don't fit in the root alongside 3 addresses
    dist: Cell<DistState>    // batch distribution state
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}
