import "constants"

// ---------------------------------------------------------------- collection

struct RoyaltyParams {
    numerator: uint16
    denominator: uint16
    destination: address
}

struct CollectionContent {
    /// TEP-64 off-chain collection metadata cell: 0x01 + URL of collection.json
    collectionMetadata: cell
    /// Common prefix of item content, e.g. "https://vanity.example/api/nft/" — inline bytes in a
    /// single cell (≤ 126 bytes, no refs), so get_nft_content can emit the reference layout
    /// 0x01 || common || ^individual.
    commonContent: cell
}

/// Sale roles (inline in CollectionExt).
struct SaleConfig {
    /// Ops wallet: the only sender allowed to `admin_mint`.
    minter: address
    /// ed25519 key whose signature authorizes a `buy` voucher.
    signerPublicKey: uint256
    /// Receives the price of every `buy` (paid by the freshly deployed item, see ItemInit).
    treasury: address
}

/// An upgrade waiting for its timelock. Everything the authority approves is in this cell, and the
/// approval names its hash, so what was proposed is exactly what gets installed.
struct UpgradeProposal {
    /// Earliest unix time `approve_upgrade` is accepted (proposal time + the delay in force then).
    readyAt: uint32
    /// Upgrade authority after the approval (rotation is time-locked like everything else).
    authority: address
    /// Timelock after the approval.
    delay: uint32
    /// New collection code; null keeps the current code.
    code: cell?
    /// Parameters handed to the new code's `migrate` (only together with `code`).
    migration: cell?
    /// New item code holders may opt into; null keeps the published one.
    itemCode: cell?
}

/// Upgrade governance. The authority is a wallet the admin signs with (TON Connect), never a server
/// key: every proposal and every approval is a message it signs.
struct UpgradeState {
    authority: address
    /// Seconds between a proposal and the earliest approval (≤ MAX_UPGRADE_DELAY).
    delay: uint32
    /// Latest approved item code, installed into an item only when its holder asks (`upgrade_item`).
    /// Starts as the address code.
    itemCode: cell
    pending: Cell<UpgradeProposal>?
}

/// Roles and governance in one ref (the root holds four refs already).
struct CollectionExt {
    sale: SaleConfig
    upgrades: Cell<UpgradeState>
}

/// Layout invariants every future collection version keeps, so an upgrade can't move item addresses
/// and new code always knows which layout it reads:
///   - the data starts with `version:uint32` (the code version that last wrote the data);
///   - the first ref is the item address code (the code in every item's StateInit). It never changes.
struct CollectionStorage {
    version: uint32
    /// Admin: the only sender allowed to change roles, content, royalty, pause and withdraw.
    owner: address
    /// Blocks both `buy` and `admin_mint`.
    paused: bool
    /// Mint operations dispatched by the collection (a duplicate index is refunded by the item but
    /// still counted: the collection can't know an item exists).
    mintedCount: uint64
    /// Item address code: get_nft_address_by_index and every mint use it, whatever code items run later.
    itemCode: cell
    content: Cell<CollectionContent>
    royalty: Cell<RoyaltyParams>
    ext: Cell<CollectionExt>
}

fun CollectionStorage.load(): CollectionStorage {
    return CollectionStorage.fromCell(contract.getData());
}

fun CollectionStorage.save(self) {
    contract.setData(self.toCell());
}

// ---------------------------------------------------------------- pattern claim

/// Pattern text: len:uint6 followed by len ASCII bytes [A-Za-z0-9].
type PatternText = slice

fun PatternText.unpackFromSlice(mutate s: slice): PatternText {
    val len = s.loadUint(6);
    return s.loadBits(len * 8);
}

fun PatternText.packToBuilder(self, mutate b: builder) {
    b.storeUint(self.remainingBitsCount() / 8, 6);
    b.storeSlice(self);
}

/// What the item claims about its own address. Validated on-chain against the address itself,
/// so a claim can never be false. Stored on the item and returned as TEP-62 individual content;
/// the collection turns it into the metadata URL in get_nft_content.
struct PatternClaim {
    /// 0 = start, 1 = end, 2 = both
    mode: uint2
    caseSensitive: bool
    pattern: PatternText
}

/// Value of a base64url character, or -1 if it is not [A-Za-z0-9] ('-' and '_' are refused: they
/// look different in standard base64).
fun b64Value(c: int): int {
    if (c >= 65 && c <= 90) {
        return c - 65;
    }
    if (c >= 97 && c <= 122) {
        return c - 71;
    }
    if (c >= 48 && c <= 57) {
        return c + 4;
    }
    return -1;
}

/// 6-bit value of friendly-address char `position` (1-based, 4..45) taken from the account id.
fun sixBitsAt(accountId: uint256, position: int): int {
    val offset = 6 * position - 22;
    return (accountId >> (256 - offset - 6)) & 63;
}

