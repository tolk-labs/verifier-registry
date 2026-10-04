enum TradeErrors {
    InvalidMessage = 0xFFFF
    SameUsers = 100
    NotParticipant = 101
    SideAlreadyAccepted = 103
    EmptyTonDeposit = 104
    AlreadyCompleted = 109
    AlreadyCancelled = 110
    InsufficientMessageValue = 112
    InvalidAmount = 113
    NotOwner = 114
    TradeNotClosed = 115
    NothingToSweep = 116
    TradeNotCompleted = 117
    TradeNotCancelled = 118
    TradeNotStuck = 119
    StuckTimeoutNotReached = 120
    TradeNotExpired = 121
    // V4-3: an allowlist entry naming a schema the escrow does not implement would be accepted but
    // could never authenticate anything — a silently dead entry. Reject it at the door instead.
    UnknownNftSchema = 122
    // V4-3: an empty batch is always a caller mistake; committing nothing while reporting success
    // would hide a broken allowlist script.
    EmptyBatch = 123
    // V5-2: without this, a terminal escrow could be drained to MIN_ESCROW_DUST_RESERVE while it still
    // owes someone an NFT — and that reserve is the only thing keeping RetryPending executable long
    // enough to hand the item back. V5-7 narrowed the callers to the participants and the fee
    // recipient, which removes the stranger but not the mistake, so this check stays independent.
    EscrowHasObligations = 124
}

