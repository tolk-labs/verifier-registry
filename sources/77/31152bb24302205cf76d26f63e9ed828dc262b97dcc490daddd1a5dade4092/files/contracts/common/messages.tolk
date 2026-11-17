tolk 1.5

// The layouts of the messages the Sworn root, tills and locks send and take, and the terms of a lock. Their
// handlers are in the contracts: sworn-root.tolk, sworn-till.tolk and, for the locks, lock-core.tolk
// (jettons), gram-lock-core.tolk (GRAM) and lock-base.tolk (both).
//
// Standard opcodes come from TEP-74 (jettons), TEP-62 (NFT), TEP-66 (royalty) and TEP-85 (SBT). Every
// opcode of Sworn's own is the crc32 checksum of "sworn::" followed by the name of its struct in
// snake_case: InitLock has crc32("sworn::init_lock"). Of a jetton Sworn uses only what TEP-74 describes:
// transfer, transfer_notification and excesses (and off chain its get methods), so every jetton that
// follows it can be locked.
//
// A lock holds either a jetton or GRAM: what differs for a lock of GRAM has a section of its own after the
// messages of a lock of jettons.

// ============== TEP-74 ==============

struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    amount: coins
    destination: address
    responseDestination: address?
    customPayload: cell?
    forwardTonAmount: coins // TEP-74's forward_ton_amount: GRAM the transfer forwards with its notification
    forwardPayload: RemainingBitsAndRefs
}

// The sender of a transfer_notification is a MsgAddress in TEP-74, in any of its forms. TVM's LDMSGADDR
// refuses addr_var and anycast (exit 9), so it is read by hand. Only an internal address of 256 bits, on a
// workchain that fits 8 bits, names an account (an anycast prefix rewrites its first bits).
type NotificationSender = address?

// Nothing Sworn sends writes a notification: the compiler takes a custom reading only with its writing,
// since the messages a contract declares it takes must be serializable both ways
fun NotificationSender.packToBuilder(self, mutate b: builder): void {
    b.storeAddressOpt(self);
}

