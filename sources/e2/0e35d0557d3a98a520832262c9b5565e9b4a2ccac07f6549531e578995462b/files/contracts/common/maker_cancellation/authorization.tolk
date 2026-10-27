import "@contracts/common/offer/constants"
import "@contracts/common/offer/wallets"
import "constants"

type MakerCancellationKeys = map<address, uint256>

struct MakerCancellationPolicy {
    networkGlobalId: int32
    appDomainHash: uint256
    keys: MakerCancellationKeys = []
}

struct (0x4d43414e) MakerCancellationAuthorization {
    networkGlobalId: int32
    escrow: address
    offerId: uint128
    validUntil: uint64
}

struct TonConnectMakerCancellation {
    magic: uint32
    schemaHash: uint32
    timestamp: uint64
    userAddress: address
    appDomain: cell
    payload: Cell<MakerCancellationAuthorization>
}

struct (0x58434e43) RelayMakerCancellation {
    signature: bits512
    signed: Cell<TonConnectMakerCancellation>
}

fun MakerCancellationPolicy.isValidFor(
    self,
    makerWallets: OfferWallets,
): bool {
    if (self.keys.isEmpty()) {
        return false;
    }
    if (
        self.appDomainHash == 0 ||
        (self.networkGlobalId != TON_MAINNET_GLOBAL_ID &&
            self.networkGlobalId != TON_TESTNET_GLOBAL_ID)
    ) {
        return false;
    }

    var count = 0;
    var entry = self.keys.findFirst();
    while (entry.isFound) {
        count += 1;
        if (
            count > MAX_OFFER_ESCROW_WALLETS || entry.loadValue() == 0 ||
            !makerWallets.exists(entry.getKey())
        ) {
            return false;
        }
        entry = self.keys.iterateNext(entry);
    }
    return true;
}

@inline
fun MakerCancellationPolicy.accepts(
    self,
    signature: bits512,
    signedCell: Cell<TonConnectMakerCancellation>,
    offerId: uint128,
): bool {
    val signed = lazy signedCell.load();
    val now = blockchain.now();
    if (
        signed.magic != TON_CONNECT_SIGNED_CELL_MAGIC ||
        signed.schemaHash != MAKER_CANCELLATION_SCHEMA_HASH ||
        signed.timestamp > now + MAKER_CANCELLATION_CLOCK_SKEW ||
        now >= signed.timestamp + MAKER_CANCELLATION_TTL ||
        signed.appDomain.hash() != self.appDomainHash
    ) {
        return false;
    }

    val publicKey = self.keys.get(signed.userAddress);
    if (!publicKey.isFound) {
        return false;
    }

    val payload = lazy signed.payload.load();
    if (
        payload.networkGlobalId != self.networkGlobalId ||
        payload.escrow != contract.getAddress() ||
        payload.offerId != offerId ||
        payload.validUntil <
        signed.timestamp ||
        now >= payload.validUntil ||
        payload.validUntil > signed.timestamp + MAKER_CANCELLATION_TTL
    ) {
        return false;
    }

    return isSignatureValid(
        signedCell.hash(),
        signature as slice,
        publicKey.loadValue(),
    );
}
