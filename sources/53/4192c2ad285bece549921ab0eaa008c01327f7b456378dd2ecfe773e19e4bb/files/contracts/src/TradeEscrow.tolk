import "trade_types"

contract TradeEscrow {
    author: "Tradegram"
    version: "0.1.0"
    description: "Two-party TON and NFT escrow trade room"
    storage: TradeEscrowStorage
    incomingMessages: EscrowMessage
}

type EscrowMessage =
    | DepositTon
    | AcceptTrade
    | CancelTrade
    | SweepDust
    | RetryPending
    | ForceResolveStuck
    | ExpireTrade
    | OwnershipAssigned

fun isUserA(storage: TradeEscrowStorage, addr: address): bool {
    return storage.participants.load().userA == addr;
}

fun isUserB(storage: TradeEscrowStorage, addr: address): bool {
    return storage.participants.load().userB == addr;
}

fun assertParticipant(storage: TradeEscrowStorage, addr: address) {
    assert (isUserA(storage, addr) || isUserB(storage, addr)) throw TradeErrors.NotParticipant;
}

// SETTLING/COMPLETED only. Deliberately excludes TRADE_STATUS_SETTLE_STUCK so a late bounce can never
// reopen a force-resolved trade, and so RetryPending routes SETTLE_STUCK to its own return path.
fun isSettlementStatus(status: uint8): bool {
    return status == TRADE_STATUS_SETTLING || status == TRADE_STATUS_COMPLETED;
}

fun isRefundStatus(status: uint8): bool {
    return status == TRADE_STATUS_REFUNDING || status == TRADE_STATUS_REFUNDED;
}

fun isStuckStatus(status: uint8): bool {
    return status == TRADE_STATUS_SETTLE_STUCK;
}

// L-04: only truly terminal states allow SweepDust.
// SETTLING and REFUNDING are retry-pending: NFT transfers are still in flight and the escrow
// balance funds each retry send (NFT_TRANSFER_VALUE via PAY_FEES_SEPARATELY). Sweeping early
// narrows that buffer. SETTLE_STUCK must be included — it IS terminal (no state transitions out),
// so excluding it would permanently lock any remaining balance with no recovery path.
fun isTerminalStatus(status: uint8): bool {
    return status == TRADE_STATUS_COMPLETED || status == TRADE_STATUS_REFUNDED ||
    status == TRADE_STATUS_SETTLE_STUCK;
}

fun assertOpen(storage: TradeEscrowStorage) {
    assert (!isSettlementStatus(storage.status)) throw TradeErrors.AlreadyCompleted;
    assert (!isRefundStatus(storage.status)) throw TradeErrors.AlreadyCancelled;
    assert (storage.status == TRADE_STATUS_OPEN) throw TradeErrors.InvalidMessage;
}

fun requiredActionValueForNfts(nftCount: int): coins {
    return MIN_TRADE_ACTION_VALUE + NFT_TRANSFER_VALUE * nftCount;
}

fun shouldTransferNft(status: uint8): bool {
    return status == NFT_STATUS_DEPOSITED || status == NFT_STATUS_TRANSFER_BOUNCED;
}

fun pendingNftCount(nfts: map<address, uint8>): int {
    var count = 0;
    var entry = nfts.findFirst();
    while (entry.isFound) {
        if (shouldTransferNft(entry.loadValue())) {
            count += 1;
        }
        entry = nfts.iterateNext(entry);
    }
    return count;
}

fun totalPendingNftCount(assets: TradeAssets): int {
    return pendingNftCount(assets.nftA) + pendingNftCount(assets.nftB);
}

fun assertNftTransferReserve(inValue: coins, nftCount: int) {
    assert (
        inValue >= requiredActionValueForNfts(nftCount)
    ) throw TradeErrors.InsufficientMessageValue;
}

fun tradeFee(amount: coins): coins {
    return amount * TRADE_FEE_BPS / BPS_DENOMINATOR;
}

// sweepableBalance + sendTon are shared helpers defined in trade_types.tolk (S-1).

// M-04: derive a unique queryId from the NFT address so concurrent settlement transfers are
// distinguishable by off-chain indexers. cell.hash() returns uint256; we read the first 64 bits
// back out via loadUint to avoid a TVM range-check error from a direct uint256 → uint64 cast.
//
// V4-9: 0 is RESERVED for the return lane (NFT_RETURN_QUERY_ID), because that is how a bounce is
// attributed to the message that caused it. The derivation is a hash, so 0 is possible — vanishingly
// unlikely, but "vanishingly unlikely" is not a safety property when the consequence is a terminal
// trade re-opening. Force it non-zero so the reservation is total.
fun nftQueryId(nft: address): uint64 {
    val h = beginCell().storeAddress(nft).endCell().hash();
    val derived = beginCell().storeUint(h, 256).endCell().beginParse().loadUint(64);
    return (derived == NFT_RETURN_QUERY_ID ? 1 : derived) as uint64;
}

fun transferNft(nft: address, newOwner: address) {
    createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: NFT_TRANSFER_VALUE,
        dest: nft,
        body: NftTransfer {
            queryId: nftQueryId(nft),
            newOwner,
            responseDestination: contract.getAddress(),
            customPayload: false,
            forwardAmount: 1,
            forwardPayload: false,
        },
    }).send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun returnNft(nft: address, previousOwner: address) {
    // C-03: fund the return from the inbound message (mode 64), never from the escrow balance.
    // OwnershipAssigned is unauthenticated, so any sender can hit a reject branch. If the return
    // were escrow-funded (fixed value + PAY_FEES_SEPARATELY, like transferNft) an attacker could
    // drain the contract by forging notifications. Carrying the remaining inbound value means a
    // return can never pay out more than what just arrived, so forging is never profitable.
    // Legitimate settlement/refund transfers stay escrow-funded via transferNft (reserve-gated).
    createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: 0,
        dest: nft,
        body: NftTransfer {
            queryId: NFT_RETURN_QUERY_ID, // V4-9: marks the return lane for bounce attribution
            newOwner: previousOwner,
            responseDestination: previousOwner,
            customPayload: false,
            forwardAmount: 1,
            forwardPayload: false,
        },
    }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// N-2 / H-1: a rejected or late NFT deposit is returned to its sender via the inbound-funded mode-64
