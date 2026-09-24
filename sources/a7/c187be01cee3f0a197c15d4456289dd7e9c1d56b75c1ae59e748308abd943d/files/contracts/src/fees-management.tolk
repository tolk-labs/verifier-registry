const MIN_GRAMS_FOR_STORAGE = grams("0.05")

/// Value forwarded to a newly deployed NFT item (pays for its deploy and storage).
const NFT_ITEM_VALUE = grams("0.05")

/// Upper bound for the collection's gas and forwarding fees spent on one mint.
/// When a fee spike leaves less than one forward fee for the refund, the refund is skipped
/// (SEND_MODE_IGNORE_ERRORS) and that dust stays on the collection, recoverable only by
/// Withdraw; a larger spike makes the item deploy fail and bounces the whole mint.
const MINT_GAS_RESERVE = grams("0.03")

/// Amount a minter must attach on top of the mint price; the unspent part is refunded.
const MINT_OVERHEAD = NFT_ITEM_VALUE + MINT_GAS_RESERVE

/// Balance the collection keeps after an admin withdrawal.
const MIN_COLLECTION_BALANCE = grams("0.1")