const MAX_NFTS_PER_SIDE = 6
const NFT_TRANSFER_VALUE = 30000000
const MIN_ESCROW_DEPLOY_VALUE = 50000000
const MIN_CREATE_TRADE_VALUE = 10000000
const MIN_TRADE_ACTION_VALUE = 10000000
const TRADE_FEE_BPS = 50
const BPS_DENOMINATOR = 10000
// V5-2 option A (D8): what a swept escrow keeps, to pay storage rent. An account frozen for unpaid
// rent cannot execute, and RetryPending / ForceResolveStuck are contract calls — so this number is
// what keeps the NFT recovery levers usable. The real floor left behind is this PLUS
// SWEEP_FEE_BUFFER below, i.e. 0.06 TON.
//
// Sized against measurement, not a rule of thumb. Mainnet config 18 is cell_price_ps=135 and
// bit_price_ps=0, so rent depends only on CELL COUNT: rent = cells * 135 * seconds / 2^16. The real v4
// spike escrow measured 131 cells → 0.008510 TON/yr. Modelling allowlist growth (56 gift collections
// share one library-reference item code and cost ~2 cells each; a distinct ordinary item code like
// Telegram Usernames costs ~21) plus 6+6 NFTs and a full pending-return ledger puts the worst case
// near 300 cells, ~0.019 TON/yr.
//
// Target: comfortably more than one year at that worst case (owner call, 2026-08-06). 0.06 TON
// retained buys ~3 years there. The previous 0.03 (0.04 retained) would already have met a bare
// one-year bar; the raise buys margin for three things that are real — the state model validates ~19%
// LOW against the one on-chain datapoint, the allowlist is deliberately on a growth path, and a late
// re-deposit into an already-swept escrow (a first-class path since V5-1) needs the escrow still alive
// to be recoverable. The cost is bounded and is not waste: it is prepaid rent that would otherwise be
// swept to the fee recipient.
const MIN_ESCROW_DUST_RESERVE = 50000000
const MIN_FACTORY_DUST_RESERVE = 30000000
const SWEEP_FEE_BUFFER = 10000000
// I-05: schema/behaviour version, exposed via getVersion() on both contracts so the indexer can route
// by version after a code upgrade. Bump whenever a deployed code change must be distinguishable
// off-chain (existing on-chain instances keep the version they were deployed with).
//   v1 → initial testnet release.
//   v2 → 2026-07-20 review H-1: the MIN_NFT_FORWARD_VALUE floor no longer gates a *successful* NFT
//        deposit (only the reject/return paths). A valid deposit forwarding below the floor is now
//        recorded instead of being reverted-and-stranded — a behaviour change, hence a new version.
//   v3 → 2026-07-22 review H-1: an inbound NFT that cannot join the trade (late deposit, or an
//        authenticated-but-unrecordable one) is now recorded as a PendingReturn before its return is
//        attempted, so a bounced return is recoverable via RetryPending instead of silently stranding
//        the item. Adds the `pendingReturns` map to storage — a new deterministic escrow address.
//   v4 → 2026-08-01. Three behaviour changes, all in NFT handling:
//        (V4-1) the telemint item layout is fixed — v2/v3 recomputed an address no Telegram-native
//        item has ever had, so no gift, username or +888 number could be traded at all. Schema 1 is
//        repaired in place and renamed DNS → TELEMINT.
//        (V4-8) recordPendingReturn now guards on whether a side entry is still LIVE, not whether it
//        exists, so a genuine item re-deposited after settlement is recorded and recoverable instead
//        of silently held.
//        (V4-9) NFT-transfer bounces are attributed by queryId (0 = the return lane) rather than by
//        item address, so a bounced return can no longer be booked as a bounced settlement transfer
//        and re-open a terminal trade.
//   v5 → scope complete 2026-08-06. Four changes:
//        (V5-1) the OTHER half of V4-8's guard. recordPendingReturn tested `pendingReturns.exists`,
//        but that ledger is insert-only, so a SENT entry — meaning "handed off, not held" — read as
//        "already handled". A re-deposit of the same item was then neither recorded nor returned:
//        permanently held, pendingReturnCount 0, invisible to RetryPending and to every off-chain
//        reader. It now guards on whether the entry represents custody the escrow still HAS
//        (CR-2026-08-04-M1). Also fixes the misdelivery arm — the entry is refreshed on re-deposit, so
//        markBouncedReturn can no longer return a new owner's item to the original depositor.
//        (V5-2) escrow rent solvency. SweepDust now refuses while `hasOutstandingObligations`, and
//        MIN_ESCROW_DUST_RESERVE rose 0.03 → 0.05 (0.06 retained with SWEEP_FEE_BUFFER). A swept
//        escrow's reserve is what keeps RetryPending/ForceResolveStuck executable, so this is the
//        difference between a held NFT being recoverable and being frozen with it.
//        (V5-3) the hand-rolled `addrWorkchain` is gone; the factory's workchain check uses
//        `address.getWorkchain()`, which applies the anycast rewrite instead of assuming it absent
//        (CR-2026-07-22-L1).
//        (V5-7) SweepDust is restricted to the two participants and the fee recipient. Independent of
//        V5-2's obligation gate — permissioning removes the stranger, not the mistake.
//        FROZEN 2026-08-07 on owner authorisation (versions/README.md rule 4a). Frozen code hashes
//        are recorded in versions/v5-test-plan.md §7.3 and are what a deployed factory must match on
//        chain — getVersion() returning 5 is a claim, the code hash is the proof. Deploying is a
//        SEPARATE rule-4a decision, per network.
const CONTRACT_VERSION: uint16 = 5
// H-01: a settlement that keeps bouncing (an NFT whose item contract permanently rejects the transfer
// to the counterparty) would otherwise sit in SETTLING forever. After this timeout from the moment
// settlement began, anyone may call ForceResolveStuck to return the undeliverable NFTs to their
// depositors and move the trade to TRADE_STATUS_SETTLE_STUCK. 7 days = 604800 seconds.
const STUCK_SETTLEMENT_TIMEOUT = 604800
// M-03: an OPEN trade where every participant goes silent (both ghost, or a depositor loses their key
// and the counterparty never appears) would otherwise lock its deposited TON and NFTs forever — neither
// can be cancelled by anyone who is still around. After this much inactivity (`lastActivityAt` is reset
// on every participant deposit/accept, so only genuinely-abandoned trades qualify), anyone may call
// ExpireTrade to refund all assets to their depositors. 30 days = 2592000 seconds — generous, because
// OPEN is the negotiation phase where legitimate pauses happen, and an active trade resets the clock.
const OPEN_TRADE_TIMEOUT = 2592000
// N-2 / H-1: minimum inbound value required to fund the mode-64 *return* of a rejected or late NFT
// deposit. The return carries only the inbound value (mode 64, never escrow balance — C-03), so an
// underfunded return would revert AFTER the item already (non-bounceably) moved ownership to the
// escrow, stranding the NFT. This floor is enforced ONLY on the reject/return branches of
// OwnershipAssigned — never on a successful deposit, which sends no message and needs no value (that
// over-broad early gate was H-1: it reverted-and-stranded valid low-value deposits). The SDK always
// forwards 20 mTON (NFT_OWNERSHIP_NOTIFICATION_VALUE), comfortably above this floor.
const MIN_NFT_FORWARD_VALUE = 5000000
const TRADE_STATUS_OPEN: uint8 = 0
const TRADE_STATUS_SETTLING: uint8 = 1
const TRADE_STATUS_COMPLETED: uint8 = 2
const TRADE_STATUS_REFUNDING: uint8 = 3
const TRADE_STATUS_REFUNDED: uint8 = 4
// Terminal degraded outcome: both parties' TON was distributed by settlement, but at least one NFT
// could not be delivered to the counterparty and was force-returned to its depositor after the
// stuck-settlement timeout. Distinct from COMPLETED so the indexer/UI can flag the failed delivery.
const TRADE_STATUS_SETTLE_STUCK: uint8 = 5
const NFT_STATUS_DEPOSITED: uint8 = 0
const NFT_STATUS_TRANSFER_SENT: uint8 = 1
const NFT_STATUS_TRANSFER_BOUNCED: uint8 = 2