// path (returnNft). That return needs enough inbound value to cover its own gas; otherwise the escrow
// reverts AFTER the item already (non-bounceably) moved ownership to the escrow, permanently stranding
// the NFT with no record and no recovery lever. Gate the floor HERE — only where an outgoing return is
// actually sent. A *successful* deposit sends no message and needs no floor, so this is never on the
// record path (that over-broad early gate was H-1: it destroyed valid deposits forwarding < 5 mTON).
//
// This does not reopen the N-2 "gas waste on adversarial low-value inputs" concern. A forged sub-floor
// notification now runs the authentication recompute before hitting this assert, but the assert THROWS,
// so the transaction aborts: the TVM caps the gas actually charged to a failed internal message at the
// message-value's gas credit and rolls back the balance-funded remainder, so a forged low-value input
// can never drain the escrow's balance (verified — see `test underfunded forged deposits do not drain
// escrow balance`). Only a *successful* deposit commits full balance-funded gas, and that is a genuine
// participant depositing their own NFT — a few mTON of ordinary operating cost, never an attack.
fun assertReturnFunded(inValue: coins) {
    assert (inValue >= MIN_NFT_FORWARD_VALUE) throw TradeErrors.InsufficientMessageValue;
}

fun nftAlreadyRecorded(assets: TradeAssets, nft: address): bool {
    return assets.nftA.exists(nft) || assets.nftB.exists(nft);
}

// V4-8: is this item still a LIVE trade asset — one the escrow is holding on a side and still owes a
// send for — as opposed to a settled entry that is now just history?
//
// The distinction matters because side entries are never deleted. `nftAlreadyRecorded` therefore stays
// true forever once an item has traded, which is correct for the deposit path (duplicate protection,
// canRecordNftForA/B) but catastrophically wrong for the pending-return path: an item coming back
// AFTER settlement is genuinely in the escrow's custody again and needs a recovery record, yet the
// existence check silently refused to write one. See v4-plan.md §8 V4-8 (CR-2026-07-29-M1).
//
// `shouldTransferNft` is already the project's definition of "this entry still owes a send"
// (DEPOSITED or BOUNCED), so reusing it keeps one definition of live-vs-historical.
fun nftHeldOnSide(assets: TradeAssets, nft: address): bool {
    if (assets.nftA.exists(nft)) {
        return shouldTransferNft(assets.nftA.mustGet(nft));
    }
    if (assets.nftB.exists(nft)) {
        return shouldTransferNft(assets.nftB.mustGet(nft));
    }
    return false;
}

// Recomputes the item address that a genuine NFT of `collection` at `index` must have, given that
// collection's item code and schema. The escrow only trusts a deposit whose sender equals this address.
// The schema selects the item init-data layout — and the two layouts differ in shape, not just width:
//   NFT_SCHEMA_TELEMINT → bit(0) ++ ^(index:uint256 ++ collection)  — gifts, usernames, +888 numbers
//   NFT_SCHEMA_STANDARD → index:uint64 ++ collection                — reference TEP-62 items
// `index` is carried at the widest width (uint256) and narrowed to uint64 for the standard layout; the
// deposit parser only ever loads it at the schema's declared width, so a standard index always fits.
//
// v4: the telemint branch previously packed its payload inline, which produced an address no real item
// has ever had — see trade_types.tolk TelemintNftItemInitData. Both branches are pinned against real
// mainnet items in contracts/tests/nft_golden_vectors.test.tolk; change neither without re-running them.
// See docs/contracts/nft-deposit.md for the full wire format and authentication flow.
fun computeNftItemAddress(
    itemCode: cell,
    schema: uint8,
    collection: address,
    index: uint256,
): address {
    // Both branches produce distinct Cell<T> types; cast to a plain cell so the ternary unifies and the
    // result drops straight into ContractState.data.
    val data = schema == NFT_SCHEMA_TELEMINT
        ? (TelemintNftItemInitData {
            initialized: false,
            payload: TelemintNftItemPayload { index, collection }.toCell(),
        }.toCell() as cell)
        : (NftItemInitData {
            index: index as uint64,
            collection,
        }.toCell() as cell);
    val stateInit = ContractState {
        code: itemCode,
        data,
    };
    return AutoDeployAddress { stateInit }.calculateAddress();
}

fun canRecordNftForA(storage: TradeEscrowStorage, assets: TradeAssets, nft: address): bool {
    return !storage.acceptedA && !nftAlreadyRecorded(assets, nft) && assets.nftCountA <
    MAX_NFTS_PER_SIDE;
}

fun canRecordNftForB(storage: TradeEscrowStorage, assets: TradeAssets, nft: address): bool {
    return !storage.acceptedB && !nftAlreadyRecorded(assets, nft) && assets.nftCountB <
    MAX_NFTS_PER_SIDE;
}

