// Copyright (C) 2026 MENA
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later
// variant:begin
// SwapEscrowV2 — escrow swap contract for TON with a supervisor role:
// NFT, GRAM and Jetton deposits. Outside the supervisor blocks it is
// SwapEscrowNosup line for line, except the marked variant regions
// (ts-tests/v2-sync.test.ts).
// variant:end

// variant:begin
import "@acton/tolk-stdlib/gas-payments"
import "messages"
import "shared/accounting"
import "shared/messages"
import "shared/types"
import "v2/accounting"
import "v2/messages"
import "v2/storage"

contract SwapEscrowV2 {
    author: "MENA"
    version: "2.0.0-beta"
    description: "Escrow swap with a supervisor: NFT + GRAM + Jetton deposits"
    storage: Storage
    incomingMessages: EscrowInMessage
}

// variant:end

// Whether a text command equals `expected`. Tolk does not coerce a string
// literal to slice, so `expected` is a string, and both sides are compared by
// slice.hash() (a representation hash of the content). string.hash() is a
// different algorithm (FNV-1a) and must not be mixed with it.
fun textCmdIs(cmd: slice, expected: string): bool {
    return cmd.hash() == expected.beginParse().hash();
}

// `InMessage` cannot be passed around as a value (its fields map to TVM
// instructions), so the router hands each handler the fields it needs —
// `senderAddress` and `valueCoins` — as plain parameters.
fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        handlePlainTransfer(in.senderAddress, in.valueCoins);
        return;
    }
    val op = in.body.preloadUint(32);
    if (op == 0) {
        var cmd = in.body;
        cmd.skipBits(32);
        handleTextCommand(in.senderAddress, in.valueCoins, cmd);
        return;
    }
    val msg = lazy EscrowInMessage.fromSlice(in.body);
    match (msg) {
        OwnershipAssigned => {
            handleNftReceived(in.senderAddress, in.valueCoins, msg);
        }
        TakeWalletAddressNosup => {
            handleTakeWalletAddress(in.senderAddress, in.valueCoins, msg);
        }
        JettonTransferNotification => {
            handleJettonNotification(in.senderAddress, in.valueCoins, msg);
        }
        Excesses => {
            // leftover gas from a jetton wallet (if someone set the escrow as
            // responseDestination) — silently credited to the balance; NOT
            // 0xFFFF, or a legitimate excesses message would get bounced
        }
        ContinueDistribution => {
            handleContinueDistribution(in.senderAddress);
        }
        ClaimAsset => {
            handleClaimAsset(in.senderAddress, in.valueCoins, msg);
        }
        AcceptDeal => {
            handleAcceptDeal(in.senderAddress, in.valueCoins, msg);
        }
        // sup:begin
        SupervisorAssetReceived => {
            handleSupervisorAssetReceived(in.senderAddress, in.valueCoins, msg);
        }
        RescueNft => {
            handleRescueNft(in.senderAddress, in.valueCoins, msg);
        }
        RescueJetton => {
            handleRescueJetton(in.senderAddress, in.valueCoins, msg);
        }
        ForceDeliver => {
            handleForceDeliver(in.senderAddress, in.valueCoins, msg);
        }
        // sup:end
        else => {
            throw Errors.UnknownOp;
        }
    }
}

// Text commands — part of the wire protocol integrators depend on
fun handleTextCommand(sender: address, value: coins, cmd: slice) {
    if (textCmdIs(cmd, "deploy_fee")) {
        handleDeployFee(sender, value);
        return;
    }
    if (textCmdIs(cmd, "deposit_ton1")) {
        handleDepositGram(sender, value, 1);
        return;
    }
    if (textCmdIs(cmd, "deposit_ton2")) {
        handleDepositGram(sender, value, 2);
        return;
    }
    if (textCmdIs(cmd, "service_fee_owner1")) {
        handleServiceFee(sender, value, 1);
        return;
    }
    if (textCmdIs(cmd, "service_fee_owner2")) {
        handleServiceFee(sender, value, 2);
        return;
    }
    if (textCmdIs(cmd, "execute_swap")) {
        handleExecuteSwap(sender, value);
        return;
    }
    if (textCmdIs(cmd, "cancel_swap")) {
        handleCancelSwap(sender, value);
        return;
    }
    if (textCmdIs(cmd, "kick")) {
        handleKick(sender, value);
        return;
    }
    // sup:begin
    if (textCmdIs(cmd, "emergency_collect_assets")) {
        handleEmergencyCollect(sender, value);
        return;
    }
    if (textCmdIs(cmd, "emergency_return_assets")) {
        handleEmergencyReturn(sender, value);
        return;
    }
    if (textCmdIs(cmd, "emergency_withdraw_ton")) {
        handleEmergencyWithdraw(sender, value);
        return;
    }
    // sup:end
    // Unknown text command -> exit 130; part of the wire contract
    throw 130;
}

// Single point for computing the gas reserve for a distribution of `sends`
// transfers. GETGASFEE includes a flat price component (the first
// flat_gas_limit units) — one call over the TOTAL units, rather than `sends`
// separate calls: the flat component is counted once, so the result is ≥ the
// linear estimate (the margin errs on the safe side).
fun execGasReserve(sends: int): coins {
    return calculateGasFee(BASECHAIN, EXEC_GAS_UNITS_BASE + EXEC_GAS_UNITS_PER_SEND * sends);
}

// Value of the self-addressed continue message: the gas it must buy plus its
// own forwarding fee (mode 0 takes the fee out of the value).
fun continueMsgValue(): coins {
    return calculateGasFee(BASECHAIN, CONTINUE_GAS_UNITS) + calculateForwardFee(BASECHAIN, 1023, 1);
}

// The smallest amount a plain message can safely carry: two forward fees. A
// refund goes out in mode 0 and pays its own forwarding out of its value: a
// plain message with no body costs the lump price
// (calculateForwardFee(BASECHAIN, 0, 0), measured 66,667 nanoton), so an
// amount below that fails the whole action phase (result code 37) and aborts
// the transaction that carries it. Two forward fees, because the cancel
// finale splits its leftover in halves that must each pay their own
// forwarding. The cancel's initiating transaction uses this bound for its
// refunds and surplus (pinned in tests/nosup/cancel_refund_min.test.tolk).
fun sendableMinimum(): coins {
    return calculateForwardFee(BASECHAIN, 0, 0) * 2;
}

// The smallest refund worth a message of its own on execute and in the cancel
// finale. Amounts up to DUST (22x sendableMinimum today) are not worth a
// message and go to the fee wallet with the sweep; the larger of the two
// bounds holds if forward prices rise. Pinned in
// tests/nosup/storage_floor.test.tolk (cancel finale) and
// tests/nosup/execute_refund_min.test.tolk (execute).
fun refundMinimum(): coins {
    val sendable = sendableMinimum();
    return sendable > DUST ? sendable : DUST;
}

// Gas for the batch chain beyond its first transaction, by the work it does:
// a base per batch, plus walking past every entry that is not sent. Sends are
// priced separately (execGasReserve on execute; the per-send term in
// quoteCancel on cancel). On cancel the walk of the first batch is also inside
// the initiating transaction's units, so it is counted twice: at most
// CONTINUE_GAS_UNITS, on the safe side. A chain limited by sends needs
// ceil(sends / BATCH_MAX_SENDS) batches; one limited by skipping needs as many
// as the walk takes at BATCH_GAS_SOFT_CAP per batch. No chain for <= 100.
fun batchChainReserve(registrySize: int, sends: int): coins {
    if (registrySize <= FAST_PATH_MAX_ASSETS) {
        return 0;
    }
    val walkUnits = SKIP_GAS_UNITS_PER_ENTRY * (registrySize - sends);
    // ceiling divisions: the batch COUNT times the per-batch base is the
    // intended arithmetic.
    // check-disable-next-line divide-before-multiply
    val batches = (sends + BATCH_MAX_SENDS - 1) / BATCH_MAX_SENDS +
        (walkUnits + BATCH_GAS_SOFT_CAP - 1) / BATCH_GAS_SOFT_CAP;
    return calculateGasFee(BASECHAIN, BATCH_EXTRA_GAS_UNITS * batches + walkUnits);
}

// Messages execution sends besides the assets: fee wallet, refund1, refund2
// and one per TON leg.
fun numExtraSends(g: GramState): int {
    var numExtra = 3;
    if (g.gram1Amount > 0) {
        numExtra += 1;
    }
    if (g.gram2Amount > 0) {
        numExtra += 1;
    }
    return numExtra;
}

// Gas units the execution transaction itself may use; gasReserveForSwap
// prices exactly these units, so the reserve and the gas limit set from it
// cannot drift apart.
fun Storage.executionGasUnits(self, g: GramState): int {
    return EXEC_GAS_UNITS_BASE +
        EXEC_GAS_UNITS_PER_SEND * ((self.assetsCount as int) + numExtraSends(g));
}

// The gas-reserve and minimum-balance formulas are computed from the deal's
// PARAMETERS (gram1Amount/gram2Amount from GramState, assetsCount), never
// from the current received counters. This is deliberate: a threshold derived
// from what has arrived so far would drift as deposits come in, so the same
// deposit could pass or fail depending on ordering.
fun Storage.gasReserveForSwap(self, g: GramState): coins {
    val totalNfts = self.assetsCount as int;
    var reserve = calculateGasFee(BASECHAIN, self.executionGasUnits(g));
    // Execution sends every asset, so nothing is skipped: sends == registrySize.
    reserve += batchChainReserve(totalNfts, totalNfts);
    return reserve;
}

// The cost must be split by asset kind, not priced uniformly. Jetton assets
// are pricier to send than NFTs (JETTON_TRANSFER_VALUE = 0.05 against 0.03,
// because a jetton takes two hops: our wallet -> internal_transfer -> the
// recipient's wallet). Pricing every asset at the NFT rate makes
// `explicitOut`/`minBalanceForSwap` underestimate the real distribution cost,
// and a jetton deal then aborts its execution cascade with
// action_result_code=37 ("Not enough Toncoin") — pinned by the
// overpaymentOnFinalDepositStillExecutes test. For pure-NFT deals
// (jettonsCount == 0) this reduces to NFT_TRANSFER_VALUE * assetsCount.
fun Storage.assetTransferCost(self): coins {
    val jettons = self.jettonsCount as int;
    val nfts = (self.assetsCount as int) - jettons;
    return NFT_TRANSFER_VALUE * nfts + JETTON_TRANSFER_VALUE * jettons;
}

fun Storage.minBalanceForSwap(self, g: GramState): coins {
    return g.gram1Amount + g.gram2Amount + SERVICE_FEE * 2 + self.assetTransferCost() +
        self.sharedCosts(g);
}

// What the deal spends that belongs to neither side alone: execution gas, the
// dust margin and a year of storage. Shared equally.
fun Storage.sharedCosts(self, g: GramState): coins {
    return self.gasReserveForSwap(g) + DUST + self.storageFloor();
}

// One year of storage fees for this deal's state, modelled from the registry
// size (see STORAGE_FLOOR_SECONDS). A settled escrow keeps this much on its
// balance so it does not freeze while claim_asset may still be needed.
fun Storage.storageFloor(self): coins {
    val n = self.assetsCount as int;
    // variant:begin
    // SwapEscrowV2's state is larger: its code and the supervisor's cell.
    val baseCells = STORAGE_CELLS_BASE + SUP_STORAGE_CELLS;
    // variant:end
    return calculateStorageFee(
        BASECHAIN,
        STORAGE_FLOOR_SECONDS,
        STORAGE_BITS_BASE + STORAGE_BITS_PER_ASSET * n,
        baseCells + STORAGE_CELLS_PER_ASSET * n,
    );
}

// What `side` must have paid before the deal can execute: its TON leg, its
// service fee, the transfer of its own assets and half of the shared costs.
// The two shares sum to minBalanceForSwap; side 2 takes the odd nanoton.
fun Storage.sideShare(self, g: GramState, side: int, ownCost: coins): coins {
    val shared = self.sharedCosts(g);
    val half: coins = side == 1 ? shared / 2 : shared - shared / 2;
    val leg = side == 1 ? g.gram1Amount : g.gram2Amount;
    return leg + SERVICE_FEE + ownCost + half;
}

