import "otc-constants"

// Cumulative pro-rata price: what the first `filled` units cost in total.
// Rounding up means the maker never receives less than the exact price, and
// the sum over all partial fills equals totalPrice exactly (telescoping).
fun cumulativePrice(filled: int, amountTotal: int, totalPrice: int): int {
    return mulDivCeil(filled, totalPrice, amountTotal);
}

fun fillCost(amount: int, amountLeft: int, amountTotal: int, totalPrice: int): int {
    val filledBefore = amountTotal - amountLeft;
    val filledAfter = filledBefore + amount;
    return cumulativePrice(filledAfter, amountTotal, totalPrice) -
        cumulativePrice(filledBefore, amountTotal, totalPrice);
}

fun takerFeeOf(cost: int): int {
    return mulDivCeil(cost, TAKER_FEE_BPS, BPS_DENOMINATOR);
}

fun makerFeeOf(cost: int): int {
    return mulDivCeil(cost, MAKER_FEE_BPS, BPS_DENOMINATOR);
}

fun makeQueryId(kind: int, queryId: int): int {
    // keep the caller's low 56 bits for tracing, tag the top byte
    return (kind << 56) | (queryId & 0xFFFFFFFFFFFFFF);
}

fun queryKind(queryId: int): int {
    return queryId >> 56;
}
