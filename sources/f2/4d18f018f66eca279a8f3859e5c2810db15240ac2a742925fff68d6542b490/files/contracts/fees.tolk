/// Value of the NFT transfer from the sale to the new owner.
const NFT_TRANSFER_AMOUNT = grams("0.0028")

/// Minimum value that the buyer adds to the full price. It pays for the NFT transfer and the fees.
const MIN_BUY_EXTRA_AMOUNT = grams("0.0048")

/// Number of basis points in 100%.
const BPS_DENOMINATOR = 10000

/// Returns the fee for `price` at `feeBps` basis points. The result is rounded down.
@inline
fun calcFee(price: coins, feeBps: uint16): coins {
    return price * feeBps / BPS_DENOMINATOR;
}