// Authenticates and records an incoming NFT deposit.
//
// C-01/H-03: the deposit notification (OwnershipAssigned) is unauthenticated — any contract can send
// one with an arbitrary prevOwner. We never trust prevOwner on its own. Instead the transfer's
// forward payload must carry an allowlisted collection address + item index whose recomputed TEP-62
// address equals the actual sender. Only a genuine item of an allowlisted collection can satisfy this,
// which in turn means its prevOwner field is set by that item and can be trusted to identify the side.
//
// Payload wire format (Either Cell ^Cell — see docs/contracts/nft-deposit.md). The index width follows
// the allowlisted collection's schema (uint64 standard, uint256 DNS):
//   Inline: bit(0) | address(collection) | uintW(index)
//   Ref:    bit(1) | ^(address(collection) | uintW(index))
//
// Returns true and records the NFT (status DEPOSITED) on success; false on any failure (bad payload,
// unknown collection, address mismatch, wrong/accepted side, duplicate, side full) so the caller can
// return the NFT to its sender. Parsing + the allowlist lookup + recompute are wrapped in try/catch so a
// malformed payload (or an index too short for the schema's width) can never abort the transaction and
// strand the NFT at the escrow.
// C-01/H-03: is `nft` a genuine item of an allowlisted collection? Re-parses the transfer's forward
// payload (Either Cell ^Cell), reads the collection + schema-width index, and recomputes the item's
// TEP-62 address — only a real item of an allowlisted collection can make it equal the actual sender.
// Wrapped in try/catch so a malformed payload (or an index too short for the schema) can never abort the
// transaction and strand the NFT. This is the ONLY trust gate: a caller that passes it moved a real
// asset to the escrow and its prevOwner can be trusted; a caller that fails moved nothing real.
fun isAuthenticNftDeposit(
    storage: TradeEscrowStorage,
    nft: address,
    payload: slice,
): bool {
    try {
        var p = payload;
        var body = p;
        if (p.remainingBitsCount() >= 1) {
            // forward_payload is Either Cell ^Cell: bit 0 = inline, bit 1 = in a ref.
            if (p.loadBool()) {
                body = p.loadRef().beginParse();
            } else {
                body = p;
            }
        }
        val collection = body.loadAddress();
        if (storage.allowedCollections.exists(collection)) {
            val entry = storage.allowedCollections.mustGet(collection);
            // Parse the index at the width the entry's schema dictates. A DNS collection whose deposit
            // only carries 64 bits (or vice versa) fails: loadUint throws on short input, or the
            // recompute produces a different address — either way the NFT is returned. This is what
            // gates the schema (wrong-schema deposits never authenticate).
            var index: uint256 = 0;
            if (entry.schema == NFT_SCHEMA_TELEMINT) {
                index = body.loadUint(256) as uint256;
            } else {
                index = body.loadUint(64) as uint256;
            }
            return computeNftItemAddress(entry.itemCode, entry.schema, collection, index) == nft;
        }
    } catch {
        return false;
    }
    return false;
}

fun tryRecordDeposit(
    mutate storage: TradeEscrowStorage,
    mutate assets: TradeAssets,
    nft: address,
    prevOwner: address,
    payload: slice,
): bool {
    if (!isAuthenticNftDeposit(storage, nft, payload)) {
        return false;
    }

    if (isUserA(storage, prevOwner) && canRecordNftForA(storage, assets, nft)) {
        assets.nftA.set(nft, NFT_STATUS_DEPOSITED);
        assets.nftCountA += 1;
        return true;
    }
    if (isUserB(storage, prevOwner) && canRecordNftForB(storage, assets, nft)) {
        assets.nftB.set(nft, NFT_STATUS_DEPOSITED);
        assets.nftCountB += 1;
        return true;
    }
    return false;
}

fun transferPendingNfts(mutate nfts: map<address, uint8>, to: address) {
    var entry = nfts.findFirst();
    while (entry.isFound) {
        val nft = entry.getKey();
        if (shouldTransferNft(entry.loadValue())) {
            transferNft(nft, to);
            nfts.set(nft, NFT_STATUS_TRANSFER_SENT);
        }
        entry = nfts.iterateNext(entry);
    }
}

fun nftAddressSet(nfts: map<address, uint8>): map<address, bool> {
    var result: map<address, bool> = [];
    var entry = nfts.findFirst();
    while (entry.isFound) {
        result.set(entry.getKey(), true);
        entry = nfts.iterateNext(entry);
    }
    return result;
}

// Returns (this is a bounced NFT transfer we sent, the queryId it carried). V4-9: the queryId is what
// attributes the bounce to the errand — NFT_RETURN_QUERY_ID for a return, a non-zero hash-derived id
// for a settlement/refund transfer. Routing on the item address alone cannot distinguish them, because
// the same item can be a settled side entry AND the subject of an outstanding return simultaneously.
//
// A bounce preserves 0xFFFFFFFF ++ the first 256 bits of the original body, so the opcode (32) and the
// queryId (64) are always present for a transfer we sent — hence the 128-bit floor. Anything shorter is
// not our NftTransfer and is ignored rather than parsed.
fun parseNftTransferBounce(bouncedBody: slice): (bool, uint64) {
    var body = bouncedBody;
    if (body.remainingBitsCount() < 128) {
        return (false, 0);
    }
    // M-05: read the prefix explicitly rather than calling skipBouncedPrefix(), whose behaviour on
    // edge-case slices is Tolk-version-specific. A body with the wrong prefix (e.g. a non-bounced
    // message accidentally matching the bit count) is now safely rejected here.
    val prefix = body.loadUint(32);
    if (prefix != 0xFFFFFFFF) {
        return (false, 0);
    }
    if (body.loadUint(32) != 0x5fcc3d14) {
        return (false, 0);
    }
    return (true, body.loadUint(64) as uint64);
}

