// Copyright (C) 2026 MENA
// SPDX-License-Identifier: AGPL-3.0-or-later
// Types and constants shared by SwapEscrowNosup and SwapEscrowV2.

// Phases. SETUP is used when a deal involves jettons — jetton deals deploy
// into PHASE_SETUP and wait for TEP-89 discovery of all unique minters (see
// handleDeployFee/handleTakeWalletAddress in the escrow contracts); NFT-only
// deals (pendingWallets == 0) still deploy straight into ACTIVE.
const PHASE_SETUP = 0
const PHASE_ACTIVE = 1
const PHASE_EXECUTING = 2 // set only for large deals routed through the batch-distribution engine (see Storage.executeSwap)
const PHASE_DONE = 3
const PHASE_CANCELLED = 4

// User-facing economics: what a deal costs its participants. DO NOT change
// these — every deployed deal's arithmetic is calibrated against them, and a
// change also moves the code hash and therefore every deal address.
const SERVICE_FEE = ton("0.1")
const NFT_TRANSFER_VALUE = ton("0.03")
const DUST = ton("0.003")

// Storage floor: a settled escrow keeps one year of storage fees so its pull
// path does not die with a frozen account. The contract cannot read its own
// size, so bits and cells are modelled from the registry size and priced by
// calculateStorageFee against the current network storage prices. Calibrated
// in tests/nosup/storage_floor.test.tolk: the model must stay between 1x and
// 1.5x of the measured fee on NFT and jetton registries.
// Under today's prices a cell costs about 64,962 nanoton a year and bits are
// priced near zero, so the cell terms carry the model. Measured: each registry
// entry adds 2 cells (129,924 nanoton a year per entry between 300 and 1,000
// entries), the rest of the state about 176 cells. Year fee, measured / model:
// 1x1 NFT 11,693,189 / 16,500,389 (1.41x); 300 entries 50,410,635 /
// 55,217,835 (1.10x); 1,000 entries 141,357,657 / 146,164,856 (1.034x); a
// two-jetton deal 11,693,189 / 16,500,389 (1.41x). The margin is the 74 cells
// of base above the measured 176, so the code can grow by about 50 cells
// before the 1,000-entry case drops below 1x; the per-entry term is exact.
// The bits terms
// only matter if bit prices rise: an Asset is 590 bits for a jetton (two
// addresses and an amount) and 283 for an NFT, plus the dictionary labels,
// so 700 per entry covers the wider jetton entry.
const STORAGE_FLOOR_SECONDS = 31536000
const STORAGE_BITS_BASE = 20000
const STORAGE_CELLS_BASE = 250
const STORAGE_BITS_PER_ASSET = 700
const STORAGE_CELLS_PER_ASSET = 2

// Gas cost is stored in GAS UNITS (config-independent), converted to TON via
// calculateGasFee (GETGASFEE) against the CURRENT network config (the same
// pattern as TON's reference stablecoin contract). The units correspond to
// the intended 0.003/0.0006 TON at a price of 66.67 nanoton/unit
// (4369067/2^16): 45000 ≈ 0.003, 9000 ≈ 0.0006.
// Margin over measured consumption (gas ≈ 18445 + 4231×N) is preserved:
// 2.44× (base), 2.13× (per send). If the gas price changes via the network
// config, the reserve recalculates itself — the margin principle "reserve ≥
// actual cost" does not depend on the constants staying up to date.
// BASECHAIN is already defined in stdlib (common.tolk) — reused, not duplicated.
const EXEC_GAS_UNITS_BASE = 45000
const EXEC_GAS_UNITS_PER_SEND = 9000
const RETURN_TRANSFER_VALUE = ton("0.03")

// Value for each outgoing jetton transfer — pricier than NFT (two hops: our
// wallet -> internal_transfer -> the recipient's wallet)
const JETTON_TRANSFER_VALUE = ton("0.05")
// value for each TEP-89 provide_wallet_address to a unique minter (SETUP);
// a jetton deal's deploy transaction must carry
// 0.05 + PROVIDE_WALLET_VALUE × <number of unique minters>
const PROVIDE_WALLET_VALUE = ton("0.02")

// handleDeployFee scans ALL assetsCount entries (not just jetton ones) on
// every deploy_fee in PHASE_SETUP, so the deploy value must scale with the
// TOTAL asset count — not with the number of unique minters. Pricing it from
// minters alone leaves a jetton deal short of gas at 38-39 total assets
// (action_result_code=37, "Not enough Toncoin"), because the per-entry scan
// is paid for by nobody.
// Hence the deploy value adds calculateGasFee(BASECHAIN,
// DEPLOY_GAS_UNITS_PER_ASSET × assetsCount) on top of the flat fee, the same
// gas-units pattern as EXEC_GAS_UNITS_* above.
// Measured with one minter owning every asset — the worst case for this
// scan: total=10 -> 17311 gas, total=40 -> 53331 gas, total=100 -> 127421
// gas. Linear model (least squares): gas ≈ 4768 + 1225×N; the intercept is
// already covered with margin by the flat 0.05 TON, so no separate BASE
// constant is needed. Margin ≥2× over the measured per-asset cost (1225):
// chose 3000 (≈2.45×, the same margin style as EXEC_GAS_UNITS_PER_SEND).
const DEPLOY_GAS_UNITS_PER_ASSET = 3000

