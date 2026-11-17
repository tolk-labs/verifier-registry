// Copyright (C) 2026 MENA
// SPDX-License-Identifier: AGPL-3.0-or-later

// variant:begin
// The storage of SwapEscrowV2 — SwapEscrowNosup's storage plus the
// supervisor — and its error codes. The types it is built from are shared
// with SwapEscrowNosup (shared/types.tolk).
// variant:end
import "../shared/types"

// sup:begin

// The supervisor and its isolated rescue registry: foreign NFTs it registered
// (SupervisorAssetReceived), swept only by emergency_collect_assets.
struct SupervisorState {
    supervisor: address
    rescueAssets: map<uint16, address>
    rescueCount: uint16
}

// Delivery modes of the supervisor's batch operations (phase CANCELLED).
const DIST_COLLECT = 3 // emergency_collect: to the supervisor
const DIST_RETURN = 4 // emergency_return: to depositors, without a sweep

// The emergency_collect sweep of sup.rescueAssets; at or above
// QUERY_ID_NON_ASSET, so its bounces are ignored.
const QUERY_ID_RESCUE_REGISTRY = 0xFFFF

// Cells SwapEscrowV2's state holds beyond what STORAGE_CELLS_BASE models for
// SwapEscrowNosup: the supervisor's code and its cell. Calibrated in
// tests/v2/storage_floor.test.tolk (the generated copy of the nosup check):
// the model must stay between 1x and 1.5x of the measured fee. Year fee,
// measured / model: 1x1 17,150,010 / 22,346,983 (1.30x); 1,000 entries
// 146,814,478 / 152,011,451 (1.035x), so the code can grow by about 80 cells.
const SUP_STORAGE_CELLS = 90

// sup:end

// Error codes. The numeric values are part of the wire contract — integrators
// match on them — so they are pinned by tests and must not be renumbered.
enum Errors {
    NotOwner1 = 401
    NotOwner2 = 402
    NotOwners = 403
    // sup:begin
    NotSupervisor = 404
    // sup:end
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
    pendingWallets: uint16     // outstanding TEP-89 minter discoveries (0 for NFT-only deals)
    jettonsCount: uint16       // total number of jetton assets (both sides)
    receivedJettons1: uint16   // of those, how many side 1 has received (used by the cancel formulas)
    receivedJettons2: uint16
    assets: map<uint16, Asset>
    grams: Cell<GramState>     // ref: 8 coins fields don't fit in the root alongside 3 addresses
    // sup:begin
    sup: Cell<SupervisorState> // the 4th and last reference of the root cell
    // sup:end
    dist: Cell<DistState>      // batch distribution state
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}
