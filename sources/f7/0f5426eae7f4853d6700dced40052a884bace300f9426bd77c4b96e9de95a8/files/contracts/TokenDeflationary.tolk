import "creation"
import "fee-rules"
import "fee-token"
import "fee-token-storage"
import "token-storage"

contract TokenDeflationary {
    version: "2.0"
    description: "Deflationary token: a part of every transfer is burned and, when the token has taxes, up to three go to their addresses. The rates are fixed for ever and no more tokens can be made; its admin can exclude an address from the fees, lock that until a date, pass the role or give it up. TEP-74 and TEP-89 compliant"
    storage: FeeTokenStorage
    storageAtDeployment: Unstarted
    incomingMessages: AllowedMessageToFeeToken
}

fun onBouncedMessage(in: InMessageBounced) {
    restoreSupplyOfBouncedFeeMint(in.bouncedBody);
}

fun onInternalMessage(in: InMessage) {
    handleFeeTokenMessage(in.senderAddress, in.valueCoins, in.body);
}

get fun get_jetton_data(): TokenDataReply {
    return feeTokenJettonData();
}

get fun get_wallet_address(ownerAddress: address): address {
    return feeWalletOf(ownerAddress, loadStartedFeeToken().rules).calculateAddress();
}

get fun get_next_admin_address(): address? {
    val storage = loadFeeTokenIfStarted();
    return storage == null ? null : storage.roles.load().nextAdminAddress;
}

get fun feeRules(): FeeRulesReply {
    return feeRulesReply();
}

get fun isExcludedForGood(account: address): bool {
    val storage = loadFeeTokenIfStarted();
    return storage != null && storage.rules.load().isExcludedForGood(account);
}

get fun firstSupply(): coins {
    val storage = loadFeeTokenIfStarted();
    return storage == null ? 0 : storage.firstSupply;
}

get fun exclusionsLockedUntil(): int {
    val storage = loadFeeTokenIfStarted();
    return storage == null ? 0 : storage.exclusionsLockedUntil;
}

get fun origin(): OriginReply {
    return feeTokenOrigin();
}

get fun tokenKind(): int {
    return feeTokenOrigin().kind;
}
