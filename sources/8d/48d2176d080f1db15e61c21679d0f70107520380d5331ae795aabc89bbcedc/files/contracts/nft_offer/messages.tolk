import "@contracts/messages"

struct (0x474d0200) CancelNftOffer {
    sign: bits512?
}

struct (0x69cc5721) CancelByBuyer {}

type NftOfferMessage = OwnershipAssigned | CancelByBuyer