// Uses the received counters, so only meaningful once every asset has arrived
// (canAutoExecute and execute_swap check that first).
fun Storage.sideFunded(self, g: GramState, side: int): bool {
    return paidBy(g, side) >= self.sideShare(g, side, self.ownTransferCost(side));
}

// The per-side counters include deposit gas (credited gross), so they can say
// "funded" while the balance is short; this check is what guarantees the
// action phase can pay for everything execution sends.
fun Storage.balanceCovers(self, g: GramState, committedOut: coins): bool {
    return contract.getOriginalBalance() - committedOut >= self.minBalanceForSwap(g);
}

// contract.getOriginalBalance() (common.tolk:363) — the contract's balance
// at the start of this transaction's Computation Phase, i.e. BEFORE this
// same transaction's gas is deducted — i.e. it includes the incoming
// message's attached value but not this message's own processing cost.
fun Storage.canAutoExecute(self, committedOut: coins): bool {
    if (self.phase != PHASE_ACTIVE) {
        return false;
    }
    if (self.received1Count < self.required1Count) {
        return false;
    }
    if (self.received2Count < self.required2Count) {
        return false;
    }
    val g = self.grams.load();
    if (g.gram1Received < g.gram1Amount) {
        return false;
    }
    if (g.gram2Received < g.gram2Amount) {
        return false;
    }
    if (g.serviceFee1 < SERVICE_FEE) {
        return false;
    }
    if (g.serviceFee2 < SERVICE_FEE) {
        return false;
    }
    if (!self.sideFunded(g, 1) || !self.sideFunded(g, 2)) {
        return false;
    }
    return self.balanceCovers(g, committedOut);
}

// ── Fast-path / batch-path gate ──
// Deals of up to FAST_PATH_MAX_ASSETS (100) assets are distributed in a
// single transaction (executeSwapSingleTx below). Larger deals switch to
// EXECUTING and are distributed in batches through the self-trigger chain.
fun Storage.executeSwap(mutate self, committedOut: coins) {
    if ((self.assetsCount as int) <= FAST_PATH_MAX_ASSETS) {
        // Small deal: the single-transaction path.
        self.executeSwapSingleTx(committedOut);
        return;
    }
    // Large deal: point of no return — EXECUTING, batches.
    self.phase = PHASE_EXECUTING;
    self.dist = DistState {
        mode: DIST_EXECUTE,
        cursor: 0,
    }.toCell();
    self.runDistributionBatch(committedOut);
}

// ── Recipient addressing and sending a single asset ──
// The recipient (dest) and responseDestination of an asset transfer, based
// on the delivery mode. For a jetton, excesses go to the jetton recipient;
// for an NFT in execute, they go to the previous owner.
fun Storage.assetRecipient(self, a: Asset, mode: int): (address, address) {
    // sup:begin
    if (mode == DIST_COLLECT) {
        val supervisor = self.sup.load().supervisor;
        return (supervisor, supervisor);
    }
    // sup:end
    if (mode == DIST_EXECUTE) {
        val newOwner = a.ownerSide == 1 ? self.owner2 : self.owner1;
        val resp = a.kind == 1 ? newOwner : (a.ownerSide == 1 ? self.owner1 : self.owner2);
        return (newOwner, resp);
    }
    // DIST_CANCEL: to the depositor
    val backTo = a.ownerSide == 1 ? self.owner1 : self.owner2;
    return (backTo, backTo);
}

fun sendAsset(a: Asset, idx: int, dest: address, resp: address) {
    if (a.kind == 1) {
        sendJettonTransfer(
            a.jettonWallet!,
            idx,
            a.amount,
            dest,
            resp,
            JETTON_TRANSFER_VALUE,
            SEND_MODE_REGULAR,
        );
    } else {
        sendNftTransfer(
            a.addr,
            idx,
            dest,
            resp,
            NFT_TRANSFER_VALUE,
            SEND_MODE_REGULAR,
        );
    }
}

// ── One delivery batch ──
// Walks the registry with a cursor and sends every received asset to the
// current mode's recipient. Progress is written with a SINGLE write to the
// dist cell per batch. A bounced delivery never stalls the chain: the bounce
// handler marks the asset claimable and its recipient pulls it with
// claim_asset.
//
// FINALIZATION — ONLY AS A SEPARATE TRANSACTION WITH NO ASSET SENDS.
// If THIS batch sent any assets (sends > 0), finalization is deferred with one
// more ContinueDistribution — otherwise the finalization refund formula would
// compute `available` from getOriginalBalance() WITHOUT subtracting the value
// of assets sent in this same transaction (up to 50×0.03/0.05), and the action
// phase would fail with code=37. In a separate finalization transaction,
// getOriginalBalance() already reflects all transfers from previous batches.
// Completion rule:
//   cursor<n                -> continue;
//   cursor>=n, sends>0      -> continue (finalize in the next transaction);
//   cursor>=n, sends==0     -> FINALIZE.
// `queued` is value this transaction queued before the batch;
// getOriginalBalance() does not reflect it, so a finale in the same
// transaction must subtract it.
fun Storage.runDistributionBatch(mutate self, queued: coins) {
    var d = self.dist.load();
    if (d.mode == DIST_IDLE) {
        return;
    }
    var sends = 0;
    val n = self.assetsCount as int;
    while (
        (d.cursor as int) < n && sends < BATCH_MAX_SENDS && getGasConsumedAtTheMoment() <
        BATCH_GAS_SOFT_CAP
    ) {
        val a = self.assets.mustGet(d.cursor);
        // variant:begin
        // A collect leaves a slot whose wallet the minter never confirmed.
        if (a.received && !(d.mode == DIST_COLLECT && a.walletUnverified)) {
            // variant:end
            val (dest, resp) = self.assetRecipient(a, d.mode as int);
            sendAsset(a, d.cursor as int, dest, resp);
            sends += 1;
        }
        d.cursor += 1;
    }

    if ((d.cursor as int) >= n && sends == 0) {
        self.finalizeDistribution(d.mode as int, queued);
        d.mode = DIST_IDLE;
    } else {
        val m = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: continueMsgValue(),
            dest: contract.getAddress(),
            body: ContinueDistribution { queryId: d.cursor as int },
        });
        m.send(SEND_MODE_REGULAR);
    }
    self.dist = d.toCell();
}

// ── Delivery finalization ──
// Called ONLY from a batch that sent no assets (see runDistributionBatch,
// the sends == 0 gate): getOriginalBalance() here already reflects
// the spending of all previous batches, so the refund is honestly computed
// FROM THE CURRENT balance. DIST_EXECUTE: GRAM exchange, fee, refunds, dust
// sweep, DONE; execGasReserve(numExtraSends(g)) covers this finalization (≤6
// messages). DIST_CANCEL: the refunds already went out in the initiating
// transaction; what the chain did not spend is split equally, then the dust
// sweep; this branch prices its own gas from what the transaction has
// consumed so far, since the batch before it may have walked the registry.
// Both branches keep the storage floor on the balance.
fun Storage.finalizeDistribution(mutate self, mode: int, queued: coins) {
    if (mode == DIST_EXECUTE) {
        self.phase = PHASE_DONE;
        val g = self.grams.load();
        val fees = SERVICE_FEE * 2;
        // Asset transfers went out in earlier batches, so the balance already
        // reflects them; R is what is left after anything this transaction
        // already queued, the legs, the fee, this transaction's gas and the
        // dust margin.
        val r = contract.getOriginalBalance() - queued - g.gram1Amount - g.gram2Amount - fees -
            execGasReserve(numExtraSends(g)) -
            DUST -
            self.storageFloor();
        val (refund1, refund2) = splitRefunds(
            r,
            paidBy(g, 1) - g.gram1Amount - SERVICE_FEE - self.ownTransferCost(1),
            paidBy(g, 2) - g.gram2Amount - SERVICE_FEE - self.ownTransferCost(2),
        );
        if (g.gram2Amount > 0) {
            createMessage({ bounce: BounceMode.NoBounce, value: g.gram2Amount, dest: self.owner1 }).send(
                SEND_MODE_REGULAR,
            );
        }
        if (g.gram1Amount > 0) {
            createMessage({ bounce: BounceMode.NoBounce, value: g.gram1Amount, dest: self.owner2 }).send(
                SEND_MODE_REGULAR,
            );
        }
        createMessage({ bounce: BounceMode.NoBounce, value: fees, dest: self.feeWallet }).send(
            SEND_MODE_REGULAR,
        );
        // A refund below refundMinimum is not sent: below one forward fee it
        // would fail the action phase and abort the whole finale; it stays on
        // the balance and goes to the fee wallet with the sweep, as sub-dust
        // amounts do on cancel.
        val minRefund = refundMinimum();
        if (refund1 >= minRefund) {
            createMessage({ bounce: BounceMode.NoBounce, value: refund1, dest: self.owner1 }).send(
                SEND_MODE_REGULAR,
            );
        }
        if (refund2 >= minRefund) {
            createMessage({ bounce: BounceMode.NoBounce, value: refund2, dest: self.owner2 }).send(
                SEND_MODE_REGULAR,
            );
        }
        // Keep a year of storage on the escrow; the sweep carries everything above it.
        reserveGramsOnBalance(self.storageFloor(), RESERVE_MODE_AT_MOST);
        // SAFETY: last statement of the DIST_EXECUTE branch (phase is already
        // PHASE_DONE and every computed payout above — gram legs, service
        // fee, both refunds that reach refundMinimum — has been sent). The
        // refunds split everything except this transaction's gas reserve,
        // DUST and the storage floor; the floor is reserved first, so what the
        // sweep carries is the unused part of that gas reserve plus DUST, plus
        // any refund below refundMinimum — the intended settlement to
        // feeWallet.
        createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: self.feeWallet }).send(
            SEND_MODE_CARRY_ALL_BALANCE,
        );
        return;
    }
    if (mode == DIST_CANCEL) {
        // What the chain did not spend — unused batch gas, the value of any
        // kick — belongs to both sides equally. `queued` is what this same
        // transaction already queued (the surplus and refunds, when a batch
        // cancel finalizes in its initiating transaction); the balance at the
        // start of the transaction still includes it. This transaction's own
        // gas is what it has used so far plus the finale's sends; when the
        // batch walked the registry before finishing, that is far more than
        // the finale alone.
        val ownGas = calculateGasFee(
            BASECHAIN,
            getGasConsumedAtTheMoment() + EXEC_GAS_UNITS_BASE + EXEC_GAS_UNITS_PER_SEND * 3,
        );
        val leftover = contract.getOriginalBalance() - queued - ownGas - DUST - self.storageFloor();
        // Split only an amount worth two messages (refundMinimum): a smaller
        // leftover would fail the whole action phase (a 1-nanoton leftover:
        // result code 37) or is not worth splitting, and goes to the sweep.
        if (leftover > refundMinimum()) {
            val half = leftover / 2;
            createMessage({ bounce: BounceMode.NoBounce, value: half, dest: self.owner1 }).send(
                SEND_MODE_REGULAR,
            );
            val rest = leftover - half;
            createMessage({ bounce: BounceMode.NoBounce, value: rest, dest: self.owner2 }).send(
                SEND_MODE_REGULAR,
            );
        }
        // Keep a year of storage on the escrow; the sweep carries everything above it.
        reserveGramsOnBalance(self.storageFloor(), RESERVE_MODE_AT_MOST);
        // SAFETY: the refunds went out in the initiating transaction and the
        // leftover has just been split (or is sub-dust); the floor is reserved
        // first, so the sweep carries only the dust margin above it.
        createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: self.feeWallet }).send(
            SEND_MODE_CARRY_ALL_BALANCE,
        );
    }
}

