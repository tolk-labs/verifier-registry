import "errors"

struct SaleRoyalty {
    recipient: address
    bps: uint16
}

// Immutable fields determine the sale address. Never store a caller-supplied sale address.
struct SaleConfig {
    seller: address
    nft: address
    initialPrice: coins
    salt: uint64
    royalty: Cell<SaleRoyalty>
}

struct SaleStorage {
    config: Cell<SaleConfig>
    price: coins
    phase: SalePhase
}

fun SaleStorage.initial(config: Cell<SaleConfig>): SaleStorage {
    val saleConfig = lazy config.load();
    return {
        config,
        price: saleConfig.initialPrice,
        phase: SalePhase.Waiting,
    };
}

// The seller receives price in full; royalty is funded on top.
fun saleTotal(price: coins, bps: uint16): coins {
    return price + price * bps / 10000;
}

fun SaleStorage.load(): SaleStorage {
    return SaleStorage.fromCell(contract.getData());
}

fun SaleStorage.save(self) {
    contract.setData(self.toCell());
}
