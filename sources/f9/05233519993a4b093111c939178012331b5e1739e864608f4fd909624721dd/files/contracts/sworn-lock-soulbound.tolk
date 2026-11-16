tolk 1.5

import "common/lock-base"
import "common/lock-core"
import "common/sworn"

// Sworn lock of jettons, soulbound kind: a TEP-62 NFT item and TEP-85 SBT without an authority (nobody can
// revoke it) and without destroy. Lock indexes ending in binary 01.
//
// This file declares the contract: its entrypoints and its get methods. The lock itself is in
// common/lock-core.tolk, which the transferable kind shares (sworn-lock-transferable.tolk differs from this
// file only in its name, in the kind it passes to the handler and in the three get methods this one adds
// for TEP-85: get_answer_cost_with_payload, get_authority_address and get_revoked_time), and in
// common/lock-base.tolk, which the locks of GRAM share too.

contract SwornLockSoulbound {
    description: "Sworn lock of jettons, soulbound kind: a TEP-62 NFT and TEP-85 SBT that holds the locked jettons"
    version: "8"
    storage: LockStorage
    storageAtDeployment: LockInitData
    incomingMessages: LockMessage
    thrownErrors: LockErrors | JettonErrors
}

// Every internal message but a bounce. `true`: this contract is the soulbound kind.
fun onInternalMessage(in: InMessage) {
    try {
        handleLockMessage(
            {
                sender: in.senderAddress,
                value: in.valueCoins,
                fwdFee: in.originalForwardFee,
                body: in.body,
            },
            true,
        );
    } catch (code) {
        // The handler refused the message, for the reason `code` (refuse, in lock-base). A message that
        // asked to bounce bounces, with that code. Of one that did not, what is left of its value goes back
        // to its sender, unless it is a jetton wallet's notification, whose GRAM stays on the lock.
        // Whatever the handler did before it refused is undone (it runs in the try block).
        refuse(in.senderAddress, in.body, code);
    }
}

// A message of the lock's that bounced
fun onBouncedMessage(in: InMessageBounced) {
    handleLockBounce({
        sender: in.senderAddress,
        value: in.valueCoins,
        fwdFee: in.originalForwardFee,
        body: in.bouncedBody,
    });
}

// ============== Get methods ==============
// The same in both kinds of lock of jettons, but for the three a soulbound lock adds for TEP-85. One that
// reads the lock returns what lock-core computes, where it is described; the others return a cost or the
// version of sworn.tolk, or the cost of an answer (answerCost, in lock-base), as it stands, and the two
// TEP-85 asks of a lock that has no authority and is never revoked answer so. Where no lock was created
// each answers for the empty address, and every cost is 0 (lock-base).

// TEP-62: (init?, index, collection, owner, individual_content)
get fun get_nft_data(): (bool, int, address, address?, cell) {
    if (!isInitialized()) {
        return viewNftDataBeforeInit();
    }
    return viewNftData();
}

// The lock as it stands: its status, its parties, the schedule in force, its amounts and fee rates
get fun get_lock_data(): LockInfo {
    if (!isInitialized()) {
        return viewLockDataBeforeInit();
    }
    return viewLockData();
}

// What the lock holds and owes besides its schedule: its till, the fees attested, the deadline of the
// setup, why it was cancelled, a refund or fee tokens owed, and from when a sweep or a recovery may go
get fun get_custody_data(): CustodyInfo {
    if (!isInitialized()) {
        return viewCustodyDataBeforeInit();
    }
    return viewCustodyData();
}

// The immutable terms the lock's index commits to (an empty cell where no lock was created)
get fun get_lock_terms(): cell {
    if (!isInitialized()) {
        return beginCell().endCell();
    }
    return viewLockTerms();
}

// What the schedule in force has unlocked at time `t`, whatever was claimed
get fun get_unlocked_at(t: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewUnlockedAt(t);
}

// What a Claim can take now
get fun get_claimable(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewClaimable();
}

// GRAM a Claim with this forward amount and no forward payload must carry
get fun get_claim_cost(forwardTonAmount: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewClaimCost(forwardTonAmount);
}

// GRAM a Claim with this forward amount and this forward payload must carry
get fun get_claim_cost_with_payload(forwardTonAmount: int, forwardPayload: cell): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewClaimCostWithPayload(forwardTonAmount, forwardPayload);
}

// GRAM to attach, as its forward_ton_amount, to a top-up of this lock
get fun get_top_up_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewTopUpCost();
}

// GRAM a Sweep, which moves the lock's tokens, must carry
get fun get_sweep_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewSweepCost();
}

// GRAM a SweepGram must carry
get fun get_sweep_gram_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return lockSweepGramCost();
}

// What a SweepGram would pay now, on top of what is left of its own value (0 while the lock refuses one)
get fun get_sweep_gram_amount(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewSweepGramAmount();
}

// GRAM a ClaimForeign through a jetton wallet must carry. `walletWorkchain` is that wallet's: 0, or -1 for
// a wallet on the masterchain (one named on any other workchain is refused).
get fun get_claim_foreign_cost(walletWorkchain: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return claimForeignCost(walletWorkchain);
}

// GRAM a transfer of this lock's jetton needs on top of its forward_ton_amount
get fun get_jetton_transfer_value(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewJettonTransferValue();
}

// GRAM an ExtendLock to `end`, or one that makes the lock permanent, must carry
get fun get_extend_cost(permanent: bool, end: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewExtendCost(permanent, end);
}

// GRAM a CancelCreation must carry
get fun get_cancel_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewCancelCost();
}

// GRAM that covers a RetryRefund and a RetryFee alike. It is what a RetryFee must carry, whose transfer
// forwards the GRAM of the till's receipt; a RetryRefund is asked for less by that much, and what it does
// not use comes back with the excess.
get fun get_retry_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewRetryCost();
}

// GRAM a RecoverUnrecorded through a jetton wallet must carry. `walletWorkchain` is that wallet's: 0, or -1
// for a wallet on the masterchain (one named on any other workchain is refused). It counts the gas of
// restoring the refund record should the transfer bounce: the lock keeps that when the recovery is the
// refund it owes, and it comes back with the excess otherwise.
get fun get_recover_cost(walletWorkchain: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return recoverCost(walletWorkchain, true);
}

// GRAM a RetryFunding must carry
get fun get_retry_funding_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return retryFundingCost();
}

// GRAM a request must carry that the lock answers on the request's own value, with no payload: a
// GetStaticData or a RequestLockState (`workchain` is the asker's) and a ClaimForeignNft (the NFT's).
// `workchain`: 0, or -1 for the masterchain, whose prices are those of any chain but the basechain.
get fun get_answer_cost(workchain: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return answerCost(workchain, false, null);
}

// GRAM a ProveOwnership or a RequestOwner must carry (TEP-85): the lock answers on the request's own value,
// to `dest`, whose workchain is `workchain` (0, or -1 for the masterchain), passing `payload` on, with the
// lock's content when `withContent`. A get method of its own, since get methods take no nullable argument.
get fun get_answer_cost_with_payload(workchain: int, withContent: bool, payload: cell): int {
    if (!isInitialized()) {
        return 0;
    }
    return answerCost(workchain, withContent, payload);
}

// The version of the Sworn contracts this code is part of
get fun get_sworn_version(): int {
    return SWORN_VERSION;
}

// TEP-85: no authority
get fun get_authority_address(): any_address {
    return createAddressNone();
}

// TEP-85: never revoked
get fun get_revoked_time(): int {
    return 0;
}
