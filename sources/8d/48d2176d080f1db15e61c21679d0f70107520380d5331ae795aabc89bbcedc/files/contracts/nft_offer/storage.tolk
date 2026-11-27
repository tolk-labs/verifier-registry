import "@stdlib/gas-payments"

// Price is the seller payout. Royalty is charged on top, and zero bps is allowed.
struct NftOfferRoyalty {
    recipient: address
    bps: uint16
    fineBps: uint16
}

struct NftOfferParties {
    buyer: address
    recipient: address
    seller: address
}

struct NftOfferConfig {
    nft: address
    price: coins
    salt: uint64
    expiresAt: uint32
    parties: Cell<NftOfferParties>
    royalty: Cell<NftOfferRoyalty>
}

enum NftOfferPhase: uint8 {
    Funding = 0
    Ready = 1
    Filled = 2
    Expired = 3
}

struct NftOfferStorage {
    config: Cell<NftOfferConfig>
    public: uint256
    phase: NftOfferPhase
}

fun NftOfferStorage.load(): NftOfferStorage {
    return NftOfferStorage.fromCell(contract.getData());
}

fun NftOfferStorage.save(self) {
    contract.setData(self.toCell());
}

// Budget rent through expiry separately from purchase collateral and cancellation gas.
// Include account metadata and margin for storage prices; phase changes do not grow data.
fun nftOfferStorageBudget(code: cell, data: cell, expiresAt: uint32): coins {
    val (cells, bits, _) = beginCell().storeRef(code).storeRef(data).endCell().calculateSizeStrict(1024);
    return 2 * calculateStorageFee(0, max(0, expiresAt - blockchain.now()), bits + 1024, cells + 4);
}