// V4-9: the escrow sends NFT transfers on two different errands, and a bounce must be attributed to
// the errand rather than to the item — an item can be BOTH a settled side entry (history) and the
// subject of an outstanding return at the same time. `queryId` carries that attribution: this value
// marks the RETURN lane (returnNft / resendReturnNft), and every settlement/refund transfer uses a
// hash-derived id that nftQueryId() guarantees is non-zero. The bounced body preserves 256 bits,
// which covers the opcode and the queryId, so the lane survives the round trip.
//
// Before this split, `markBouncedNft` matched on item address alone and always won, so a bounced
// return of an already-settled item was booked as a failed settlement transfer and re-opened a
// terminal trade — see docs/contracts/versions/v4-plan.md §8 V4-9 (CR-2026-07-29-M2).
const NFT_RETURN_QUERY_ID: uint64 = 0

// H-1: a durable record of an inbound NFT the escrow could not add to the trade (a late deposit that
// arrived after OPEN, or an authenticated deposit that could not be recorded — side full, side already
// accepted, duplicate, or a genuine item whose prevOwner is not a participant). Such an item has already
// moved ownership to the escrow non-bounceably, and its return is inbound-funded (mode 64) and can
// itself bounce. Recording (item -> depositor) BEFORE the return means a bounced return is no longer
// silently lost: `onBouncedMessage` flips it to BOUNCED and `RetryPending` re-attempts it, exactly like
// a bounced settlement transfer. Only AUTHENTICATED items are ever recorded here — a forged notification
// moved no real asset, and recording it would reopen the escrow-drain vector (C-03), so it is never
// added. `target` is the depositor (msg.prevOwner, trustworthy only once authentication has proven the
// sender is a genuine item that set it). `status` reuses the transfer lifecycle: SENT after an attempt,
// BOUNCED once a return bounces (the only state RetryPending re-sends).
struct PendingReturn {
    target: address
    status: uint8
}

// C-01/H-03: NFT item address-recompute schemas. An allowlist entry declares which item init-data
// layout its collection uses; the escrow recomputes the item address from that layout and trusts a
// deposit only if the sender matches. The two layouts differ in BOTH index width and cell shape:
//   STANDARD → NftItemInitData     { index: uint64, collection }        — reference TEP-62 items.
//   TELEMINT → TelemintNftItemInitData { bit(0), ^(index: uint256, collection) }
//              — every Telegram-native asset: gifts, usernames, +888 anonymous numbers.
//                index = string_hash(token_name); the payload is nested behind a one-bit header.
// Keep STANDARD = 0 so an entry with a defaulted/zero schema field behaves exactly as before the rework.
//
// v4 (2026-08-01) — the DNS schema was BROKEN in v2/v3 and is repaired, not replaced. It packed
// `index ++ collection` inline, on a documented-but-false claim that telemint items differ from TEP-62
// only in index width. Real telemint items nest that exact payload one cell deeper behind a one-bit
// "initialized" header, and a cell's hash covers its refs' hashes, so the recomputed address never
// matched and NO Telegram-native NFT could authenticate. The schema id is reused rather than adding a
// third value: the flat-DNS layout matches zero real mainnet collections, so nothing that worked is
// lost, and keeping a broken schema 1 beside a correct schema 2 would preserve a trap. The name moves
// from DNS to TELEMINT because "DNS" described the family we guessed at, not the layout we now pin.
// Pinned against real mainnet items in contracts/tests/nft_golden_vectors.test.tolk — see
// docs/contracts/nft-telemint-authentication-gap.md for the full analysis.
const NFT_SCHEMA_STANDARD: uint8 = 0
const NFT_SCHEMA_TELEMINT: uint8 = 1

// An allowlist entry pairs a collection's NFT item code with the schema needed to recompute an item's
// address from it. Snapshotted (per entry) into every escrow at CreateTrade, so its layout is part of the
// escrow's deterministic address.
struct CollectionEntry {
    schema: uint8
    itemCode: cell
}

