import "types"

// ================================================================ collection, public

/// What the sale backend signs to authorize one `buy`. The signer signs the representation hash of
/// this exact cell (the claim ref's hash is part of it). The prefix equals the `buy` opcode, so a
/// voucher can't be confused with any other signed payload.
struct (0x5ab5915e) Voucher {
    /// The collection the voucher is valid for (replay on another deployment is refused).
    collection: address
    index: uint256
    /// The item goes to this owner; changing it invalidates the signature.
    owner: address
    /// Forwarded to the treasury by the freshly deployed item.
    price: coins
    /// Unix time; the voucher is refused when now() > validUntil.
    validUntil: uint32
    /// What the address shows; must really appear in it (checked against the computed address).
    claim: Cell<PatternClaim>
}

/// Anyone may send it with a voucher signed by `signerPublicKey`: one transaction pays and mints.
struct (0x5ab5915e) Buy {
    queryId: uint64
    signature: bits512
    voucher: Cell<Voucher>
}

/// Ops wallet only (`minter`): mints without payment (e.g. orders paid in Telegram Stars).
struct (0x61cdb98a) AdminMint {
    queryId: uint64
    index: uint256
    owner: address
    responseDestination: address
    claim: Cell<PatternClaim>
}

/// TEP-66
struct (0x693d3950) RequestRoyaltyParams {
    queryId: uint64
}

struct (0xa8cb00ad) ResponseRoyaltyParams {
    queryId: uint64
    royaltyParams: RoyaltyParams
}

// ================================================================ collection, admin

struct (0x636f776e) ChangeOwner {
    queryId: uint64
    newOwner: address
}

struct (0x3db5d4d1) SetMinter {
    queryId: uint64
    minter: address
}

struct (0x774325f3) SetSigner {
    queryId: uint64
    signerPublicKey: uint256
}

struct (0x728a371b) SetTreasury {
    queryId: uint64
    treasury: address
}

struct (0x73636e74) SetContent {
    queryId: uint64
    content: Cell<CollectionContent>
}

struct (0x73726f79) SetRoyalty {
    queryId: uint64
    royalty: Cell<RoyaltyParams>
}

struct (0x70617573) SetPaused {
    queryId: uint64
    paused: bool
}

/// amount = 0 withdraws everything above COLLECTION_RESERVE.
struct (0x77647277) Withdraw {
    queryId: uint64
    amount: coins
    destination: address
}

// ================================================================ collection, upgrades
// Opcodes are crc32 of the TL-B lines in schema.tlb (masked with 0x7fffffff), like the v2 messages.

/// Upgrade authority only. Replaces any pending proposal and starts its timelock (`delay` in force
/// now). At least one of: new code, new item code, a different authority or delay.
struct (0x472c384e) ProposeUpgrade {
    queryId: uint64
    authority: address
    delay: uint32
    code: cell?
    migration: cell?
    itemCode: cell?
}

/// Upgrade authority only, after the timelock. `proposalHash` = hash of the pending proposal cell
/// (get_upgrade_state), so the signer approves exactly what is pending.
struct (0x24dfe185) ApproveUpgrade {
    queryId: uint64
    proposalHash: uint256
}

/// Upgrade authority only.
struct (0x7723de44) CancelUpgrade {
    queryId: uint64
}

/// Sent by the collection to itself right after it installs new code, so the NEW code converts the
/// data (`fromVersion` = the old data version). Every collection version must handle it; the
/// remaining value goes back to the upgrade authority.
struct (0x1d69271d) Migrate {
    queryId: uint64
    fromVersion: uint32
    migration: cell?
}

/// Item → collection, on behalf of its holder: "send me the approved item code with this hash".
/// Accepted only from the item address of `index`.
struct (0x786f6cc0) RequestItemCode {
    queryId: uint64
    index: uint256
    codeHash: uint256
}

// ================================================================ upgrade events
// External log messages to ExtOutLogBucket { topic: UPGRADE_LOG_TOPIC }.

struct (0x710e6369) UpgradeProposed {
    queryId: uint64
    proposalHash: uint256
    readyAt: uint32
}

