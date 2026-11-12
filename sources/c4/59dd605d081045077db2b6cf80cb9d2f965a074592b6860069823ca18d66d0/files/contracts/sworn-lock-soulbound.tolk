tolk 1.5

import "common/lock-core"

// Sworn lock, soulbound kind: TEP-62 NFT + TEP-85 SBT without an authority (nobody can revoke
// it) and without destroy. Odd lock indexes.

fun onInternalMessage(in: InMessage) {
    handleLockMessage({
        sender: in.senderAddress,
        value: in.valueCoins,
        fwdFee: in.originalForwardFee,
        body: in.body
    }, true);
}

fun onBouncedMessage(in: InMessageBounced) {
    handleLockBounce({
        sender: in.senderAddress,
        value: in.valueCoins,
        fwdFee: in.originalForwardFee,
        body: in.bouncedBody
    });
}

// TEP-85: no authority
get fun get_authority_address(): any_address {
    return createAddressNone();
}

// TEP-85: never revoked
get fun get_revoked_time(): int {
    return 0;
}
