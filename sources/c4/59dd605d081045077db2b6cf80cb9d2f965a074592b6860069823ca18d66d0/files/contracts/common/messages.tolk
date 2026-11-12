tolk 1.5

// Messages shared by the Sworn root, tills and lock items.
// Standard opcodes come from TEP-74 (jettons), TEP-62 (NFT) and TEP-85 (SBT). New Sworn opcodes are
// crc32("sworn::<name>"). Of a jetton Sworn uses only what TEP-74 describes: transfer,
// transfer_notification and excesses (and off chain the getters), so every jetton following it locks.

// ============== TEP-74 ==============

const OP_JETTON_TRANSFER = 0x0f8a7ea5;
const OP_TRANSFER_NOTIFICATION = 0x7362d09c;
const OP_NFT_TRANSFER = 0x5fcc3d14;
const OP_OWNERSHIP_PROOF = 0x0524c7ae;
const OP_OWNER_INFO = 0x0dd607e3;

struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    amount: coins
    destination: address
    responseDestination: address?
    customPayload: cell?
    forwardTonAmount: coins
    forwardPayload: RemainingBitsAndRefs
}

// sender is a MsgAddress in TEP-74, in any of its forms. TVM's LDMSGADDR refuses addr_var and anycast
// (exit 9), so it is read by hand: an internal address of 256 bits names an account, nothing else does
type NotificationSender = address?

fun NotificationSender.packToBuilder(self, mutate b: builder): void {
    b.storeAddressOpt(self);
}

fun NotificationSender.unpackFromSlice(mutate s: slice): NotificationSender {
    if (s.remainingBitsCount() >= 3 && s.preloadUint(3) == 0b100) {
        return s.loadAddress();     // addr_std without anycast: every wallet in practice
    }
    val form = s.loadUint(2);
    if (form == 0) {
        return null;
    }
    if (form == 1) {
        val length = s.loadUint(9);
        s.skipBits(length);
        return null;
    }
    var depth = 0;
    var prefix = 0;
    if (s.loadBool()) {
        depth = s.loadUint(5);
        prefix = s.loadUint(depth);
    }
    var length = 256;
    var workchain = 0;
    if (form == 2) {
        workchain = s.loadInt(8);
    } else {
        length = s.loadUint(9);
        workchain = s.loadInt(32);
    }
    if (length != 256 || workchain < -128 || workchain > 127) {
        s.skipBits(length);
        return null;
    }
    var hash = s.loadUint(256);
    if (depth > 0) {
        hash = (hash & ((1 << (256 - depth)) - 1)) | (prefix << (256 - depth));
    }
    return address.fromWorkchainAndHash(workchain, hash);
}

struct (0x7362d09c) TransferNotification {
    queryId: uint64
    amount: coins
    sender: NotificationSender
    forwardPayload: RemainingBitsAndRefs
}

struct (0xd53276db) Excesses {
    queryId: uint64
}

// ============== TEP-62 / TEP-85 ==============

struct (0x5fcc3d14) NftTransfer {
    queryId: uint64
    newOwner: address
    responseDestination: address?
    customPayload: cell?
    forwardAmount: coins
    forwardPayload: RemainingBitsAndRefs
}

struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    prevOwner: address
    forwardPayload: RemainingBitsAndRefs
}

struct (0x2fcb26a2) GetStaticData {
    queryId: uint64
}

struct (0x8b771735) ReportStaticData {
    queryId: uint64
    index: uint256
    collection: address
}

struct (0x04ded148) ProveOwnership {
    queryId: uint64
    dest: address
    forwardPayload: cell
    withContent: bool
}

struct (0x0524c7ae) OwnershipProof {
    queryId: uint64
    itemId: uint256
    owner: address
    data: cell
    revokedAt: uint64
    content: cell?
}

struct (0xd0c3bfea) RequestOwner {
    queryId: uint64
    dest: address
    forwardPayload: cell
    withContent: bool
}

struct (0x0dd607e3) OwnerInfo {
    queryId: uint64
    itemId: uint256
    initiator: address
    owner: address
    data: cell
    revokedAt: uint64
    content: cell?
}

struct (0xc18e86d2) OwnershipProofBounced {
    queryId: uint64
}

struct (0x1f04537a) Destroy {
    queryId: uint64
}

struct (0x6f89f5e3) Revoke {
    queryId: uint64
}

// TEP-66
struct (0x693d3950) GetRoyaltyParams {
    queryId: uint64
}

struct (0xa8cb00ad) ReportRoyaltyParams {
    queryId: uint64
    numerator: uint16
    denominator: uint16
    destination: address
}

// ============== Sworn: lock terms ==============

// Unlock schedule. A plain time lock is cliff == end. Times are unix seconds (uint48 keeps them
// valid far beyond 2106).
//   t < cliff            -> nothing unlocked
//   cliff <= t < end     -> initial + (total - initial) * elapsed / (end - cliff)
//                           elapsed = t - cliff, rounded down to a multiple of step when step > 0
//   t >= end             -> everything unlocked
struct Schedule {
    cliff: uint48
    end: uint48
    step: uint32
    initialBps: uint16
}