fun markBouncedNft(mutate assets: TradeAssets, nft: address): bool {
    if (assets.nftA.exists(nft)) {
        if (assets.nftA.mustGet(nft) == NFT_STATUS_TRANSFER_SENT) {
            assets.nftA.set(nft, NFT_STATUS_TRANSFER_BOUNCED);
        }
        return true;
    }

    if (assets.nftB.exists(nft)) {
        if (assets.nftB.mustGet(nft) == NFT_STATUS_TRANSFER_SENT) {
            assets.nftB.set(nft, NFT_STATUS_TRANSFER_BOUNCED);
        }
        return true;
    }

    return false;
}

fun reopenStatusAfterNftBounce(mutate storage: TradeEscrowStorage) {
    if (isSettlementStatus(storage.status)) {
        storage.status = TRADE_STATUS_SETTLING;
    } else if (isRefundStatus(storage.status)) {
        storage.status = TRADE_STATUS_REFUNDING;
    }
}

// V5-1 (CR-2026-08-04-M1): does the pending-return ledger say the escrow still HOLDS this item?
//
// Not "is there an entry". `pendingReturns` is insert-only — the premise D7 / CR-2026-07-23-M1 accepts
// for rent: a successful return sends the escrow no acknowledgement, so absence of a bounce is the only
// success signal and there is nothing to delete on. A SENT entry therefore means "we sent a return for
// this item once, and it probably worked" — the escrow does NOT hold it, and an inbound deposit of that
// same item is a NEW custody episode that must be recorded afresh. Only BOUNCED means the return came
// back and the escrow is still holding the item on the return lane.
//
// This is V4-8's own reasoning applied to the guard's second operand: ask whether the ledger entry
// represents custody the escrow still has, not merely whether an entry exists.
fun pendingReturnHeld(assets: TradeAssets, nft: address): bool {
    return assets.pendingReturns.exists(nft) &&
    assets.pendingReturns.mustGet(nft).status == NFT_STATUS_TRANSFER_BOUNCED;
}

// H-1: record an authenticated inbound NFT that cannot join the trade so its return stays recoverable.
// Never records an item the escrow is still holding as a LIVE trade asset (V4-8 — a settled entry is
// history, not custody) or one it still holds on the return lane (V5-1) — and the caller only ever
// reaches here for an AUTHENTICATED deposit, so a forged notification (which moved no real asset) is
// never recorded and can never later trigger an escrow-funded resend (preserving the C-03 anti-drain
// property).
// `initialStatus` is SENT when the caller will attempt an inbound-funded return now, or BOUNCED when it
// cannot (a below-floor forwarded value — M-4), leaving the escrow-funded resend to RetryPending.
// Re-deposit of an item whose entry is SENT deliberately OVERWRITES that entry: it is a new custody
// episode, and its target must be whoever sent it this time, not whoever sent it first.
fun recordPendingReturn(
    mutate assets: TradeAssets,
    nft: address,
    target: address,
    initialStatus: uint8,
) {
    // V5-1 — BOTH arms are unreachable by construction, and that is the intended end state. The
    // committed coverage artifact shows `true=0` on each, which here means "correct", not "untested".
    //
    // The only caller is the OwnershipAssigned handler, so this runs solely when an item has just been
    // transferred INTO the escrow. Either arm being true would mean the escrow ALREADY holds that item
    // — live on a side, or bounced back onto the return lane — and an item the escrow holds cannot be
    // transferred in, because TEP-62 requires the current owner to initiate and the escrow never
    // transfers to itself. A forged notification cannot reach here either: `isAuthenticNftDeposit`
    // gates the call and requires the sender to BE the recomputed item address.
    //
    // Kept rather than deleted because contracts are immutable (D1) and this is the guard that stops a
    // future second caller from overwriting live custody. What was deleted is the arm that WAS
    // reachable and wrong: testing `pendingReturns.exists` fired on SENT entries — items already handed
    // off — and that is the whole of CR-2026-08-04-M1.
    if (nftHeldOnSide(assets, nft) || pendingReturnHeld(assets, nft)) {
        return;
    }
    assets
        .pendingReturns
        .set(
            nft,
            PendingReturn {
                target,
                status: initialStatus,
            },
        );
}

// H-1: a bounced return needs the same reserve budget as any other NFT send, so RetryPending can size
// its gas. Counts only BOUNCED entries — the ones a retry will actually re-send.
fun pendingReturnResendCount(pendingReturns: map<address, PendingReturn>): int {
    var count = 0;
    var entry = pendingReturns.findFirst();
    while (entry.isFound) {
        if (entry.loadValue().status == NFT_STATUS_TRANSFER_BOUNCED) {
            count += 1;
        }
        entry = pendingReturns.iterateNext(entry);
    }
    return count;
}

// V5-2: does this escrow still owe an asset to somebody? Both lanes count — a side entry the escrow
// still has to send (DEPOSITED or a bounced settlement/refund), and a bounced pending return awaiting
// RetryPending. Either way the escrow is holding a real NFT that only a contract call can move.
//
// Deliberately keyed on OBLIGATIONS, not on status. Gating SweepDust on `SETTLE_STUCK` would be the
// obvious-looking check and would be wrong: a stuck settlement whose force-resolve returns all landed
// owes nothing, and refusing to sweep it forever is exactly the permanent balance lock that
// `isTerminalStatus` documents as the reason SETTLE_STUCK is terminal in the first place. An
// obligation is always clearable, and RetryPending — the action that clears it — is permissionless,
// so this can never strand a balance that someone wants to release.
fun hasOutstandingObligations(assets: TradeAssets): bool {
    return totalPendingNftCount(assets) > 0 || pendingReturnResendCount(assets.pendingReturns) > 0;
}