fun charMatches(accountId: uint256, position: int, c: int, caseSensitive: bool): bool {
    val v = sixBitsAt(accountId, position);
    if (caseSensitive || c < 65) {
        return v == b64Value(c);
    }
    val upper = (c >= 97) ? c - 32 : c;
    return v == b64Value(upper) || v == b64Value(upper + 32);
}

/// True iff the claim is well-formed and really appears in the address.
fun PatternClaim.isTrueFor(self, accountId: uint256): bool {
    val bits = self.pattern.remainingBitsCount();
    if (bits % 8 != 0) {
        return false;
    }
    val len = bits / 8;
    if (len < 1 || len > MAX_PATTERN_LENGTH || self.mode > 2) {
        return false;
    }
    if (self.mode == 2 && len * 2 > MAX_PATTERN_LENGTH) {
        return false;
    }
    var s = self.pattern;
    var i = 0;
    while (i < len) {
        val c = s.loadUint(8);
        if (b64Value(c) < 0) {
            return false;
        }
        if (self.mode != 1 && !charMatches(accountId, WINDOW_FIRST + i, c, self.caseSensitive)) {
            return false;
        }
        if (self.mode != 0 && !charMatches(accountId, WINDOW_LAST + 1 - len + i, c, self.caseSensitive)) {
            return false;
        }
        i += 1;
    }
    return true;
}

// ---------------------------------------------------------------- item

/// Item data at deployment: exactly 523 bits, no refs. The order (collection first) is part of the
/// mining protocol: the 27-bit inner nonce lands in the second SHA-256 block of the cell repr.
struct ItemInitData {
    collection: address
    index: uint256
}

/// Code hash the holder asked to install (`upgrade_item`); the collection's reply must match it.
struct ItemUpgradeRequest {
    codeHash: uint256
}

/// Initialized item. `collection` and `index` stay first (they are the deployment data); `version`
/// is the item code version that last wrote the data, so later code knows which layout it reads.
struct ItemStorage {
    collection: address
    index: uint256
    version: uint16
    owner: address
    forwarding: bool
    claim: Cell<PatternClaim>
    upgradeRequest: Cell<ItemUpgradeRequest>?
}

struct ItemStorageLoader {
    collection: address
    index: uint256
    private rest: RemainingBitsAndRefs
}

fun ItemStorage.startLoading(): ItemStorageLoader {
    return ItemStorageLoader.fromCell(contract.getData());
}

fun ItemStorageLoader.isInitialized(self): bool {
    return !self.rest.isEmpty();
}

fun ItemStorageLoader.endLoading(mutate self): ItemStorage {
    return {
        collection: self.collection,
        index: self.index,
        version: self.rest.loadAny(),
        owner: self.rest.loadAny(),
        forwarding: self.rest.loadAny(),
        claim: self.rest.loadAny(),
        upgradeRequest: self.rest.loadAny(),
    };
}

fun ItemStorage.save(self) {
    contract.setData(self.toCell());
}

/// Top 8 bits of the index are the item's fixed address prefix.
fun indexPrefix(index: uint256): int {
    return index >> 248;
}

/// StateInit + shard options of an item. The address is prefix(8) || hash(StateInit)[8..256).
fun calcItemAddress(collection: address, index: uint256, itemCode: cell): AutoDeployAddress {
    val data: ItemInitData = { collection, index };
    return {
        workchain: BASECHAIN,
        stateInit: { code: itemCode, data: data.toCell() },
        toShard: {
            fixedPrefixLength: FIXED_PREFIX_LENGTH,
            closeTo: address.fromWorkchainAndHash(BASECHAIN, indexPrefix(index) << 248),
        },
    };
}

// ---------------------------------------------------------------- getter replies

struct CollectionDataReply {
    nextItemIndex: int
    collectionMetadata: cell
    owner: address
}

struct SaleConfigReply {
    minter: address
    signerPublicKey: uint256
    treasury: address
    paused: bool
}

struct BuyParamsReply {
    itemInitValue: coins
    mintGasAllowance: coins
    treasuryFeeAllowance: coins
    itemCodeHash: uint256
}

struct CollectionVersionReply {
    /// Version of the code that last wrote the data.
    version: uint32
    /// Version compiled into the running code.
    codeVersion: uint32
    /// Hash of the running code.
    codeHash: uint256
}

struct UpgradeStateReply {
    authority: address
    delay: uint32
    /// Code in every item's StateInit (never changes).
    addressCodeHash: uint256
    /// Latest approved item code (what `upgrade_item` installs).
    itemCodeHash: uint256
    /// The pending UpgradeProposal cell, or null.
    pending: Cell<UpgradeProposal>?
}

struct ItemUpgradeStatusReply {
    /// Item code version that last wrote the data.
    version: uint16
    /// Hash of the code the item runs now.
    codeHash: uint256
    /// Code hash the holder asked for that hasn't been installed yet (0 = none).
    requestedCodeHash: uint256
}

struct NftDataReply {
    isInitialized: bool
    index: int
    collection: address
    owner: address? = null
    content: cell? = null
}

struct MirrorDataReply {
    owner: address?
    forwarding: bool
    reserve: coins
    version: int
}