struct LockParties {
    owner: address
    creator: address             // funds the lock; refunds and the unused setup GRAM go back here
    salt: uint64                 // makes two otherwise identical requests distinct locks
}

// The immutable terms of a lock. Their hash is the lock's index (low bit replaced by `soulbound`),
// so the lock address commits to every field here: whoever deploys a lock cannot change them.
// The lock's jetton wallet is not here (its address depends on the lock's, see InitLock); the
// schedule and `permanent` can later only move in the owner's disfavour (Extend), the live values
// are in the lock's storage.
struct LockTerms {
    version: uint8               // SWORN_VERSION: terms of one version never hash to a lock of another
    soulbound: bool              // TEP-85 kind (odd index); transferable NFT otherwise (even index)
    permanent: bool              // never unlocks; schedule must be all zeros
    jettonMaster: address
    schedule: Schedule
    expectedAmount: coins        // what the creator sends; the lock holds what arrives
    maxFlatFee: coins            // the lock cancels instead of paying a higher fee than the creator saw
    maxFeeBps: uint16
    maxTopUpFlatFee: coins       // the top-up flat fee is fixed in the lock for its whole life
    createBefore: uint48         // InitLock must arrive by then (and at most MAX_CREATE_AHEAD earlier): a lock
                                 // deleted for storage debt decades later can never be initialized again
    parties: Cell<LockParties>
}

// ============== Sworn: user payloads (jetton forward_payload) ==============

// Forward payload of the funding transfer (in a ref). The lock funds on the first deposit from
// its creator through its wallet whatever the payload; on a funded lock this tag marks a
// duplicate creation, which goes back to its sender instead of becoming a gift.
struct (0x3671e1cc) FundTag {
}

// Jetton forward_payload of a top-up sent straight to a lock (fits inline). The lock's own fee
// rates apply (get_top_up_cost on the lock).
struct (0x60f47ca2) TopUpPayload {
}

// ============== Sworn: anyone -> lock ==============

// Deploys a lock (sent with the lock's StateInit). The terms must hash to the lock's index, and only
// the creator they name may send it: `jettonWallet` is not in the terms (the wallet address depends
// on the lock address), so it is the creator's word: the lock's jetton wallet as the master derives
// it (TEP-74 get_wallet_address). A contract cannot ask a master, so whoever relies on a lock
// compares this wallet with that getter (SPEC.md 3.5). `tillCode` is checked against the hash compiled
// into the lock and only used to derive the lock's till address.
struct (0x546a0af8) InitLock {
    queryId: uint64
    jettonWallet: address
    terms: Cell<LockTerms>
    tillCode: cell
}

// Anyone, with fresh value: ask the till again for the attestation the setup is still missing (a
// till deployed late); the caller's surplus comes back to the caller.
struct (0xcd0a471a) RetryFunding {
    queryId: uint64
}

// Anyone, with fresh value: pay the refund a cancelled lock still owes (its transfer bounced)
struct (0x5d48b0ca) RetryRefund {
    queryId: uint64
}

// Anyone, with fresh value: deliver the fee tokens the lock still owes its till (the transfer bounced)
struct (0xf29020e4) RetryFee {
    queryId: uint64
}

// Cancel a lock still being set up: its creator at any time, anyone else once SETUP_WINDOW has
// passed (the creation can no longer complete). Pending funding goes back to the creator, as does
// the setup GRAM.
struct (0x08184ea6) CancelCreation {
    queryId: uint64
}

// Cancelled lock: recover tokens from any wallet the lock holds (its own, or one the creator's word
// did not name) for the creator: funding that arrived before the lock existed, a refund the
// creator's own wallet refused, a refund still pending (the record shrinks accordingly).
// Anyone may send it with `destination` = the creator; only the creator may name another destination.
struct (0x8c1838a7) RecoverUnrecorded {
    queryId: uint64
    wallet: address
    amount: coins
    destination: address
}

struct (0x9a05091f) StorageTopUp {
    queryId: uint64
}

// Anyone: what the lock holds and how, answered to the sender (LockState, with the remaining value). TEP-62
// tells a contract nothing of an item but its index and collection; an offer for a transferable lock
// checks this once ownership_assigned has come, since until then its owner could claim, sweep, extend or
// make it permanent, then pays or sends the lock back. It pays only if the answer comes from the lock it
// was made for and says all of: funded, permanent or not as expected, the schedule the buyer saw (an
// extension can push the end decades out), at least the amount offered for still locked, and the jetton
// wallet the buyer verified (SPEC.md 3.3).
struct (0x33d9799d) RequestLockState {
    queryId: uint64
}

struct LockStateParties {
    owner: address
    jettonMaster: address
    jettonWallet: address       // the creator's word: compare it with the master's get_wallet_address (SPEC.md 3.5)
}

struct (0x069a4fab) LockState {
    queryId: uint64
    index: uint256
    status: uint8               // 0 awaiting setup, 2 funded, 3 cancelled
    permanent: bool
    schedule: Schedule
    totalAmount: coins          // locked by the schedule (0 unless funded)
    claimed: coins
    freeBalance: coins
    parties: Cell<LockStateParties>
}