/// codeHash / itemCodeHash are 0 when that part stayed unchanged.
struct (0x21b15ac1) UpgradeApproved {
    queryId: uint64
    proposalHash: uint256
    codeHash: uint256
    itemCodeHash: uint256
}

struct (0x0548ac53) UpgradeCancelled {
    queryId: uint64
    proposalHash: uint256
}

struct (0x7d6e70e5) ItemCodeInstalled {
    queryId: uint64
    codeHash: uint256
}

// ================================================================ collection → item

/// Reply to RequestItemCode: the approved item code. The item installs it only if its holder asked
/// for exactly this hash.
struct (0x0d8c21ad) InstallItemCode {
    queryId: uint64
    code: cell
}

/// Sent by the collection together with the deployment. On the first init the item pays `mintPrice`
/// to `treasury` (buy) out of the value it received. A second init (duplicate index) is refunded
/// in full, price included, to `responseDestination` by the item; nothing reaches the treasury and
/// nothing bounces back into the collection.
struct (0x696e6974) ItemInit {
    queryId: uint64
    owner: address
    responseDestination: address
    treasury: address
    mintPrice: coins
    claim: Cell<PatternClaim>
}

// ================================================================ item, TEP-62

struct (0x2fcb26a2) RequestStaticData {
    queryId: uint64
}

struct (0x8b771735) ResponseStaticData {
    queryId: uint64
    index: uint256
    collection: address
}

struct (0b0) PayloadInline {
    value: RemainingBitsAndRefs
}

struct (0b1) PayloadInRef {
    value: Cell<RemainingBitsAndRefs>
}

struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    previousOwner: address
    @abi.clientType(PayloadInline | PayloadInRef)
    payload: RemainingBitsAndRefs
}

struct (0xd53276db) Excesses {
    queryId: uint64
}

struct (0x5fcc3d14) Transfer {
    queryId: uint64
    newOwner: address
    responseDestination: address?
    customPayload: cell?
    forwardAmount: coins
    @abi.clientType(PayloadInline | PayloadInRef)
    forwardPayload: RemainingBitsAndRefs
}

// ================================================================ item, mirror account

/// One node of the action list: send `message` (a serialized MessageRelaxed) with `mode`.
/// Layout: mode:uint8 ^MessageRelaxed next:(Maybe ^MirrorAction)
struct MirrorActionHead {
    mode: uint8
    message: cell
    next: cell?
}

/// Owner-only. Sends up to 254 messages from the item's address.
/// Only SENDRAWMSG is ever executed, so set_code / set_library are impossible; mode +32 is rejected.
struct (0x6d657865) MirrorExec {
    queryId: uint64
    actions: Cell<MirrorActionHead>
}

/// Owner-only. Replace the claim (e.g. after someone minted the item for you with a shorter one);
/// it is checked against the item's own address.
struct (0x73636c6d) SetClaim {
    queryId: uint64
    claim: Cell<PatternClaim>
}

/// Owner-only. Auto-forward incoming plain TON (minus reserve and fees) to the owner.
struct (0x66776472) SetForwarding {
    queryId: uint64
    enabled: bool
}

/// Owner-only. Opt-in upgrade of the holder's own account to the item code the collection publishes
/// (get_upgrade_state.itemCodeHash). The holder signs the exact code hash; nobody else, not even the
/// collection, can change an item's code. Must carry ITEM_UPGRADE_ALLOWANCE; the excess comes back.
struct (0x3b731a11) UpgradeItem {
    queryId: uint64
    codeHash: uint256
}

/// Sent by the item to itself right after it installs new code, so the NEW code converts the data.
/// Idempotent (the holder can send it via mirror_exec too); the remaining value goes to the holder.
struct (0x44761c75) MigrateItem {
    queryId: uint64
}

/// Jetton transfer notification (TEP-74). Accepted, never auto-forwarded.
struct (0x7362d09c) JettonTransferNotification {
    queryId: uint64
    amount: coins
    sender: address
    forwardPayload: RemainingBitsAndRefs
}

/// Text comment / plain transfer with comment.
struct (0x00000000) TextComment {
    text: RemainingBitsAndRefs
}
