// This token was deployed using DappBuilder's no-code platform.
// Create your own smart contracts without coding: https://dappbuilder.org
import "creation"
import "token-core"
import "token-fixed"
import "token-storage"

contract TokenFixedFree {
    author: "DappBuilder.org"
    version: "2.0"
    description: "This token was deployed using DappBuilder's no-code platform. Create your own smart contracts without coding: https://dappbuilder.org"
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
    return TOKEN_KIND_FIXED_FREE;
}
