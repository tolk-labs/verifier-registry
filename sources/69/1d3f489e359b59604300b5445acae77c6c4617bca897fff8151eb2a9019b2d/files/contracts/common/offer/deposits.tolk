import "@contracts/common/nft/deliveries"
import "@contracts/common/usdt/deposits"
import "terms"
import "wallets"

// Deposit ledgers share one root ref, leaving room for terms, NFT deposits
// and execution even when all four dictionaries are populated.
struct OfferEscrowDeposits {
    // Адрес фактического плательщика одновременно означает, что комиссия внесена.
    makerFeePayer: address? = null
    maker: PaymentDeposits = { total: 0, contributions: [] }
    nftDeliveries: NftDeliveries = []
    usdt: UsdtDeposits = {}
}

fun Cell<OfferEscrowDeposits>.addMakerTonDeposit(mutate self, source: address, amount: coins) {
    var escrowDeposits = self.load();
    escrowDeposits.maker.total += amount;
    escrowDeposits.maker.contributions.add(source, amount);
    self = escrowDeposits.toCell();
}

fun Cell<OfferEscrowDeposits>.setUsdtDeposits(mutate self, usdtDeposits: UsdtDeposits) {
    var escrowDeposits = self.load();
    escrowDeposits.usdt = usdtDeposits;
    self = escrowDeposits.toCell();
}

fun Cell<OfferEscrowDeposits>.applyMakerUsdtDeposits(mutate self, usdtDeposits: UsdtDeposits) {
    var escrowDeposits = self.load();
    escrowDeposits.usdt = usdtDeposits;
    escrowDeposits.maker.total = usdtDeposits.principal + usdtDeposits.fee;
    self = escrowDeposits.toCell();
}