// executeSwapSingleTx — distributes the whole deal in one transaction. The
// fast path (<=100 assets) calls it directly; larger deals use the batch path
// above.
fun Storage.executeSwapSingleTx(mutate self, committedOut: coins) {
    self.phase = PHASE_DONE;
    val g = self.grams.load();

    val fees = SERVICE_FEE * 2;
    val explicitOut = g.gram1Amount + g.gram2Amount + self.assetTransferCost() + fees;
    val gasReserve = self.gasReserveForSwap(g);

    // R: the actual balance minus everything this transaction sends besides
    // the refunds (TON legs, asset transfers, the fee, any value an earlier
    // step of this same transaction queued as committedOut), minus this
    // transaction's own gas, the dust margin and the storage floor.
    val r = contract.getOriginalBalance() - committedOut - explicitOut - gasReserve - DUST -
        self.storageFloor();
    val (refund1, refund2) = splitRefunds(
        r,
        paidBy(g, 1) - g.gram1Amount - SERVICE_FEE - self.ownTransferCost(1),
        paidBy(g, 2) - g.gram2Amount - SERVICE_FEE - self.ownTransferCost(2),
    );

    // 1. GRAM exchange: each side receives the amount deposited by the
    // OPPOSITE side.
    if (g.gram2Amount > 0) {
        createMessage({ bounce: BounceMode.NoBounce, value: g.gram2Amount, dest: self.owner1 }).send(
            SEND_MODE_REGULAR,
        );
    }
    if (g.gram1Amount > 0) {
        createMessage({ bounce: BounceMode.NoBounce, value: g.gram1Amount, dest: self.owner2 }).send(
            SEND_MODE_REGULAR,
        );
    }

    // 2. NFT — each side gets the assets of the opposite side; queryId =
    // asset_index (map key) — prep for future bounce handling.
    //
    // CONSTRAINT: the distribution loop must stay READ-ONLY. Writing back per
    // asset — `a.sent = true; self.assets.set(idx, a)` — rebuilds O(log N)
    // dictionary cells on every iteration, around 9000 gas per NFT, and that
    // breaks the auto-cascade at as few as 61 total NFTs
    // (action_result_code=37).
    // The sent flags are only needed for batching; in this single-transaction
    // path, re-entry is already ruled out by `phase = DONE` (set BEFORE the
    // distribution — the transaction is atomic, so the distribution either
    // goes out in full or rolls back in full).
    // NOTE: the batching path does not restore them either — it tracks its
    // progress with `DistState.cursor` alone and never writes `sent`. The
    // field stays in the Asset layout as a reserved slot: removing it would
    // change the storage layout, and therefore every deal address.
    // The loop must also dispatch on `a.kind`. Without that branch, jetton
    // assets receive a TIP-4 `NftTransfer` addressed to the MINTER — for
    // kind=1, `a.addr` is the minter, not a wallet — and the action fails with
    // exit_code=63 ("prefix does not match"), since a minter does not
    // understand that opcode. Pinned by the
    // `overpaymentOnFinalDepositStillExecutes` test. Jetton assets go out via
    // sendJettonTransfer to the RESOLVED a.jettonWallet! (guaranteed
    // non-null: canAutoExecute requires received1Count/received2Count to be
    // met, and the per-asset jetton-receipt gate resolves the wallet before
    // marking received).
    //
    // CONSTRAINT: that branch must sit OUTSIDE the loop. The gas boundary here
    // is calibrated to the edge — gas_probe pins 115x115 OK against 116x116
    // FAIL — so the hot loop has no headroom for extra instructions. A single
    // additional `a.kind == 1` check per iteration is enough to push 115x115
    // and 230x1 into exit_code=-14.
    // So `self.jettonsCount == 0` is tested EXACTLY ONCE per transaction:
    // pure-NFT deals run the tight loop with no per-iteration dispatch, while
    // mixed and jetton deals take a separate loop that branches on kind. The
    // asymmetry is affordable because jetton deals are always small in asset
    // count — NFT_TRANSFER_VALUE against JETTON_TRANSFER_VALUE makes a
    // comparable volume uneconomical.
    if (self.jettonsCount == 0) {
        var r = self.assets.findFirst();
        while (r.isFound) {
            val idx = r.getKey();
            val a = r.loadValue();
            val newOwner = a.ownerSide == 1 ? self.owner2 : self.owner1;
            val resp = a.ownerSide == 1 ? self.owner1 : self.owner2;
            sendNftTransfer(
                a.addr,
                idx,
                newOwner,
                resp,
                NFT_TRANSFER_VALUE,
                SEND_MODE_REGULAR,
            );
            r = self.assets.iterateNext(r);
        }
    } else {
        var r = self.assets.findFirst();
        while (r.isFound) {
            val idx = r.getKey();
            val a = r.loadValue();
            val newOwner = a.ownerSide == 1 ? self.owner2 : self.owner1;
            val resp = a.ownerSide == 1 ? self.owner1 : self.owner2;
            if (a.kind == 1) {
                // responseDest = newOwner (not resp, unlike the NFT branch
                // below): TEP-74 excess-refund goes to the jetton recipient,
                // not the original depositor.
                sendJettonTransfer(
                    a.jettonWallet!,
                    idx,
                    a.amount,
                    newOwner,
                    newOwner,
                    JETTON_TRANSFER_VALUE,
                    SEND_MODE_REGULAR,
                );
            } else {
                sendNftTransfer(
                    a.addr,
                    idx,
                    newOwner,
                    resp,
                    NFT_TRANSFER_VALUE,
                    SEND_MODE_REGULAR,
                );
            }
            r = self.assets.iterateNext(r);
        }
    }

    // 3. Service fee: exactly SERVICE_FEE per side. Anything a side paid above
    // that is part of its contribution and comes back in its refund.
    createMessage({ bounce: BounceMode.NoBounce, value: fees, dest: self.feeWallet }).send(
        SEND_MODE_REGULAR,
    );

    // 4. Refunds. A refund below refundMinimum is not sent: below one forward
    // fee it would fail the action phase and abort the whole execution; it
    // stays on the balance and goes to the fee wallet with the sweep, as
    // sub-dust amounts do on cancel.
    val minRefund = refundMinimum();
    if (refund1 >= minRefund) {
        createMessage({ bounce: BounceMode.NoBounce, value: refund1, dest: self.owner1 }).send(
            SEND_MODE_REGULAR,
        );
    }
    if (refund2 >= minRefund) {
        createMessage({ bounce: BounceMode.NoBounce, value: refund2, dest: self.owner2 }).send(
            SEND_MODE_REGULAR,
        );
    }

    // 5. Dust sweep — sent LAST: whatever is physically left on the balance
    // above the reserved storage floor after all the messages above (the
    // unused part of the gas reserve, DUST and any refund below
    // refundMinimum) goes to feeWallet via mode 128 (CARRY_ALL_BALANCE).
    // Keep a year of storage on the escrow; the sweep carries everything above it.
    reserveGramsOnBalance(self.storageFloor(), RESERVE_MODE_AT_MOST);
    // SAFETY: step 5 of 5 in this function — every asset/NFT/jetton
    // transfer, the service fee, and both refunds that reach refundMinimum
    // (steps 1-4 above) have already been sent, and this is the function's
    // final statement. The refunds split everything except the gas reserve,
    // DUST and the floor; the floor is reserved first, so the sweep carries
    // only what is above it.
    createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: self.feeWallet }).send(
        SEND_MODE_CARRY_ALL_BALANCE,
    );
}

// Called after a deposit or fee has been credited. Execution gas comes from
// the reserve canAutoExecute has just confirmed is on the balance, not from
// the value of the message that completed the deal: a deposit's forward is
// sized for recording one asset. SETGASLIMIT caps the limit at what the
// balance can buy.
// Kept inline: as a separate procedure this reshuffles all of Storage's
// fields on the stack on every call, whether or not the branch fires, so
// every deposit's auto-execute check would pay for a call it mostly skips.
@inline
fun Storage.tryAutoExecute(mutate self, committedOut: coins) {
    if (self.canAutoExecute(committedOut)) {
        setGasLimit(self.executionGasUnits(self.grams.load()));
        self.executeSwap(committedOut);
    }
}

// Auto-execution from a transaction that has already done other work (the
// minter's answer walks the whole registry). That work counts against the gas
// limit too, so the limit is execution's own units on top of what is already
// used, up to the transaction ceiling. If execution still runs out, the caller
// has committed its state and execute_swap settles the deal. Large deals run
// as a batch chain that stops itself by consumed gas (runDistributionBatch).
fun Storage.tryAutoExecuteAfterWalk(mutate self) {
    if (self.canAutoExecute(0)) {
        val units = getGasConsumedAtTheMoment() + self.executionGasUnits(self.grams.load());
        setGasLimit(units < TX_GAS_LIMIT_CEILING ? units : TX_GAS_LIMIT_CEILING);
        self.executeSwap(0);
    }
}

// Fallback for a message with an empty body: from an owner it is treated as
// an ordinary GRAM deposit for that side; from anyone else it is forwarded to
// feeWallet, since there is no reason to hold a stranger's TON on the escrow's
// balance.
//
// Note for integrators: crediting an owner's bare transfer also calls
// st.tryAutoExecute(), so a plain TON transfer with no command can complete a
// deal — auto-execution is not limited to the text deposit commands. It runs
// behind the full canAutoExecute gate (the same phase/received/gram/fee/
// balance checks as everywhere else), but it is observable at the wire level
// and worth knowing about. Outside SETUP and ACTIVE an owner's bare transfer
// bounces.
fun handlePlainTransfer(sender: address, value: coins) {
    var st = Storage.load();
    if (sender != st.owner1 && sender != st.owner2) {
        // Funded by the incoming message's own value (mode 64), NOT from the
        // balance — the same idiom as returnForeignNft / returnJettons below.
        // Forwarding the full `value` under SEND_MODE_REGULAR would make every
        // stranger's transfer a net loss: the contract would hand on everything
        // it received while paying this transaction's compute gas out of its
        // own balance, so anyone could grind the escrow's reserve down —
        // below minBalanceForSwap (auto-execution stops firing) or below
        // cancel_swap's `required` (throw 430). Mode 64 carries what remains
        // of the inbound value after gas, leaving the balance untouched.
        val fwd = createMessage({
            bounce: BounceMode.NoBounce,
            value: 0,
            dest: st.feeWallet,
        });
        fwd.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }
    // An owner's bare transfer is a TON deposit and follows the same phase
    // rule as deposit_ton1/2: once the deal is finalized it bounces back
    // instead of landing on a balance that nothing can pay out.
    assert (st.phase == PHASE_ACTIVE || st.phase == PHASE_SETUP) throw Errors.AlreadyFinalized;
    var g = st.grams.load();
    if (sender == st.owner1) {
        g.gram1Received += value;
    } else {
        g.gram2Received += value;
    }
    st.grams = g.toCell();
    st.tryAutoExecute(0);
    st.save();
}

// A jetton slot whose wallet its minter has not confirmed yet: no address, or
// one that side 2 only claimed.
fun Asset.walletPending(self): bool {
    return self.kind == 1 && (self.jettonWallet == null || self.walletUnverified);
}

// The minters a discovery round asks, found in one pass over the registry:
// each minter with a pending slot once, in registry order, and how many of
// its slots are pending.
struct DiscoveryPlan {
    minters: map<uint16, address> // numbered 0..count-1
    slots: map<uint16, uint16>    // pending slots of each numbered minter
    count: int
}