// Registry-size-independent part of one deploy_fee call (argument parsing,
// minter dedup map, the provide loop over unique minters). Measured: a call on
// a 1-entry registry uses 8,406 gas, of which DEPLOY_GAS_UNITS_PER_ASSET covers
// 3,000; 15,000 leaves ~2.8x over the remaining 5,406.
const DEPLOY_BASE_GAS_UNITS = 15000

// Gas of the minter's take_wallet_address answer, priced per minter by the
// number of its slots k (handleTakeWalletAddress): a walk over all n registry
// entries plus a write for each of the minter's k slots. Measured on Tolk
// 1.5 with one minter M and the rest of the registry owned by another:
// walk (k = 1) n=10 -> 16,905, n=40 -> 45,665, n=100 -> 103,210 gas, so
// about 7,315 + 959 per entry; the write per slot, in the worst case where
// every slot of M holds a provisional deposit the answer undoes, is
// 3,742 / 4,898 / 5,604 gas at k = n = 10 / 40 / 100 (it grows with the
// dictionary's depth). Each constant is about 1.5x its measurement.
const TAKE_SCAN_BASE_UNITS = 11000
const TAKE_SCAN_UNITS_PER_ENTRY = 1500
const TAKE_SET_UNITS = 8500

// Gas model of AcceptDeal's claim and discovery passes: a walk over every
// registry entry (twice: claims, then the discovery plan) and a dictionary
// write per claimed slot, bounded by jettonsCount. AcceptDeal writes claims and
// starts discovery only while the model stays within TX_GAS_LIMIT_CEILING;
// above it the message only credits side 2, so it never runs out of gas on a
// large registry. Measured on Tolk 1.5 (AcceptDeal below the discovery price,
// j claimed slots of one minter plus n - j dummy entries): (n, j) = (1, 1)
// 14,142; (101, 1) 206,142; (301, 1) 611,817; (40, 40) 313,525; (80, 80)
// 662,680 gas — about 14,100 + 1,920..1,992 per entry + 6,200 per claim
// (both grow with the dictionary's depth). Each constant is about 1.2x its
// measurement, so a deal the model admits uses at most about 1/1.2 of the
// ceiling (a jetton-only registry of up to 93 claimed slots).
const ACCEPT_BASE_UNITS = 17000
const ACCEPT_UNITS_PER_ENTRY = 2500
const ACCEPT_UNITS_PER_CLAIM = 8000

// Limits the deploying side (the dapp) enforces; the contract does not read
// them.
// TAKE_MAX_SLOTS: slots of one minter whose answer still fits the
// transaction ceiling with a 1.2x margin. At this size AcceptDeal writes no
// claims (the ACCEPT_* model admits at most 93), so the answer only records
// the wallet: 120 -> 741,610, 140 -> 925,750, 160 -> out of gas. The heaviest
// answer with claims (every claimed slot undone) is pinned at the model's
// edge in tests/nosup/section2_limits. Above TAKE_MAX_SLOTS the deal may never
// leave SETUP (it stays cancellable).
const TAKE_MAX_SLOTS = 120
// ONE_SIGNATURE_MAX_ASSETS: a registry size up to which the last minter
// answer is sure to execute the deal in its own transaction, measured on the
// harshest shape (every slot a jetton of one minter, provisionally
// deposited): 40, 60, 80, 90 slots execute (answer and execution 385,356 /
// 578,126 / 793,671 / 893,881 gas); 90 less 10%. Within the ACCEPT_* model
// even the heaviest claimed deal (9 NFTs + 91 jettons) executes, at 956,603;
// should an answer still run out, it keeps the deal ACTIVE and execute_swap
// settles it.
const ONE_SIGNATURE_MAX_ASSETS = 80

// ── Reserved queryId sentinels ──
// Outgoing NFT/jetton transfers carry the asset's registry index as their
// queryId, and onBouncedMessage reads it back to decide which asset bounced.
// Transfers that are NOT registry assets must therefore use a queryId that
// can never be mistaken for an index: onBouncedMessage ignores any bounce at
// or above QUERY_ID_NON_ASSET. Anything sent with a literal 0 would be
// indistinguishable from a bounce of asset index 0.
// The registry is keyed by uint16, so reserving the top values costs theoretically-addressable indices that no real deal can reach.
const QUERY_ID_NON_ASSET = 0xFFFE // jetton excess refunds

