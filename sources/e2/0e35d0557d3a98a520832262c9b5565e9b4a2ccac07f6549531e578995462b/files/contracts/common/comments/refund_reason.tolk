enum RefundReason: uint8 {
    OfferCancelled = 0
    OfferExpired = 1
    OfferUnavailable = 2
    ExecutionExpired = 3
    AmountTooLow = 4
    InvalidAsset = 5
    ExecutionRejected = 6
    InvalidItem = 7
    InvalidPayment = 8
}

fun RefundReason.comment(self): slice {
    return match (self) {
        RefundReason.OfferCancelled => "@gettran: Refund (offer cancelled)".literalSlice(),
        RefundReason.OfferExpired => "@gettran: Refund (offer expired)".literalSlice(),
        RefundReason.OfferUnavailable => "@gettran: Refund (offer unavailable)".literalSlice(),
        RefundReason.ExecutionExpired => "@gettran: Refund (execution expired)".literalSlice(),
        RefundReason.AmountTooLow => "@gettran: Refund (amount too low)".literalSlice(),
        RefundReason.InvalidAsset => "@gettran: Refund (invalid asset)".literalSlice(),
        RefundReason.ExecutionRejected => "@gettran: Refund (execution rejected)".literalSlice(),
        RefundReason.InvalidItem => "@gettran: Refund (invalid item)".literalSlice(),
        RefundReason.InvalidPayment => "@gettran: Refund (invalid payment)".literalSlice(),
    };
}