// O(n·log n) minter dedup: a transaction-local map of seen minters, NOT
// persisted in Storage. The map is what keeps this sub-quadratic; deduping by
// re-scanning all previous assets on every iteration walls a jetton deal at
// 38-39 total assets, where the quadratic compute growth aborts the call with
// action_result_code=37 ("Not enough Toncoin"). A SINGLE pass over the n
// assets (DEPLOY_GAS_UNITS_PER_ASSET is calibrated for one scan, see
// shared/types.tolk): the provides go out in a second, cheap pass over the unique
// minters only (sendProvides).
fun Storage.planDiscovery(self): DiscoveryPlan {
    var seen: map<address, uint16> = [];
    var minters: map<uint16, address> = [];
    var slots: map<uint16, uint16> = [];
    var count = 0;
    val n = self.assetsCount as int;
    var i = 0;
    while (i < n) {
        val a = self.assets.mustGet(i as uint16);
        if (a.walletPending()) {
            val r = seen.get(a.addr);
            if (r.isFound) {
                val k = r.loadValue();
                slots.set(k, (slots.mustGet(k) + 1) as uint16);
            } else {
                seen.set(a.addr, count as uint16);
                minters.set(count as uint16, a.addr);
                slots.set(count as uint16, 1);
                count += 1;
            }
        }
        i += 1;
    }
    return DiscoveryPlan { minters, slots, count };
}

// Value of one provide_wallet_address to a minter with `slots` pending slots:
// the request plus the gas of its answer — a walk of the whole registry and,
// for each of its slots, the most expensive write (a provisional deposit
// undone). See TAKE_SCAN_BASE_UNITS in shared/types.tolk.
fun Storage.provideValueFor(self, slots: int): coins {
    val n = self.assetsCount as int;
    return PROVIDE_WALLET_VALUE +
        calculateGasFee(
            BASECHAIN,
            TAKE_SCAN_BASE_UNITS + TAKE_SCAN_UNITS_PER_ENTRY * n + TAKE_SET_UNITS * slots,
        );
}

// Everything a discovery round spends: the provides and the registry scan
// that found them (DEPLOY_BASE_GAS_UNITS + DEPLOY_GAS_UNITS_PER_ASSET × n).
// The caller pays it, so the escrow's balance does not: without the scan
// share, a registry minter that keeps the provide value and never answers
// would let a third party turn repeated, fully funded deploy_fee calls into a
// drain on the owners' deposits. Must match tests/nosup/nosup_helpers.tolk
// (deployEscrow, discoveryValue) byte for byte.
fun Storage.discoveryCost(self, plan: DiscoveryPlan): coins {
    val n = self.assetsCount as int;
    var total = calculateGasFee(
        BASECHAIN,
        DEPLOY_BASE_GAS_UNITS + DEPLOY_GAS_UNITS_PER_ASSET * n,
    );
    var k = 0;
    while (k < plan.count) {
        total += self.provideValueFor(plan.slots.mustGet(k as uint16));
        k += 1;
    }
    return total;
}

// The provides go out in mode 0: their forwarding fees come out of their own
// value, not the balance.
fun Storage.sendProvides(self, plan: DiscoveryPlan) {
    var k = 0;
    while (k < plan.count) {
        val m = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: self.provideValueFor(plan.slots.mustGet(k as uint16)),
            dest: plan.minters.mustGet(k as uint16),
            body: ProvideWalletAddress {
                queryId: k,
                ownerAddress: contract.getAddress(),
                includeAddress: false,
            },
        });
        m.send(SEND_MODE_REGULAR);
        k += 1;
    }
}

// deploy_fee: the manual way to start (or retry) discovery. If the deal
// contains jettons, the contract deploys into SETUP; provide_wallet_address
// (TEP-89) goes to every unique minter with a pending slot. A repeat while in
// SETUP is a legal retry for a minter that did not answer: it asks only the
// minters still pending. The sender is not gated; the caller pays for
// everything the call spends (discoveryCost), checked before any send. An
// owner's deploy_fee is that owner's payment; a stranger's is a gift that the
// settlement shares equally. On an active deal an owner's deploy_fee also runs
// the auto-execution check, as deposit_ton does.
fun handleDeployFee(sender: address, value: coins) {
    var st = Storage.load();
    assert (st.phase == PHASE_ACTIVE || st.phase == PHASE_SETUP) throw Errors.AlreadyFinalized;
    if (sender == st.owner1 || sender == st.owner2) {
        var g = st.grams.load();
        if (sender == st.owner1) {
            g.gram1DepositReserve += value;
        } else {
            g.gram2DepositReserve += value;
        }
        st.grams = g.toCell();
        // An owner's payment, like deposit_ton: it may complete the funding.
        if (st.phase == PHASE_ACTIVE) {
            st.tryAutoExecute(0);
        }
        st.save();
    }
    if (st.phase != PHASE_SETUP) {
        return; // NFT-only deal: no action needed
    }
    val plan = st.planDiscovery();
    assert (value >= st.discoveryCost(plan)) throw Errors.InsufficientBalance;
    st.sendProvides(plan);
}

// Modelled gas of AcceptDeal's claim and discovery passes (see
// ACCEPT_BASE_UNITS): every entry walked, every jetton slot possibly claimed.
fun Storage.acceptWorkUnits(self): int {
    return ACCEPT_BASE_UNITS + ACCEPT_UNITS_PER_ENTRY * (self.assetsCount as int) +
        ACCEPT_UNITS_PER_CLAIM * (self.jettonsCount as int);
}

// Side 2's claimed wallets go into its jetton slots that have none yet. A
// claim only lets a deposit be recorded before the minter answers; the
// answer confirms or undoes it (handleTakeWalletAddress). Side 1's slots, and
// slots that already have an address, are left alone.
fun Storage.writeClaims(mutate self, claims: map<address, address>) {
    if (claims.isEmpty()) {
        return;
    }
    val n = self.assetsCount as int;
    var i = 0;
    while (i < n) {
        var a = self.assets.mustGet(i as uint16);
        if (a.kind == 1 && a.ownerSide == 2 && a.jettonWallet == null) {
            val c = claims.get(a.addr);
            if (c.isFound) {
                a.jettonWallet = c.loadValue();
                a.walletUnverified = true;
                self.assets.set(i as uint16, a);
            }
        }
        i += 1;
    }
}

// AcceptDeal: side 2 takes the deal in one signature. It is usually the first
// message of owner2's batch and deploys the escrow; the transfers of side 2's
// assets follow in the same batch, so it never fails for lack of value. What
// it carries is side 2's payment; discovery starts only when that covers it,
// otherwise deploy_fee starts it later. In ACTIVE it is a payment like any
// other and may complete the deal (a failed execution bounces the whole
// message back with its value). Claims are written only in SETUP; side 1's
// minters are asked too.
fun handleAcceptDeal(sender: address, value: coins, msg: AcceptDeal) {
    var st = Storage.load();
    assert (sender == st.owner2) throw Errors.NotOwner2;
    assert (st.phase == PHASE_ACTIVE || st.phase == PHASE_SETUP) throw Errors.AlreadyFinalized;
    var g = st.grams.load();
    g.creditSide2(value);
    st.grams = g.toCell();
    if (st.phase == PHASE_SETUP) {
        // A registry whose claim and discovery passes could exhaust this
        // message's gas only credits: a failed AcceptDeal would bounce side
        // 2's payment while the batch's transfers still arrive. deploy_fee
        // starts discovery for it.
        val work = st.acceptWorkUnits();
        if (work <= TX_GAS_LIMIT_CEILING) {
            st.writeClaims(msg.claims);
            val plan = st.planDiscovery();
            // The value pays this message's own walks and writes too: on a
            // fresh deploy the balance is only this value, so the provides go
            // out only if it covers them after that gas, or the action phase
            // would fail and bounce the whole message.
            if (value >= st.discoveryCost(plan) + calculateGasFee(BASECHAIN, work)) {
                st.sendProvides(plan);
            }
        }
        st.save();
        return;
    }
    st.tryAutoExecute(0);
    st.save();
}

// TEP-89 take_wallet_address: accepted ONLY from the address the request
// was sent to (sender == the minter of some jetton asset). A minter resolves
// when it has at least one pending slot (no wallet, or one side 2 only
// claimed); every such slot of that minter takes the answered address (a
// minter can be on both sides). A claimed slot already received keeps its
// deposit when the minter names the claimed address; otherwise the deposit is
// undone. One answer per minter decrements pendingWallets; a repeat finds
// nothing pending and is ignored, as are an answer from a non-minter and one
// outside SETUP (not thrown: these are external messages, and failing them
// gains us nothing). An addr_none answer resolves nothing: the deal stays in
// SETUP.
fun handleTakeWalletAddress(sender: address, _value: coins, msg: TakeWalletAddressNosup) {
    var st = Storage.load();
    if (st.phase != PHASE_SETUP) {
        return;
    }
    var resolvedAny = false;
    var undone = 0;
    val w = msg.walletAddress;
    val n = st.assetsCount as int;
    var i: int = 0;
    while (i < n) {
        var a = st.assets.mustGet(i as uint16);
        if (a.addr == sender && a.kind == 1 && (a.jettonWallet == null || a.walletUnverified)) {
            resolvedAny = true;
            // Only a claimed slot can be received before its minter answers,
            // and only side 2 claims. If the minter names another address (or
            // addr_none), undo the deposit; the TON it carried stays credited
            // to side 2.
            if (a.walletUnverified) {
                if (a.received && (w == null || w! != a.jettonWallet!)) {
                    a.received = false;
                    undone += 1;
                }
            }
            a.jettonWallet = w;
            a.walletUnverified = false;
            st.assets.set(i as uint16, a);
        }
        i += 1;
    }
    if (!resolvedAny) {
        return;
    }
    st.received2Count -= undone;
    st.receivedJettons2 -= undone;
    if (w == null) {
        // addr_none: the minter does not serve this escrow. Its slots stay
        // without a wallet (a claim is erased) and the deal stays in SETUP
        // until it is cancelled.
        st.save();
        return;
    }
    st.pendingWallets -= 1;
    if (st.pendingWallets == 0) {
        st.phase = PHASE_ACTIVE;
        // With claims every deposit may already be in when the last minter
        // answers: this answer then completes the deal. The answer is
        // recorded before execution: this transaction has already walked the
        // registry, so execution may run out of gas here, and the minter's
        // answer must not be lost with it.
        st.save();
        commitContractDataAndActions();
        st.tryAutoExecuteAfterWalk();
    }
    st.save();
}

fun handleDepositGram(sender: address, value: coins, side: int) {
    var st = Storage.load();
    assert (st.phase == PHASE_ACTIVE || st.phase == PHASE_SETUP) throw Errors.AlreadyFinalized;
    var g = st.grams.load();
    if (side == 1) {
        assert (sender == st.owner1) throw Errors.NotOwner1;
        g.gram1Received += value;
    } else {
        assert (sender == st.owner2) throw Errors.NotOwner2;
        g.gram2Received += value;
    }
    st.grams = g.toCell();
    st.tryAutoExecute(0);
    st.save();
}

fun handleServiceFee(sender: address, value: coins, side: int) {
    var st = Storage.load();
    assert (st.phase == PHASE_ACTIVE || st.phase == PHASE_SETUP) throw Errors.AlreadyFinalized;
    var g = st.grams.load();
    if (side == 1) {
        assert (sender == st.owner1) throw Errors.NotOwner1;
        g.serviceFee1 += value;
    } else {
        assert (sender == st.owner2) throw Errors.NotOwner2;
        g.serviceFee2 += value;
    }
    st.grams = g.toCell();
    st.tryAutoExecute(0);
    st.save();
}

// Manual execution, for a deal that is fully funded but did not execute on its
// last deposit (for example, the completing deposit could record itself but not
// pay for the check). Either owner may call it. What it carries counts as the
// caller's own payment, so one message can pay a shortfall and execute.
// The checks run from the most specific to the most general, so the error
// says what is missing and, for 433/434, which side has to pay.
fun handleExecuteSwap(sender: address, value: coins) {
    var st = Storage.load();
    assert (sender == st.owner1 || sender == st.owner2) throw Errors.NotOwners;
    assert (st.phase == PHASE_ACTIVE) throw Errors.AlreadyFinalized;
    var g = st.grams.load();
    if (sender == st.owner1) {
        g.gram1Received += value;
    } else {
        g.gram2Received += value;
    }
    st.grams = g.toCell();
    assert (g.gram1Received >= g.gram1Amount) throw Errors.NotEnoughTon1;
    assert (g.gram2Received >= g.gram2Amount) throw Errors.NotEnoughTon2;
    assert (g.serviceFee1 >= SERVICE_FEE) throw Errors.ServiceFee1;
    assert (g.serviceFee2 >= SERVICE_FEE) throw Errors.ServiceFee2;
    assert (st.received1Count >= st.required1Count) throw Errors.NftsNotReceived;
    assert (st.received2Count >= st.required2Count) throw Errors.NftsNotReceived;
    assert (st.sideFunded(g, 1)) throw Errors.SideUnderfunded1;
    assert (st.sideFunded(g, 2)) throw Errors.SideUnderfunded2;
    assert (st.balanceCovers(g, 0)) throw Errors.InsufficientBalance;
    setGasLimit(st.executionGasUnits(g));
    st.executeSwap(0);
    st.save();
}