fun NotificationSender.unpackFromSlice(mutate s: slice): NotificationSender {
    if (s.remainingBitsCount() >= 3 && s.preloadUint(3) == 0b100) {
        return s.loadAddress(); // addr_std without anycast: every wallet in practice
    }
    val form = s.loadUint(2);
    if (form == 0) {
        return null; // addr_none
    }
    if (form == 1) {
        // addr_extern: not an account
        val length = s.loadUint(9);
        s.skipBits(length);
        return null;
    }
    // addr_std (form 2) or addr_var (form 3), either with an optional anycast prefix
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
        // an addr_var of another length, or on a workchain an account's address cannot name
        s.skipBits(length);
        return null;
    }
    var hash = s.loadUint(256);
    if (depth > 0) {
        // the anycast prefix takes the place of the first `depth` bits of the address
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

// ============== TEP-66 ==============

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

// Unlock schedule. A plain time lock is cliff == end. Times are unix seconds (uint48 keeps them valid far
// beyond 2106), `step` is a number of seconds.
//   t < cliff            -> nothing unlocked
//   cliff <= t < end     -> initial + (total - initial) * elapsed / (end - cliff)
//                           initial = total * initialBps / 10000, unlocked at the cliff
//                           elapsed = t - cliff, rounded down to a multiple of step when step > 0
//   t >= end             -> everything unlocked
struct Schedule {
    cliff: uint48
    end: uint48
    step: uint32
    initialBps: uint16
}

// The accounts the terms name and the salt, in a cell of their own (LockTerms.parties)
struct LockParties {
    owner: address   // the lock's first owner: what the schedule unlocks is its owner's to claim
    creator: address // funds the lock; refunds and what is left of the budget go back here
    salt: uint64     // makes two otherwise identical requests distinct locks
}

// The immutable terms of a lock. Their hash is the lock's index (its two low bits replaced by the kind:
// `soulbound`, and whether it locks GRAM), so the lock address commits to every field here: whoever deploys
// a lock cannot change them. The lock's jetton wallet is not here (its address depends on the lock's, see
// InitLock). The schedule and `permanent` are those the lock starts with: its owner can later only extend
// the lock (ExtendLock), and the schedule in force is in the lock's storage.
struct LockTerms {
    version: uint8         // SWORN_VERSION: terms of one version never hash to a lock of another
    soulbound: bool        // TEP-85 kind (bit 0 of the index); transferable NFT otherwise
    permanent: bool        // never unlocks; schedule must be all zeros
    jettonMaster: address? // the jetton locked; none for a lock of GRAM (bit 1 of the index)
    schedule: Schedule
    // what the creator sends: a lock of jettons locks what arrives, a lock of GRAM this amount
    expectedAmount: coins
    maxFlatFee: coins      // the lock cancels instead of paying a higher fee than the creator saw
    maxTopUpFlatFee: coins // the top-up flat fee is fixed in the lock for its whole life
    maxFeeBps: uint16
    // InitLock or InitGramLock must arrive by then, and at most MAX_CREATE_AHEAD before it: a lock deleted
    // for storage debt decades later can never be created again
    createBefore: uint48
    parties: Cell<LockParties>
}

// ============== Sworn: user payloads (jetton forward_payload) ==============

// Forward payload of the funding transfer (in a ref). The lock funds on the first deposit from its creator
// through its wallet whatever the payload; on a funded lock this tag marks a duplicate creation, which goes
// back to its sender instead of becoming a gift.
struct (0xf1f0c746) FundTag {}

// Forward payload of a top-up sent straight to a lock (in a ref, as the funding's tag: some wallets drop an
// inline payload; a lock reads it either way). The lock's own fee rates apply (get_top_up_cost on the
// lock).
struct (0xc909ab22) TopUpTag {}

// ============== Sworn: the creator, or anyone -> lock ==============

// Creates a lock of jettons (sent with the lock's StateInit, which deploys its account). The terms must
// hash to the lock's index, and only the creator they name may send it. `jettonWallet` is not in the terms
// (the wallet's address depends on the lock's), so it is the creator's word for the lock's jetton wallet as
// the master derives it (TEP-74 get_wallet_address). A contract cannot ask a master, so whoever relies on a
// lock compares this wallet with what that get method answers (SPEC.md 3.5). `tillCode` is checked against
// the hash compiled into the lock and only used to derive the address of the lock's till.
struct (0x546a0af8) InitLock {
    queryId: uint64
    jettonWallet: address
    terms: Cell<LockTerms>
    tillCode: cell
}

// Anyone, with fresh value: ask the till again for the attestation the setup is still missing (a till
// deployed late); the caller's surplus comes back to the caller.
struct (0x7f819005) RetryFunding {
    queryId: uint64
}

// Anyone, with fresh value: pay the refund a cancelled lock still owes (its transfer bounced)
struct (0x6b948773) RetryRefund {
    queryId: uint64
}

// Anyone, with fresh value: deliver the fee tokens the lock still owes its till (the transfer bounced)
struct (0xe5e9e8f4) RetryFee {
    queryId: uint64
}

// Cancel a lock still being set up: its creator at any time, anyone else once SETUP_WINDOW has passed (the
// creation can no longer complete). Pending funding goes back to the creator, as does what is left of the
// budget.
struct (0x08184ea6) CancelCreation {
    queryId: uint64
}

// A cancelled lock of jettons: recover, for the creator, tokens from any jetton wallet that holds some for
// the lock (its own, or one the creator's word did not name): funding that arrived before the lock existed,
// a refund the creator's own wallet refused, a refund still pending (the record shrinks accordingly).
// Anyone may send it with `destination` = the creator; only the creator may name another destination.
struct (0x6d078204) RecoverUnrecorded {
    queryId: uint64
    wallet: address
    amount: coins
    destination: address
}

// Anyone: GRAM for the lock's storage. It stays on the lock, as GRAM sent with no body does. Unlike that,
// it has the lock save its state, which brings lastTx to now when no storage fee is left due: the quotes of
// a lock, and the get methods of a lock of GRAM, count the storage from then on.
struct (0x9a05091f) StorageTopUp {
    queryId: uint64
}

// Anyone: what the lock holds and how, answered to the sender (LockState, with the remaining value). TEP-62
// tells a contract nothing of an item but its index and collection; an offer for a transferable lock checks
// this once ownership_assigned has come, since until then its owner could claim, sweep, extend or make it
// permanent, then pays or sends the lock back. It pays only if the answer comes from the lock it was made
// for and says all of: funded, permanent or not as expected, the schedule the buyer saw (an extension can
// push the end decades out), at least the amount offered for still locked, and the jetton wallet the buyer
// verified (SPEC.md 3.3).
struct (0x33d9799d) RequestLockState {
    queryId: uint64
}

// jettonWallet is the creator's word: compare it with the master's get_wallet_address (SPEC.md 3.5). A lock
// of GRAM has neither a master nor a wallet: it holds what its account holds.
struct LockStateParties {
    owner: address
    jettonMaster: address?
    jettonWallet: address?
}

// The lock's answer to RequestLockState
struct (0x069a4fab) LockState {
    queryId: uint64
    index: uint256
    status: uint8      // 0 awaiting setup, 1 funded, 2 cancelled
    permanent: bool
    schedule: Schedule
    // locked by the schedule (0 unless funded); in a lock of GRAM what the schedule has paid out and what
    // the lock still holds for it
    totalAmount: coins
    claimed: coins
    freeBalance: coins // claimable at any time (always 0 in a lock of GRAM)
    parties: Cell<LockStateParties>
}

// ============== Sworn: owner -> lock ==============
// The last two also come from the creator of a cancelled lock, and from anyone on the creator's behalf

// The owner of a lock of jettons: pay `amount` of what is claimable (the free balance first, then what the
// schedule has unlocked) to `destination`, through the lock's jetton wallet. The transfer forwards
// `forwardTonAmount` GRAM and `forwardPayload` to the destination; its excess goes to
// `responseDestination`, or to the owner when that names no basechain account. The payload is bounded: more
// than 4096 cells, 2^20 bits or a depth of 256 is refused with PayloadTooLarge (payloadCarriage, in
// lock-base).
struct (0x0c7923d1) Claim {
    queryId: uint64
    amount: coins // 0 = everything claimable
    destination: address
    responseDestination: address?
    forwardTonAmount: coins
    forwardPayload: cell?
}

// The owner: a later schedule, or a permanent lock (`schedule` is then ignored). It never unlocks anything
// earlier than the schedule in force: the exact rule is Schedule.isValidExtension (sworn). The message
// brings the storage of the longer life (get_extend_cost on the lock).
struct (0x38e19ff6) ExtendLock {
    queryId: uint64
    makePermanent: bool
    schedule: Schedule
}

// The owner of a lock of jettons that is funded and finished (fully unlocked): move whatever is in its
// jetton wallet. `amount` is what is asked for, and the wallet's own balance bounds it. It also recovers
// tokens a recipient's wallet sent back (jetton wallets return them silently).
struct (0x233befc4) Sweep {
    queryId: uint64
    amount: coins
    destination: address
}

// Move another jetton that landed in the lock, through the wallet that holds it (never the wallet a lock of
// jettons holds its own tokens in): the owner of a funded lock. In a cancelled lock everything is the
// creator's, under one rule: the creator moves it to any destination, anyone else only to the creator. A
// lock of GRAM takes this message there. A lock of jettons refuses it there: RecoverUnrecorded moves the
// tokens of any of its wallets under that rule, and keeps its refund record as it does.
struct (0x6d85ebd6) ClaimForeign {
    queryId: uint64
    wallet: address
    amount: coins
    destination: address
}

// Move an NFT that landed in the lock (never the lock itself): the owner of a funded lock. Out of a
// cancelled lock, of either kind, its creator hands it to any account, and anyone else only to the creator.
struct (0x47d3f729) ClaimForeignNft {
    queryId: uint64
    nft: address
    newOwner: address
}

// ============== Sworn: a lock of GRAM ==============
// A lock of GRAM takes the messages above that do not go through the wallet a lock of jettons holds its
// tokens in: RetryFunding, CancelCreation, StorageTopUp, RequestLockState, ExtendLock, ClaimForeign (every
// jetton is foreign to it) and ClaimForeignNft, with those of TEP-62 and TEP-85. In place of InitLock and
// its funding transfer, of a top-up transfer, of Claim and of Sweep it takes the four below. The GRAM to
// lock travels in the first two themselves. The last, SweepGram, a lock of jettons takes too, for the GRAM
// it holds.

// Creates a lock of GRAM (sent with the lock's StateInit, which deploys its account) and brings what it
// locks: the message carries the GRAM to lock, the terms' expectedAmount, on top of its costs
// (get_gram_create_cost on the root). The terms name no jetton master and must hash to the lock's index;
// only the creator they name may send it. The lock funds when its till has attested the fees, and what is
// left of the costs comes back to the creator.
struct (0x72e98e58) InitGramLock {
    queryId: uint64
    terms: Cell<LockTerms>
    tillCode: cell
}

// The owner or the creator: add `amount` GRAM to the lock's schedule, less the fee on it at the rate fixed
// at the lock's setup. The message carries the amount on top of its costs (get_top_up_cost on the lock,
// which counts the flat fee of a top-up); the rest of its value comes back.
struct (0x3e3ef8f9) TopUpGram {
    queryId: uint64
    amount: coins
}

// The owner: pay out GRAM the schedule has unlocked, with what is left of this message's value, in a
// message that cannot bounce. `comment`: the body of that message, which is nothing or a text comment as
// wallets write one (an ordinary cell: 32 zero bits, then the text): what an exchange asks for with a
// deposit. The lock refuses any other body, so its owner cannot have it send, in its own name, what passes
// for a message of the lock's own. The comment is bounded as a claim's payload is: more than 4096 cells,
// 2^20 bits or a depth of 256 is refused with PayloadTooLarge (payloadCarriage, in lock-base).
struct (0x3387d16a) ClaimGram {
    queryId: uint64
    amount: coins // 0 = everything claimable
    destination: address
    comment: cell?
}

// The GRAM a lock holds above the storage it keeps (at most what a cancelled lock keeps), to `destination`,
// in a message that cannot bounce and has no body. A lock of either kind takes it.
// In a lock of GRAM it is the sweep: the owner of a funded lock that is finished, or the creator of a
// cancelled one, takes everything the lock holds but that storage.
// In a lock of jettons, whose tokens leave with a Sweep, the owner of a funded lock that is finished takes
// the GRAM the lock does not need any more: the storage paid for a life it will not have, and plain GRAM
// that reached it.
struct (0xc61ef9e5) SweepGram {
    queryId: uint64
    destination: address
}

// ============== Sworn: lock <-> till ==============

// Lock -> till: the setup request, for the fee config. Read-only; answered with the remaining value.
struct (0xb0c7a90d) AttestFees {
    queryId: uint64
}

// Till -> lock: the current config. The lock cancels if creation is disabled or a fee is above what its
// creator accepted, otherwise it fixes these rates for its whole life.
struct (0x05292e3d) FeesAttested {
    queryId: uint64
    enabled: bool
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

// Forward payload of a fee transfer, lock -> till (in a ref). The till only emits an event.
struct (0x92add29a) FeeTag {
    index: uint256
    master: address
    kind: uint8 // FEE_KIND_*
}

// Lock -> till: the flat fee, as the value (it never travels through jetton code). A lock of GRAM has no
// master and pays the fee on the amount in the same value: `amount` says how much of it (0 from a lock of
// jettons, whose fee on the amount travels as tokens, with a FeeTag).
struct (0x7f73a69f) FeeNotice {
    queryId: uint64
    index: uint256
    master: address?
    kind: uint8 // FEE_KIND_*
    amount: coins
}

// What a fee is for: the `kind` of a FeeTag and of a FeeNotice
const FEE_KIND_FUNDING = 0
const FEE_KIND_TOP_UP = 1
const FEE_KIND_RETRY = 2 // fee tokens owed after a bounced fee transfer, delivered by RetryFee or Sweep

// ============== Sworn: root -> till ==============

// The root's fee config and whether creation is enabled, for the till to attest. The till checks the fee
// caps again.
struct (0x511d31bb) SetTillConfig {
    queryId: uint64
    enabled: bool
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

// A till holds only fees: the root may move anything in any of its wallets
struct (0xaffefce6) TillWithdrawJetton {
    queryId: uint64
    wallet: address
    amount: coins
    destination: address
}

// GRAM of the till, above what keeps its storage paid
struct (0x5b3fe5ba) TillWithdrawGrams {
    queryId: uint64
    amount: coins
    destination: address
}

// An NFT the till owns (only ever by someone's mistake: locks refuse their own till as owner)
struct (0x6c7ebe78) TillWithdrawNft {
    queryId: uint64
    nft: address
    newOwner: address
}

// ============== Sworn: anyone / admin -> root ==============

// Anyone (the sender pays): deploy till n with the current config, or push the config to it again
struct (0xf87f9016) DeployTill {
    queryId: uint64
    n: uint8
}

// The admin: the fees the tills attest from then on, within the caps; pushed to every till
struct (0x38b8a3b8) SetFees {
    queryId: uint64
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

// The admin: the TEP-66 royalty of the collection, at most MAX_ROYALTY_BPS
struct (0x3ad19b14) SetRoyalty {
    queryId: uint64
    numerator: uint16
    denominator: uint16
    destination: address
}

// The admin: the collection's metadata. Takes effect CONTENT_DELAY later (wallets and indexers see the
// change coming).
struct (0x8f325db8) SetContent {
    queryId: uint64
    collectionContent: cell
    itemBaseUri: cell
}

// The admin: stop or resume the creation of locks; pushed to every till. Funded locks are untouched; a
// creation still waiting for its till's answer is cancelled by it.
struct (0xe10a5084) SetCreationEnabled {
    queryId: uint64
    enabled: bool
}

// The six withdrawals, each the admin's: out of a till its fee tokens, its GRAM and an NFT that reached it,
// then the same three out of the root. Each goes to an account on the basechain.

// Fee tokens out of till `n`, through that till's jetton wallet `wallet`
struct (0x9ded6daf) WithdrawTillJetton {
    queryId: uint64
    n: uint8
    wallet: address
    amount: coins
    destination: address
}

// GRAM out of till `n`, above what the till keeps: its reserve and its storage paid in advance
struct (0x90c24f96) WithdrawTillGrams {
    queryId: uint64
    n: uint8
    amount: coins
    destination: address
}

// An NFT that till `n` owns, which only a mistake brings there, to `newOwner`. `nftInit`: the NFT's
// StateInit (it must hash to `nft`), so the root can tell a Sworn lock, which it never moves, from any
// other NFT.
struct (0x7cd8a7bc) WithdrawTillNft {
    queryId: uint64
    n: uint8
    nft: address
    newOwner: address
    nftInit: cell
}

// Tokens that reached one of the root's jetton wallets by mistake (nothing there is owed to anyone),
// through that wallet `wallet`
struct (0xee95c1f0) WithdrawRootJetton {
    queryId: uint64
    wallet: address
    amount: coins
    destination: address
}

// GRAM of the root, above what the root keeps: its reserve and its storage paid in advance
struct (0x34789311) WithdrawRootGrams {
    queryId: uint64
    amount: coins
    destination: address
}

// An NFT that the root owns, which only a mistake brings there, to `newOwner`. `nftInit` as for
// WithdrawTillNft.
struct (0x0f6335ec) WithdrawRootNft {
    queryId: uint64
    nft: address
    newOwner: address
    nftInit: cell
}

// The admin hands over in two steps. It proposes a successor (none withdraws the proposal), who becomes the
// admin by accepting.
struct (0xbb67d3ce) ProposeAdmin {
    queryId: uint64
    newAdmin: address?
}

struct (0x7e9b44ea) AcceptAdmin {
    queryId: uint64
}