// H-1: the return leg of onBouncedMessage — flip a bounced pending-return to BOUNCED so RetryPending
// re-sends it. Returns true if `nft` was a pending return (so the bounce is handled here, not on a side).
//
// V5-1: `existing.target` is PRESERVED rather than recomputed, and that is only safe because of the
// guard above. A bounce carries just the item address — there is no new target to write — so this
// function has to trust the ledger. Before V5-1 it could not: a re-deposit by a new owner was skipped
// by the guard, leaving the first depositor's target in place, and the next RetryPending shipped the
// item to a stranger (CR-2026-08-04-M1 scenario B). Now every deposit that finds no held custody
// overwrites the entry, so what is preserved here is always the current episode's depositor.
//
// The overwrite cannot race this flip. An entry is only overwritable while it is SENT — i.e. while the
// escrow holds nothing — and a bounce that flips a SENT entry comes from a transfer whose ownership
// never moved, so the item could not have been passed on and re-deposited in the interval.
fun markBouncedReturn(mutate assets: TradeAssets, nft: address): bool {
    if (!assets.pendingReturns.exists(nft)) {
        return false;
    }
    val existing = assets.pendingReturns.mustGet(nft);
    if (existing.status == NFT_STATUS_TRANSFER_SENT) {
        assets
            .pendingReturns
            .set(
                nft,
                PendingReturn {
                    target: existing.target,
                    status: NFT_STATUS_TRANSFER_BOUNCED,
                },
            );
    }
    return true;
}

// H-1 / V4-9: re-send a bounced pending return, escrow-funded like any other retry, but carrying the
// return lane's reserved queryId so its OWN bounce is attributable. Reusing transferNft here (as v3 did)
// would stamp a settlement-lane queryId on a return and re-enter the exact ambiguity V4-9 removes.
// responseDestination stays the escrow because the escrow — not the depositor — is funding this send.
fun resendReturnNft(nft: address, previousOwner: address) {
    createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: NFT_TRANSFER_VALUE,
        dest: nft,
        body: NftTransfer {
            queryId: NFT_RETURN_QUERY_ID,
            newOwner: previousOwner,
            responseDestination: contract.getAddress(),
            customPayload: false,
            forwardAmount: 1,
            forwardPayload: false,
        },
    }).send(SEND_MODE_PAY_FEES_SEPARATELY);
}

// H-1: re-send every bounced pending return to its depositor, escrow-funded like any other retry (safe:
// only authenticated items are ever recorded, and the target is the item-set prevOwner). Reserve is
// asserted by the caller against the combined count.
fun resendBouncedReturns(mutate assets: TradeAssets) {
    var entry = assets.pendingReturns.findFirst();
    while (entry.isFound) {
        val nft = entry.getKey();
        val pr = entry.loadValue();
        if (pr.status == NFT_STATUS_TRANSFER_BOUNCED) {
            resendReturnNft(nft, pr.target);
            assets
                .pendingReturns
                .set(
                    nft,
                    PendingReturn {
                        target: pr.target,
                        status: NFT_STATUS_TRANSFER_SENT,
                    },
                );
        }
        entry = assets.pendingReturns.iterateNext(entry);
    }
}

fun refundAll(mutate storage: TradeEscrowStorage, inValue: coins) {
    var assets = storage.assets.load();
    val participants = storage.participants.load();
    assertNftTransferReserve(inValue, totalPendingNftCount(assets));

    storage.status = TRADE_STATUS_REFUNDING;
    // Stamp the moment the trade left OPEN. Refunds always target the depositor, so a permanently
    // rejecting NFT just keeps RetryPending-able here (no escape needed) — the stamp is recorded for
    // symmetry and getState observability only.
    storage.statusChangedAt = blockchain.now() as uint32;

    sendTon(participants.userA, storage.depositedTonA);
    sendTon(participants.userB, storage.depositedTonB);
    transferPendingNfts(mutate assets.nftA, participants.userA);
    transferPendingNfts(mutate assets.nftB, participants.userB);

    storage.assets = assets.toCell();
    storage.status = TRADE_STATUS_REFUNDED;
    // L-01: zero the deposit fields so getState() is unambiguous after refund.
    storage.depositedTonA = 0;
    storage.depositedTonB = 0;
    storage.save();
}

fun completeTrade(mutate storage: TradeEscrowStorage, inValue: coins) {
    var assets = storage.assets.load();
    val participants = storage.participants.load();
    val feeA = tradeFee(storage.depositedTonA);
    val feeB = tradeFee(storage.depositedTonB);
    assertNftTransferReserve(inValue, totalPendingNftCount(assets));

    storage.status = TRADE_STATUS_SETTLING;
    // H-01: stamp when settlement began. The stuck-settlement escape is gated on
    // now() >= statusChangedAt + STUCK_SETTLEMENT_TIMEOUT. Retries/bounces never touch this, so the
    // clock runs from the first settlement attempt and cannot be reset by a griefer.
    storage.statusChangedAt = blockchain.now() as uint32;

    sendTon(participants.userA, storage.depositedTonB - feeB);
    sendTon(participants.userB, storage.depositedTonA - feeA);
    sendTon(storage.feeRecipient, feeA + feeB);
    transferPendingNfts(mutate assets.nftA, participants.userB);
    transferPendingNfts(mutate assets.nftB, participants.userA);

    storage.assets = assets.toCell();
    storage.status = TRADE_STATUS_COMPLETED;
    // L-01: zero the deposit fields so getState() is unambiguous after settlement — a non-zero
    // depositedTonA on a COMPLETED trade otherwise looks like funds are still held.
    storage.depositedTonA = 0;
    storage.depositedTonB = 0;
    storage.save();
}

