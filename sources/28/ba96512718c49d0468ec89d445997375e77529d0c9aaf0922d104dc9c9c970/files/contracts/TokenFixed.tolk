import "creation"
import "token-core"
import "token-fixed"
import "token-storage"

contract TokenFixed {
    version: "2.0"
    description: "Fixed supply token: all tokens exist from the start and no more can ever be made. TEP-74 and TEP-89 compliant"
    storage: TokenStorage
    storageAtDeployment: Unstarted
    incomingMessages: AllowedMessageToFixedToken
}

fun onBouncedMessage(in: InMessageBounced) {
    restoreSupplyOfBouncedMint(in.bouncedBody);
}

fun onInternalMessage(in: InMessage) {
    handleFixedTokenMessage(in.senderAddress, in.valueCoins, in.body);
}

get fun get_jetton_data(): TokenDataReply {
    return tokenJettonData();
}

get fun get_wallet_address(ownerAddress: address): address {
    return tokenWalletAddress(ownerAddress);
}

get fun origin(): OriginReply {
    return tokenOrigin();
}

get fun tokenKind(): int {
    return tokenOrigin().kind;
}