// ── Self-trigger for the next batch ──
// ONLY from itself — no other sender should be able to drive the batch
// chain; delivery must be in progress (mode != IDLE — otherwise this is the
// tail of an already-finalized chain, and we stay silent).
fun handleContinueDistribution(sender: address) {
    assert (sender == contract.getAddress()) throw Errors.NotOwners;
    var st = Storage.load();
    val d = st.dist.load();
    if (d.mode == DIST_IDLE) {
        return;
    }
    st.runDistributionBatch(0);
    st.save();
}

// ── kick — resumes a stalled batch chain ──
// A ContinueDistribution can fail (it bounces, and the bounce is ignored);
// either owner restarts the chain from the current cursor. A text command so
// that it can be sent as a plain comment from any wallet.
fun handleKick(sender: address, _value: coins) {
    var st = Storage.load();
    assert (sender == st.owner1 || sender == st.owner2) throw Errors.NotOwners;
    val d = st.dist.load();
    assert (d.mode != DIST_IDLE) throw Errors.AlreadyFinalized;
    st.runDistributionBatch(0);
    st.save();
}

// Gas units the cancel's initiating transaction may use: every send it may
// queue and the walk over the registry, which visits every entry whether it
// was received or not. On the batch path that transaction runs only the first
// batch, which stops at BATCH_GAS_SOFT_CAP, so the units are capped at what
// one batch transaction may use. On the fast path they are capped at
// TX_GAS_LIMIT_CEILING: setGasLimit grants no more than that, and the reserve
// (quoteCancel prices these same units) must not charge the sides for gas the
// transaction can never use. A fully deposited 100-entry cancel models
// 1,201,000 units and measured 354,689 (a 100-NFT registry, every item
// deposited, tests/nosup/cancel_settlement.test.tolk), about 2.8x below the
// ceiling.
fun cancelTxGasUnits(registrySize: int, sendCount: int): int {
    val units = EXEC_GAS_UNITS_BASE + EXEC_GAS_UNITS_PER_SEND * sendCount +
        SKIP_GAS_UNITS_PER_ENTRY * registrySize;
    if (registrySize > FAST_PATH_MAX_ASSETS && units > CONTINUE_GAS_UNITS) {
        return CONTINUE_GAS_UNITS;
    }
    if (units > TX_GAS_LIMIT_CEILING) {
        return TX_GAS_LIMIT_CEILING;
    }
    return units;
}

// What a cancel needs, computed from the balance BEFORE the canceller's
// attachment. `baseCost` (C) is what cancel spends or keeps regardless of who
// gets what: asset returns, gas for this and every later transaction, the
// dust margin and the storage floor.
// raw1/raw2 are the formula refunds, unclamped: a negative one is that side's
// shortfall. `required` keeps the side without a shortfall whole — comparing
// the balance with C plus the shortfalls alone would let the other side's
// money on the balance "cover" them. `gasUnits` is the gas limit of the
// initiating transaction; `baseCost` prices exactly these units.
struct CancelQuote {
    baseCost: coins
    required: coins
    raw1: coins
    raw2: coins
    gasUnits: int
}

fun Storage.quoteCancel(self, g: GramState, balanceBefore: coins): CancelQuote {
    val o1 = self.ownTransferCost(1);
    val o2 = self.ownTransferCost(2);
    val receivedTotal = (self.received1Count as int) + (self.received2Count as int);
    val registrySize = self.assetsCount as int;
    // feeWallet sweep + refund1 + refund2 + the surplus refund to the canceller
    val sendCount = receivedTotal + 4;
    val gasUnits = cancelTxGasUnits(registrySize, sendCount);
    var baseCost = o1 + o2 + calculateGasFee(BASECHAIN, gasUnits) + DUST;
    if (registrySize > FAST_PATH_MAX_ASSETS) {
        // The chain's later transactions: the returns the first batch did not
        // send, and a base per batch (gated on the REGISTRY SIZE: the chain's
        // length is set by how far the cursor walks). The first batch sends
        // the continue message in this transaction, together with the
        // refunds: its value must be on the balance. It comes back on
        // arrival, so it is present, not spent.
        baseCost += calculateGasFee(BASECHAIN, EXEC_GAS_UNITS_PER_SEND * receivedTotal) +
            batchChainReserve(registrySize, receivedTotal) +
            continueMsgValue();
    }
    // A year of storage stays on the cancelled escrow.
    baseCost += self.storageFloor();
    val r0 = balanceBefore - baseCost;
    val raw1 = (r0 + (paidBy(g, 1) - o1) - (paidBy(g, 2) - o2)) / 2;
    val raw2 = r0 - raw1;
    var required = baseCost;
    if (raw1 > 0) {
        required += raw1;
    }
    if (raw2 > 0) {
        required += raw2;
    }
    return CancelQuote { baseCost, required, raw1, raw2, gasUnits };
}

// Cancel settles by the same formula as execute: each side gets back what it
// paid less the return of its own assets and half of the shared costs. The
// balance check (throw 430) makes cancel all-or-nothing: it either fully
// succeeds — every asset return and every refund that reaches sendableMinimum
// sent — or fully rolls back. The
// canceller covers any side's shortfall (its own first), and anything it
// attached above that comes back to it.
fun handleCancelSwap(sender: address, value: coins) {
    var st = Storage.load();
    assert (sender == st.owner1 || sender == st.owner2) throw Errors.NotOwners;
    assert (st.phase == PHASE_ACTIVE || st.phase == PHASE_SETUP) throw Errors.AlreadyFinalized;

    val g = st.grams.load();
    val balance = contract.getOriginalBalance();
    val q = st.quoteCancel(g, balance - value);
    assert (balance >= q.required) throw Errors.InsufficientBalance;
    // From here on this transaction's gas comes out of the reserve inside
    // `required` (it prices exactly these units), not out of the attached
    // value.
    setGasLimit(q.gasUnits);

    // The attachment covers the shortfalls — the canceller's own first, then
    // the other side's; what is left above them comes back to the canceller.
    var surplus = balance - q.required;
    if (surplus > value) {
        surplus = value;
    }
    val credit = value - surplus;
    val short1: coins = q.raw1 < 0 ? -q.raw1 : 0;
    val short2: coins = q.raw2 < 0 ? -q.raw2 : 0;
    val cancellerIsOne = sender == st.owner1;
    val ownShort = cancellerIsOne ? short1 : short2;
    val otherShort = cancellerIsOne ? short2 : short1;
    val toOwn = credit < ownShort ? credit : ownShort;
    var toOther = credit - toOwn;
    if (toOther > otherShort) {
        toOther = otherShort;
    }
    val credit1 = cancellerIsOne ? toOwn : toOther;
    val credit2 = cancellerIsOne ? toOther : toOwn;
    val (refund1, refund2) = splitRefunds(
        balance - q.baseCost - surplus,
        paidBy(g, 1) + credit1 - st.ownTransferCost(1),
        paidBy(g, 2) + credit2 - st.ownTransferCost(2),
    );

    st.phase = PHASE_CANCELLED;

    // Surplus and refunds go out IMMEDIATELY, in the initiating transaction
    // (both paths): the batch finale only splits what the chain did not spend.
    // An amount below sendableMinimum is not sent: below one forward fee it
    // would fail the action phase and abort the cancel, and anyone can move
    // the refunds there with an unattributed inflow. It stays on the balance
    // and goes to the fee wallet with the sweep. The bound is the forwarding
    // cost, not DUST, so the pre-check gas allowance cancelCost adds still
    // comes back to the canceller.
    val minRefund = sendableMinimum();
    var queued: coins = 0;
    if (surplus >= minRefund) {
        createMessage({ bounce: BounceMode.NoBounce, value: surplus, dest: sender }).send(
            SEND_MODE_REGULAR,
        );
        queued += surplus;
    }
    if (refund1 >= minRefund) {
        createMessage({ bounce: BounceMode.NoBounce, value: refund1, dest: st.owner1 }).send(
            SEND_MODE_REGULAR,
        );
        queued += refund1;
    }
    if (refund2 >= minRefund) {
        createMessage({ bounce: BounceMode.NoBounce, value: refund2, dest: st.owner2 }).send(
            SEND_MODE_REGULAR,
        );
        queued += refund2;
    }

    // The gate is the REGISTRY SIZE, not the number of received assets: the
    // loop below walks every registry entry, so its cost is driven by
    // assetsCount. A large-registry deal with few deposits — the state a deal
    // is in BEFORE deposits arrive, i.e. exactly when a party is most likely
    // to cancel — must still be cancellable within the 1,000,000-gas ceiling,
    // so the gate cannot key off how many deposits actually arrived.
    // Storage.executeSwap gates on assetsCount for the same reason.
    val registrySize = st.assetsCount as int;
    if (registrySize <= FAST_PATH_MAX_ASSETS) {
        // Fast path (<=100): single-transaction return + sweep.
        //
        // Returns only the assets actually received — to their own
        // depositors. The loop must stay read-only (no per-asset
        // `sent=true` + assets.set) for the gas reason described at
        // executeSwap; re-entry is ruled out by phase=CANCELLED.
        //
        // `a.jettonWallet!` is safe: received == true is only possible
        // after the minter is resolved (the per-asset jetton-receipt gate
        // in handleJettonNotification resolves the wallet before marking
        // received) — same pattern as in executeSwap.
        var r = st.assets.findFirst();
        while (r.isFound) {
            val idx = r.getKey();
            val a = r.loadValue();
            if (a.received) {
                val backTo = a.ownerSide == 1 ? st.owner1 : st.owner2;
                if (a.kind == 1) {
                    sendJettonTransfer(
                        a.jettonWallet!,
                        idx,
                        a.amount,
                        backTo,
                        backTo,
                        JETTON_TRANSFER_VALUE,
                        SEND_MODE_REGULAR,
                    );
                } else {
                    sendNftTransfer(
                        a.addr,
                        idx,
                        backTo,
                        backTo,
                        NFT_TRANSFER_VALUE,
                        SEND_MODE_REGULAR,
                    );
                }
            }
            r = st.assets.iterateNext(r);
        }

        // Keep a year of storage on the escrow; the sweep carries everything above it.
        reserveGramsOnBalance(st.storageFloor(), RESERVE_MODE_AT_MOST);
        // The remainder goes to fee_wallet, sent LAST.
        // SAFETY: fast-path cancel — the surplus and both refunds that reach
        // sendableMinimum were already sent above and every received asset
        // has just been returned to its original depositor. This is the
        // function's last statement before st.save(). The floor is reserved
        // first, so what the sweep carries is the unused part of the gas
        // reserve, the dust margin and any amount below sendableMinimum.
        createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: st.feeWallet }).send(
            SEND_MODE_CARRY_ALL_BALANCE,
        );
        st.save();
        return;
    }

    // Batch return (>100): the surplus and refunds already sent above; assets
    // go out in batches through the engine; the sweep happens in the final
    // batch (finalizeDistribution DIST_CANCEL, mode 128). We do NOT send a
    // sweep in the initiating transaction. The batch is told what this
    // transaction has already queued, in case it finalizes right here; an
    // amount held back above is not queued: it stays on the balance for the
    // finale, which splits it with the unspent reserve or sweeps it.
    st.dist = DistState {
        mode: DIST_CANCEL,
        cursor: 0,
    }.toCell();
    st.runDistributionBatch(queued);
    st.save();
}