// Unified RetryPending handler. Re-sends whatever is still pending:
//   - the status-specific side-NFT retry (settlement swap / refund-to-depositor / stuck-return), and
//   - v3 H-1: any bounced pending return, in EVERY status (a late deposit's return can be outstanding on
//     a trade that is OPEN, terminal, or anything between).
// The gas reserve is asserted once against the COMBINED count so a single message funds both. Side
// retries are only meaningful in the settlement/refund/stuck statuses; an OPEN trade is retry-eligible
// only when it actually has a bounced return to flush (otherwise there is nothing to do → InvalidMessage,
// preserving the prior "cannot RetryPending an OPEN trade" behaviour).
fun retryPendingAll(mutate storage: TradeEscrowStorage, inValue: coins) {
    var assets = storage.assets.load();
    val participants = storage.participants.load();
    val status = storage.status;

    val statusEligible = isStuckStatus(status) || isSettlementStatus(status) ||
    isRefundStatus(status);
    val sideCount = statusEligible ? totalPendingNftCount(assets) : 0;
    val returnCount = pendingReturnResendCount(assets.pendingReturns);
    assert (statusEligible || returnCount > 0) throw TradeErrors.InvalidMessage;
    assertNftTransferReserve(inValue, sideCount + returnCount);

    if (isStuckStatus(status)) {
        // Re-attempt the depositor returns for a SETTLE_STUCK trade; status stays terminal.
        transferPendingNfts(mutate assets.nftA, participants.userA);
        transferPendingNfts(mutate assets.nftB, participants.userB);
    } else if (isSettlementStatus(status)) {
        storage.status = TRADE_STATUS_SETTLING;
        transferPendingNfts(mutate assets.nftA, participants.userB);
        transferPendingNfts(mutate assets.nftB, participants.userA);
        storage.status = TRADE_STATUS_COMPLETED;
    } else if (isRefundStatus(status)) {
        storage.status = TRADE_STATUS_REFUNDING;
        transferPendingNfts(mutate assets.nftA, participants.userA);
        transferPendingNfts(mutate assets.nftB, participants.userB);
        storage.status = TRADE_STATUS_REFUNDED;
    }

    resendBouncedReturns(mutate assets);
    storage.assets = assets.toCell();
    storage.save();
}

// H-01: permissionless, timeout-gated escape from a permanently-stuck settlement.
//
// When an NFT's item contract permanently rejects the settlement transfer to the counterparty, the
// transfer bounces, the trade reverts COMPLETED -> SETTLING, and RetrySettlement keeps re-sending to
// the same rejecting destination forever — the NFT is locked with no recovery, even though the TON
// was already distributed. After STUCK_SETTLEMENT_TIMEOUT from the first settlement attempt, anyone
// may call this to return each side's still-held NFTs to *their own depositor* (a destination
// RetrySettlement never tries) and move the trade to the terminal TRADE_STATUS_SETTLE_STUCK.
//
// Safety properties:
//   - Status must be exactly SETTLING. A clean COMPLETED trade (no bounce) can never be force-resolved,
//     so this cannot disturb a successful settlement. OPEN/REFUNDING/SETTLE_STUCK are likewise rejected.
//   - Permissionless is safe: the only action is returning NFTs to the address that deposited them,
//     which harms no party that the non-transferable NFT had not already harmed. The timeout — not an
//     admin key — is the safety gate, so there is no trusted operator and no liveness dependency.
//   - TON is NOT touched (it was distributed by completeTrade); only NFTs move.
//   - Reserve-gated like every other NFT-sending action.
fun forceResolveStuckSettlement(mutate storage: TradeEscrowStorage, inValue: coins) {
    assert (storage.status == TRADE_STATUS_SETTLING) throw TradeErrors.TradeNotStuck;
    assert (
        blockchain.now() >= storage.statusChangedAt + STUCK_SETTLEMENT_TIMEOUT
    ) throw TradeErrors.StuckTimeoutNotReached;

    var assets = storage.assets.load();
    val participants = storage.participants.load();
    assertNftTransferReserve(inValue, totalPendingNftCount(assets));

    // Return each side's still-held NFTs to that side's depositor (nftA -> userA, nftB -> userB).
    transferPendingNfts(mutate assets.nftA, participants.userA);
    transferPendingNfts(mutate assets.nftB, participants.userB);

    storage.assets = assets.toCell();
    storage.status = TRADE_STATUS_SETTLE_STUCK;
    storage.save();
}

