// Shared constants. Mirrors packages/vanity-core (FIXED_PREFIX_LENGTH, NONCE_BITS).

/// StateInit.fixed_prefix_length of every item (current network maximum, config param 43).
const FIXED_PREFIX_LENGTH = 8

/// Index layout v2: index = prefix:uint8 || nonce:uint248, nonce = outer:221 || inner:27.
const NONCE_BITS = 248
const INNER_NONCE_BITS = 27

/// TON kept on every item forever: storage rent buffer that even `mirror_exec` with mode 128 can't spend.
const STORAGE_RESERVE = ton("0.05")

/// Initial balance the collection gives a freshly minted item (becomes its storage reserve).
const ITEM_INIT_VALUE = ton("0.05")

/// Extra value attached to the item for paying the treasury message fee when the price is non-zero.
const TREASURY_FEE_ALLOWANCE = ton("0.01")

/// Minimum value a buy / admin_mint must carry on top of price + item value: collection gas and
/// forward fees (signature check, voucher parsing, claim check, deployment, excess).
const MINT_GAS_ALLOWANCE = ton("0.03")

/// The collection never lets its own balance drop below this on withdraw.
const COLLECTION_RESERVE = ton("0.05")

/// Gas + forward fees the item needs to process `transfer` with notifications.
const TRANSFER_GAS_ALLOWANCE = ton("0.01")

/// TVM allows 255 output actions; one is the storage reserve.
const MAX_MIRROR_ACTIONS = 254

/// Bumped on every change of the item contract; reported by get_mirror_data and stored in the
/// item's data (its layout version). 1 = the non-upgradeable item of collection v2.
const MIRROR_VERSION = 2

/// Version of the collection code; stored as the first field of its data (layout version).
/// 2 = the non-upgradeable collection, 3 = the first upgradeable one.
const COLLECTION_VERSION = 3

/// Longest upgrade timelock the authority may set (30 days): a typo can't freeze upgrades forever.
const MAX_UPGRADE_DELAY = 2592000

/// Value an `upgrade_item` must carry: item → collection → item → item (migrate) hops, the code
/// cell travelling once, and the excess back to the holder.
const ITEM_UPGRADE_ALLOWANCE = ton("0.05")

/// Topic of the external log messages (ExtOutLogBucket) every upgrade event is emitted to.
const UPGRADE_LOG_TOPIC = 0x7570677261646573 // "upgrades"

/// Config param 43 (SizeLimitsConfig) offset of max_acc_fixed_prefix_length for constructors #02/#03:
/// tag(8) + 3×uint32 + uint16 + uint32 + uint16 + 5×uint32 = 328 bits.
const CONFIG43_FIXED_PREFIX_OFFSET = 328

/// Controllable window of a 48-char friendly address (1-based, inclusive): chars 4..45.
const WINDOW_FIRST = 4
const WINDOW_LAST = 45
const MAX_PATTERN_LENGTH = 42

/// NFT protocol messages counterparties trust when they come from an NFT item's address.
/// mirror_exec refuses to send them, so the holder can't impersonate the item's own code.
const OP_OWNERSHIP_ASSIGNED = 0x05138d91
const OP_REPORT_STATIC_DATA = 0x8b771735

/// Opcode of RequestItemCode (messages.tolk), matched in the item's bounce handler.
const OP_REQUEST_ITEM_CODE = 0x786f6cc0

/// Known SizeLimitsConfig constructors that carry max_acc_fixed_prefix_length at bit 328.
const CONFIG43_TAG_V2 = 2
const CONFIG43_TAG_V3 = 3
