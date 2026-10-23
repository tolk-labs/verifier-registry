import "../../lib/access/ownable_2step"
import "types"

struct Storage {
    id: uint32;
    ownable: Ownable2Step;
    allowedPriceUpdaters: map<address, ()>;

    maxFeeJuelsPerMsg: uint96;
    linkToken: address;
    tokenPriceStalenessThreshold: uint32;

    // NOTE: usdPerUnitGasByDestChain is on DestChainConfig instead (same as Solana)
    usdPerToken: map<address, TimestampedPrice>;
    // NOTE: use presence in this map to validate a token as feeToken
    premiumMultiplierWeiPerEth: map<address, uint64>;

    destChainConfigs: map<uint64, DestChainConfig>
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.store(self) {
    return contract.setData(self.toCell());
}