struct TradeFactoryStorage {
    owner: address
    nextTradeId: uint64
    escrowCode: cell
    // C-01/H-03: allowlist of tradable NFT collections → that collection's (schema, item code).
    // An escrow authenticates a deposit by recomputing the sender's expected item address from
    // (itemCode, schema-dictated index width, collection) and requiring it to match; only genuine items
    // of an allowlisted collection pass. Snapshotted into each escrow at CreateTrade.
    allowedCollections: map<address, CollectionEntry>
}

fun TradeFactoryStorage.load(): TradeFactoryStorage {
    return TradeFactoryStorage.fromCell(contract.getData());
}

fun TradeFactoryStorage.save(self) {
    contract.setData(self.toCell());
}

struct TradeEscrowStorage {
    tradeId: uint64
    factory: address
    feeRecipient: address
    participants: Cell<TradeParticipants>
    acceptedA: bool
    acceptedB: bool
    depositedTonA: coins
    depositedTonB: coins
    assets: Cell<TradeAssets>
    status: uint8
    // H-01: Unix time (seconds) when the trade first left OPEN — set once when settlement begins
    // (completeTrade) or a refund begins (refundAll), never updated by retries/bounces. The
    // stuck-settlement escape is time-gated against this. Initialised to 0 at deploy (a constant, so
    // the deterministic escrow address never depends on wall-clock time).
    statusChangedAt: uint32
    // M-03: Unix time of the last participant action while OPEN (TON deposit, NFT deposit, or accept).
    // 0 until the first such action. The OPEN-trade expiry escape is time-gated against this, so any
    // genuine activity pushes the deadline out and only a truly-abandoned trade can be expired.
    lastActivityAt: uint32
    // C-01/H-03: snapshot of the factory allowlist at creation time (collection → (schema, item code)).
    // A deposit is authenticated by recomputing the sender's expected item address from
    // (itemCode, schema-dictated index width, collection) carried in the transfer's forward payload and
    // requiring a match.
    allowedCollections: map<address, CollectionEntry>
}

struct TradeParticipants {
    userA: address
    userB: address
}

fun TradeEscrowStorage.load(): TradeEscrowStorage {
    return TradeEscrowStorage.fromCell(contract.getData());
}

fun TradeEscrowStorage.save(self) {
    contract.setData(self.toCell());
}

struct TradeState {
    tradeId: uint64
    factory: address
    feeRecipient: address
    userA: address
    userB: address
    acceptedA: bool
    acceptedB: bool
    depositedTonA: coins
    depositedTonB: coins
    nftCountA: uint16
    nftCountB: uint16
    pendingNftCount: uint16
    status: uint8
    statusChangedAt: uint32
    lastActivityAt: uint32
    completed: bool
    cancelled: bool
    // True when status == TRADE_STATUS_SETTLE_STUCK: settlement completed but an NFT could not be
    // delivered and was force-returned to its depositor. Lets the app flag the degraded outcome
    // without hard-coding the magic status value.
    stuck: bool
    // H-1: number of recorded pending returns (items held by the escrow that could not join the trade
    // and are awaiting return to their depositor). Non-zero means RetryPending still has work to do,
    // independent of trade status. Distinct from `pendingNftCount`, which counts only tradable side NFTs.
    pendingReturnCount: uint16
}

struct TradeAssets {
    nftA: map<address, uint8>
    nftB: map<address, uint8>
    nftCountA: uint16
    nftCountB: uint16
    // H-1: items the escrow holds but could not add to either side, recorded so a bounced return stays
    // recoverable via RetryPending. Kept OUT of nftA/nftB (which drive settlement direction) and out of
    // `pendingNftCount` (the settlement-reserve driver, which must only count tradable side assets).
    pendingReturns: map<address, PendingReturn>
}

struct EscrowConfig {
    minTradeActionValue: coins
    nftTransferValue: coins
    minEscrowDeployValue: coins
    minCreateTradeValue: coins
    maxNftsPerSide: uint8
    tradeFeeBps: uint16
    stuckSettlementTimeout: uint32
    openTradeTimeout: uint32
}

struct (0x54524352) CreateTrade {
    userA: address
    userB: address
    deployValue: coins
}

struct (0x544f4e44) DepositTon {}

struct (0x41434350) AcceptTrade {}

struct (0x43414e43) CancelTrade {}

struct (0x53574550) SweepDust {}

struct (0x46535750) SweepFactoryDust {}

