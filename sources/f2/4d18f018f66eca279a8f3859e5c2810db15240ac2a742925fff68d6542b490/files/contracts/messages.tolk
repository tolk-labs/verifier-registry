// TEP-62 wire layout. The one-bit zero forward payload is Either Left, empty slice.
struct (0x5fcc3d14) NftTransfer {
    queryId: uint64
    newOwner: address
    responseDestination: address?
    customPayload: cell?
    forwardAmount: coins
    forwardPayload: RemainingBitsAndRefs
}

struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    previousOwner: address
    forwardPayload: RemainingBitsAndRefs
}

struct (0xd53276db) NftExcesses {
    queryId: uint64
}

struct (0x474d0001) Buy {
    queryId: uint64
    expectedPrice: coins
    recipient: address
}

struct (0x474d0002) ChangePrice {
    price: coins
}

struct (0x474d0003) CancelSale {
    queryId: uint64
    feeRecipient: address
}

type SaleMessage = OwnershipAssigned | Buy | ChangePrice | CancelSale

fun emptyForwardPayload(): RemainingBitsAndRefs {
    return beginCell().storeBool(false).toSlice();
}
