tolk 1.5

import "common/gram-lock-core"
import "common/lock-base"
import "common/sworn"

// Sworn lock of GRAM, transferable kind: a TEP-62 NFT item. Whoever owns the NFT owns the lock: only its
// current owner claims. Lock indexes ending in binary 10.
//
// This file declares the contract: its entrypoints and its get methods. The lock itself is in
// common/gram-lock-core.tolk, which the soulbound kind shares (sworn-gram-lock-soulbound.tolk differs from
// this file only in its name, in the kind it passes to the handler and in the three get methods a soulbound
// lock adds for TEP-85: get_answer_cost_with_payload, get_authority_address and get_revoked_time), and in
// common/lock-base.tolk, which the locks of jettons share too.

contract SwornGramLockTransferable {
    description: "Sworn lock of GRAM, transferable kind: a TEP-62 NFT that holds the locked GRAM"
    version: "8"
    storage: GramLockStorage
    storageAtDeployment: LockInitData
    incomingMessages: GramLockMessage
    thrownErrors: LockErrors | GramErrors
}

// Every internal message but a bounce. `false`: this contract is the transferable kind.
fun onInternalMessage(in: InMessage) {
    try {
        handleGramLockMessage(
            {
                sender: in.senderAddress,
                value: in.valueCoins,
                fwdFee: in.originalForwardFee,
                body: in.body,
            },
            false,
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
    handleGramLockBounce({
        sender: in.senderAddress,
        value: in.valueCoins,
        fwdFee: in.originalForwardFee,
        body: in.bouncedBody,
    });
}

// ============== Get methods ==============
// The same in both kinds of lock of GRAM, but for the three a soulbound lock adds for TEP-85. One that
// reads the lock returns what gram-lock-core computes, where it is described; the others return a cost or
// the version of sworn.tolk, or the cost of an answer (answerCost, in lock-base), as it stands. Where no
// lock was created each answers for the empty address, and every cost is 0 (lock-base).

// TEP-62: (init?, index, collection, owner, individual_content)
get fun get_nft_data(): (bool, int, address, address?, cell) {
    if (!isInitialized()) {
        return viewNftDataBeforeInit();
    }
    return viewGramNftData();
}

// The lock as it stands: its status, its parties, the schedule in force, its amounts and fee rates
get fun get_lock_data(): LockInfo {
    if (!isInitialized()) {
        return viewLockDataBeforeInit();
    }
    return viewGramLockData();
}

// What the lock holds and owes besides its schedule: its till, the fees attested, the deadline of the setup
// and why it was cancelled (what speaks of tokens or of a jetton wallet is 0 in a lock of GRAM)
get fun get_custody_data(): CustodyInfo {
    if (!isInitialized()) {
        return viewCustodyDataBeforeInit();
    }
    return viewGramCustodyData();
}

// The immutable terms the lock's index commits to (an empty cell where no lock was created)
get fun get_lock_terms(): cell {
    if (!isInitialized()) {
        return beginCell().endCell();
    }
    return viewGramLockTerms();
}

// What the schedule in force has unlocked at time `t`, whatever was claimed
get fun get_unlocked_at(t: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewGramUnlockedAt(t);
}

// What a ClaimGram can take now
get fun get_claimable(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewGramClaimable();
}

// GRAM a ClaimGram without a comment must carry
get fun get_claim_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return gramClaimCost();
}

// GRAM a ClaimGram with this comment must carry
get fun get_claim_cost_with_comment(comment: cell): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewGramClaimCostWithComment(comment);
}

// GRAM a TopUpGram must carry on top of the GRAM it adds
get fun get_top_up_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewGramTopUpCost();
}

// GRAM a SweepGram must carry. (A lock of GRAM has no Sweep: that message moves tokens.)
get fun get_sweep_gram_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return gramLockSweepGramCost();
}

// What a SweepGram would pay now, on top of what is left of its own value (0 while no sweep is due)
get fun get_sweep_gram_amount(): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewGramSweepGramAmount();
}

// GRAM a ClaimForeign through a jetton wallet must carry. `walletWorkchain` is that wallet's: 0, or -1 for
// a wallet on the masterchain (one named on any other workchain is refused).
get fun get_claim_foreign_cost(walletWorkchain: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return claimForeignCost(walletWorkchain);
}

// GRAM an ExtendLock to `end`, or one that makes the lock permanent, must carry
get fun get_extend_cost(permanent: bool, end: int): int {
    if (!isInitialized()) {
        return 0;
    }
    return viewGramExtendCost(permanent, end);
}

// GRAM a CancelCreation must carry
get fun get_cancel_cost(): int {
    if (!isInitialized()) {
        return 0;
    }
    return gramCancelCost();
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

// The version of the Sworn contracts this code is part of
get fun get_sworn_version(): int {
    return SWORN_VERSION;
}