struct (0x41444443) AddCollection {
    collection: address
    itemCode: cell
    // Item address-recompute schema for this collection (NFT_SCHEMA_STANDARD / NFT_SCHEMA_TELEMINT). Standard
    // callers pass NFT_SCHEMA_STANDARD (0), which reproduces pre-rework behaviour.
    schema: uint8
}

// V4-3: allowlist many collections in one owner transaction. D1 keeps contracts immutable, so every
// contract fix is a new factory address and every allowlisted collection must be re-added by hand —
// `manage-allowlist.mjs` can pack at most 4 single-adds per transaction, which makes a real catalog
// (63 gift collections today) dozens of owner transactions per redeploy. This makes it one or two.
//
// The payload is the same map type the factory stores, so a batch is literally "here is a piece of the
// allowlist": no new authentication surface, no new entry semantics, and each entry is validated
// exactly as a single AddCollection is. Batch size is bounded by cell depth and gas, not by a constant —
// the sender finds the limit by the transaction failing, and nothing partial is ever committed because
// a failed TVM transaction commits no storage at all.
struct (0x41444442) AddCollections {
    entries: map<address, CollectionEntry>
}

struct (0x524d5643) RemoveCollection {
    collection: address
}

struct (0x544f574e) TransferOwnership {
    newOwner: address
}

struct (0x52455452) RetryPending {}

// H-01: permissionless, timeout-gated escape from a permanently-stuck SETTLING trade. Carries no
// fields — the escrow is per-trade and reads everything it needs from its own storage.
struct (0x46525356) ForceResolveStuck {}

// M-03: permissionless, timeout-gated refund of an abandoned OPEN trade. Carries no fields.
struct (0x45585052) ExpireTrade {}

struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    prevOwner: address
    forwardPayload: RemainingBitsAndRefs
}

struct (0x5fcc3d14) NftTransfer {
    queryId: uint64
    newOwner: address
    responseDestination: address
    customPayload: bool
    forwardAmount: coins
    forwardPayload: bool
}

// TEP-62 NFT item initial state data. An item's address is the address of
// StateInit{ code: itemCode, data: NftItemInitData{ index, collection } }. The escrow recomputes
// this from the allowlisted collection's item code to authenticate a deposit's sender.
// Used by NFT_SCHEMA_STANDARD (reference TEP-62 items).
struct NftItemInitData {
    index: uint64
    collection: address
}

// The payload a telemint item is deployed with, held one cell deep. Identical in content to
// NftItemInitData apart from the index width — which is exactly what made the v3 defect so easy to
// miss: the bytes matched, the SHAPE did not.
struct TelemintNftItemPayload {
    index: uint256
    collection: address
}

// Telegram-native (telemint) NFT item initial state data — gifts, usernames, +888 anonymous numbers.
// Used by NFT_SCHEMA_TELEMINT.
//
//   real : data = bit(0) , ^( index:uint256 , collection )       1 bit, 1 ref
//   v2/v3: data =           index:uint256 , collection         523 bits, 0 refs   ← WRONG
//
// The leading bit is telemint's "item already initialized" flag, 0 in the deploy state that fixes the
// address. Because a cell's hash covers its refs' hashes, nesting the payload changes the address, so
// the v2/v3 layout recomputed an address no real item has ever had and every Telegram-native deposit
// failed to authenticate. Verified against the deploy StateInit of live mainnet items from five
// collections (two gift item codes, usernames, numbers) — see
// contracts/tests/nft_golden_vectors.test.tolk and docs/contracts/nft-telemint-authentication-gap.md.
//
// Do not "simplify" this back into one flat cell. That is the bug.
struct TelemintNftItemInitData {
    // Serializes as the one-bit header; telemint writes 0 here at deploy time.
    initialized: bool
    payload: Cell<TelemintNftItemPayload>
}

// S-1: shared between TradeFactory and TradeEscrow so the two copies can't drift. These are free
// functions invoked inside a contract transaction, so `contract.*` resolves to whichever contract is
// executing and `createMessage` queues from its action phase.
fun sweepableBalance(inValue: coins, minReserve: coins): coins {
    val originalBalance = contract.getOriginalBalance();
    if (originalBalance <= inValue) {
        return 0;
    }
    val balance = originalBalance - inValue;
    if (balance <= minReserve + SWEEP_FEE_BUFFER) {
        return 0;
    }
    return balance - minReserve - SWEEP_FEE_BUFFER;
}

fun sendTon(to: address, amount: coins) {
    if (amount > 0) {
        createMessage({
            bounce: BounceMode.NoBounce,
            value: amount,
            dest: to,
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);
    }
}
