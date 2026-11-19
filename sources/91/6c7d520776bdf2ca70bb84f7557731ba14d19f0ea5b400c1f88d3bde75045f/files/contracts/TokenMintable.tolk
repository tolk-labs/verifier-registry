import "creation"
import "token-admin"
import "token-core"
import "token-storage"

contract TokenMintable {
    version: "2.0"
    description: "Mintable token: its admin can make more, up to the maximum if one was set, lock minting until a date, pass the role, or close minting for ever. TEP-74 and TEP-89 compliant"
    storage: TokenStorage
    storageAtDeployment: Unstarted
    incomingMessages: AllowedMessageToMintableToken
}

fun onBouncedMessage(in: InMessageBounced) {
    restoreSupplyOfBouncedMint(in.bouncedBody);
}

fun onInternalMessage(in: InMessage) {
    handleMintableTokenMessage(in.senderAddress, in.valueCoins, in.originalForwardFee, in.body);
}

get fun get_jetton_data(): TokenDataReply {
    return tokenJettonData();
}

get fun get_wallet_address(ownerAddress: address): address {
    return tokenWalletAddress(ownerAddress);
}

get fun get_next_admin_address(): address? {
    val storage = loadTokenIfStarted();
    return storage == null ? null : storage.roles.load().nextAdminAddress;
}

get fun mintingLockedUntil(): int {
    val storage = loadTokenIfStarted();
    return storage == null ? 0 : storage.mintingLockedUntil;
}

get fun maxSupply(): int {
    val storage = loadTokenIfStarted();
    return storage == null ? 0 : storage.maxSupply;
}

get fun origin(): OriginReply {
    return tokenOrigin();
}

get fun tokenKind(): int {
    return tokenOrigin().kind;
}