// ── claim_asset — pull delivery of a deal asset ──
// The rightful recipient pulls an asset whose push delivery did not arrive.
// Recipient: the opposite side while executing or after DONE; the depositor
// after CANCELLED. Funded entirely by the attached value (mode 64), so it
// does not draw on the storage floor a settled escrow keeps, and lets the
// caller attach more gas than the original transfer carried.
//
// NFT: allowed for any received NFT the distribution has already sent
// (dist idle, or index behind the cursor), without a bounce mark — a bounce
// may never arrive when the NFT's compute consumes the whole value. This is
// safe because an NFT item only honours a transfer from its current owner: if
// the NFT was already delivered, the transfer is rejected and nothing moves.
//
// A registry NFT slot that was never recorded — the item reached the escrow
// with a forward too small to notify it — is claimable only after cancel, by
// its side owner. The current-owner check protects this case: if the item
// never actually arrived, the escrow does not own it and the transfer is
// refused, so the claim moves nothing beyond its own attached value. The
// registry does not forbid listing the same NFT address on both sides, so
// this claim also refuses if that address appears in any slot on the OTHER
// side — the escrow may be holding the item for that other side instead
// (Storage.hasCrossSideDuplicate).
//
// Jetton: only while marked claimable. The escrow holds one wallet per
// minter, possibly with tokens of another asset of the same minter, so an
// unconfirmed resend could move tokens that are not this asset's. A bounce of
// the escrow wallet's transfer proves the tokens are still there.

// Whether NFT address `addr` (the item registered at `idx`) also occupies a
// registry slot on the OTHER side — recorded or not. The registry has no
// rule against listing one NFT address twice across sides, so an unrecorded
// slot's own side ownership does not prove the escrow is holding THIS item
// for THIS slot: it may instead be holding a same-address item deposited (or
// stuck) on the other side. A duplicate on the SAME side is harmless — same
// owner either way. Paid entirely by the claimer's attached value, like the
// rest of claim_asset, at about 1,350 gas per entry: a 100-entry registry's
// claim uses 134,352 gas (about 0.009 TON today). No attachment buys more than
// the 1,000,000-gas transaction limit, so above about 740 entries (measured:
// 740 entries 993,827 gas, 760 out of gas) this claim always runs out of gas
// and an unrecorded item there cannot be pulled out; running out of gas simply
// bounces the value back.
fun Storage.hasCrossSideDuplicate(self, idx: uint16, addr: address): bool {
    val mySide = self.assets.mustGet(idx).ownerSide;
    val n = self.assetsCount as int;
    var i: int = 0;
    while (i < n) {
        if (i != (idx as int)) {
            val a = self.assets.mustGet(i as uint16);
            if (a.kind == 0 && a.addr == addr && a.ownerSide != mySide) {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

fun handleClaimAsset(sender: address, value: coins, msg: ClaimAsset) {
    var st = Storage.load();
    assert (
        st.phase == PHASE_EXECUTING || st.phase == PHASE_DONE || st.phase == PHASE_CANCELLED
    ) throw Errors.AlreadyFinalized;
    val idx = msg.assetIndex;
    assert ((idx as int) < (st.assetsCount as int)) throw Errors.BadAssetIndex;
    var a = st.assets.mustGet(idx);
    if (a.kind == 1) {
        assert (a.claimable) throw Errors.NotClaimable;
    } else if (a.received) {
        val d = st.dist.load();
        assert (d.mode == DIST_IDLE || (idx as int) < (d.cursor as int)) throw Errors.NotClaimable;
    } else {
        // An NFT the escrow never recorded: sent to the deal with a forward too
        // small to notify it. Only after cancel, and only by its side owner
        // (the recipient in CANCELLED). The item refuses the transfer if the
        // escrow does not own it, so a claim for an item that never arrived
        // moves nothing. If the same address is also listed on the OTHER
        // side, the escrow may be holding the item for that side instead
        // (a recorded deposit stuck there, or another too-small forward) —
        // refuse rather than hand it to the wrong side.
        assert (st.phase == PHASE_CANCELLED) throw Errors.NotClaimable;
        assert (!st.hasCrossSideDuplicate(idx, a.addr)) throw Errors.NotClaimable;
    }
    val depositor = a.ownerSide == 1 ? st.owner1 : st.owner2;
    val counterparty = a.ownerSide == 1 ? st.owner2 : st.owner1;
    val recipient = st.phase == PHASE_CANCELLED ? depositor : counterparty;
    assert (sender == recipient) throw Errors.NotRecipient;
    val need = a.kind == 1 ? JETTON_TRANSFER_VALUE : NFT_TRANSFER_VALUE;
    assert (value >= need) throw Errors.InsufficientBalance;

    if (a.claimable) {
        a.claimable = false;
        st.assets.set(idx, a);
        st.save();
    }
    if (a.kind == 1) {
        sendJettonTransfer(
            a.jettonWallet!,
            idx as int,
            a.amount,
            recipient,
            recipient,
            0,
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
        );
    } else {
        sendNftTransfer(
            a.addr,
            idx as int,
            recipient,
            recipient,
            0,
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
        );
    }
}

// Outgoing TIP-4 transfer, reused by execute/cancel — all of them
// send NFTs onward through this same body builder.
fun sendNftTransfer(
    nft: address,
    queryId: int,
    newOwner: address,
    responseDest: address,
    value: coins,
    mode: int,
) {
    val m = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value,
        dest: nft,
        body: NftTransfer {
            queryId,
            newOwner,
            responseDestination: responseDest,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: zeroBitSlice(),
        },
    });
    m.send(mode);
}

// Auto-return of a foreign, duplicate or late NFT, so that it does not simply
// sit on the escrow's balance. NEVER throw in any case — the
// incoming transaction must stay successful, or the NFT master would see a
// failed tx on OwnershipAssigned, which looks like a bug.
fun returnForeignNft(nft: address, to: address, incomingValue: coins) {
    if (incomingValue < RETURN_TRANSFER_VALUE) {
        return; // underpaid gas — the NFT stays with the escrow (documented risk)
    }
    // mode 64 (CARRY_ALL_REMAINING_MESSAGE_VALUE): the return is funded by
    // the value attached to THIS incoming message, not by the contract's balance.
    val m = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: nft,
        body: NftTransfer {
            queryId: 0,
            newOwner: to,
            responseDestination: to,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: zeroBitSlice(),
        },
    });
    m.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// Outgoing TEP-74 transfer from OUR jetton wallet. Reused by: distribution,
// returns (returnJettons below), cancel.
// forwardTonAmount = 0 — no recipient notification, matching how NFTs are
// distributed; leftover gas from the transfer comes back to responseDest
// as excesses.
fun sendJettonTransfer(
    wallet: address,
    queryId: int,
    amount: coins,
    dest: address,
    responseDest: address,
    value: coins,
    mode: int,
) {
    val m = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value,
        dest: wallet,
        body: JettonTransfer {
            queryId,
            amount,
            destination: dest,
            responseDestination: responseDest,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: zeroBitSlice(),
        },
    });
    m.send(mode);
}

// Auto-return of jettons (underpaid/duplicate/foreign/late) — mirrors
// returnForeignNft. NO throw at all. The return is a
// reverse transfer through sender() (our wallet); a fake notification from
// a foreign address gets a transfer message back that does nothing there.
// BounceMode.NoBounce so the reply to the fake does not bounce back to us.
fun returnJettons(ourWallet: address, to: address, amount: coins, incomingValue: coins) {
    if (incomingValue < RETURN_TRANSFER_VALUE) {
        return; // underpaid gas — the tokens stay in the wallet (documented risk)
    }
    val m = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: ourWallet,
        body: JettonTransfer {
            queryId: 0,
            amount,
            destination: to,
            responseDestination: to,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: zeroBitSlice(),
        },
    });
    m.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// Hint from forward_payload: either bit 0 + uint16.
// Anything else (ref-payload, shorter than 17 bits) means "no hint" -> -1.
fun parseAssetIndexHint(payload: slice): int {
    if (payload.remainingBitsCount() < 17) {
        return -1;
    }
    val isRef = payload.loadBool();
    if (isRef) {
        return -1;
    }
    return payload.loadUint(16);
}

// Verifies the registry entry against the actual sender (the
// index is a hint that requires verification; the pair (our wallet,
// depositor) is used because one minter can be on both sides of the deal).
fun Storage.jettonAssetMatches(self, a: Asset, ourWallet: address, depositor: address): bool {
    if (a.kind != 1 || a.received) {
        return false;
    }
    if (a.jettonWallet == null) {
        return false; // per-asset gate: the minter is not resolved yet
    }
    if (a.jettonWallet! != ourWallet) {
        return false;
    }
    val sideOwner = a.ownerSide == 1 ? self.owner1 : self.owner2;
    return sideOwner == depositor;
}

// Asset lookup: hint first (O(1) after bounds checking; does NOT verify
// the amount — the hint explicitly addresses a slot, and
// underpayment/overpayment are handled further up the call stack).
// Fallback runs in TWO passes: (1) exact amount match — otherwise, with
// several assets from the same minter on ONE side at different amounts, a
// deposit would match the first slot by key order and a legitimate
// transfer would be rejected as "underpayment"; (2) any match on the
// (wallet, depositor) pair. -1 = not found.
fun Storage.matchJettonAsset(
    self,
    ourWallet: address,
    depositor: address,
    hintIdx: int,
    amount: coins,
): int {
    val n = self.assetsCount as int;
    if (hintIdx >= 0 && hintIdx < n) {
        val a = self.assets.mustGet(hintIdx as uint16);
        if (self.jettonAssetMatches(a, ourWallet, depositor)) {
            return hintIdx;
        }
    }
    var i: int = 0;
    while (i < n) {
        if (i != hintIdx) {
            val a = self.assets.mustGet(i as uint16);
            if (self.jettonAssetMatches(a, ourWallet, depositor) && a.amount == amount) {
                return i;
            }
        }
        i += 1;
    }
    i = 0;
    while (i < n) {
        if (i != hintIdx) {
            val a = self.assets.mustGet(i as uint16);
            if (self.jettonAssetMatches(a, ourWallet, depositor)) {
                return i;
            }
        }
        i += 1;
    }
    return -1;
}

// Jetton receipt (the "receipt rules", items 2-4). WITHOUT A SINGLE throw.
fun handleJettonNotification(sender: address, value: coins, msg: JettonTransferNotification) {
    var st = Storage.load();

    // terminal phases (DONE/CANCELLED/EXECUTING) -> a late transfer, return it
    if (st.phase != PHASE_ACTIVE && st.phase != PHASE_SETUP) {
        returnJettons(sender, msg.sender, msg.amount, value);
        return;
    }

    val payload = msg.forwardPayload;
    val idx = st.matchJettonAsset(sender, msg.sender, parseAssetIndexHint(payload), msg.amount);
    if (idx < 0) {
        // foreign jetton / fake notification / duplicate / wallet not resolved yet
        returnJettons(sender, msg.sender, msg.amount, value);
        return;
    }
    var asset = st.assets.mustGet(idx as uint16);

    if (msg.amount < asset.amount) {
        // underpayment: topping up in parts is not supported — return it in full
        returnJettons(sender, msg.sender, msg.amount, value);
        return;
    }

    var reserveCredit = value;
    var committedOut: coins = 0; // value already queued for send by this transaction
    if (msg.amount > asset.amount) {
        // overpayment: return the excess in the same transaction if the value
        // covers it; otherwise the excess stays in our wallet (documented risk)
        if (value >= RETURN_TRANSFER_VALUE) {
            // queryId MUST be a non-asset sentinel, not 0: sendJettonTransfer
            // builds the message with bounce: BounceMode.Only256BitsOfBody, and a bounce of this
            // refund carrying queryId 0 would be read by onBouncedMessage as
            // a bounce of asset index 0 — marking asset 0 claimable although it was delivered.
            sendJettonTransfer(
                sender,
                QUERY_ID_NON_ASSET,
                msg.amount - asset.amount,
                msg.sender,
                msg.sender,
                RETURN_TRANSFER_VALUE,
                SEND_MODE_REGULAR,
            );
            reserveCredit = value - RETURN_TRANSFER_VALUE;
            committedOut = RETURN_TRANSFER_VALUE; // the auto-execution formulas must subtract this
        }
    }

    asset.received = true;
    st.assets.set(idx as uint16, asset);

    var g = st.grams.load();
    if (asset.ownerSide == 1) {
        st.received1Count += 1;
        st.receivedJettons1 += 1;
        g.gram1DepositReserve += reserveCredit;
    } else {
        st.received2Count += 1;
        st.receivedJettons2 += 1;
        g.gram2DepositReserve += reserveCredit;
    }
    st.grams = g.toCell();

    // Record the deposit before attempting execution: the jetton has already
    // moved and its notification does not bounce, so if execution ran out of
    // gas here the record must survive. COMMIT keeps it even if an exception
    // follows; the deal then waits for execute_swap. The overpayment refund
    // queued above is committed with it.
    st.save();
    commitContractDataAndActions();
    st.tryAutoExecute(committedOut);
    st.save();
}