// ============== Sworn: owner -> lock ==============

struct (0x0c7923d1) Claim {
    queryId: uint64
    amount: coins               // 0 = everything claimable
    destination: address
    responseDestination: address?
    forwardTonAmount: coins
    forwardPayload: cell?
}

// Never unlocks anything earlier (see lock contract for the exact rule)
struct (0x38e19ff6) ExtendLock {
    queryId: uint64
    makePermanent: bool
    schedule: Schedule
}

// Once a lock is funded and finished (fully unlocked), move whatever is in its jetton wallet.
// Recovers tokens a recipient wallet sent back (jetton wallets return them silently).
struct (0x233befc4) Sweep {
    queryId: uint64
    amount: coins
    destination: address
}

// Withdraw any other jetton that landed in the lock (never the wallet the lock holds its tokens in)
struct (0x6d85ebd6) ClaimForeign {
    queryId: uint64
    jettonWallet: address
    amount: coins
    destination: address
}

// Move an NFT that landed in the lock (never the lock itself): the owner of a funded lock, or for
// a cancelled lock its creator (anyone may send it with `newOwner` = the creator)
struct (0x47d3f729) ClaimForeignNft {
    queryId: uint64
    nft: address
    newOwner: address
}

// ============== Sworn: lock <-> till ==============

// Lock -> till: a request for the fee config. Read-only; answered with the remaining value.
struct (0x828e87d8) AttestTerms {
    queryId: uint64
}

// Till -> lock: the current config. The lock cancels if creation is disabled or a fee is above
// what its creator accepted, otherwise it fixes these rates for its whole life.
struct (0x411505ab) TermsAttested {
    queryId: uint64
    enabled: bool
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

// Forward payload of a fee transfer, lock -> till (in a ref). The till only emits an event.
struct (0xa519d87b) FeeTag {
    index: uint256
    master: address
    kind: uint8                 // FEE_KIND_*
}

// Lock -> till: the flat fee, as the value (it never travels through jetton code)
struct (0xe1b08320) FeeNotice {
    queryId: uint64
    index: uint256
    master: address
    kind: uint8
}

const FEE_KIND_FUNDING = 0;
const FEE_KIND_TOPUP = 1;
const FEE_KIND_RETRY = 2;       // fee tokens owed after a bounced fee transfer, delivered by RetryFee or Sweep

// ============== Sworn: root -> till ==============

struct (0x943bc4dd) SetTillConfig {
    queryId: uint64
    enabled: bool
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

// A till holds only fees: the root may move anything in any of its wallets
struct (0xd9866972) TillWithdrawJetton {
    queryId: uint64
    wallet: address
    amount: coins
    destination: address
}

struct (0xffebe1fa) TillWithdrawGrams {
    queryId: uint64
    amount: coins
    destination: address
}

// An NFT the till owns (only ever by someone's mistake: locks refuse their own till as owner)
struct (0xac04cbbf) TillWithdrawNft {
    queryId: uint64
    nft: address
    newOwner: address
}

// ============== Sworn: anyone / admin -> root ==============

// Anyone (the sender pays): deploy till n with the current config, or push the config to it again
struct (0xe3814f20) DeployTill {
    queryId: uint64
    n: uint8
}

struct (0x38b8a3b8) SetFees {
    queryId: uint64
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

struct (0x3ad19b14) SetRoyalty {
    queryId: uint64
    numerator: uint16
    denominator: uint16
    destination: address
}

// Takes effect CONTENT_DELAY later (wallets and indexers see the change coming)
struct (0x8f325db8) SetContent {
    queryId: uint64
    collectionContent: cell
    itemBaseUri: cell
}

struct (0xe10a5084) SetCreationEnabled {
    queryId: uint64
    enabled: bool
}

struct (0x7fe96236) WithdrawTillFees {
    queryId: uint64
    n: uint8
    wallet: address
    amount: coins
    destination: address
}

struct (0xf72d6265) WithdrawTillGrams {
    queryId: uint64
    n: uint8
    amount: coins
    destination: address
}

struct (0xfbc257a0) WithdrawGrams {
    queryId: uint64
    amount: coins
    destination: address
}

// Tokens and NFTs that reached the root or a till by mistake (nothing there is owed to anyone)
struct (0x1d84fda3) WithdrawRootJetton {
    queryId: uint64
    wallet: address
    amount: coins
    destination: address
}

// `nftInit`: the NFT's StateInit (it must hash to `nft`), so the root can tell a Sworn lock, which
// it never moves, from any other NFT
struct (0xa40f0c17) WithdrawRootNft {
    queryId: uint64
    nft: address
    newOwner: address
    nftInit: cell
}

struct (0xc38bdf90) WithdrawTillNft {
    queryId: uint64
    n: uint8
    nft: address
    newOwner: address
    nftInit: cell
}

struct (0xbb67d3ce) ProposeAdmin {
    queryId: uint64
    newAdmin: address?
}

struct (0x7e9b44ea) AcceptAdmin {
    queryId: uint64
}