// ── Batch distribution (self-trigger) ──
// Batch distribution engine, shared by execute and cancel. A
// batch sends ≤ BATCH_MAX_SENDS transfers per transaction, with progress
// tracked by a SINGLE write to the dist cell per batch: a per-asset
// assets.set in the distribution loop would cost ≈9000 gas/asset.
// K = 50 is deliberately conservative; ≥3× margin: 50 sends ≈
// 50×4231 + 18445 ≈ 230k gas against a 1M ceiling (limits:
// docs.ton.org/foundations/limits).
const FAST_PATH_MAX_ASSETS = 100 // <=100 assets uses the single-transaction path (proven up to 231/154)
const BATCH_MAX_SENDS = 50
// GASCONSUMED safety valve (26 gas per call; getGasConsumedAtTheMoment in
// stdlib gas-payments.tolk): a batch stops once compute has used this much and
// the rest ships in the next batch. The largest measured batch is 605,295 gas
// (a 1,200-entry batch cancel's initiating transaction with two deposits —
// its walk and sends run inside the same gas count as a continued batch's;
// a skip-limited chain measured 605,088 with one shared skip address and
// 605,286 with a distinct address per entry) — at most 5,295 over the cap
// for the iteration that crosses it. The transaction that runs a continued
// batch is funded by the continue message alone, so the ceiling that matters
// is what CONTINUE_GAS_UNITS buys.
const BATCH_GAS_SOFT_CAP = 600000
// Base cost of one additional batch transaction: a new compute phase (45000),
// one dist write (9000), headroom for building the continue message. Measured
// against the cheapest real batch — a cancel's finalize step, which does no
// registry walk: 13,528 gas, so 60,000 is about 4.4x that.
const BATCH_EXTRA_GAS_UNITS = 60000
// Gas a cancel_swap needs to reach its balance check (storage load, counters,
// the quote); after the check the transaction's gas comes from the reserve
// inside `required`. A 1x1 cancel carrying 0.001 TON (15,000 gas) ran out
// before the check, 0.003 TON (45,000) passed with 20,502 in total. 40,000
// units cover the pre-check part on any registry size (the quote is O(1)).
const CANCEL_PRECHECK_GAS_UNITS = 40000
// Gas to walk past one registry entry that is not sent: a dictionary step and
// the loop. Measured: a skip-limited chain over 2,050 entries used 3.0M gas,
// about 1,460 per entry; a cancel batch over 101-300 entries grows by about
// 1,270 per entry; the fast-path cancel loop about 920 per entry. 2,200 is
// 1.5x the largest.
const SKIP_GAS_UNITS_PER_ENTRY = 2200
// Gas units the self-addressed continue_distribution message buys. It is sent
// in mode 0, so its value is calculateGasFee(CONTINUE_GAS_UNITS) plus its own
// forwarding fee (see continueMsgValue): the gas it buys is the same at any gas
// price. 730,000 is about 1.21x the largest measured batch (605,295, a
// 1,200-entry registry's batch cancel with two deposits); a batch cancel's
// initiating transaction on the same 1,200-entry registry used 604,936 with
// no deposits. The value returns to the balance on arrival — only the
// forwarding fee and the gas used are spent. A batch cancel's initiating
// transaction runs only its first batch, so its gas limit is capped here too
// (cancelTxGasUnits).
const CONTINUE_GAS_UNITS = 730000
// Hard compute ceiling of an ordinary basechain transaction (GasPricesExtended.
// gasLimit, see .acton/emulation/config.tolk): setGasLimit never grants more,
// so a reserve priced for more units would only pay for gas that cannot be
// used (cancelTxGasUnits).
const TX_GAS_LIMIT_CEILING = 1000000

// Delivery modes (who receives the batch):
const DIST_IDLE = 0 // no delivery in progress
const DIST_EXECUTE = 1 // execution: to the opposite side (phase EXECUTING)
const DIST_CANCEL = 2 // cancel_swap: to depositors, with a sweep at the end (phase CANCELLED)

struct DistState {
    mode: uint3
    cursor: uint16 // next registry index to process
}

struct Asset {
    kind: uint2            // 0 = NFT, 1 = Jetton
    ownerSide: uint2       // 1 | 2 — which side is depositing
    addr: address          // NFT item address (or jetton minter address)
    jettonWallet: address? // null for NFT assets
    amount: coins          // 0 for NFT assets
    received: bool
    // True while `jettonWallet` holds an address side 2 claimed in AcceptDeal
    // that the minter has not confirmed yet; the minter's take_wallet_address
    // clears it (handleTakeWalletAddress).
    walletUnverified: bool
    // saturating count of bounced deliveries (diagnostics)
    bounces: uint4
    // Set when an outgoing transfer of this asset bounced back to the escrow;
    // cleared when claim_asset sends it again. Jettons can only be claimed
    // while this is set.
    claimable: bool
}

struct GramState {
    gram1Amount: coins
    gram2Amount: coins
    gram1Received: coins
    gram2Received: coins
    gram1DepositReserve: coins // value attached to side 1's NFT deposits
    gram2DepositReserve: coins
    serviceFee1: coins
    serviceFee2: coins
}