// A registry slot that can take this NFT from this sender: an unreceived NFT
// slot for the same item, and — when checkSender — one whose side owner is the
// sender. The sender is only checked when the notification carries enough to
// send a rejected item back (RETURN_TRANSFER_VALUE): below that a rejected
// item would stay unrecorded with the escrow, and after cancel it would
// normally go to the same side owner anyway — except when the same address
// is also listed on the OTHER side, in which case claim_asset's cross-side
// check (Storage.hasCrossSideDuplicate) refuses either side's unrecorded
// slot. So rejecting the deposit here would only break the deal.
fun Storage.nftSlotAccepts(self, a: Asset, nft: address, sender: address, checkSender: bool): bool {
    if (a.kind != 0 || a.received || a.addr != nft) {
        return false;
    }
    if (!checkSender) {
        return true;
    }
    val sideOwner = a.ownerSide == 1 ? self.owner1 : self.owner2;
    return sideOwner == sender;
}

fun handleNftReceived(sender: address, value: coins, msg: OwnershipAssigned) {
    var st = Storage.load();
    val nft = sender;

    // Accepted only in SETUP/ACTIVE; in DONE/CANCELLED/EXECUTING — return to sender
    if (st.phase != PHASE_ACTIVE && st.phase != PHASE_SETUP) {
        returnForeignNft(nft, msg.previousOwner, value);
        return;
    }

    var foundIdx = -1;
    var asset: Asset = Asset {
        kind: 0,
        ownerSide: 0,
        addr: nft,
        jettonWallet: null,
        amount: 0,
        received: false,
        walletUnverified: false,
        bounces: 0,
        claimable: false,
    };

    // O(1) hint for NFT receipt: the frontend puts asset_index in the
    // deposit's forward_payload (the same either-0 + uint16 format as the
    // jetton hint; the mock/real item passes the
    // payload straight through in OwnershipAssigned). THE INDEX IS ONLY A
    // HINT, NOT A SOURCE OF TRUTH: it is verified by the same predicate as
    // the linear fallback below — item address, unreceived, and (when the
    // value can pay a return) the sender — so there is no way to forge the
    // index to sneak in the wrong/a foreign NFT, or to hint at another
    // side's slot. A wrong hint falls through to the fallback, then to
    // auto-return. The hint only replaces an O(N) scan with an O(1) lookup,
    // removing the deposit ceiling (~850 -> no ceiling).
    val checkSender = value >= RETURN_TRANSFER_VALUE;
    val hintIdx = parseAssetIndexHint(msg.forwardPayload);
    if (hintIdx >= 0 && hintIdx < (st.assetsCount as int)) {
        val a = st.assets.mustGet(hintIdx as uint16);
        if (st.nftSlotAccepts(a, nft, msg.previousOwner, checkSender)) {
            foundIdx = hintIdx;
            asset = a;
        }
    }

    // Fallback: no hint, a malformed one, or one that does not accept this
    // item from this sender -> linear search with the same predicate, so a
    // wrong hint falls through to the right slot instead of bouncing the item.
    // The asset is captured directly during the scan, so there is no repeat
    // dictionary lookup (`mustGet`) after the loop.
    if (foundIdx < 0) {
        var r = st.assets.findFirst();
        while (r.isFound && foundIdx < 0) {
            val a = r.loadValue();
            if (st.nftSlotAccepts(a, nft, msg.previousOwner, checkSender)) {
                foundIdx = r.getKey();
                asset = a;
            }
            r = st.assets.iterateNext(r);
        }
    }

    if (foundIdx < 0) {
        // No free registry slot for this item and sender: a foreign NFT, a
        // duplicate of a received item, or a third party's deposit -> auto-return.
        returnForeignNft(nft, msg.previousOwner, value);
        return;
    }

    asset.received = true;
    st.assets.set(foundIdx as uint16, asset);

    var g = st.grams.load();
    if (asset.ownerSide == 1) {
        st.received1Count += 1;
        g.gram1DepositReserve += value;
    } else {
        st.received2Count += 1;
        g.gram2DepositReserve += value;
    }
    st.grams = g.toCell();

    // Record the deposit before attempting execution: the item's ownership has
    // already moved and its notification does not bounce, so if execution ran
    // out of gas here the record must survive. COMMIT keeps it even if an
    // exception follows; the deal then waits for execute_swap.
    st.save();
    commitContractDataAndActions();
    st.tryAutoExecute(0);
    st.save();
}

// sup:begin
// ── Supervisor ──
// The commands below are SwapEscrowV2's only difference from SwapEscrowNosup.
// Each is accepted only from sup.supervisor (404 before any other check).

fun requireSupervisor(sender: address, st: Storage): SupervisorState {
    val sup = st.sup.load();
    assert (sender == sup.supervisor) throw Errors.NotSupervisor;
    return sup;
}

// Sends every received asset to the recipient of `mode` (assetRecipient); in
// DIST_COLLECT a slot whose wallet the minter has not confirmed stays. The
// fast path of the supervisor's operations (registry of <= 100 entries).
fun Storage.sendReceived(self, mode: int) {
    var r = self.assets.findFirst();
    while (r.isFound) {
        val a = r.loadValue();
        if (a.received && !(mode == DIST_COLLECT && a.walletUnverified)) {
            val (dest, resp) = self.assetRecipient(a, mode);
            sendAsset(a, r.getKey() as int, dest, resp);
        }
        r = self.assets.iterateNext(r);
    }
}

// What a supervisor's batch operation must attach: the chain's later
// transactions run on the escrow's balance, so the attachment pays for them
// up front — the same addition quoteCancel makes for a batch cancel.
fun Storage.emergencyChainReserve(self): coins {
    val receivedTotal = (self.received1Count as int) + (self.received2Count as int);
    return calculateGasFee(BASECHAIN, EXEC_GAS_UNITS_PER_SEND * receivedTotal) +
        batchChainReserve(self.assetsCount as int, receivedTotal) +
        continueMsgValue();
}

// emergency_return_assets — SETUP/ACTIVE -> CANCELLED, every received asset
// back to its depositor, TON split by the settlement rules (as cancel_swap).
// The supervisor's attachment pays this transaction's gas and any batch chain
// and stays out of the split; the sides bear their own returns, the dust
// margin and the storage floor. No balance check below the chain reserve and
// no sweep to feeWallet: what is left stays on the escrow
// (emergency_withdraw_ton). An attachment that cannot pay for the returns
// fails the action phase, which rolls the whole transaction back.
fun handleEmergencyReturn(sender: address, value: coins) {
    var st = Storage.load();
    requireSupervisor(sender, st);
    assert (st.phase == PHASE_ACTIVE || st.phase == PHASE_SETUP) throw Errors.AlreadyFinalized;
    val registrySize = st.assetsCount as int;
    if (registrySize > FAST_PATH_MAX_ASSETS) {
        assert (value >= st.emergencyChainReserve()) throw Errors.InsufficientBalance;
    }
    val g = st.grams.load();
    val o1 = st.ownTransferCost(1);
    val o2 = st.ownTransferCost(2);
    val r = contract.getOriginalBalance() - value - o1 - o2 - DUST - st.storageFloor();
    val (refund1, refund2) = splitRefunds(r, paidBy(g, 1) - o1, paidBy(g, 2) - o2);
    st.phase = PHASE_CANCELLED;
    val minRefund = sendableMinimum();
    var queued: coins = 0;
    if (refund1 >= minRefund) {
        createMessage({ bounce: BounceMode.NoBounce, value: refund1, dest: st.owner1 }).send(
            SEND_MODE_REGULAR,
        );
        queued += refund1;
    }
    if (refund2 >= minRefund) {
        createMessage({ bounce: BounceMode.NoBounce, value: refund2, dest: st.owner2 }).send(
            SEND_MODE_REGULAR,
        );
        queued += refund2;
    }
    if (registrySize <= FAST_PATH_MAX_ASSETS) {
        st.sendReceived(DIST_RETURN);
        st.save();
        return;
    }
    st.dist = DistState {
        mode: DIST_RETURN,
        cursor: 0,
    }.toCell();
    st.runDistributionBatch(queued);
    st.save();
}

// emergency_collect_assets — SETUP/ACTIVE -> CANCELLED, every received asset
// and the rescue registry to the supervisor; no TON is refunded (the balance
// is the supervisor's to withdraw). A jetton slot whose wallet the minter has
// not confirmed is not sent: the claimed address may not be the escrow's
// wallet. After checking it, the supervisor takes those tokens with
// RescueJetton. A later minter answer is ignored (the phase is no longer
// SETUP), so such a slot stays unconfirmed. Above 100 entries the attachment
// must cover the batch chain (430), as for emergency_return_assets.
fun handleEmergencyCollect(sender: address, value: coins) {
    var st = Storage.load();
    val sup = requireSupervisor(sender, st);
    assert (st.phase == PHASE_ACTIVE || st.phase == PHASE_SETUP) throw Errors.AlreadyFinalized;
    if ((st.assetsCount as int) > FAST_PATH_MAX_ASSETS) {
        assert (value >= st.emergencyChainReserve()) throw Errors.InsufficientBalance;
    }
    st.phase = PHASE_CANCELLED;
    if ((st.assetsCount as int) <= FAST_PATH_MAX_ASSETS) {
        st.sendReceived(DIST_COLLECT);
    } else {
        st.dist = DistState {
            mode: DIST_COLLECT,
            cursor: 0,
        }.toCell();
        st.runDistributionBatch(0);
    }
    var rr = sup.rescueAssets.findFirst();
    while (rr.isFound) {
        sendNftTransfer(
            rr.loadValue(),
            QUERY_ID_RESCUE_REGISTRY,
            sup.supervisor,
            sup.supervisor,
            NFT_TRANSFER_VALUE,
            SEND_MODE_REGULAR,
        );
        rr = sup.rescueAssets.iterateNext(rr);
    }
    st.save();
}