// M-03: permissionless, timeout-gated refund of an abandoned OPEN trade.
//
// Either participant can already `CancelTrade` an OPEN trade, so this only matters when *no* live party
// remains — both ghost, or a depositor loses their key and the counterparty never appears — leaving the
// deposited TON and NFTs locked forever. After `OPEN_TRADE_TIMEOUT` of inactivity (`lastActivityAt` is
// reset on every participant deposit/accept), anyone may refund everything to its depositors.
//
// Safety properties:
//   - Must be OPEN (assertOpen) — cannot touch a settling/refunding/closed trade.
//   - `lastActivityAt == 0` (no deposit ever happened) is *not* expirable: an empty freshly-created
//     trade has nothing to recover and must not be closable out from under its participants.
//   - Any participant action pushes the deadline out, so an active trade is never force-expired.
//   - Permissionless is safe: the only action is `refundAll`, which returns assets to their depositors.
//   - Reserve-gated via `refundAll`.
fun expireTrade(mutate storage: TradeEscrowStorage, inValue: coins) {
    assertOpen(storage);
    assert (
        storage.lastActivityAt != 0 &&
        blockchain.now() >= storage.lastActivityAt + OPEN_TRADE_TIMEOUT
    ) throw TradeErrors.TradeNotExpired;
    refundAll(mutate storage, inValue);
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    val msg = lazy EscrowMessage.fromSlice(in.body);

    match (msg) {
        DepositTon => {
            var storage = lazy TradeEscrowStorage.load();
            assertOpen(storage);
            assertParticipant(storage, in.senderAddress);
            assert (in.valueCoins > MIN_TRADE_ACTION_VALUE) throw TradeErrors.EmptyTonDeposit;
            val depositAmount = in.valueCoins - MIN_TRADE_ACTION_VALUE;

            if (isUserA(storage, in.senderAddress)) {
                assert (!storage.acceptedA) throw TradeErrors.SideAlreadyAccepted;
                storage.depositedTonA += depositAmount;
            } else {
                assert (!storage.acceptedB) throw TradeErrors.SideAlreadyAccepted;
                storage.depositedTonB += depositAmount;
            }

            storage.lastActivityAt = blockchain.now() as uint32; // M-03: reset the abandonment clock
            storage.save();
        }
        OwnershipAssigned => {
            var storage = lazy TradeEscrowStorage.load();
            var assets = storage.assets.load();

            val nft = in.senderAddress;
            val prevOwner = msg.prevOwner;

            // Happy path: an OPEN trade records an authenticated deposit onto its depositor's side.
            // C-01/H-03: tryRecordDeposit recomputes the sender's expected TEP-62 item address from the
            // allowlisted collection + schema-width index in the forward payload and requires a match, so
            // a forged notification can never seed a phantom asset. A successful deposit sends no outgoing
            // message, so no value floor applies — a valid deposit forwarding below MIN_NFT_FORWARD_VALUE
            // is recorded, not stranded (v2 H-1).
            if (
                storage.status == TRADE_STATUS_OPEN &&
                tryRecordDeposit(mutate storage, mutate assets, nft, prevOwner, msg.forwardPayload)
            ) {
                storage.assets = assets.toCell();
                storage.lastActivityAt = blockchain.now() as uint32; // M-03: reset the abandonment clock
                storage.save();
                return;
            }

            // The deposit cannot join the trade: it arrived after OPEN (M-08 late deposit), or it is
            // authenticated but unrecordable (side accepted/full, duplicate, or a genuine item whose
            // prevOwner is not a participant), or it is forged. Each is returned to its sender, funded
            // only from the inbound value (mode 64, never escrow balance — C-03).
            //
            // v3 H-1: a GENUINE item's ownership has really moved to the escrow (OwnershipAssigned is
            // non-bounceable), and its inbound-funded return can itself bounce — so record it as a
            // recoverable pending return BEFORE attempting the return. If the inbound value is below the
            // floor we cannot fund the return now, so record it as BOUNCED (needing retry) and let the
            // escrow-funded RetryPending re-send it later, instead of reverting-and-stranding it (M-4).
            // A FORGED notification moved no real asset, so it is never recorded (recording it would
            // reopen the C-03 drain vector) and is returned best-effort behind the floor gate.
            if (isAuthenticNftDeposit(storage, nft, msg.forwardPayload)) {
                val canReturnNow = in.valueCoins >= MIN_NFT_FORWARD_VALUE;
                recordPendingReturn(
                    mutate assets,
                    nft,
                    prevOwner,
                    canReturnNow ? NFT_STATUS_TRANSFER_SENT : NFT_STATUS_TRANSFER_BOUNCED,
                );
                storage.assets = assets.toCell();
                storage.save();
                if (canReturnNow) {
                    returnNft(nft, prevOwner);
                }
                return;
            }

            assertReturnFunded(in.valueCoins);
            returnNft(nft, prevOwner);
        }
        AcceptTrade => {
            var storage = lazy TradeEscrowStorage.load();
            assertOpen(storage);
            assertParticipant(storage, in.senderAddress);
            assert (
                in.valueCoins >= MIN_TRADE_ACTION_VALUE
            ) throw TradeErrors.InsufficientMessageValue;

            // Every recorded NFT is already DEPOSITED (deposits are authenticated and recorded
            // synchronously in OwnershipAssigned), so accepting can never lock in an asset the
            // escrow does not yet hold.
            if (isUserA(storage, in.senderAddress)) {
                assert (!storage.acceptedA) throw TradeErrors.SideAlreadyAccepted;
                storage.acceptedA = true;
            } else {
                assert (!storage.acceptedB) throw TradeErrors.SideAlreadyAccepted;
                storage.acceptedB = true;
            }

            if (storage.acceptedA && storage.acceptedB) {
                completeTrade(mutate storage, in.valueCoins);
            } else {
                storage.lastActivityAt = blockchain.now() as uint32; // M-03: reset abandonment clock
                storage.save();
            }
        }
        CancelTrade => {
            var storage = lazy TradeEscrowStorage.load();
            assertOpen(storage);
            assertParticipant(storage, in.senderAddress);
            assert (
                in.valueCoins >= MIN_TRADE_ACTION_VALUE
            ) throw TradeErrors.InsufficientMessageValue;
            refundAll(mutate storage, in.valueCoins);
        }
        SweepDust => {
            val storage = lazy TradeEscrowStorage.load();
            // V5-7: sweeping is restricted to the two participants and the fee recipient — the party
            // the balance is sent to anyway, and the factory owner at creation time. L-02 accepted a
            // permissionless sweep as griefing-only because "the caller pays", which accounts for the
            // gas but not the consequence: the sweep empties the escrow to its rent runway, and the
            // timing of that is nobody else's decision. Checked before anything else so an
            // unauthorised caller never even loads the assets cell.
            assert (
                isUserA(storage, in.senderAddress) || isUserB(storage, in.senderAddress) ||
                in.senderAddress == storage.feeRecipient
            ) throw TradeErrors.NotParticipant;
            assert (isTerminalStatus(storage.status)) throw TradeErrors.TradeNotClosed;
            // V5-2: independent of the V5-7 check above, and still needed after it. Permissioning
            // removed the stranger; it did not remove the mistake. A participant or the operator can
            // still take a terminal escrow down to MIN_ESCROW_DUST_RESERVE while it holds someone's
            // NFT — and the operator is the party with a standing reason to sweep. That reserve is
            // the escrow's remaining storage-rent runway, and an account frozen for unpaid rent
            // cannot execute, which would make RetryPending and ForceResolveStuck uncallable and the
            // held item permanently unrecoverable.
            assert (
                !hasOutstandingObligations(storage.assets.load())
            ) throw TradeErrors.EscrowHasObligations;
            val amount = sweepableBalance(in.valueCoins, MIN_ESCROW_DUST_RESERVE);
            assert (amount > 0) throw TradeErrors.NothingToSweep;
            sendTon(storage.feeRecipient, amount);
            sendTon(in.senderAddress, in.valueCoins);
        }
        RetryPending => {
            var storage = lazy TradeEscrowStorage.load();
            retryPendingAll(mutate storage, in.valueCoins);
        }
        ForceResolveStuck => {
            var storage = lazy TradeEscrowStorage.load();
            forceResolveStuckSettlement(mutate storage, in.valueCoins);
        }
        ExpireTrade => {
            var storage = lazy TradeEscrowStorage.load();
            expireTrade(mutate storage, in.valueCoins);
        }
        else => {
            assert (in.body.isEmpty()) throw TradeErrors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    val (isNftTransferBounce, queryId) = parseNftTransferBounce(in.bouncedBody);
    if (!isNftTransferBounce) {
        return;
    }

    var storage = lazy TradeEscrowStorage.load();
    var assets = storage.assets.load();

    // V4-9: route by WHICH MESSAGE bounced, not by which item it concerns. The previous code asked the
    // side ledger first and `markBouncedNft` matched any item ever recorded on a side regardless of
    // status, so the return lane was unreachable for anything that had traded — a bounced return of a
    // settled item was booked as a failed settlement and re-opened a terminal trade (CR-2026-07-29-M2).
    if (queryId == NFT_RETURN_QUERY_ID) {
        // v3 H-1: a pending return bounced. Flip it to BOUNCED so RetryPending re-sends it. This is
        // independent of settlement, so — unlike a side-NFT bounce — it never reopens the trade status.
        if (markBouncedReturn(mutate assets, in.senderAddress)) {
            storage.assets = assets.toCell();
            storage.save();
        }
        return;
    }

    if (markBouncedNft(mutate assets, in.senderAddress)) {
        storage.assets = assets.toCell();
        reopenStatusAfterNftBounce(mutate storage);
        storage.save();
    }
}

get fun getState(): TradeState {
    val storage = lazy TradeEscrowStorage.load();
    val assets = storage.assets.load();
    val participants = storage.participants.load();
    return {
        tradeId: storage.tradeId,
        factory: storage.factory,
        feeRecipient: storage.feeRecipient,
        userA: participants.userA,
        userB: participants.userB,
        acceptedA: storage.acceptedA,
        acceptedB: storage.acceptedB,
        depositedTonA: storage.depositedTonA,
        depositedTonB: storage.depositedTonB,
        nftCountA: assets.nftCountA,
        nftCountB: assets.nftCountB,
        pendingNftCount: totalPendingNftCount(assets),
        status: storage.status,
        statusChangedAt: storage.statusChangedAt,
        lastActivityAt: storage.lastActivityAt,
        completed: storage.status == TRADE_STATUS_COMPLETED,
        cancelled: storage.status == TRADE_STATUS_REFUNDED,
        stuck: isStuckStatus(storage.status),
        // v3 H-1: bounced returns still awaiting a RetryPending re-send. Independent of `status`.
        pendingReturnCount: pendingReturnResendCount(assets.pendingReturns) as uint16,
    };
}

// v3 H-1: full pending-return ledger (item -> {depositor, status}) for the indexer/UI. A non-empty
// map with a BOUNCED entry signals an item the escrow holds that still needs returning via RetryPending.
get fun getPendingReturns(): map<address, PendingReturn> {
    val storage = lazy TradeEscrowStorage.load();
    return storage.assets.load().pendingReturns;
}

get fun getNftsA(): map<address, bool> {
    val storage = lazy TradeEscrowStorage.load();
    return nftAddressSet(storage.assets.load().nftA);
}

get fun getNftsB(): map<address, bool> {
    val storage = lazy TradeEscrowStorage.load();
    return nftAddressSet(storage.assets.load().nftB);
}

get fun getNftStatusesA(): map<address, uint8> {
    val storage = lazy TradeEscrowStorage.load();
    return storage.assets.load().nftA;
}

get fun getNftStatusesB(): map<address, uint8> {
    val storage = lazy TradeEscrowStorage.load();
    return storage.assets.load().nftB;
}

// I-05: numeric code version so the indexer can route by version after a code upgrade.
get fun getVersion(): uint16 {
    return CONTRACT_VERSION;
}
