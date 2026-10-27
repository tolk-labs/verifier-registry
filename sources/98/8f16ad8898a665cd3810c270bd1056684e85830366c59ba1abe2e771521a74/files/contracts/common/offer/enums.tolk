// Единственная денежная leg фиксируется в StateInit: нативный TON либо pinned Tether USDT.
enum PaymentAsset: uint8 {
    Ton = 0
    Usdt = 1
}

enum OfferSide: uint8 {
    Maker = 0
    Taker = 1
}