// ForceDeliver — the supervisor delivers a recorded asset the push delivery
// did not land: the same admission as claim_asset for recorded assets (a
// jetton only while claimable; an NFT once the distribution has passed it).
// An NFT the escrow never recorded is RescueNft's case. fallback = false: to
// claim_asset's recipient (the counterparty while executing or after DONE,
// the depositor after CANCELLED); fallback = true: to the supervisor, for a
// recipient that keeps refusing. Paid entirely by the attachment (mode 64).
// An NFT the escrow no longer owns refuses the transfer, so nothing moves.
fun handleForceDeliver(sender: address, value: coins, msg: ForceDeliver) {
    var st = Storage.load();
    val sup = requireSupervisor(sender, st);
    assert (
        st.phase == PHASE_EXECUTING || st.phase == PHASE_DONE || st.phase == PHASE_CANCELLED
    ) throw Errors.AlreadyFinalized;
    val idx = msg.assetIndex;
    assert ((idx as int) < (st.assetsCount as int)) throw Errors.BadAssetIndex;
    var a = st.assets.mustGet(idx);
    if (a.kind == 1) {
        assert (a.claimable) throw Errors.NotClaimable;
    } else {
        assert (a.received) throw Errors.NotClaimable;
        val d = st.dist.load();
        assert (d.mode == DIST_IDLE || (idx as int) < (d.cursor as int)) throw Errors.NotClaimable;
    }
    var recipient = sup.supervisor;
    if (!msg.fallback) {
        val depositor = a.ownerSide == 1 ? st.owner1 : st.owner2;
        val counterparty = a.ownerSide == 1 ? st.owner2 : st.owner1;
        recipient = st.phase == PHASE_CANCELLED ? depositor : counterparty;
    }
    val need = a.kind == 1 ? JETTON_TRANSFER_VALUE : NFT_TRANSFER_VALUE;
    assert (value >= need) throw Errors.InsufficientBalance;
    if (a.claimable) {
        a.claimable = false;
        st.assets.set(idx, a);
        st.save();
    }
    if (a.kind == 1) {
        sendJettonTransfer(
            a.jettonWallet!,
            idx as int,
            a.amount,
            recipient,
            recipient,
            0,
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
        );
    } else {
        sendNftTransfer(
            a.addr,
            idx as int,
            recipient,
            recipient,
            0,
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
        );
    }
}

// emergency_withdraw_ton: the whole balance to the supervisor, in any phase,
// deliberately — after DONE or CANCELLED TON can still sit on the balance. No
// state changes; the supervisor's attachment pays this transaction's gas.
fun handleEmergencyWithdraw(sender: address, _value: coins) {
    val st = Storage.load();
    val sup = requireSupervisor(sender, st);
    // SAFETY: the whole function — requireSupervisor has checked the sender,
    // and there is no state to protect (no phase gate, no save). A full
    // balance sweep to the supervisor is what this command is.
    createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: sup.supervisor }).send(
        SEND_MODE_CARRY_ALL_BALANCE,
    );
}

// Registers a foreign or stuck NFT in the isolated rescue registry
// (sup.rescueAssets), unrelated to the deal's assets; it is swept only by
// emergency_collect_assets.
fun handleSupervisorAssetReceived(sender: address, _value: coins, msg: SupervisorAssetReceived) {
    var st = Storage.load();
    var sup = requireSupervisor(sender, st);
    sup.rescueAssets.set(sup.rescueCount, msg.assetAddr);
    sup.rescueCount += 1;
    st.sup = sup.toCell();
    st.save();
}

// A one-off rescue of a named NFT to the supervisor (any address, deal assets
// included). No phase gate and no state change — just a forward.
fun handleRescueNft(sender: address, _value: coins, msg: RescueNft) {
    val st = Storage.load();
    val sup = requireSupervisor(sender, st);
    sendNftTransfer(
        msg.nftAddr,
        QUERY_ID_NON_ASSET,
        sup.supervisor,
        sup.supervisor,
        NFT_TRANSFER_VALUE,
        SEND_MODE_REGULAR,
    );
}

// The same for jettons: a named amount from one of the escrow's jetton wallets
// to the supervisor. The escrow does not know its wallets' balances — the
// supervisor supplies the amount. No phase gate and no state change.
fun handleRescueJetton(sender: address, _value: coins, msg: RescueJetton) {
    val st = Storage.load();
    val sup = requireSupervisor(sender, st);
    sendJettonTransfer(
        msg.jettonWallet,
        QUERY_ID_NON_ASSET,
        msg.amount,
        sup.supervisor,
        sup.supervisor,
        JETTON_TRANSFER_VALUE,
        SEND_MODE_REGULAR,
    );
}

// sup:end

// Bounce handling for outgoing asset transfers.
// bounce-body = 0xFFFFFFFF + the first 256 bits of the original body —
// op(32) + queryId(64) are always available; the queryId of an outgoing
// asset transfer is its registry index. A bounce never stalls distribution:
// it only marks the asset claimable, and its recipient pulls it with
// claim_asset. Paid for by the bounced value, so it stays minimal: one
// registry read, one write, no loops.
fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
    if (in.bouncedBody.remainingBitsCount() < 96) {
        return;
    }
    val op = in.bouncedBody.loadUint(32);
    if (op != 0x5fcc3d14 && op != 0x0f8a7ea5) {
        return; // not NftTransfer / JettonTransfer (includes ContinueDistribution — recovered via kick)
    }
    val queryId = in.bouncedBody.loadUint(64);
    if (queryId >= QUERY_ID_NON_ASSET) {
        return; // reserved sentinels — outside the deal's registry
    }
    var st = Storage.load();
    if ((queryId as int) >= (st.assetsCount as int)) {
        return;
    }
    if (st.phase != PHASE_EXECUTING && st.phase != PHASE_DONE && st.phase != PHASE_CANCELLED) {
        return; // asset transfers only leave the escrow in these phases
    }
    val idx = queryId as uint16;
    var a = st.assets.mustGet(idx);
    if (!a.received) {
        return;
    }
    if (a.bounces < 15) {
        a.bounces += 1; // saturating counter — no uint4 overflow
    }
    a.claimable = true;
    st.assets.set(idx, a);
    st.save();
}

// Getters read storage with `lazy Storage.load()`, which deserializes only the
// fields they use.
get fun phase(): int {
    val st = lazy Storage.load();
    return st.phase;
}

get fun swapId(): int {
    val st = lazy Storage.load();
    return st.swapId;
}

get fun canAutoExecuteNow(): bool {
    val st = lazy Storage.load();
    return st.canAutoExecute(0);
}

// How much each side still has to pay before the deal can execute (0 when
// funded). Paying this amount must pass the leg check (gramNReceived against
// gramNAmount), the per-side check (sideFunded) and the balance check
// (balanceCovers, throw 430). A payment made through execute_swap or a
// deposit raises paidBy and gramNReceived by the same amount, so per side the
// first two need a_N = max(0, sideShare - paidBy, gramNAmount - gramNReceived).
// The per-side counters credit deposits gross, while every deposit's
// processing gas comes off the shared balance, so paying a_1 + a_2 can still
// leave the balance below minBalanceForSwap. That deficit,
// max(0, minBalanceForSwap - (balance + a_1 + a_2)), is split equally on top
// (side 2 takes the odd nanoton) while the deal is in SETUP or ACTIVE.
// The balance check reads the balance before the paying message's own gas, so
// the payment that completes the deal needs nothing extra. When both sides pay
// figures read at the same time, the first payment's processing gas
// (758,401 nanoton for a deposit_ton1/2 at today's gas price, measured by
// tests/nosup/execute_swap.test.tolk) comes off the balance before the second
// arrives, so each side adds 0.001 TON to its figure (one side's 0.001 alone
// covers that gas with a 32% margin).
// After one side's payment has landed its figure is only its half of the
// remaining deficit, and the other side can pay both figures together.
// Deposits still to come add their attached value. Walks the registry.
// The figure also keeps both settlement shares at or above zero, so each side
// bears exactly half of what the deal spent, including the deployment and
// wallet discovery that side 2 paid up front. It is exact when read after
// every asset has arrived (each later deposit spends gas from the shared
// balance), so the TON part is paid last. A side that pays both figures still
// executes the deal; what it paid beyond its own share comes back to it.
get fun executionShortfall(): (int, int) {
    val st = lazy Storage.load();
    val g = st.grams.load();
    var s1 = st.sideShare(g, 1, st.registryTransferCost(1)) - paidBy(g, 1);
    val leg1 = g.gram1Amount - g.gram1Received;
    if (leg1 > s1) {
        s1 = leg1;
    }
    if (s1 < 0) {
        s1 = 0;
    }
    var s2 = st.sideShare(g, 2, st.registryTransferCost(2)) - paidBy(g, 2);
    val leg2 = g.gram2Amount - g.gram2Received;
    if (leg2 > s2) {
        s2 = leg2;
    }
    if (s2 < 0) {
        s2 = 0;
    }
    if (st.phase != PHASE_ACTIVE && st.phase != PHASE_SETUP) {
        // A settled or executing deal has no balance check left to pass.
        return (s1, s2);
    }
    val deficit = st.minBalanceForSwap(g) - (contract.getOriginalBalance() + s1 + s2);
    if (deficit > 0) {
        val half1 = deficit / 2;
        s1 += half1;
        s2 += deficit - half1;
    }
    // Both formula shares must stay at or above zero after the payments, or
    // the side that paid more would also bear the other side's half (see
    // noClampTopUps). R and the nets are taken as execution will compute them,
    // with every registry asset counted at its transfer cost.
    val r = contract.getOriginalBalance() + s1 + s2 - st.minBalanceForSwap(g);
    val n1 = paidBy(g, 1) + s1 - g.gram1Amount - SERVICE_FEE - st.registryTransferCost(1);
    val n2 = paidBy(g, 2) + s2 - g.gram2Amount - SERVICE_FEE - st.registryTransferCost(2);
    val (t1, t2) = noClampTopUps(r, n1, n2);
    s1 += t1;
    s2 += t2;
    return (s1, s2);
}

// What cancel_swap needs now: (required, value to attach). The value covers
// both sides' shortfalls plus the gas to reach the balance check; anything
// attached above that comes back to the canceller.
get fun cancelCost(): (int, int) {
    val st = lazy Storage.load();
    val g = st.grams.load();
    val balance = contract.getOriginalBalance();
    val q = st.quoteCancel(g, balance);
    var shortfall = q.required - balance;
    if (shortfall < 0) {
        shortfall = 0;
    }
    return (q.required, shortfall + calculateGasFee(BASECHAIN, CANCEL_PRECHECK_GAS_UNITS));
}

// One year of storage fees for this deal's state; a settled escrow keeps this
// much on its balance.
get fun storageFloor(): int {
    val st = lazy Storage.load();
    return st.storageFloor();
}

get fun receivedCounts(): (int, int) {
    val st = lazy Storage.load();
    return (st.received1Count, st.received2Count);
}

get fun gramState(): GramState {
    val st = lazy Storage.load();
    return st.grams.load();
}

get fun pendingWalletsLeft(): int {
    val st = lazy Storage.load();
    return st.pendingWallets;
}

get fun assetJettonWallet(idx: int): address? {
    val st = lazy Storage.load();
    val a = st.assets.mustGet(idx as uint16);
    return a.jettonWallet;
}

// The jetton wallet of a registry slot and whether its minter confirmed it.
// (address, false) is a wallet side 2 claimed that the minter has not
// answered for yet; (null, false) means no wallet is known.
get fun jettonWalletStatus(idx: int): (address?, bool) {
    val st = lazy Storage.load();
    val a = st.assets.mustGet(idx as uint16);
    return (a.jettonWallet, a.jettonWallet != null && !a.walletUnverified);
}

// Batch distribution progress (mode, cursor).
get fun distributionProgress(): (int, int) {
    val st = lazy Storage.load();
    val d = st.dist.load();
    return (d.mode as int, d.cursor as int);
}

// Delivery state of one registry entry: (received, claimable, bounces).
get fun assetStatus(idx: int): (bool, bool, int) {
    val st = lazy Storage.load();
    val a = st.assets.mustGet(idx as uint16);
    return (a.received, a.claimable, a.bounces as int);
}

// Registry indices currently marked claimable. A claimable NFT may already
// be with its recipient (a claim of a delivered NFT bounces and marks it);
// check the NFT's owner before offering a claim.
get fun claimableAssets(): map<uint16, bool> {
    val st = lazy Storage.load();
    var out: map<uint16, bool> = [];
    var r = st.assets.findFirst();
    while (r.isFound) {
        if (r.loadValue().claimable) {
            out.set(r.getKey(), true);
        }
        r = st.assets.iterateNext(r);
    }
    return out;
}

// sup:begin
get fun supervisor(): address {
    return Storage.load().sup.load().supervisor;
}
// sup:end
