import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "@stdlib/exotic-cells"
// BondingCurve.tolk
//
// One instance per launch. Sells the meme jetton against a whitelisted quote
// jetton (USDT / XAUt0 / SP500) along a constant-product curve with a 1% fee.
// The 1% trading fee is ALWAYS taken in the quote asset (buys skim it from
// the quote input, sells skim it from the quote output). The split is per
// pair and set by the master at CINT. Round 28 non-stock pairs use 20% creator,
// 55% treasury, 10% locked LP and 10% burns; Community mode turns the creator
// share into another 10% locked LP and 10% burns. Stock pairs use 60% holder
// rewards, 20% locked LP and 20% treasury.
// When `raised >= cap`, graduation is PERMISSIONLESS: anyone may poke
// graduate#47524144 with no arguments. The DeDust vault addresses are pinned
// in storage (quote vault from the master's immutable config, meme vault set
// once by the treasury via set_vault#53455456 right after launch), so a poker
// cannot reroute the raise. This removes the treasury liveness dependency.
// The curve then calls
// the DeDust factory on-chain, creates the volatile pool, deposits the LP
// share of quote+meme, and KEEPS the resulting LP position in a wallet it owns
// itself. There is no code path that can transfer that LP anywhere, so the
// pool liquidity is locked forever. HRVS does NOT touch that position: it is a
// treasury-only, once-an-hour call that claims the pool's accrued creator-fee
// counters (the DeDust ClaimCreatorFees flow) in full. Principal reserves and
// the locked LP jettons are unreachable by every opcode.
// NOTE: HARVEST_MAX_BPS / HARVEST_STEP_BPS / lpHarvested below are vestigial
// from the earlier LP-burn harvest model; they are kept only so the storage
// layout stays stable and are not read by the harvest path.
//
// Storage (after CINT):
//   master:MsgAddress
//   creator:MsgAddress
//   quote_master:MsgAddress
//   salt:uint64
//   ^[ treasury:MsgAddress meme_master:MsgAddress
//      quote_wallet:MsgAddress meme_wallet:MsgAddress
//      dedust_factory:MsgAddress lock_vault:MsgAddress
//      raised:Coins cap:Coins sold:Coins
//      virt_quote:Coins virt_meme:Coins
//      graduated:bool pool:MsgAddress lp_locked:Coins lp_unlock_at:uint32
//      metadata:^Cell ]

const OP_CURVE_INIT = 0x43494e54;         // "CINT" from master
const OP_JETTON_TRANSFER = 0x0f8a7ea5;
const OP_INTERNAL_TRANSFER = 0x178d4519;
const OP_MINT = 21;
const OP_TRANSFER_NOTIFICATION = 0x7362d09c;
const OP_EXCESSES = 0xd53276db;           // jetton wallet gas refund — accept silently

const OP_BUY = 0x42555921;                // "BUY!" forward payload
const OP_SELL = 0x53454c4c;               // "SELL" forward payload
const OP_GRADUATE = 0x47524144;           // "GRAD"
const OP_CLAIM = 0x434c414d;              // "CLAM" treasury claims accrued fee pool
const OP_CLAIM_CREATOR = 0x434c4d43;      // "CLMC" launch creator claims their accrued fee share
const OP_SET_FEE_TO = 0x5346544f;         // "SFTO" multisig-approved community takeover: creator fees -> LP + burns, for good
// DeDust CPMM v2 wire protocol (hub-beta.dedust.io/docs/cpmm-v2)
const OP_DEDUST_INIT_POOL = 0xde8402ce;       // deploy + initialise a CPMM v2 pool
const OP_DEDUST_INIT_RESULT = 0xce185bd7;     // pool -> initiator once it is Initialized
const OP_DEDUST_PAY_JETTON = 0xcbc33949;      // jetton forward payload wrapper
const OP_DEDUST_DEPOSIT_PAYLOAD = 0xc9a015da; // deposit: amounts + locked LP share
const OP_DEDUST_CLAIM_CREATOR_FEES = 0xbe3e3179; // pull accrued creator fees out of a pool
const DEDUST_POOL_LIBRARY_HASH = 0x6045e67b617e73486aac445cfcad0dbead6d315ccc8f4aede3f2e23ad14da4b0;
// Mainnet CPMM v2 pool controller (DeDust protocol), part of the pool's init data.
const DEDUST_POOL_CONTROLLER = address("UQAzZk-YE-C_2TaxMzNi71upLfwLYBWRpWCK6M1vhbAOtJ5S");
const DEDUST_FEE_IN_BOTH = 0;                 // (unused) fee skimmed on the input asset
// AUDIT 2026-10-25: fees are collected in the QUOTE asset only (quote = asset
// Y here), so every harvest arrives in quote: treasury, creator, burns, LP.
const DEDUST_FEE_IN_QUOTE = 2;                // FeeIn.AssetY
// AUDIT 2026-10-25: DeDust keeps 20% of every pool fee (fixed). creatorFeeBPS
// is 0: a pool-creator payout is an untagged, silent jetton transfer the curve
// cannot book. The whole 80% accrues to the curve's locked position instead and
// HRVS claims it back to THIS curve with a tagged payout (external H-2): the
// curve splits it on-chain — treasury share straight to the multisig, creator
// share into creatorPool (CLMC), LP into lpPool (LPRL), the rest into holderPool.
const DEDUST_CREATOR_FEE_BPS = 0;
const OP_HARVEST_PAYOUT = 0x48525650;        // "HRVP" tag on the position-fee payout
const OP_LP_RELAY = 0x4c50524c;              // "LPRL" operator deposits lpPool into the locked pool
// LP refunds (user 2026-10-25): a refused LP swap comes back from the pool tagged
// LPRF and is booked into lpPool again, so the next LPRL deposits it instead of
// it leaving the curve.
// SELF-FUNDED GAS (user 2026-10-25): the curve pays its own HRVS / LPRL gas out
// of its gas reserve (unused trade gas), so the automated key only sends pocket
// change. Bounded so a stolen key cannot drain it: at most once per
// SELF_GAS_INTERVAL per job, never below GAS_RESERVE_FLOOR, excess gas comes
// back to the curve, and the work itself only ever moves money along its
// hard-wired paths. A caller that attaches the full gas pays as before.
const SELF_GAS_INTERVAL = 9000;           // 2.5 h between self-funded runs of each job
const GAS_RESERVE_FLOOR = 500000000;      // 0.5 GRAM the curve always keeps
const HARVEST_GAS = 500000000;            // gas an HRVS needs (caller- or self-funded)
const OP_LP_REFUND = 0x4c505246;             // "LPRF"
const LP_REFUND_FWD = 50000000;              // 0.05 GRAM so the refunded quote produces a notification
const HARVEST_EXTRA_GAS = 150000000;         // 0.15 GRAM forwarded with the payout to fund the split
// AUDIT 2026-10-25 (external M-1): seed refunds only rewind within this window.
const SEED_REFUND_WINDOW = 3600;
const OP_DEDUST_WITHDRAW = 0x20b5ef89;
const OP_DEDUST_SWAP_V2 = 0xc442500f;        // CPMM v2 SwapPayload (matches src/lib/wrappers/DeDust.ts)
// LP DEPOSIT RELAY (AUDIT 2026-10-25): post-migration LP shares are added to the
// locked pool through the curve (only the curve may deposit).
const OP_LP_DEPOSIT = 0x4c504450;            // "LPDP" fulfil payload of that swap: deposit tokens + held quote
const LP_RELAY_GAS = 1500000000;             // 1.5 GRAM the LPQT notification must carry
const LP_DEPOSIT_GAS_J = 1000000000;         // 1.0 GRAM forwarded with the swap output for the two deposit legs
const DEDUST_LOCKED_LP_BPS = 10000;           // 100% of the seeded LP is locked forever
const OP_PREPARE = 0x50524550;            // "PREP" legacy no-op (kept for old callers)
const OP_SET_VAULT = 0x53455456;          // "SETV" legacy no-op (kept for old callers)
const OP_SET_LP = 0x5345544c;             // "SETL" treasury pins the DeDust LP jetton wallet
const OP_SWEEP = 0x53575045;              // "SWPE" treasury rescues a stranded jetton
const OP_HARVEST = 0x48525653;            // "HRVS" treasury harvests accrued LP fees
const OP_RESEND_LEG = 0x52534e44;         // "RSND" anyone resends a seed leg that bounced (caller-funded)
const OP_FORCE_SEED = 0x46534544;         // "FSED" anyone retries a blocked pool seed at a 0.5% floor
const OP_SET_OPS = 0x534f5053;            // "SOPS" treasury pins the ops multisig, once
const OP_ESCAPE = 0x45534350;             // "ESCP" permissionless: opens pro-rata refunds after 7 days stuck at cap
const OP_REQUEST_QUOTE_WALLET = 0x52515741; // "RQWA" anyone re-requests the TEP-89 quote wallet while unset (audit L-4)

// ROUND 31 (user go-ahead 2026-11-01)
// DeDust's position contract (this curve's locked LP position) tells its owner
// when a deposit has minted liquidity. Its address is derived on-chain from the
// pool (split_depth 8 StateInit, library code below), so the confirmation can't
// be forged. The first one after a seed makes the migration final.
const OP_POSITION_NOTIFY = 0x63554160;
const DEDUST_POSITION_LIBRARY_HASH = 0xdd82f24db614798ee7c579f8b3f07f0645d06d65cede368d80d0d74b180d2dd6;
const OP_BURN_LEFTOVER = 0x42524e4c;      // "BRNL" anyone retries the leftover-token burn (caller-funded)
// Refund reasons for integrators: every returned or partly returned trade
// carries refund_reason#52464e44 query_id:uint64 reason:uint8 as the jetton
// forward payload (and as an external log). query_id = the trader's own
// query id of the transfer that reached the curve.
const OP_REFUND_REASON = 0x52464e44;      // "RFND"
const REASON_CLOSED = 1;                  // curve full or migrated
const REASON_NOT_LIVE = 2;                // trading not open yet
const REASON_CREATOR_WINDOW = 3;          // first 30 s: creator only
const REASON_WALLET_LIMIT = 4;            // this wallet already holds its 2% (full refund)
const REASON_WALLET_LIMIT_PARTIAL = 5;    // the part above the 2% wallet limit came back
const REASON_CAP_PARTIAL = 6;             // the part above the curve cap came back
const REASON_SLIPPAGE = 7;                // output below min_out
const REASON_LOW_GAS = 8;                 // not enough GRAM attached
const REASON_WRONG_ASSET = 9;             // wrong jetton for this op
const REASON_MALFORMED = 10;              // forward payload could not be read
const REASON_WORKCHAIN = 11;              // trader outside the basechain
const REASON_INVALID_SELL = 12;           // sell amount out of range
const REASON_MIN_GRAM = 50000000;         // returns carrying less than 0.05 GRAM come back without a reason
// Query ids of outgoing legs. Payments to a wallet use the low 63 bits of that
// wallet's hash (so a bounced CLAM payout is recognised and re-pooled).
// Curve-internal legs set the top bit.
const QID_TAG = 0x8000000000000000;
const QID_SEED_TAG = 0x4000000000000000;  // seed attempts: QID_TAG | QID_SEED_TAG | lt
const QID_LP = 0x80000000004c5052;        // LP relay legs
const QID_BURN = 0x8000000042524e4c;      // leftover burn
const LEG_KEY_MASK = 0x7fffffffffffffff;
const LEFTOVER_BURN_GAS = 50000000;       // 0.05 GRAM for the burn + its notification

// AUDIT (high, fixed — external review H-5): the hot treasury key used to be
// able to force-seed a skewed pool (FSED), pin the LP wallet (SETL) and sweep
// curve jettons (SWPE). Those powers now belong to the ops MULTISIG, pinned
// once by the treasury via SOPS. The hot key keeps only what pays INTO the
// treasury (CLAM, HRVS). No timelock, per the owner's decision.

// AUDIT (high, fixed — external review H-1): if a sniper pre-seeds the
// deterministic pool and keeps it skewed, every honest seed reverts and the
// raise would sit in the curve forever. After ESCAPE_DELAY at the cap without
// a confirmed seed, the multisig may refund buyers pro-rata out of `raised`.
const ESCAPE_DELAY = 604800;              // 7 days stuck at cap before refunds open

// AUDIT (high, fixed — external review H-3): the lifetime buyer ledger stops
// growing at MAX_BUYERS_TRACKED entries so account state can never cross
// TON's size limit and brick the curve mid-sale.
const MAX_BUYERS_TRACKED = 4096;


const OP_JETTON_BURN = 0x595f07bc;        // TEP-74 burn (redeems DeDust LP into reserves)
// AUDIT 2026-10-24: minimum notification value to return tokens sent with a malformed payload
const MALFORMED_RETURN_GRAM = 50000000;   // 0.05 GRAM


// Locked-liquidity fee harvest limits. The LP position itself can never be
// transferred out of this contract; the harvest redeems a sliver of it, which
// on a constant-product pool is exactly how accrued trading fees are realised.
// Hard caps keep this a fee faucet and not a withdrawal hatch:
const HARVEST_MAX_BPS = 1000;             // 10% of the original LP, lifetime
const HARVEST_STEP_BPS = 25;              // 0.25% of the original LP per harvest
const HARVEST_INTERVAL = 3600;             // at most one fee claim per hour

const OP_PROVIDE_WALLET_ADDRESS = 0x2c76b973; // TEP-89 discovery request
const OP_TAKE_WALLET_ADDRESS = 0xd1735400;    // TEP-89 discovery reply

// Round 28: the trade fee is per curve (st.feeBps), fixed at CINT. Only
// these two tiers are accepted; FEE_BPS_DEFAULT is the 1% tier.
const FEE_BPS_DEFAULT = 100;              // 1% quote-asset fee per trade
// per-pair fee split now lives in storage (creatorFeeBps / treasuryFeeBps),
// set by the master at CINT. The remainder accrues to the holders pool.
// Creator-first window: for this many seconds after trading opens (the
// full-supply mint lands) only the launch creator may buy, so the creator's
// initial dev buy is always the curve's first trade. Everyone else is refunded.
const CREATOR_ONLY_SECS = 30;
const LP_SHARE_BPS = 3000;                // 30% of total token supply seeds the LP
// Hard reserve: the bonding curve may never sell more than 700M of the 1B
// supply — the remaining 300M is the DeDust liquidity allocation.
const MEME_CURVE_SUPPLY = 700000000000000;

// DeDust asset kinds (factory vault data)
const ASSET_JETTON = 1;

// 1e9 meme tokens, 6 decimals
const MEME_TOTAL_SUPPLY = 1000000000000000;
// Whale protection: one purchase may never receive more than 2% of the total
// supply (20M tokens). Anything above is refunded to the buyer in the same tx.
const MAX_BUY_MEME = 20000000000000;
// key length of the per-buyer ledger (account hash, workchain-agnostic: every
// participant is on the basechain).
// AUDIT (high, fixed): this used to store the full 256-bit account hash. A
// hashmap of 256-bit keys with a Coins value costs ~307 bits of account state
// per buyer, so the curve crossed TON's 2,097,152-bit account-state limit at
// roughly 6,800 unique buyers and could no longer save state — a popular
// launch would brick itself mid-curve, permanently. The top 128 bits of the
// hash are used instead (~178 bits/buyer, ~11,800 buyers of headroom);
// grinding an address that collides in 128 bits is infeasible, and a collision
// would only make the cap STRICTER for the colliding pair, never looser.
const BUYER_KEY_LEN = 128;

// Minimum TON a trade notification must carry. Every trade leg (output,
// treasury fee, refund) is funded with an explicit TON value out of the
// curve's balance, and the forward amount is chosen by the SENDER — without
// this floor an attacker could spam 1-nanoton buys/sells and burn ~0.1 TON of
// the curve's reserve each time until it dropped under the graduation floor.
// The launcher UI forwards 0.15 TON, so legitimate trades are unaffected.
const MIN_TRADE_GRAM = 200000000;
// TON attached to each jetton leg a trade pays for (output, treasury fee,
// refund). AUDIT (medium, fixed, round 15): these legs used to be funded with
// 0.05 TON each out of the curve's own balance while the floor above only
// demanded 0.18 TON of inbound gas, so a buy that paid all three legs
// (0.15 TON) plus transaction fees was net NEGATIVE for the curve and
// repeated minimum-size round trips slowly bled its TON reserve. The leg cost
// is now 0.04 TON and the floor is 0.20 TON, so the worst case (three legs)
// leaves the curve ahead on every trade.
const TRADE_LEG_GRAM = 40000000;
// Virtual reserves are tuned so the curve sells EXACTLY 70% of the supply
// (700M) by the time `raised == cap`, leaving 300M = LP_SHARE_BPS for the
// DeDust pool, AND so the price-matched LP deposit works out to ~233M (the
// remainder of the 300M allocation stays on the curve):
//   sold(cap)  = VIRT_MEME * cap / (virt_quote + cap) = 700M   with virt_quote = cap/2
//   lp_meme    = cap * (VIRT_MEME - 700M) / (virt_quote + cap) ≈ 233M
const VIRT_QUOTE_NUM = 1;                 // virtual quote depth = cap * 1/2
const VIRT_QUOTE_DEN = 2;
const VIRT_MEME = 1050000000000000;       // 1.05B virtual meme (6 decimals)


const ERR_NOT_MASTER = 200;
const ERR_NOT_QUOTE_WALLET = 201;
const ERR_NOT_MEME_WALLET = 202;
const ERR_SLIPPAGE = 203;
const ERR_GRADUATED = 204;
const ERR_NOT_READY = 205;
const ERR_NOT_ALLOWED = 206;
const ERR_NOTHING = 207;
const ERR_ALREADY_INIT = 208;
const ERR_LOW_GAS = 209;


struct Curve {
    master: address;
    creator: address;
    quoteMaster: address;
    salt: int;
    treasury: address;
    memeMaster: address;
    quoteWallet: address;
    memeWallet: address;
    dedustFactory: address;
    lockVault: address;
    raised: coins;
    cap: coins;
    sold: coins;
    virtQuote: coins;
    virtMeme: coins;
    graduated: bool;
    pool: address;
    lpLocked: coins;     // total DeDust LP received and permanently held by THIS contract
    lpUnlockAt: int;     // unix ts of the last fee harvest (HRVS rate limit)
    migrationFee: coins;  // fixed ~$20 in quote units, paid to treasury at graduation
    holderPool: coins;   // remainder of every 1% trade fee accrues here for holders
    lpPool: coins;       // share of the 1% fee reinvested into the LP at graduation
    creatorFeeBps: int;  // share of the 1% fee paid to the creator (USDT: 3000)
    treasuryFeeBps: int; // share of the 1% fee paid to the treasury
    lpFeeBps: int;       // share of the 1% fee reinvested into the LP (USDT: 4000)
    feeBps: int;         // trade fee in bps: always 100 (1%)
    quoteVault: address; // DeDust vault for the quote jetton (pinned by the master)
    memeVault: address;  // DeDust vault for the meme jetton (pinned once by treasury)
    lpWallet: address;   // the ONE jetton wallet whose deposits count as LP (pinned on first LP receipt)
    creatorPool: coins;  // creator share of the 1% fee, claimable by the creator (CLMC)
    seedQuote: coins;    // quote amount sent to the pool by the last seed attempt (refund detection)
    buyers: dict;        // buyer account hash -> meme bought so far (lifetime 2% cap)
    lpHarvested: coins;  // LP redeemed so far by fee harvests (capped at HARVEST_MAX_BPS of lpLocked)
    capReached: bool;    // sticky: set the moment raised first touches cap, never cleared
    prepared: bool;      // sticky: DeDust vaults + volatile pool provisioning requested
    minted: bool;        // set once the full-supply mint lands; trades rejected before it
    seeded: bool;        // sticky: pool confirmed the deposit — graduation can never rewind
    capReachedAt: int;   // unix ts when the cap first filled (ESCP delay clock)
    buyerCount: int;     // entries in `buyers`; capped at MAX_BUYERS_TRACKED (H-3)
    holderPayout: address; // receives holderPool on CLAM (stock payout hot wallet)
    initConfirmed: bool; // sticky: pool sent InitPoolResult — FSED allowed only after (audit H-3)
    refunding: bool;     // terminal: ESCP opened pro-rata refunds; graduation blocked (audit H-1)
    quoteBack: bool;     // the quote leg of the last seed was refunded by the pool (audit H-2)
    memeBack: bool;      // the meme leg of the last seed was refunded by the pool (audit H-2)
    seedMeme: coins;     // meme amount sent to the pool by the last seed attempt
    legBounced: int;     // AUDIT 2026-10-24: bit 1 = meme seed leg bounced, bit 2 = quote seed leg bounced (RSND resends)
    seedSlack: int;      // slack of the last seed attempt, so a resent leg carries the identical deposit payload
    lpRelayQuote: coins; // AUDIT 2026-10-25: quote half held for the pending LP relay deposit
    lpRelayAt: int;      // unix ts of the last LPRL (self-funded rate limit)
    takenOver: bool;     // terminal: multisig-approved CTO turned the creator share into LP + burns
    seedAt: int;         // AUDIT 2026-10-25: unix time of the last seed attempt (refund window)
    liveAt: int;         // unix ts trading opened (mint landed); creator-only buys for CREATOR_ONLY_SECS
    seedQid: int;        // ROUND 31: query id of the last seed attempt's legs (bounce matching)
    lpRelayQid: int;     // ROUND 31: secret nonce of the in-flight LPRL swap (0 = none)
    leftoverBurned: bool; // ROUND 31: leftover tokens burned once DeDust confirmed the seed
    opsMultisig: address; // AUDIT 2026-10-25 (L-1): despite the name, the AUTOMATED operator hot key (pinned at launch); it may run SETL, SWPE (pre-cap), CLAM, HRVS, LPRL and trigger CLMC — every payout is hard-wired, so it can never redirect funds. FSED and ESCP are permissionless.
    metadata: cell;
}

// pure constant-product output (no fee skimmed)
fun ammOutNoFee(amountIn: coins, reserveIn: coins, reserveOut: coins): coins {
    return amountIn * reserveOut / (reserveIn + amountIn);
}

// preview helper kept for off-chain quotes: fee is routed to treasury, not kept in reserves
fun ammOut(amountIn: coins, reserveIn: coins, reserveOut: coins, feeBps: int): coins {
    val fee = amountIn * feeBps / 10000;
    val swapAmount = amountIn - fee;
    return swapAmount * reserveOut / (reserveIn + swapAmount);
}

fun loadCurve(): Curve {
    var cs = contract.getData().beginParse();
    val master = cs.loadAddress();
    val creator = cs.loadAddress();
    val quoteMaster = cs.loadAddress();
    val salt = cs.loadUint(64);

    // Freshly deployed by the master: storage holds only the init fields and
    // has no state ref yet. Return a blank curve so CINT can fill it in.
    if (cs.remainingRefsCount() == 0) {
        return {
            master: master,
            creator: creator,
            quoteMaster: quoteMaster,
            salt: salt,
            treasury: master,
            memeMaster: master,
            quoteWallet: master,
            memeWallet: master,
            dedustFactory: master,
            lockVault: master,
            raised: 0,
            cap: 0,
            sold: 0,
            virtQuote: 0,
            virtMeme: 0,
            graduated: false,
            pool: master,
            lpLocked: 0,
            lpUnlockAt: 0,
            migrationFee: 0,
            holderPool: 0,
            lpPool: 0,
            creatorFeeBps: 0,
            treasuryFeeBps: 0,
            lpFeeBps: 0,
            feeBps: FEE_BPS_DEFAULT,
            quoteVault: master,
            memeVault: master,
            lpWallet: master,
            creatorPool: 0,
            seedQuote: 0,
            buyers: null,
            lpHarvested: 0,
            capReached: false,
            prepared: false,
            minted: false,
            seeded: false,
            capReachedAt: 0,
            buyerCount: 0,
            opsMultisig: master,   // sentinel: unpinned (SOPS required)
            holderPayout: master,
            initConfirmed: false,
            refunding: false,
            quoteBack: false,
            memeBack: false,
            seedMeme: 0,
            legBounced: 0,
            seedSlack: 0,
            lpRelayQuote: 0,
            lpRelayAt: 0,
            takenOver: false,
            seedAt: 0,
            liveAt: 0,
            seedQid: 0,
            lpRelayQid: 0,
            leftoverBurned: false,
            metadata: beginCell().endCell(),
        };
    }

    // A TON cell holds at most 1,023 bits, so the state is chained across
    // three refs instead of packed into one.
    var a = cs.loadRef().beginParse();
    val treasury = a.loadAddress();
    val memeMaster = a.loadAddress();
    val quoteWallet = a.loadAddress();
    var b = a.loadRef().beginParse();
    val memeWallet = b.loadAddress();
    val dedustFactory = b.loadAddress();
    val lockVault = b.loadAddress();
    val lpRelayAtV = b.loadUint(32);
    val takenOverV = b.loadUint(1) != 0;
    var c = b.loadRef().beginParse();
    // refs of `c`, in stored order: 0 = metadata, 1 = pinned DeDust vaults.
    // Popped up front so the bit fields below can stay inline.
    val metadataRef = c.loadRef();
    var vaults = c.loadRef().beginParse();
    // Ref order inside the vaults cell: 0 = buyers dict, 1 = the Round 29
    // security fields. Dict must be popped before the security ref.
    // FIX 2026-10-24: read the vaults cell in STORED order. The dict bit sits
    // after these fields (saveCurve), so popping it first misread every field
    // and bricked every Round 28 curve right after CINT.
    val quoteVaultV = vaults.loadAddress();
    val memeVaultV = vaults.loadAddress();
    val lpWalletV = vaults.loadAddress();
    val lpHarvestedV = vaults.loadCoins();
    val creatorPoolV = vaults.loadCoins();
    val seedQuoteV = vaults.loadCoins();
    val buyersDict = vaults.loadDict();
    var sec = vaults.loadRef().beginParse();
    var r31 = sec.loadRef().beginParse();   // ROUND 31 fields (the only ref of `sec`)
    return {
        master: master,
        creator: creator,
        quoteMaster: quoteMaster,
        salt: salt,
        treasury: treasury,
        memeMaster: memeMaster,
        quoteWallet: quoteWallet,
        memeWallet: memeWallet,
        dedustFactory: dedustFactory,
        lockVault: lockVault,
        lpRelayAt: lpRelayAtV,
        takenOver: takenOverV,
        raised: c.loadCoins(),
        cap: c.loadCoins(),
        sold: c.loadCoins(),
        virtQuote: c.loadCoins(),
        virtMeme: c.loadCoins(),
        graduated: c.loadUint(1) != 0,
        lpUnlockAt: c.loadUint(32),
        pool: c.loadAddress(),
        lpLocked: c.loadCoins(),
        migrationFee: c.loadCoins(),
        holderPool: c.loadCoins(),
        lpPool: c.loadCoins(),
        creatorFeeBps: c.loadUint(16),
        treasuryFeeBps: c.loadUint(16),
        lpFeeBps: c.loadUint(16),
        feeBps: c.loadUint(16),
        capReached: c.loadUint(1) != 0,
        prepared: c.loadUint(1) != 0,
        metadata: metadataRef,
        quoteVault: quoteVaultV,
        memeVault: memeVaultV,
        lpWallet: lpWalletV,
        lpHarvested: lpHarvestedV,
        creatorPool: creatorPoolV,
        seedQuote: seedQuoteV,
        buyers: buyersDict,
        minted: sec.loadUint(1) != 0,
        seeded: sec.loadUint(1) != 0,
        capReachedAt: sec.loadUint(32),
        buyerCount: sec.loadUint(16),
        opsMultisig: sec.loadAddress(),
        holderPayout: sec.loadAddress(),
        initConfirmed: sec.loadUint(1) != 0,
        refunding: sec.loadUint(1) != 0,
        quoteBack: sec.loadUint(1) != 0,
        memeBack: sec.loadUint(1) != 0,
        seedMeme: sec.loadCoins(),
        legBounced: sec.loadUint(2),
        seedSlack: sec.loadUint(16),
        lpRelayQuote: sec.loadCoins(),
        seedAt: sec.loadUint(32),
        liveAt: sec.loadUint(32),
        seedQid: r31.loadUint(64),
        lpRelayQid: r31.loadUint(64),
        leftoverBurned: r31.loadUint(1) != 0,
    };
}

fun saveCurve(st: Curve) {
    val c = beginCell()
        .storeCoins(st.raised)
        .storeCoins(st.cap)
        .storeCoins(st.sold)
        .storeCoins(st.virtQuote)
        .storeCoins(st.virtMeme)
        .storeUint(st.graduated ? 1 : 0, 1)
        .storeUint(st.lpUnlockAt, 32)
        .storeAddress(st.pool)
        .storeCoins(st.lpLocked)
        .storeCoins(st.migrationFee)
        .storeCoins(st.holderPool)
        .storeCoins(st.lpPool)
        .storeUint(st.creatorFeeBps, 16)
        .storeUint(st.treasuryFeeBps, 16)
        .storeUint(st.lpFeeBps, 16)
        .storeUint(st.feeBps, 16)
        .storeUint(st.capReached ? 1 : 0, 1)
        .storeUint(st.prepared ? 1 : 0, 1)
        .storeRef(st.metadata)
        .storeRef(beginCell()
            .storeAddress(st.quoteVault)
            .storeAddress(st.memeVault)
            .storeAddress(st.lpWallet)
            .storeCoins(st.lpHarvested)
            .storeCoins(st.creatorPool)
            .storeCoins(st.seedQuote)
            .storeDict(st.buyers)
            .storeRef(beginCell()
                .storeUint(st.minted ? 1 : 0, 1)
                .storeUint(st.seeded ? 1 : 0, 1)
                .storeUint(st.capReachedAt, 32)
                .storeUint(st.buyerCount, 16)
                .storeAddress(st.opsMultisig)
                .storeAddress(st.holderPayout)
                .storeUint(st.initConfirmed ? 1 : 0, 1)
                .storeUint(st.refunding ? 1 : 0, 1)
                .storeUint(st.quoteBack ? 1 : 0, 1)
                .storeUint(st.memeBack ? 1 : 0, 1)
                .storeCoins(st.seedMeme)
                .storeUint(st.legBounced, 2)
                .storeUint(st.seedSlack, 16)
                .storeCoins(st.lpRelayQuote)
                .storeUint(st.seedAt, 32)
                .storeUint(st.liveAt, 32)
                .storeRef(beginCell()
                    .storeUint(st.seedQid, 64)
                    .storeUint(st.lpRelayQid, 64)
                    .storeUint(st.leftoverBurned ? 1 : 0, 1)
                    .endCell())
                .endCell())
            .endCell())
        .endCell();
    val b = beginCell()
        .storeAddress(st.memeWallet)
        .storeAddress(st.dedustFactory)
        .storeAddress(st.lockVault)
        .storeUint(st.lpRelayAt, 32)
        .storeUint(st.takenOver ? 1 : 0, 1)
        .storeRef(c)
        .endCell();
    val a = beginCell()
        .storeAddress(st.treasury)
        .storeAddress(st.memeMaster)
        .storeAddress(st.quoteWallet)
        .storeRef(b)
        .endCell();
    contract.setData(beginCell()
        .storeAddress(st.master)
        .storeAddress(st.creator)
        .storeAddress(st.quoteMaster)
        .storeUint(st.salt, 64)
        .storeRef(a)
        .endCell());
}

// packs code+data into a canonical StateInit cell (for deploy messages)
fun packStateInit(code: cell, data: cell): cell {
    return beginCell()
        .storeUint(0, 2)          // split_depth:0 special:0
        .storeMaybeRef(code)
        .storeMaybeRef(data)
        .storeUint(0, 1)          // library:0
        .endCell();
}

// address a contract with this code+data will have once deployed
fun deployedAddress(code: cell, data: cell): address {
    val cs: ContractState = { code: code, data: data };
    return AutoDeployAddress { stateInit: cs }.calculateAddress();
}

// standard TEP-74 jetton wallet data: balance:0 owner minter ^wallet_code
fun jettonWalletData(walletCode: cell, owner: address, minter: address): cell {
    return beginCell()
        .storeCoins(0)
        .storeAddress(owner)
        .storeAddress(minter)
        .storeRef(walletCode)
        .endCell();
}

// standard TEP-74 minter data: supply:0 admin ^content ^wallet_code
fun minterData(walletCode: cell, admin: address, content: cell): cell {
    return beginCell()
        .storeCoins(0)
        .storeAddress(admin)
        .storeRef(content)
        .storeRef(walletCode)
        .endCell();
}

// Virtual quote depth must be denominated in VALUE, not in raw decimals:
// every pair's cap is worth the same, so the depth is derived from the cap
// itself (currently cap / 2 — see VIRT_QUOTE_NUM/VIRT_QUOTE_DEN above; the
// client mirrors it in src/lib/wrappers/BondingCurve.ts and both must move
// together). This keeps the price path and the % of supply sold at
// graduation identical for USDT, XAUt0 and SP500.
fun virtQuoteFor(cap: coins): coins {
    return cap * VIRT_QUOTE_NUM / VIRT_QUOTE_DEN;
}


// master finishes construction: deploys the meme jetton minter, mints the
// full 1e9 supply to this curve, and records the derived wallets.
fun initFromMaster(st: Curve, sender: address, body: slice) {
    assert(sender == st.master, ERR_NOT_MASTER);

    val treasury = body.loadAddress();
    val cap = body.loadCoins();            // per-pair graduation cap (quote units)
    val migrationFee = body.loadCoins();   // fixed ~$20 in quote units, taken at graduation
    val quoteDecimals = body.loadUint(8);  // 6 for USDT/XAUt0, 8 for SP500
    val creatorFeeBps = body.loadUint(16); // share of the 1% fee -> creator
    val treasuryFeeBps = body.loadUint(16);// share of the 1% fee -> treasury
    val lpFeeBps = body.loadUint(16);      // share of the 1% fee reinvested into the LP
    val feeBps = body.loadUint(16);        // trade fee tier chosen at launch
    assert(feeBps == FEE_BPS_DEFAULT, ERR_NOT_ALLOWED);
    // The remainder of the 1% fee accrues to the holder pool, so the three
    // configured shares must never exceed the whole fee — otherwise every
    // trade would underflow holderPool. Refuse a misconfigured launch.
    assert(creatorFeeBps + treasuryFeeBps + lpFeeBps <= 10000, ERR_NOT_ALLOWED);
    // infrastructure addresses arrive in their own ref (root cell would overflow)
    var infra = body.loadRef().beginParse();
    val dedustFactory = infra.loadAddress();
    val lockVault = infra.loadAddress();
    val quoteVault = infra.loadAddress();  // DeDust vault of the quote jetton
    // The automated operator hot key arrives in its own ref and is pinned
    // immediately — no per-launch multisig signature is ever needed (H-5).
    var opsCs = infra.loadRef().beginParse();   // ops ref nested in infra (4-ref cell limit)
    val opKey = opsCs.loadAddress();
    val holderPayout = opsCs.loadAddress();
    val metadata = body.loadRef();
    val minterCode = body.loadRef();
    val walletCode = body.loadRef();
    val myAddress = contract.getAddress();

    val minterInitData = minterData(walletCode, myAddress, metadata);
    val memeMaster = deployedAddress(minterCode, minterInitData);
    val memeWallet = deployedAddress(walletCode, jettonWalletData(walletCode, myAddress, memeMaster));
    // The quote jetton (USDT/XAUt0/SP500) uses its own wallet code, so its
    // address cannot be derived locally. Ask the quote master over TEP-89 and
    // record the reply in the take_wallet_address branch below.
    val quoteWallet = myAddress;

    st.treasury = treasury;
    st.memeMaster = memeMaster;
    st.quoteWallet = quoteWallet;
    st.memeWallet = memeWallet;
    st.dedustFactory = dedustFactory;
    st.lockVault = lockVault;
    st.raised = 0;
    st.cap = cap;
    st.sold = 0;
    st.virtQuote = virtQuoteFor(cap);
    st.virtMeme = VIRT_MEME;
    st.graduated = false;
    st.pool = lockVault;       // until graduation creates the real DeDust pool
    st.lpLocked = 0;
    st.lpUnlockAt = 0;
    st.migrationFee = migrationFee;
    st.holderPool = 0;
    st.lpPool = 0;
    st.creatorFeeBps = creatorFeeBps;
    st.treasuryFeeBps = treasuryFeeBps;
    st.lpFeeBps = lpFeeBps;
    st.feeBps = feeBps;
    st.quoteVault = quoteVault;
    // unset sentinel: the meme jetton does not exist yet, so its DeDust vault
    // is pinned later by the treasury via SETV (before graduation).
    st.memeVault = myAddress;
    // unset sentinels: pinned on the first post-graduation LP receipt
    st.lpWallet = myAddress;
    st.capReached = false;
    st.prepared = false;
    st.minted = false;
    st.liveAt = 0;
    st.seeded = false;
    st.capReachedAt = 0;
    st.buyerCount = 0;
    st.holderPayout = holderPayout;  // stock holder payout wallet, fixed for life
    st.opsMultisig = opKey;  // pinned at launch by the master; SOPS is the fallback for legacy curves
    st.seedQuote = 0;
    st.initConfirmed = false;
    st.refunding = false;
    st.quoteBack = false;
    st.memeBack = false;
    st.seedMeme = 0;
    st.legBounced = 0;
    st.seedSlack = 0;
    st.lpRelayQuote = 0;
    st.seedAt = 0;
    st.seedQid = 0;
    st.lpRelayQid = 0;
    st.leftoverBurned = false;
    st.metadata = metadata;
    saveCurve(st);

    // deploy the meme minter and mint the whole supply to this curve
    val mintFwd = beginCell()
        .storeUint(OP_INTERNAL_TRANSFER, 32)
        .storeUint(0, 64)
        .storeCoins(MEME_TOTAL_SUPPLY)
        .storeAddress(myAddress)      // sender of the internal transfer
        .storeAddress(myAddress)      // response destination
        // NOTE: internal_transfer has NO custom_payload field (TEP-74)
        .storeCoins(20000000)         // forward Gram: 0.02 covers the mint notification (load+save storage); 0.001 ran out of gas (exit -14), fix 2026-10-24
        .storeUint(0, 1)              // no forward payload
        .endCell();
    val mintBody = beginCell()
        .storeUint(OP_MINT, 32)
        .storeUint(0, 64)
        .storeAddress(myAddress)      // mint to the curve
        .storeCoins(70000000)         // Gram attached to the internal transfer (wallet deploy + 0.02 forward)
        .storeRef(mintFwd)
        .endCell();
    // TEP-89: resolve this curve's wallet on the quote jetton master
    sendRawMessage(beginCell()
        .storeUint(0x18, 6)
        .storeAddress(st.quoteMaster)
        .storeCoins(50000000)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeUint(OP_PROVIDE_WALLET_ADDRESS, 32)
        .storeUint(0, 64)
        .storeAddress(myAddress)
        .storeUint(0, 1)
        .endCell(), 1);

    sendRawMessage(beginCell()
        .storeUint(0x18, 6)
        .storeAddress(memeMaster)
        .storeCoins(300000000)        // 0.3 Gram: deploy + mint + wallet deploy
        .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
        .storeRef(packStateInit(minterCode, minterInitData))
        .storeRef(mintBody)
        .endCell(), 1);               // explicit value, fees paid separately
}

// ---------------------------------------------------------------------------
// DeDust CPMM v2 ("Uranus") migration
//
// CPMM v2 pools are NOT created through the classic factory/vault flow. Each
// pool is a plain contract whose code is a TVM library reference to DeDust's
// shared pool code and whose init data carries the whole pool config. The
// address is therefore deterministic in (assetX, assetY, creator, fees), so
// this contract derives it itself — no off-chain pinning, nothing a poker can
// reroute. Sequence:
//
//   1. GRAD  -> Init#de8402ce (+ stateInit) deploys the pool; the pool resolves
//               its two jetton wallets (TEP-89) and replies InitPoolResult
//   2. reply -> both legs are sent as ordinary jetton transfers straight to the
//               pool, each carrying PayJetton{ DepositPayload }
//
// The deposit payload locks 100% of the minted liquidity (lockedLiquidityShare
// = 10000), so the pool can never be withdrawn by anyone, including us. The
// pool's `creatorAddress` is THIS curve, which lets ClaimCreatorFees#be3e3179
// pull the accrued creator share of the trading fee without touching liquidity.
//
// assetX = MEME, assetY = QUOTE, so every chart and integrator prices the pair
// as TOKEN/USDT (or TOKEN/XAUt0, TOKEN/SP500) and not the other way round.
// ---------------------------------------------------------------------------

fun dedustPoolCode(): cell {
    return beginCell()
        .storeInt(ExoticCellType.LibraryReference, 8)
        .storeUint(DEDUST_POOL_LIBRARY_HASH, 256)
        .endCellSpecial();
}

// FEE LAYOUT (CPMM v2 charges baseFeeBPS + creatorFeeBPS to the trader):
//
//   baseFeeBPS    -> stays with the (100% locked) liquidity = unreachable
//   creatorFeeBPS -> accrues in the pool's creatorFeeX/creatorFeeY counters
//
// AUDIT (critical, fixed): the base fee compounds INSIDE the liquidity, and the
// liquidity is minted with lockedLiquidityShare = 10000 — there is no LP
// position to redeem, so every bps routed to the base fee is frozen forever
// (verified on a live pool: creatorFeeX/Y = 0 while DeDust's own protocol cut
// kept accruing). The whole st.feeBps is therefore charged as the CREATOR fee,
// which the curve — the pool's creatorAddress — pulls out with the
// rate-limited HRVS claim and forwards to the treasury for distribution.
//
// creatorAddress stays THIS contract so only the curve could ever claim.

// Base fee charged by the CPMM v2 pool on every swap.
// AUDIT (high, fixed): this used to return 0. On CPMM v2 the CREATOR fee is a
// slice carved OUT of the base fee, so a 0 bps base fee meant graduated pools
// charged traders nothing at all and no creator fee could ever accrue — the
// 1% trading fee simply did not exist post-graduation (confirmed on the live
// USDT and USDe pools, baseFeeBPS = 0). The pad's full 1% is charged here.
fun dedustBaseFeeBps(st: Curve): int {
    return st.feeBps;
}
// Of that 1%, the launch's LP share (lpFeeBps of the fee) stays with the
// 100%-locked liquidity on every swap = the post-migration LP deposit
// (memecoins 10%, Community 22.5%, stocks/gold 20% of the fee). The rest is
// the pool creator fee, harvested to the treasury by HRVS.
fun dedustLpKeepBps(st: Curve): int {
    val keep = st.feeBps * st.lpFeeBps / 10000;
    return keep > st.feeBps ? st.feeBps : keep;
}




fun dedustPoolConfig(st: Curve): cell {
    val baseFee = dedustBaseFeeBps(st);
    return beginCell()
        .storeAddress(st.memeMaster)          // assetX
        .storeAddress(st.quoteMaster)         // assetY
        .storeAddress(contract.getAddress())  // creatorAddress = the curve
        .storeUint(baseFee, 16)                                   // total fee charged per swap
        .storeUint(DEDUST_CREATOR_FEE_BPS, 16)    // creatorFeeBPS: 40% of the fee, harvested via HRVS

        // DEPOSIT LOCK (2026-10-24): Activation.initiator(curve) — the pool
        // refuses every deposit not sent by this curve (DeDust exit 38,
        // verified against the real pool code in scripts/sim). Nobody can
        // pre-seed the deterministic pool at a skewed price any more, so a
        // migration can never be blocked that way. Swaps stay unrestricted.
        .storeBool(true)
        .storeRef(beginCell().storeUint(0x02, 8).storeAddress(contract.getAddress()).endCell())
        .storeBool(false)                     // no swap activation rule
        .storeUint(DEDUST_FEE_IN_QUOTE, 2)
        .storeBool(false)                     // customResolvers: empty dict
        .storeBool(false)                     // allowedRewards: empty dict
        .endCell();
}


fun dedustPoolFees(): cell {
    return beginCell()
        .storeCoins(0).storeCoins(0)          // protocolFeeX / protocolFeeY
        .storeCoins(0).storeCoins(0)          // creatorFeeX / creatorFeeY
        .storeUint(0, 5).storeUint(0, 5)      // xFeePerToken / yFeePerToken (Q120x120 zero)
        .endCell();
}

fun dedustPoolExtra(): cell {
    return beginCell()
        .storeAddress(DEDUST_POOL_CONTROLLER)
        .storeBool(false)                     // walletsByAssets
        .storeBool(false)                     // assetsByWallets
        .storeBool(false)                     // resolutions
        .endCell();
}

fun dedustPoolStorage(st: Curve): cell {
    return beginCell()
        .storeRef(dedustPoolConfig(st))
        .storeRef(dedustPoolFees())
        .storeRef(dedustPoolExtra())
        .storeBool(false)                     // rewards: empty dict
        .storeUint(0, 2)                      // status: Uninitialized
        .storeBool(false)                     // depositActive
        .storeBool(false)                     // swapActive
        .storeCoins(0)                        // liquidity
        .storeCoins(0).storeCoins(0)          // reserveX / reserveY
        .endCell();
}

fun dedustPoolDeploy(st: Curve): AutoDeployAddress {
    return {
        workchain: 0,
        stateInit: {
            code: dedustPoolCode(),
            data: dedustPoolStorage(st),
        },
    };
}

// Integer square root (Newton). Used to derive the liquidity a *clean*
// (empty, or exactly price-matched) pool must mint for our seed, which is the
// basis of the anti-pre-seed guard below.
fun isqrt(n: int): int {
    if (n <= 0) { return 0; }
    var x = n;
    var y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}

// AUDIT (critical, fixed): the CPMM v2 pool address is deterministic in the
// asset pair + config, so a sniper could deploy and seed THAT pool before
// graduation at a price of their choosing, with UNLOCKED liquidity. With
// minimalLiquidity = 0 our seed would then be accepted at the attacker's
// ratio: only the proportional share is taken, the rest refunded, the pool
// opens at a manipulated price and the attacker can pull their unlocked
// position and dump into our locked one.
//
// A first (empty-pool) deposit mints sqrt(x*y). A proportional deposit into an
// existing pool at OUR ratio mints exactly sqrt(x*y) too. Any other ratio
// mints strictly less. Demanding minimalLiquidity = sqrt(x*y) minus a small
// rounding slack therefore accepts an untouched pool and an honestly
// price-matched one, and makes a manipulated pool REVERT the deposit (funds
// refund to the curve and graduation rewinds for a retry) instead of silently
// underfilling at the attacker's price.
const SEED_LIQUIDITY_SLACK_BPS = 50;   // 0.5% rounding tolerance
const SEED_FORCE_SLACK_BPS = 50;       // multisig rescue floor: never below 99.5% of fair liquidity (audit H-4)

// deposit#c9a015da amountX:Coins amountY:Coins minimalLiquidity:Coins
//   lockedLiquidityShare:uint16
fun dedustDepositPayload(lpMeme: int, lpQuote: int, slackBps: int): cell {
    val minLiquidity = isqrt(lpMeme * lpQuote) * (10000 - slackBps) / 10000;
    return beginCell()
        .storeUint(OP_DEDUST_DEPOSIT_PAYLOAD, 32)
        .storeCoins(lpMeme as coins)          // amountX == meme
        .storeCoins(lpQuote as coins)         // amountY == quote
        .storeCoins(minLiquidity as coins)    // anti pre-seed / price-manipulation floor
        .storeUint(DEDUST_LOCKED_LP_BPS, 16)  // 100% locked forever
        .endCell();
}


// ExtendedPayoutConfig with no payout overrides; excesses go to `excessesTo`.
fun dedustPayoutConfig(excessesTo: address): cell {
    return beginCell()
        // AUDIT (H-1): non-zero forward amount so a refunded jetton leg always
        // produces a transfer_notification the curve can book.
        .storeUint(0, 2).storeCoins(20000000).storeMaybeRef(null).storeBool(false)
        .storeUint(0, 2).storeCoins(20000000).storeMaybeRef(null).storeBool(false)
        .storeAddress(excessesTo)
        .endCell();
}

fun dedustPayJetton(depositPayload: cell, payoutConfig: cell): cell {
    return beginCell()
        .storeUint(OP_DEDUST_PAY_JETTON, 32)
        .storeRef(depositPayload)
        .storeRef(payoutConfig)
        .endCell();
}

// PHASE 1 — called once `raised >= cap` (permissionlessly, or automatically by
// the cap-filling buy). Deploys the CPMM v2 pool at its deterministic address
// and asks it to initialise. Nothing is deposited yet and nothing about the
// pool is caller-supplied, so this cannot reroute a single unit.
fun graduateToDeDust(st: Curve, queryId: int) {
    val poolAddr = dedustPoolDeploy(st).calculateAddress();
    st.pool = poolAddr;
    st.prepared = true;          // "init requested"; deposits follow on the reply
    saveCurve(st);

    sendRawMessage(beginCell()
        .storeUint(0x18, 6)
        .storeAddress(poolAddr)
        .storeCoins(300000000)                       // 0.3 TON: deploy + TEP-89 resolution
        .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
        .storeRef(packStateInit(dedustPoolCode(), dedustPoolStorage(st)))
        .storeRef(beginCell()
            .storeUint(OP_DEDUST_INIT_POOL, 32)
            .storeUint(queryId, 64)
            .storeMaybeRef(null)                     // no custom payload
            .endCell())
        .endCell(), 1);
}

// PHASE 2 — the pool reports it is initialised, so both legs can be seeded.
// The full net raise (cap minus the fixed migration fee, plus the reinvested
// share of the trading fees) is paired with a price-matched slice of the 30%
// liquidity allocation, so the pool opens exactly where the curve closed.
fun seedDeDustPool(st: Curve, queryId: int, slackBps: int) {
    val poolAddr = st.pool;

    val migFee = st.migrationFee <= st.raised ? st.migrationFee : st.raised;
    val lpQuote = st.raised - migFee + st.lpPool;
    val remainingMeme = MEME_TOTAL_SUPPLY - st.sold;
    val targetMeme = MEME_TOTAL_SUPPLY * LP_SHARE_BPS / 10000;
    val pricedMeme = lpQuote * (st.virtMeme - st.sold) / (st.virtQuote + st.raised);
    var lpMeme = pricedMeme < targetMeme ? pricedMeme : targetMeme;
    if (lpMeme > remainingMeme) { lpMeme = remainingMeme; }

    val depositPayload = dedustDepositPayload(lpMeme, lpQuote, slackBps);
    // AUDIT (critical, fixed): the payout config used to name the TREASURY as
    // the payout/excesses target. That is where CPMM v2 sends a deposit it
    // REJECTS — so the strict minimalLiquidity floor (our anti pre-seed guard)
    // would have shipped the entire net raise into a hot wallet instead of
    // refunding it, and the retain-and-retry branch below could never fire.
    // Refunds now come back to the curve itself, where `raised` is restored and
    // migration rewinds for a clean retry.
    val payload = dedustPayJetton(depositPayload, dedustPayoutConfig(contract.getAddress()));


    st.graduated = true;
    st.lpLocked = 0;              // liquidity lives in the pool, locked 100%
    st.lpUnlockAt = 0;
    st.raised = 0;
    st.lpPool = 0;
    // Remember what this attempt sent, so a returning payment can be told apart:
    // a dust excess after a SUCCESSFUL deposit must not rewind the migration,
    // a full rejection must.
    st.seedQuote = lpQuote as coins;
    st.seedMeme = lpMeme as coins;
    st.legBounced = 0;
    st.seedSlack = slackBps;
    st.seedAt = blockchain.now();
    // ROUND 31 (audit 2026-10-26): this attempt's legs carry their own query id,
    // so a bounce is matched to the seed by id, never by amount.
    st.seedQid = QID_TAG | QID_SEED_TAG | (blockchain.logicalTime() & (QID_SEED_TAG - 1));
    st.quoteBack = false;
    st.memeBack = false;
    // AUDIT (M-5, fixed): buys are closed for good once the cap is hit, so the
    // lifetime buyer ledger is dead weight. Dropping it stops a graduated
    // curve from paying storage rent on ~8k cells forever and freezing.
    st.buyers = null;
    st.buyerCount = 0;
    // The fixed migration fee is charged exactly once. If the pool refunds the
    // deposit and the seed is retried, the refunded quote comes back into
    // `raised` — without this the treasury would be paid the fee again on
    // every attempt.
    st.migrationFee = 0;
    saveCurve(st);


    // treasury receives exactly the fixed migration fee; the pool gets the rest
    if (migFee > 0) {
        jettonTransfer(st.quoteWallet, migFee, st.treasury, st.treasury, 1000000, null, 60000000);
    }
    // Both legs go straight to the pool; it credits the deposit once both have
    // arrived and mints 100%-locked liquidity. Unused TON on each leg returns
    // to the curve (not the treasury) so a retry is still funded.
    val selfAddr = contract.getAddress();
    jettonTransferQ(st.memeWallet, st.seedQid, lpMeme as coins, poolAddr, selfAddr, 200000000, payload, 250000000);
    jettonTransferQ(st.quoteWallet, st.seedQid, lpQuote as coins, poolAddr, selfAddr, 200000000, payload, 250000000);
}


// LP DEPOSIT RELAY (AUDIT 2026-10-25). Only the curve may deposit into its pool
// (deposit activation rule), so a post-migration LP share is relayed: the payout
// wallet sends the quote amount here (LPQT); the curve keeps half, swaps the
// other half into tokens with ITSELF as the recipient (fulfil payload LPDP),
// then deposits the tokens + the kept half as 100%-locked liquidity. A rejected
// swap (price moved past minOut) returns its quote to THIS curve tagged LPRF and
// is booked into lpPool again; a kept half left over from a refused swap is
// folded into the next relay. Nothing ever leaves for another wallet.
fun lpRelaySwap(mutate st: Curve, amount: int, minOut: int, selfPay: bool) {
    val all = amount + st.lpRelayQuote;
    val half = all / 2;
    st.lpRelayQuote = all - half;
    // ROUND 31 (audit 2026-10-26): a fresh secret nonce per relay. The deposit
    // leg (LPDP) only fires for a fulfil payload carrying it, so a stranger's
    // swap paid to this curve can never trigger the deposit early.
    st.lpRelayQid = relayNonce();
    saveCurve(st);
    val selfAddr = contract.getAddress();
    val swap = beginCell()
        .storeUint(OP_DEDUST_SWAP_V2, 32)
        .storeCoins(minOut)
        .storeUint(0, 40)                      // no deadline
        .storeMaybeRef(null)                   // single hop
        .storeBool(false)                      // partnerConfig
        .storeBool(false)                      // referrerConfig
        .endCell();
    val payout = beginCell()
        // fulfil: tokens to this curve with LPDP + nonce + gas for the two deposit legs
        .storeAddress(selfAddr)
        .storeCoins(LP_DEPOSIT_GAS_J)
        .storeMaybeRef(beginCell().storeUint(OP_LP_DEPOSIT, 32).storeUint(st.lpRelayQid, 64).endCell())
        .storeBool(false)
        // reject: quote back to this curve, tagged LPRF -> lpPool
        .storeAddress(selfAddr)
        .storeCoins(LP_REFUND_FWD)
        .storeMaybeRef(beginCell().storeUint(OP_LP_REFUND, 32).endCell())
        .storeBool(false)
        .storeAddress(selfPay ? selfAddr : st.opsMultisig) // excesses back to whoever paid
        .endCell();
    val payload = beginCell()
        .storeUint(OP_DEDUST_PAY_JETTON, 32)
        .storeRef(swap)
        .storeRef(payout)
        .endCell();
    jettonTransferQ(st.quoteWallet, QID_LP, half as coins, st.pool, selfAddr,
        (LP_DEPOSIT_GAS_J + 250000000) as coins, payload, (LP_DEPOSIT_GAS_J + 350000000) as coins);
}

// Unpredictable until this transaction runs (block random seed mixed with lt).
fun relayNonce(): int {
    random.initialize();
    return QID_TAG | (random.uint256() >> 193);
}

// Deposit exactly the relayed tokens + the held quote half as locked LP.
fun relayLpDepositJ(mutate st: Curve, memeAmt: int) {
    val quoteAmt = st.lpRelayQuote;
    st.lpRelayQuote = 0;
    saveCurve(st);
    val selfAddr = contract.getAddress();
    val depositPayload = dedustDepositPayload(memeAmt, quoteAmt, 10000);   // no floor: relayed funds only
    val payload = dedustPayJetton(depositPayload, dedustPayoutConfig(selfAddr));
    jettonTransferQ(st.memeWallet, QID_LP, memeAmt as coins, st.pool, selfAddr, 200000000, payload, 250000000);
    jettonTransferQ(st.quoteWallet, QID_LP, quoteAmt as coins, st.pool, selfAddr, 200000000, payload, 250000000);
}

// ROUND 31: payments to a wallet carry that wallet's key as their query id, so
// a bounced CLAM payout can be recognised (see onBouncedMessage).
fun legKey(a: address): int {
    val (_, h) = a.getWorkchainAndHash();
    return h & LEG_KEY_MASK;
}

fun jettonTransfer(wallet: address, amount: coins, to: address, responseTo: address,
                   fwdTon: coins, fwdPayload: cell?, tonValue: coins) {
    jettonTransferQ(wallet, legKey(to), amount, to, responseTo, fwdTon, fwdPayload, tonValue);
}

fun jettonTransferQ(wallet: address, queryId: int, amount: coins, to: address, responseTo: address,
                    fwdTon: coins, fwdPayload: cell?, tonValue: coins) {
    var b = beginCell()
        .storeUint(OP_JETTON_TRANSFER, 32)
        .storeUint(queryId, 64)
        .storeCoins(amount)
        .storeAddress(to)
        .storeAddress(responseTo)
        .storeUint(0, 1)          // custom_payload
        .storeCoins(fwdTon);
    if (fwdPayload != null) {
        b = b.storeUint(1, 1).storeRef(fwdPayload!);
    } else {
        b = b.storeUint(0, 1);
    }
    sendRawMessage(beginCell()
        .storeUint(0x18, 6)
        .storeAddress(wallet)
        .storeCoins(tonValue)
        .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeRef(b.endCell())
        .endCell(), 1);
}

// Refund/reject variant: the message carries whatever TON is LEFT of the
// incoming notification (mode 64) instead of spending the curve's own balance.
//
// AUDIT (medium, fixed): every reject path used to pay 0.05 TON of the curve's
// own balance. The forward TON amount on a jetton transfer is chosen by the
// SENDER, so an attacker could forward 1 nanoton, get refunded, and repeat —
// burning the curve's TON reserve until it dropped under the 1.2 TON
// graduation floor and migration stalled. Now a reject is funded strictly by
// the gas the sender attached: under-fund it and only the attacker's own
// jettons get stuck, never the curve's TON.
// ROUND 31: `why` (a refund_reason cell) rides as the forward payload of the
// return, with `fwdTon` for the owner notification (0 = payload only, visible in
// the wallet-to-wallet transfer).
fun jettonTransferCarry(wallet: address, amount: coins, to: address, responseTo: address, why: cell?, fwdTon: coins) {
    var b = beginCell()
        .storeUint(OP_JETTON_TRANSFER, 32)
        .storeUint(legKey(to), 64)
        .storeCoins(amount)
        .storeAddress(to)
        .storeAddress(responseTo)
        .storeUint(0, 1);         // custom_payload
    if (why != null) {
        b = b.storeCoins(fwdTon).storeUint(1, 1).storeRef(why!);
    } else {
        b = b.storeCoins(0).storeUint(0, 1);
    }
    sendRawMessage(beginCell()
        .storeUint(0x18, 6)
        .storeAddress(wallet)
        .storeCoins(0)
        .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeRef(b.endCell())
        .endCell(), 64 + 2);      // carry remaining inbound value, ignore errors
}

// refund_reason#52464e44 query_id:uint64 reason:uint8
fun refundReason(queryId: int, reason: int): cell {
    return beginCell().storeUint(OP_REFUND_REASON, 32).storeUint(queryId, 64).storeUint(reason, 8).endCell();
}

// External log (ext_out_msg_info, src/dest addr_none) for indexers.
fun emitLog(body: cell) {
    sendRawMessage(beginCell()
        .storeUint(0x30, 6)
        .storeUint(0, 64 + 32 + 1)
        .storeUint(1, 1)
        .storeRef(body)
        .endCell(), 2);
}

// Return a rejected trade in full with its reason. A full-gas trade gets the
// payload with a 0.001 GRAM owner notification (like every trade output) plus
// the log; a low-gas one (>= REASON_MIN_GRAM) gets the payload only; below
// that the return carries nothing extra, so it still fits its own gas.
fun rejectJetton(wallet: address, amount: coins, to: address, queryId: int, reason: int, value: int) {
    if (value >= MIN_TRADE_GRAM) {
        val why = refundReason(queryId, reason);
        emitLog(why);
        jettonTransferCarry(wallet, amount, to, to, why, 1000000);
    } else if (value >= REASON_MIN_GRAM) {
        jettonTransferCarry(wallet, amount, to, to, refundReason(queryId, reason), 0);
    } else {
        jettonTransferCarry(wallet, amount, to, to, null, 0);
    }
}

// Hash of this curve's DeDust position contract for `pool` (the address keeps
// the pool's top 8 bits: split_depth 8). Verified against the real DeDust code
// in scripts/sim.
fun dedustPositionHashFor(pool: address): int {
    val data = beginCell()
        .storeAddress(pool)
        .storeAddress(contract.getAddress())
        .storeCoins(0).storeCoins(0)
        .storeUint(0, 1)
        .storeRef(beginCell().storeUint(0, 26).endCell())
        .endCell();
    val code = beginCell()
        .storeInt(ExoticCellType.LibraryReference, 8)
        .storeUint(DEDUST_POSITION_LIBRARY_HASH, 256)
        .endCellSpecial();
    val si = beginCell()
        .storeUint(1, 1).storeUint(8, 5)   // fixed_prefix_length = 8
        .storeUint(0, 1)                   // no tick/tock
        .storeMaybeRef(code)
        .storeMaybeRef(data)
        .storeUint(0, 1)                   // no libraries
        .endCell();
    val (_, poolHash) = pool.getWorkchainAndHash();
    val low = (1 << 248) - 1;
    return (poolHash & ~low) | (si.hash() & low);
}

// ROUND 31 (audit 2026-10-26, approved 2026-11-01): once DeDust confirmed the
// seed, the tokens left on the curve (the unsold part of the 300M liquidity
// allocation, ~6.7% of supply) are burned, so explorers show the real supply.
// Tokens from a bounced wallet payment are not part of it; they stay on the curve.
fun burnLeftover(mutate st: Curve) {
    if (st.leftoverBurned) { return; }
    st.leftoverBurned = true;
    val leftover = MEME_TOTAL_SUPPLY - st.sold - st.seedMeme;
    if (leftover <= 0) { return; }
    sendRawMessage(beginCell()
        .storeUint(0x18, 6)
        .storeAddress(st.memeWallet)
        .storeCoins(LEFTOVER_BURN_GAS)
        .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeRef(beginCell()
            .storeUint(OP_JETTON_BURN, 32)
            .storeUint(QID_BURN, 64)
            .storeCoins(leftover as coins)
            .storeUint(0, 2)               // response_destination: addr_none
            .storeUint(0, 1)               // no custom payload
            .endCell())
        .endCell(), 1);
}

/// Real bounces are routed here by the runtime (unforgeable). Only bounces
/// from the curve's own quote / meme wallet count.
/// ROUND 31 (audit 2026-10-26): curve-internal legs are booked back:
///   - seed legs: matched by the attempt's own query id -> RSND resends them
///   - LP relay legs: the quote goes back into lpPool
///   - CLAM payouts: back into holderPool (the next CLAM retries)
///   - the leftover burn: re-armed for BRNL
/// A bounced payment to any other wallet (trade outputs, refunds, CLMC) simply
/// stays on the curve (owner decision 2026-11-01: no claim-back).
fun onBouncedMessage(in: InMessageBounced) {
    var st = loadCurve();
    val selfAddr = contract.getAddress();
    val fromQuote = st.quoteWallet != selfAddr && in.senderAddress == st.quoteWallet;
    val fromMeme = st.memeMaster != selfAddr && in.senderAddress == st.memeWallet;
    if (!fromQuote && !fromMeme) { return; }
    var b = in.bouncedBody;
    b.skipBouncedPrefix();
    if (b.remainingBitsCount() < 32 + 64) { return; }
    val op = b.loadUint(32);
    val qid = b.loadUint(64);
    if (op == OP_JETTON_BURN) {
        if (fromMeme && qid == QID_BURN && st.leftoverBurned) {
            st.leftoverBurned = false;
            saveCurve(st);
        }
        return;
    }
    if (op != OP_JETTON_TRANSFER) { return; }
    if (b.remainingBitsCount() < 4) { return; }
    val len = b.preloadUint(4);
    if (b.remainingBitsCount() < 4 + len * 8) { return; }
    val amount = b.loadCoins();
    if (amount <= 0) { return; }
    if (qid >= QID_TAG) {
        if (st.seedQid != 0 && qid == st.seedQid) {
            if (st.graduated) {
                st.legBounced = st.legBounced | (fromMeme ? 1 : 2);
                saveCurve(st);
            }
        } else if (qid == QID_LP && fromQuote) {
            st.lpPool += amount;
            saveCurve(st);
        }
        return;
    }
    if (fromQuote && qid == legKey(st.holderPayout)) {
        st.holderPool += amount;
        saveCurve(st);
    }
}



fun onInternalMessage(in: InMessage) {
    var body = in.body;
    if (body.isEmpty()) { return; }
    val op = body.loadUint(32);
    // Acton v1.1 does not expose an InMessage.isBounced field. TON prepends
    // 0xffffffff to a bounced body, so detect that marker before decoding the
    // query ID and accept it silently.
    // ROUND 31: real bounces go to onBouncedMessage, which books curve-internal
    // legs back into the pool they came from.
    if (op == 0xffffffff) { return; }
    val queryId = body.loadUint(64);
    var st = loadCurve();

    if (op == OP_CURVE_INIT) {
        // AUDIT (critical): the master's create_launch is permissionless and the
        // curve address is deterministic in (master, creator, quote, salt), so a
        // creator could re-send create_launch for a LIVE curve. The StateInit is
        // ignored for an already-deployed contract, but the CINT body would be
        // delivered and would reset raised/sold/cap/metadata to zero, letting the
        // creator re-buy the whole supply against a wiped reserve. A curve is
        // therefore initialisable exactly once: a live curve always has cap > 0.
        // AUDIT 2026-10-25 (external L-2): a re-sent create_launch used to bounce
        // into the master (which ignores bounces), stranding the launcher's gas.
        // The re-sender is always this curve's creator, so refund them.
        if (st.cap != 0) {
            sendRawMessage(beginCell()
                .storeUint(0x10, 6)
                .storeAddress(st.creator)
                .storeCoins(0)
                .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .endCell(), 64 + 2);
            return;
        }
        initFromMaster(st, in.senderAddress, body);
        return;
    }

    // TEP-89 reply from the quote jetton master: learn our quote wallet.
    // Accepted only once, while the wallet is still unknown, so a later reply
    // can never re-point the curve's quote wallet at another contract.
    if (op == OP_TAKE_WALLET_ADDRESS) {
        assert(in.senderAddress == st.quoteMaster, ERR_NOT_ALLOWED);
        assert(st.quoteWallet == contract.getAddress(), ERR_ALREADY_INIT);
        st.quoteWallet = body.loadAddress();
        saveCurve(st);
        return;
    }

    if (op == OP_TRANSFER_NOTIFICATION) {
        val amount = body.loadCoins();
        val from = body.loadAddress();

        // AUDIT (high, fixed — external review H-1): the full-supply mint is
        // the first transfer notification from the curve's own meme wallet,
        // sent by the minter with `from = curve`. It carries no forward
        // payload, so it must be recognised BEFORE the payload guards below.
        // Buys stay refund-only until this lands, so a failed minter deploy
        // can never debit `raised` for tokens that do not exist.
        if (!st.graduated && !st.minted
            && in.senderAddress == st.memeWallet
            && from == contract.getAddress()
            && amount >= MEME_TOTAL_SUPPLY / 2) {
            st.minted = true;
            st.liveAt = blockchain.now();   // creator-first window starts now
            saveCurve(st);
            return;
        }
        // TEP-74 allows the forward payload EITHER inline in this cell or as a
        // reference. Accept both, so a buy/sell built by a third-party wallet or
        // SDK is not mistaken for a donation.
        // AUDIT (H-1/H-2, fixed): pool refunds are handled BEFORE the payload
        // guards (a refund carries no trade payload, so the old position after
        // the guards never ran). Only the QUOTE leg decides: the meme leg is
        // simply kept, so refund arrival order no longer matters. A majority
        // quote refund rewinds the migration for a clean retry; a dust excess
        // marks the seed final (M-1).
        // AUDIT (H-2 / M-1, fixed): success is never inferred from an incoming
        // payment any more. A seed is treated as REJECTED only when BOTH legs
        // come back from the pool at (>= 99% of) the exact amounts this attempt
        // sent — order-independent. Anything else from the pool (a swap output
        // aimed at the curve, dust) is booked, never strands the raise, and can
        // never rewind graduation: forging it would cost ~the whole raise.
        if (st.graduated && from == st.pool && amount > 0) {
            // HRVP (AUDIT 2026-10-25, external H-2): harvested position fees
            // arrive here as quote tagged HRVP. Split on-chain with the launch's
            // own bps; the treasury share goes straight to the multisig.
            if (in.senderAddress == st.quoteWallet && body.remainingBitsCount() >= 1) {
                var hs = body;
                var hp = hs;
                var hok = true;
                if (hs.preloadUint(1) == 1) {
                    hok = hs.remainingRefsCount() >= 1;
                    if (hok) { hs.loadUint(1); hp = hs.loadRef().beginParse(); }
                } else {
                    hs.loadUint(1);
                    hp = hs;
                }
                if (hok && hp.remainingBitsCount() >= 32 && hp.preloadUint(32) == OP_HARVEST_PAYOUT) {
                    val treasuryAmt = amount * st.treasuryFeeBps / 10000;
                    val creatorAmt = amount * st.creatorFeeBps / 10000;
                    val lpAmt = amount * st.lpFeeBps / 10000;
                    st.creatorPool += creatorAmt;
                    st.lpPool += lpAmt;
                    st.holderPool += amount - treasuryAmt - creatorAmt - lpAmt;
                    saveCurve(st);
                    if (treasuryAmt > 0) {
                        jettonTransfer(st.quoteWallet, treasuryAmt as coins, st.treasury, st.treasury, 1000000, null, 60000000);
                    }
                    return;
                }
                // LPRF: a refused LP swap comes back
                // to the LP share. Only adds to lpPool (anyone tagging their own
                // swap here simply donates to the locked LP).
                if (hok && hp.remainingBitsCount() >= 32 && hp.preloadUint(32) == OP_LP_REFUND) {
                    st.lpPool += amount;
                    saveCurve(st);
                    return;
                }
            }
            // LP relay leg 2 (AUDIT 2026-10-25): the swapped tokens arrive with
            // LPDP — deposit them with the held quote half. Checked first so a
            // relayed swap can never be mistaken for a seed refund.
            // ROUND 31: only the curve's OWN in-flight relay may fire the deposit —
            // its fulfil payload must carry the secret nonce of that relay.
            if (in.senderAddress == st.memeWallet && st.lpRelayQuote > 0 && st.lpRelayQid != 0
                && in.valueCoins >= LP_DEPOSIT_GAS_J && body.remainingBitsCount() >= 1) {
                var ps = body;
                var pp = ps;
                var okp = true;
                if (ps.preloadUint(1) == 1) {
                    okp = ps.remainingRefsCount() >= 1;
                    if (okp) { ps.loadUint(1); pp = ps.loadRef().beginParse(); }
                } else {
                    ps.loadUint(1);
                    pp = ps;
                }
                if (okp && pp.remainingBitsCount() >= 32 + 64 && pp.preloadUint(32) == OP_LP_DEPOSIT) {
                    pp.loadUint(32);
                    if (pp.loadUint(64) == st.lpRelayQid) {
                        st.lpRelayQid = 0;
                        relayLpDepositJ(mutate st, amount);
                        return;
                    }
                }
            }
            if (in.senderAddress == st.quoteWallet && !st.quoteBack
                && !st.seeded
                && st.seedQuote > 0 && amount <= st.seedQuote
                && amount * 100 >= st.seedQuote * 99) {
                st.quoteBack = true;
                st.seedQuote = amount;          // credit exactly what came back
            } else if (in.senderAddress == st.memeWallet && !st.memeBack
                && !st.seeded
                && st.seedMeme > 0 && amount <= st.seedMeme
                && amount * 100 >= st.seedMeme * 99) {
                st.memeBack = true;
            } else {
                // not a refund of our seed: quote is recoverable via CLAM,
                // meme simply stays locked in the curve
                if (in.senderAddress == st.quoteWallet) { st.holderPool += amount; }
                saveCurve(st);
                return;
            }
            if (st.quoteBack && st.memeBack) {
                st.raised += st.seedQuote;
                st.graduated = false;
                st.prepared = false;
                st.quoteBack = false;
                st.memeBack = false;
                st.seedQuote = 0;
                st.seedMeme = 0;
                st.legBounced = 0;
            }
            saveCurve(st);
            return;
        }
        // AUDIT 2026-10-24: a malformed forward payload must never throw (a
        // throw does NOT undo the jetton transfer — TEP-74 notifications are a
        // separate transaction) and must not strand the sender's tokens either.
        // Every read is bounds-checked first: the Either bit, the reference,
        // op + query id, and the full variable-length Coins. Anything we cannot
        // parse is handed back to the sender when the notification carries
        // enough GRAM for the return transfer; only an unfunded one is kept.
        // ROUND 31: every return carries a refund reason (see OP_REFUND_REASON);
        // `queryId` is the trader's own query id of the transfer.
        var payloadOk = body.remainingBitsCount() >= 1;
        var fs = body;
        if (payloadOk) {
            val inRef = body.preloadUint(1) == 1;
            if (inRef) {
                payloadOk = body.remainingRefsCount() >= 1;
                if (payloadOk) {
                    body.loadUint(1);
                    fs = body.loadRef().beginParse();
                }
            } else {
                body.loadUint(1);
                fs = body;
            }
        }
        if (payloadOk) { payloadOk = fs.remainingBitsCount() >= 32 + 64 + 4; }
        if (payloadOk) {
            var probe = fs;
            probe.loadUint(32 + 64);
            val coinsLen = probe.preloadUint(4);
            payloadOk = probe.remainingBitsCount() >= 4 + coinsLen * 8;
        }
        if (!payloadOk) {
            if (amount > 0 && in.valueCoins >= MALFORMED_RETURN_GRAM) {
                rejectJetton(in.senderAddress, amount, from, queryId, REASON_MALFORMED, in.valueCoins);
            }
            return;
        }
        val innerOp = fs.loadUint(32);
        fs.loadUint(64);
        val minOut = fs.loadCoins();


        // AUDIT (medium): the TEP-89 reply that sets quoteWallet is sent in the
        // same init transaction but processed afterwards. A trader sending a buy
        // in the very next block would hit the curve before quoteWallet is set,
        // fail the spoof assert below, and strand the quote jettons.
        // AUDIT (fix): these used to be silently swallowed as a "donation",
        // i.e. a real loss for an early buyer. The notifier IS the jetton
        // wallet holding those tokens, so we can hand them straight back to
        // `from` without knowing which jetton it is. A fake wallet only ever
        // gets its own worthless tokens back, so this is not a new vector.
        if (st.quoteWallet == contract.getAddress()) {
            if (amount > 0) {
                rejectJetton(in.senderAddress, amount, from, queryId, REASON_NOT_LIVE, in.valueCoins);
            }
            return;
        }

        // GAS GRIEF GUARD: a trade whose forwarded TON does not cover the legs
        // this contract has to pay for is bounced straight back to the sender
        // with mode 64 (carry remaining value), so it can never nibble at the
        // curve's own TON reserve.
        if ((innerOp == OP_BUY || innerOp == OP_SELL) && in.valueCoins < MIN_TRADE_GRAM) {
            if (amount > 0) {
                rejectJetton(in.senderAddress, amount, from, queryId, REASON_LOW_GAS, in.valueCoins);
            }
            return;
        }


        if (innerOp == OP_BUY) {
            // Spoof protection stays a hard assert: only OUR quote wallet may
            // ever move quote jettons out of this curve.
            // AUDIT (low, fixed): a buy sent from the wrong wallet (e.g. the
            // meme wallet) or by a non-basechain buyer used to throw / never
            // deliver. The tokens go back through the wallet that sent them;
            // that wallet can only return its own tokens, so spoofing gains
            // nothing.
            if (in.senderAddress != st.quoteWallet || from.getWorkchain() != 0) {
                if (amount > 0) {
                    rejectJetton(in.senderAddress, amount, from, queryId,
                        in.senderAddress != st.quoteWallet ? REASON_WRONG_ASSET : REASON_WORKCHAIN, in.valueCoins);
                }
                return;
            }

            // AUDIT (high): every reject path below used to `assert`, which
            // strands the trader's jettons in the curve (the transfer itself is
            // already final). All rejects now refund the exact input instead.
            if (st.graduated || st.capReached || st.raised >= st.cap) {
                rejectJetton(st.quoteWallet, amount, from, queryId, REASON_CLOSED, in.valueCoins);
                return;
            }
            // AUDIT (high, fixed — external review H-1): refund-only until the
            // full-supply mint has landed (see the minted gate above).
            if (!st.minted) {
                rejectJetton(st.quoteWallet, amount, from, queryId, REASON_NOT_LIVE, in.valueCoins);
                return;
            }
            // Creator-first window: only the creator may buy right after launch,
            // so the dev buy is always first. Everyone else gets a full refund.
            if (from != st.creator && blockchain.now() < st.liveAt + CREATOR_ONLY_SECS) {
                rejectJetton(st.quoteWallet, amount, from, queryId, REASON_CREATOR_WINDOW, in.valueCoins);
                return;
            }
            // CAP CLAMP: only the quote still needed to reach the cap is
            // accepted. Without this the crossing buy pushed `raised` past the
            // cap (the SP500 curve ended at ~4.05 against a 3.448 cap) and the
            // pool opened with more quote than the launch advertises.
            val room = st.cap - st.raised;                 // > 0, checked above
            // gross input whose post-fee remainder is exactly `room`
            val maxGross = (room * 10000 / (10000 - st.feeBps) + 1) as coins;
            var accepted = amount < maxGross ? amount : maxGross;
            var fee = accepted * st.feeBps / 10000;
            var swapAmount = accepted - fee;
            if (swapAmount > room) {
                swapAmount = room;
                accepted = swapAmount + fee;
            }
            // WHALE / SNIPER CLAMP: a wallet can never hold more than
            // MAX_BUY_MEME (2% of total supply) worth of curve purchases over
            // the LIFETIME of the launch, not just per transaction. Each
            // buyer's cumulative purchase is tracked in a dictionary keyed by
            // the buyer's account hash, and the input is clamped to whatever
            // allowance is left. The remainder is refunded in the same tx.
            // User decision 2026-10-25: the creator is exempt on every profile.
            val capExempt = (from == st.creator);
            val (_, buyerHash) = from.getWorkchainAndHash();
            val buyerKey = buyerHash >> (256 - BUYER_KEY_LEN);

            var bought: int = 0;
            val (boughtSlice, boughtFound) = st.buyers.uDictGet(BUYER_KEY_LEN, buyerKey);
            if (boughtFound) {
                var bs = boughtSlice!;
                bought = bs.loadCoins();
            }
            var whaleClamped = false;
            if (!capExempt) {
                var allowance = MAX_BUY_MEME - bought;
                if (allowance <= 0) {
                    rejectJetton(st.quoteWallet, amount, from, queryId, REASON_WALLET_LIMIT, in.valueCoins);
                    return;
                }
                val reserveOut = st.virtMeme - st.sold;
                if (reserveOut > allowance) {
                    val maxSwap = (allowance * (st.virtQuote + st.raised) / (reserveOut - allowance)) as coins;
                    if (swapAmount > maxSwap) {
                        swapAmount = maxSwap;
                        fee = (swapAmount * st.feeBps / (10000 - st.feeBps)) as coins;
                        accepted = swapAmount + fee;
                        whaleClamped = true;
                    }
                }
            }

            val refund = amount - accepted;
            val creatorFee = fee * st.creatorFeeBps / 10000;
            val treasuryFee = fee * st.treasuryFeeBps / 10000;
            var out = ammOutNoFee(swapAmount, st.virtQuote + st.raised, st.virtMeme - st.sold);
            // out must be payable from the meme the curve still holds
            val memeLeft = MEME_CURVE_SUPPLY - st.sold;
            // AUDIT (high, fixed): the LAST sliver of a curve used to be
            // unbuyable (constant-product rounding a few units above what is
            // left). The output is clamped to whatever meme remains; the clamp
            // can only ever pay out LESS than the curve price, never more.
            if (out > memeLeft) { out = memeLeft; }
            if (out < minOut || out <= 0) {
                // a wallet whose last allowance rounds to nothing is at its limit
                rejectJetton(st.quoteWallet, amount, from, queryId,
                    (out <= 0 && whaleClamped) ? REASON_WALLET_LIMIT : REASON_SLIPPAGE, in.valueCoins);
                return;
            }

            st.raised += swapAmount;
            st.sold += out;
            // record the buyer's lifetime purchase before anything is sent out
            // AUDIT (high, fixed — external review H-3): the buyer ledger stops
            // growing at MAX_BUYERS_TRACKED entries so account state can never
            // cross TON's size limit and brick the curve. New wallets beyond
            // the cap simply skip the per-wallet purchase limit.
            if (boughtFound || st.buyerCount < MAX_BUYERS_TRACKED) {
                st.buyers.uDictSet(BUYER_KEY_LEN, buyerKey,
                    beginCell().storeCoins((bought + out) as coins).endCell().beginParse());
                if (!boughtFound) { st.buyerCount += 1; }
            }
            // Sticky: once the cap is touched the curve is closed for good.
            // AUDIT: without this a seller could dip `raised` back under the
            // cap and grief/delay migration indefinitely at 1% per round trip.
            if (st.raised >= st.cap && !st.capReached) {
                st.capReached = true;
                st.capReachedAt = blockchain.now();   // ESCP refund clock starts here
            }
            val lpFee = fee * st.lpFeeBps / 10000;
            st.lpPool += lpFee;                                       // reinvested into the LP
            st.creatorPool += creatorFee;                             // claimable by the creator on /claim
            st.holderPool += fee - treasuryFee - creatorFee - lpFee;  // remainder accrues for holders
            saveCurve(st);
            // treasury share and creator share of the fee, then output -> buyer
            if (treasuryFee > 0) {
                jettonTransfer(st.quoteWallet, treasuryFee, st.treasury, st.treasury, 1000000, null, TRADE_LEG_GRAM);
            }
            jettonTransfer(st.memeWallet, out, from, from, 1000000, null, TRADE_LEG_GRAM);
            // overshoot goes straight back to the buyer, with its reason
            if (refund > 0) {
                val why = refundReason(queryId, whaleClamped ? REASON_WALLET_LIMIT_PARTIAL : REASON_CAP_PARTIAL);
                emitLog(why);
                jettonTransfer(st.quoteWallet, refund, from, from, 1000000, why, TRADE_LEG_GRAM);
            }
            // AUTO-GRADUATION: the buy that fills the cap deploys the DeDust
            // CPMM v2 pool in the same transaction; the pool's init reply then
            // seeds both legs automatically. Everything the curve needs is
            // derived from its own storage, so nothing has to be pre-provisioned.
            if (st.capReached
                && !st.prepared
                && st.memeMaster != contract.getAddress()
                && st.quoteWallet != contract.getAddress()
                && contract.getOriginalBalance() >= 1200000000) {
                graduateToDeDust(st, 0);
            }

            return;
        }

        if (innerOp == OP_SELL) {
            // AUDIT (low, fixed): wrong-wallet sells are returned, not stranded.
            if (in.senderAddress != st.memeWallet) {
                if (amount > 0) {
                    rejectJetton(in.senderAddress, amount, from, queryId, REASON_WRONG_ASSET, in.valueCoins);
                }
                return;
            }
            // REFUND MODE (ESCP opened): pro-rata payout of the raise, no fee.
            if (st.refunding) {
                if (amount <= 0 || amount > st.sold) {
                    rejectJetton(st.memeWallet, amount, from, queryId, REASON_INVALID_SELL, in.valueCoins);
                    return;
                }
                val refundOut = (st.raised * amount / st.sold) as coins;
                if (refundOut <= 0) {
                    rejectJetton(st.memeWallet, amount, from, queryId, REASON_INVALID_SELL, in.valueCoins);
                    return;
                }
                st.raised -= refundOut;
                st.sold -= amount;
                saveCurve(st);
                jettonTransfer(st.quoteWallet, refundOut, from, from, 1000000, null, TRADE_LEG_GRAM);
                return;
            }
            // capReached: the curve is closed — refund instead of trading, so
            // migration can never be pushed back below the cap.
            if (st.graduated || st.capReached) {
                rejectJetton(st.memeWallet, amount, from, queryId, REASON_CLOSED, in.valueCoins);
                return;
            }
            if (amount > st.sold || amount <= 0) {
                rejectJetton(st.memeWallet, amount, from, queryId, REASON_INVALID_SELL, in.valueCoins);
                return;
            }
            // full meme amount re-enters the curve; the 1% fee is skimmed from
            // the QUOTE output so fees are only ever USDT/GOLD/SP500.
            var grossOut = ammOutNoFee(amount, st.virtMeme - st.sold, st.virtQuote + st.raised);
            // AUDIT (high): the constant-product output is bounded by
            // virtQuote + raised, i.e. it can mathematically exceed the REAL
            // quote the curve holds. Hard clamp.
            if (grossOut > st.raised) { grossOut = st.raised; }
            val fee = grossOut * st.feeBps / 10000;
            val out = grossOut - fee;
            val creatorFee = fee * st.creatorFeeBps / 10000;
            val treasuryFee = fee * st.treasuryFeeBps / 10000;
            if (out < minOut || out <= 0) {
                rejectJetton(st.memeWallet, amount, from, queryId, REASON_SLIPPAGE, in.valueCoins);
                return;
            }
            // Reserve drops by the full gross output; the retained 90% holder
            // share is tracked in holderPool, so the curve's quote wallet
            // balance always equals raised + holderPool exactly.
            st.raised -= grossOut;
            st.sold -= amount;
            val lpFee = fee * st.lpFeeBps / 10000;
            st.lpPool += lpFee;
            st.creatorPool += creatorFee;
            st.holderPool += fee - treasuryFee - creatorFee - lpFee;
            saveCurve(st);
            // treasury + creator shares of the quote fee, then output -> seller
            if (treasuryFee > 0) {
                jettonTransfer(st.quoteWallet, treasuryFee, st.treasury, st.treasury, 1000000, null, TRADE_LEG_GRAM);
            }
            jettonTransfer(st.quoteWallet, out, from, from, 1000000, null, TRADE_LEG_GRAM);
            return;
        }

        // Post-graduation: the curve is the DeDust LP owner.
        //
        // LIQUIDITY LOCK: the LP jetton wallet is pinned by the treasury with
        // SETL (its address is deterministic in the DeDust pool, so it is
        // computed off-chain and pinned once). Everything that arrives on a
        // wallet that is not the curve's quote/meme wallet is KEPT HERE.
        //
        // AUDIT (high, fixed): this used to pin "the first unknown jetton seen
        // after graduation" as the LP wallet and forward every other unknown
        // jetton to the treasury. Both were exploitable:
        //   * anyone could front-run the LP mint with a worthless jetton, which
        //     mis-pinned lpWallet and made the REAL LP be forwarded out of the
        //     locked custody to the treasury wallet;
        //   * each forwarded junk arrival cost the curve ~0.05 TON of its own
        //     balance, so spamming a graduated curve drained its gas reserve.
        // Nothing is forwarded any more and nothing is pinned implicitly, so a
        // stranger can neither move the LP nor burn the curve's TON.
        if (st.graduated
            && in.senderAddress != st.quoteWallet
            && in.senderAddress != st.memeWallet) {
            if (in.senderAddress == st.lpWallet) {
                st.lpLocked += amount;   // stays put, locked
                saveCurve(st);
            }
            return;
        }

        // Post-graduation quote/meme arrivals on the curve's own wallets.
        //
        // AUDIT (high, fixed): every such arrival used to be forwarded straight
        // to the treasury wallet. HRVS already pays the harvested creator fees
        // to the treasury directly (`to: st.treasury`), so the ONLY realistic
        // sender here is the DeDust pool refunding a deposit that failed — and
        // the old branch shipped the entire net raise out of the contract into a
        // hot wallet. A refund from the pool is now retained and the migration
        // is rewound so the seed can simply be retried.

        // Anything else post-graduation is a donation/airdrop; forward it.
        if (st.graduated) {
            // AUDIT (medium, fixed): this leg used to be paid from the curve's
            // own TON balance, so anyone could spam a graduated curve with dust
            // jettons and burn ~0.05 TON of its reserve per arrival. The
            // forward is now only curve-funded when the sender actually paid
            // for it; otherwise it rides on the inbound gas (mode 64).
            if (in.valueCoins >= TRADE_LEG_GRAM + 20000000) {
                jettonTransfer(in.senderAddress, amount, st.treasury, st.treasury, 1000000, null, TRADE_LEG_GRAM);
            } else {
                jettonTransferCarry(in.senderAddress, amount, st.treasury, st.treasury, null, 0);
            }
            return;
        }


        return;
    }


    // LEGACY no-ops. CPMM v2 pools need no factory vaults and no off-chain
    // pinning — the pool address is derived on-chain from storage — so the old
    // PREP/SETV provisioning steps do nothing. They are kept only so existing
    // keepers and integrations do not error out.
    if (op == OP_PREPARE || op == OP_SET_VAULT) {
        return;
    }

    // SETL — treasury pins the DeDust LP jetton wallet, once.
    //
    // AUDIT (high, fixed): the LP wallet used to be "whatever unknown jetton
    // wallet notifies the curve first after graduation". Anyone could send one
    // unit of a worthless jetton right after the GRAD poke and mis-pin it, and
    // the real LP would then be treated as a stray jetton. Pinning is now
    // explicit and treasury-only, and it only ever ENABLES the capped fee
    // harvest — it can never move funds by itself.
    if (op == OP_SET_LP) {
        // AUDIT (high, fixed — external review H-5): multisig, not the hot key.
        assert(in.senderAddress == st.opsMultisig, ERR_NOT_ALLOWED);
        assert(st.lpWallet == contract.getAddress(), ERR_ALREADY_INIT);
        // AUDIT (low, fixed): pinning was one-shot but not time-gated, so a
        // mistaken SETL sent before the pool existed would permanently pin the
        // wrong wallet and leave lpLocked/get_graduation_data wrong forever.
        // The pool address is only known once graduation has been initiated.
        assert(st.pool != st.lockVault, ERR_NOT_ALLOWED);
        val lpw = body.loadAddress();
        assert(lpw != contract.getAddress(), ERR_NOT_ALLOWED);
        assert(lpw != st.quoteWallet, ERR_NOT_ALLOWED);
        assert(lpw != st.memeWallet, ERR_NOT_ALLOWED);
        assert(lpw != st.treasury, ERR_NOT_ALLOWED);
        st.lpWallet = lpw;
        saveCurve(st);
        return;
    }


    // "RQWA" — AUDIT (L-4, fixed): if the quote master's TEP-89 reply never
    // arrived, the curve would refund every buy forever. Anyone may re-ask
    // while the wallet is still unset; the caller pays the gas.
    if (op == OP_REQUEST_QUOTE_WALLET) {
        assert(st.cap > 0, ERR_NOT_READY);
        assert(st.quoteWallet == contract.getAddress(), ERR_ALREADY_INIT);
        assert(in.valueCoins >= 80000000, ERR_LOW_GAS);
        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(st.quoteMaster)
            .storeCoins(50000000)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeUint(OP_PROVIDE_WALLET_ADDRESS, 32)
            .storeUint(queryId, 64)
            .storeAddress(contract.getAddress())
            .storeUint(0, 1)
            .endCell(), 1);
        return;
    }

    if (op == OP_GRADUATE) {
        assert(!st.graduated, ERR_GRADUATED);
        assert(!st.refunding, ERR_NOT_ALLOWED);
        assert(st.capReached || st.raised >= st.cap, ERR_NOT_READY);
        // AUDIT (high, fixed — external review H-1): never graduate a curve
        // whose full-supply mint never landed.
        assert(st.minted, ERR_NOT_READY);
        // PERMISSIONLESS: the poke carries no addresses. The CPMM v2 pool
        // address is derived from storage alone, so the sender cannot reroute a
        // single unit. Anyone — a bot, a holder, the creator — can migrate a
        // capped curve, so migrations never stall on the treasury being online.
        // SELF-FUNDING: pay the fan-out from the curve's own TON balance when
        // it has one; the poke only tops up the shortfall.
        assert(contract.getOriginalBalance() >= 1200000000, ERR_LOW_GAS);
        // Never graduate before the TEP-89 reply set the real quote wallet,
        // otherwise the quote leg would be sent to the curve itself.
        assert(st.quoteWallet != contract.getAddress(), ERR_NOT_READY);
        // AUDIT (high, fixed): the FIRST poke is free (paid from the curve's own
        // reserve), but re-poking was free too, and each one burned another
        // 0.3 TON of the curve's balance deploying the same pool. Spamming it
        // dragged the balance under the 1.2 TON floor and stalled migration for
        // good. A RETRY must therefore be paid for by the caller.
        assert(!st.prepared || in.valueCoins >= 400000000, ERR_LOW_GAS);
        // Retry-safe: re-sending Init to an already-deployed pool is a no-op on
        // its side, but only the pool's reply ever moves funds.
        graduateToDeDust(st, queryId);

        return;
    }

    // The CPMM v2 pool confirms it is initialised (both jetton wallets
    // resolved) — seed both legs now. Only the pool address the curve itself
    // derived is accepted, so this cannot be spoofed into an early payout.
    if (op == OP_DEDUST_INIT_RESULT) {
        assert(!st.graduated, ERR_GRADUATED);
        assert(st.prepared, ERR_NOT_READY);
        assert(in.senderAddress == st.pool, ERR_NOT_ALLOWED);
        assert(st.capReached || st.raised >= st.cap, ERR_NOT_READY);
        assert(st.quoteWallet != contract.getAddress(), ERR_NOT_READY);
        assert(!st.refunding, ERR_NOT_ALLOWED);
        // AUDIT (H-3, fixed): positive proof the pool is Initialized — FSED
        // is only reachable after this.
        // AUDIT 2026-10-24: the pool's reply carries only ~0.019 GRAM, which
        // capped this handler at ~47.7k gas — it fit with almost no margin, so
        // any code growth made the seed run out of gas. The sender is verified
        // above (the pinned pool, once per init), so the curve pays the seed's
        // own gas from its reserve, bounded.
        setGasLimit(150000);
        st.initConfirmed = true;
        // Strict floor: a pre-seeded / price-manipulated pool makes this
        // deposit revert and refund instead of filling at the sniper's price.
        seedDeDustPool(st, queryId, SEED_LIQUIDITY_SLACK_BPS);
        return;
    }

    // "FSED" — permissionless rescue seed. Covers the case the strict floor
    // cannot resolve on its own: someone pre-seeded the deterministic pool at a
    // wrong ratio, so honest seeds revert. FSED re-sends the SAME deposit to the
    // SAME derived pool at the same 0.5% floor (SEED_FORCE_SLACK_BPS = 50). It
    // can only move funds into the 100%-locked pool position, and a rejected
    // deposit refunds to this curve. FSED deploys nothing.
    // AUDIT (H-3, fixed): only allowed once the pool itself has confirmed it is
    // Initialized (InitPoolResult seen) — never into an uninitialised pool.
    // "RSND" (AUDIT 2026-10-24) — resend a migration leg that bounced, with the
    // identical amounts and deposit payload, so DeDust completes the deposit
    // already holding the other leg. Permissionless and caller-funded; only
    // possible after an authenticated bounce of exactly the recorded amount.
    if (op == OP_RESEND_LEG) {
        assert(st.graduated, ERR_NOT_READY);
        assert(st.legBounced != 0, ERR_NOTHING);
        assert(st.pool != st.lockVault, ERR_NOT_READY);
        assert(in.valueCoins >= 700000000, ERR_LOW_GAS);
        val bits = st.legBounced;
        st.legBounced = 0;
        saveCurve(st);
        val selfAddr = contract.getAddress();
        val depositPayload = dedustDepositPayload(st.seedMeme, st.seedQuote, st.seedSlack);
        val payload = dedustPayJetton(depositPayload, dedustPayoutConfig(selfAddr));
        if ((bits & 1) != 0) {
            jettonTransferQ(st.memeWallet, st.seedQid, st.seedMeme, st.pool, selfAddr, 200000000, payload, 250000000);
        }
        if ((bits & 2) != 0) {
            jettonTransferQ(st.quoteWallet, st.seedQid, st.seedQuote, st.pool, selfAddr, 200000000, payload, 250000000);
        }
        return;
    }

    if (op == OP_FORCE_SEED) {
        assert(!st.graduated, ERR_GRADUATED);
        assert(!st.refunding, ERR_NOT_ALLOWED);
        assert(st.initConfirmed, ERR_NOT_READY);
        assert(st.pool != st.lockVault, ERR_NOT_READY);
        assert(st.capReached || st.raised >= st.cap, ERR_NOT_READY);
        assert(st.quoteWallet != contract.getAddress(), ERR_NOT_READY);
        assert(in.valueCoins >= 700000000, ERR_LOW_GAS);
        seedDeDustPool(st, queryId, SEED_FORCE_SLACK_BPS);
        return;
    }





    // "SOPS" — the treasury pins the ops multisig, exactly once. Until this
    // lands, opsMultisig is the curve's own address (sentinel), so FSED, SETL,
    // SWPE and ESCP are all UNREACHABLE — fail-closed.
    if (op == OP_SET_OPS) {
        assert(in.senderAddress == st.treasury, ERR_NOT_ALLOWED);
        assert(st.opsMultisig == contract.getAddress(), ERR_ALREADY_INIT);
        val ops = body.loadAddress();
        assert(ops.getWorkchain() == 0, ERR_NOT_ALLOWED);
        assert(ops != contract.getAddress(), ERR_NOT_ALLOWED);
        assert(ops != st.treasury, ERR_NOT_ALLOWED);   // hot key must not self-pin
        st.opsMultisig = ops;
        saveCurve(st);
        return;
    }

    // "ESCP" — opens pro-rata refunds for a graduation that never completed.
    // AUDIT (H-1, fixed): this used to let the treasury send any amount up to
    // `raised` to any address. It now takes NO parameters, is PERMISSIONLESS
    // after ESCAPE_DELAY at the cap without graduating, and only flips the
    // curve into a terminal `refunding` state (graduation blocked forever).
    // Holders then pull their own share by sending tokens back with a normal
    // SELL: payout = raised * tokens / circulating (sold). Returned tokens stay
    // locked in the curve. Nobody chooses a recipient or an amount.
    if (op == OP_ESCAPE) {
        assert(!st.graduated, ERR_GRADUATED);
        assert(!st.refunding, ERR_ALREADY_INIT);
        assert(st.capReached, ERR_NOT_READY);
        assert(blockchain.now() >= st.capReachedAt + ESCAPE_DELAY, ERR_NOT_READY);
        assert(in.valueCoins >= 50000000, ERR_LOW_GAS);
        st.refunding = true;
        // the stranded LP set-aside and creator share belong to the refund pot
        st.raised += st.lpPool + st.creatorPool;
        st.lpPool = 0;
        st.creatorPool = 0;
        st.buyers = null;
        st.buyerCount = 0;
        saveCurve(st);
        return;
    }

    // Treasury sweeps the accrued 90% holder fee pool (quote jettons). The
    // 10% treasury share already lands per-trade; this releases the rest so
    // the treasury wallet can distribute 90% to holders off-chain. ONLY the
    // treasury may claim. Quote-wallet balance stays >= raised because
    // holderPool is tracked separately from raised.
    if (op == OP_CLAIM) {
        // automated operator key may trigger the claim; funds go TO the
        // treasury multisig regardless — the operator can never redirect them.
        assert(in.senderAddress == st.opsMultisig, ERR_NOT_ALLOWED);
        // AUDIT (medium, fixed): the payout leg below is funded from the curve's
        // OWN balance, so a repeated claim of a 1-unit pool burned 0.06 TON of
        // curve gas each time. The caller must now cover it.
        assert(in.valueCoins >= 80000000, ERR_LOW_GAS);
        val amount = st.holderPool;
        assert(amount > 0, ERR_NOTHING);
        st.holderPool = 0;
        saveCurve(st);
        jettonTransfer(st.quoteWallet, amount, st.holderPayout, st.holderPayout, 0, null, 60000000);
        return;
    }


    // Launch creator sweeps their own accrued share of the 1% trade fee
    // (USDT pairs only — other pairs are configured with creatorFeeBps = 0).
    // ONLY the creator pinned at deploy time may claim, and only their own
    // pool: `raised`, holderPool and lpPool are tracked separately, so this
    // can never touch the curve reserve.
    if (op == OP_CLAIM_CREATOR) {
        // Creator fees unlock only after bonding (accrue until graduation).
        assert(st.graduated, ERR_NOT_ALLOWED);
        assert(!st.takenOver, ERR_NOT_ALLOWED);   // after a CTO nobody claims creator fees
        assert(in.senderAddress == st.creator, ERR_NOT_ALLOWED);
        assert(in.valueCoins >= 80000000, ERR_LOW_GAS);
        val creatorAmount = st.creatorPool;
        assert(creatorAmount > 0, ERR_NOTHING);
        st.creatorPool = 0;
        saveCurve(st);
        jettonTransfer(st.quoteWallet, creatorAmount, st.creator, st.creator, 0, null, 60000000);
        return;
    }

    // "SFTO" — multisig-approved community takeover (Round 30, token pairs).
    // The creator share is turned into the Community split ON-CHAIN, for good:
    //   - unclaimed creatorPool: 12/25 -> lpPool (locked-LP deposits), the rest
    //     -> holderPool (burns via CLAM)
    //   - future fees: creatorFeeBps -> 0, lpFeeBps += 12/25 of it, so every
    //     later split (curve trades and DeDust harvests) is 55 / 22 LP / 23 burns
    // It never pays anyone: no address is read, no wallet receives fee rights.
    // Only the treasury MULTISIG may send it (vetting is off-chain: >= 1% supply
    // burn with tx links, up to 48h review); terminal; Creator-fee launches only.
    // Never touches raised / LP.
    if (op == OP_SET_FEE_TO) {
        assert(in.senderAddress == st.treasury, ERR_NOT_ALLOWED);
        assert(st.treasury != st.opsMultisig, ERR_NOT_ALLOWED);
        assert(st.feeBps == FEE_BPS_DEFAULT, ERR_NOT_ALLOWED);
        assert(st.creatorFeeBps > 0, ERR_NOT_ALLOWED);
        assert(!st.takenOver, ERR_ALREADY_INIT);
        val cpool = st.creatorPool;
        // Round 32 dividend profile: holderPool is 10% burns + 15%
        // dividends. Convert the dividend part too, without touching burns.
        val dividendMode = st.creatorFeeBps == 1000 && st.treasuryFeeBps == 5500 && st.lpFeeBps == 1000;
        val dividends = dividendMode ? st.holderPool * 15 / 25 : 0;
        val toLp = (cpool + dividends) * 12 / 25;
        st.lpPool += toLp;
        st.holderPool += cpool - toLp;
        st.creatorPool = 0;
        st.lpFeeBps += (dividendMode ? 2500 : st.creatorFeeBps) * 12 / 25;
        st.creatorFeeBps = 0;
        st.takenOver = true;
        saveCurve(st);
        return;
    }

    // AUDIT (high): DeDust mints the LP jettons back to the curve, and a jetton
    // transfer with forward_ton_amount = 0 produces NO transfer_notification —
    // the LP would then sit in a curve-owned wallet with no way to move it, i.e.
    // permanently stranded. SWPE lets the treasury (and only the treasury) push
    // any jetton the curve owns to the treasury wallet. It cannot touch the
    // curve's quote reserve or unsold meme before graduation: both are refused
    // while the curve is live.
    // AUDIT (critical): after graduation only the price-matched slice of the
    // 30% meme allocation is seeded into DeDust. The rest stays in the curve's
    // own meme wallet. If
    // the treasury could sweep that wallet it would own that supply and
    // could dump it on the newly-created pool. Therefore SWPE is forbidden from
    // touching the curve's own quote wallet and meme wallet at ANY time. Only
    // stray jettons (DeDust LP, vault excess, airdropped junk) may be rescued.
    // AUDIT (critical, fixed): SWPE is now refused entirely once the curve has
    // graduated. Before this, the DeDust LP wallet was only protected when it
    // had been pinned by an incoming notification — and DeDust mints LP with
    // forward_ton_amount = 0, which produces no notification at all. On that
    // (normal) path lpWallet stayed unset and the treasury could sweep the whole
    // LP position out of the curve, i.e. drain the "locked forever" liquidity.
    // Post-graduation the curve has nothing left that needs rescuing anyway:
    // harvest proceeds are auto-forwarded to the treasury by the notification
    // handler above.
    if (op == OP_SWEEP) {
        // AUDIT (high, fixed — external review H-5): multisig, not the hot key.
        assert(in.senderAddress == st.opsMultisig, ERR_NOT_ALLOWED);
        assert(in.valueCoins >= 80000000, ERR_LOW_GAS);
        assert(!st.graduated, ERR_GRADUATED);
        // A refunded pool deposit rewinds `graduated` so the seed can be
        // retried; the raise is sitting on the quote wallet during that window.
        // `capReached` is sticky, so this keeps SWPE closed from the moment the
        // curve fills until the end of time, retries included.
        assert(!st.capReached, ERR_GRADUATED);

        val sweepWallet = body.loadAddress();
        val sweepAmount = body.loadCoins();
        assert(sweepAmount > 0, ERR_NOTHING);
        assert(sweepWallet != st.quoteWallet, ERR_NOT_ALLOWED);
        assert(sweepWallet != st.memeWallet, ERR_NOT_ALLOWED);
        // LOCKED LIQUIDITY: the pinned DeDust LP wallet is off-limits, so the
        // treasury can never move, sell or rescue the LP position itself.
        assert(sweepWallet != st.lpWallet, ERR_NOT_ALLOWED);
        jettonTransfer(sweepWallet, sweepAmount, st.treasury, st.treasury, 0, null, 60000000);
        return;
    }


    // HRVS — pull the accrued DeDust trading fees while the liquidity itself
    // stays locked forever.
    //
    // The liquidity is minted with lockedLiquidityShare = 10000, so there is no
    // LP position to redeem — the previous burn-a-slice-of-LP harvest could
    // never fire and the fees were unreachable. CPMM v2 instead accrues the
    // creatorFeeBPS part of every swap in the pool's creatorFeeX/creatorFeeY
    // counters, claimable only by the pool's creatorAddress, which is this
    // curve. ClaimCreatorFees pays the whole accrued balance in BOTH assets
    // straight to the treasury; the locked reserves are untouched.
    //
    // Guards: treasury-only, graduated, pool known, one claim per hour.
    // HRVS — collect the pool's trading fees back INTO this curve (external
    // H-2). The curve share (80% of the pool fee; DeDust keeps 20%) accrues to
    // the curve's 100%-locked position. Withdraw with liquidity 0 + autoClaimFees
    // pays ONLY those fees, to this curve, tagged HRVP (split on arrival, see
    // the transfer-notification handler). DeDust refuses any non-zero withdrawal
    // of locked liquidity (exit 36). Operator-triggered, caller-funded, hourly.
    if (op == OP_HARVEST) {
        assert(in.senderAddress == st.opsMultisig, ERR_NOT_ALLOWED);
        assert(st.graduated, ERR_NOT_READY);
        assert(st.pool != st.lockVault, ERR_NOT_READY);
        assert(blockchain.now() >= st.lpUnlockAt + HARVEST_INTERVAL, ERR_NOT_ALLOWED);
        // self-funded when the caller attaches less than the full gas
        val selfPay = in.valueCoins < HARVEST_GAS;
        if (selfPay) {
            assert(blockchain.now() >= st.lpUnlockAt + SELF_GAS_INTERVAL, ERR_NOT_ALLOWED);
            assert(contract.getOriginalBalance() >= HARVEST_GAS + GAS_RESERVE_FLOOR, ERR_LOW_GAS);
        }
        st.lpUnlockAt = blockchain.now();
        saveCurve(st);
        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(st.pool)
            .storeCoins(300000000 + HARVEST_EXTRA_GAS)
            .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeRef(beginCell()
                .storeUint(OP_DEDUST_WITHDRAW, 32)
                .storeUint(queryId, 64)
                .storeCoins(0)
                .storeCoins(0).storeCoins(0)
                .storeBool(true)
                .storeRef(beginCell()
                    .storeAddress(contract.getAddress())
                    .storeCoins(HARVEST_EXTRA_GAS)
                    .storeMaybeRef(beginCell().storeUint(OP_HARVEST_PAYOUT, 32).endCell())
                    .storeBool(false)
                    .storeAddress(selfPay ? contract.getAddress() : st.opsMultisig) // excess gas back to whoever paid
                    .endCell())
                .endCell())
            .endCell(), 1);
        return;
    }

    // LPRL — deposit the accrued post-migration LP share (lpPool) into the
    // locked pool: swap half into tokens with this curve as recipient, deposit
    // both (LPDP). A rejected swap returns its quote to lpPool (LPRF).
    if (op == OP_LP_RELAY) {
        assert(in.senderAddress == st.opsMultisig, ERR_NOT_ALLOWED);
        assert(st.graduated && st.pool != st.lockVault, ERR_NOT_READY);
        val selfPay = in.valueCoins < LP_RELAY_GAS;
        if (selfPay) {
            assert(blockchain.now() >= st.lpRelayAt + SELF_GAS_INTERVAL, ERR_NOT_ALLOWED);
            assert(contract.getOriginalBalance() >= LP_RELAY_GAS + GAS_RESERVE_FLOOR, ERR_LOW_GAS);
        }
        st.lpRelayAt = blockchain.now();
        val minOut = body.loadCoins();
        val total = st.lpPool;
        assert(total + st.lpRelayQuote >= 2, ERR_NOTHING);
        st.lpPool = 0;
        lpRelaySwap(mutate st, total, minOut, selfPay);
        return;
    }


    // Jetton wallets return unused forward gas as `excesses`. Throwing on it
    // (exit 65535) made every DeDust deposit/refund leg show up as a failed
    // transaction in explorers. Just keep the TON and return.
    if (op == OP_EXCESSES) {
        return;
    }

    // ROUND 31: DeDust's position contract confirms minted liquidity. The first
    // confirmation after a seed makes the migration final (refunds can no longer
    // rewind it) and burns the leftover tokens. The sender must be the position
    // derived on-chain from the curve's own pool; anything else is ignored.
    if (op == OP_POSITION_NOTIFY) {
        if (st.graduated && !st.seeded && st.pool != st.lockVault) {
            val (pwc, ph) = in.senderAddress.getWorkchainAndHash();
            if (pwc == 0 && ph == dedustPositionHashFor(st.pool)) {
                // authenticated low-value reply: the curve pays its own gas
                setGasLimit(150000);
                st.seeded = true;
                burnLeftover(mutate st);
                saveCurve(st);
            }
        }
        return;
    }

    // "BRNL" — anyone re-sends the leftover burn if it ever bounced (caller-funded).
    if (op == OP_BURN_LEFTOVER) {
        assert(st.seeded && !st.leftoverBurned, ERR_NOTHING);
        assert(in.valueCoins >= 100000000, ERR_LOW_GAS);
        burnLeftover(mutate st);
        saveCurve(st);
        return;
    }



    // AUDIT (medium, fixed): unknown ops used to throw unconditionally. The
    // DeDust pool also sends the curve informational messages (deposit result,
    // excesses variants) after the seed; throwing on those marks the migration
    // transaction chain as failed and bounces TON back and forth. Messages from
    // the pool the curve itself derived are accepted silently; everything else
    // still bounces.
    if (in.senderAddress == st.pool && st.pool != contract.getAddress()) {
        return;
    }

    assert(false, 0xffff);

}

// Read by src/lib/ton-api.functions.ts (getLaunch)
get fun get_curve_data(): (coins, coins, coins, bool, address, address, address) {
    val st = loadCurve();
    return (st.raised, st.cap, st.sold, st.graduated, st.quoteMaster, st.memeMaster, st.creator);
}

// Pinned operator hot key (see opsMultisig, audit L-1). Returns the curve's own
// address while unpinned — the keeper pins it once via SOPS.
get fun get_holder_payout(): address {
    return loadCurve().holderPayout;
}

get fun get_ops_multisig(): address {
    return loadCurve().opsMultisig;
}

// Read by src/lib/ton-api.functions.ts (getGraduation)
get fun get_graduation_data(): (bool, address, coins, int, address) {
    val st = loadCurve();
    return (st.graduated, st.pool, st.lpLocked, st.lpUnlockAt, st.treasury);
}

// Pinned DeDust vaults. meme vault == this contract means "not pinned yet",
// in which case graduation is blocked until the treasury sends SETV.
get fun get_vaults(): (address, address, bool) {
    val st = loadCurve();
    return (st.quoteVault, st.memeVault, st.prepared);
}

// Read by src/lib/ton-api.functions.ts (getHolderPool)
get fun get_holder_pool(): coins {
    return loadCurve().holderPool;
}

// accrued trading fees that will be reinvested into the LP at graduation
get fun get_creator_pool(): coins {
    return loadCurve().creatorPool;
}

// Round 30+: current owner of the creator fee share — the creator, or after a
// CTO the curve's pinned payout wallet (same meaning as on GRAM curves; on this
// curve the share is split on-chain into LP + burns and never paid to it).
get fun get_fee_to(): address {
    val st = loadCurve();
    return st.takenOver ? st.holderPayout : st.creator;
}

// Round 30+: self-funded gas state — spendable reserve above the floor, and the
// earliest unix time a self-funded HRVS / LPRL is accepted.
get fun get_self_gas(): (int, int, int) {
    val st = loadCurve();
    val spare = contract.getOriginalBalance() - GAS_RESERVE_FLOOR;
    return (spare > 0 ? spare : 0, st.lpUnlockAt + SELF_GAS_INTERVAL, st.lpRelayAt + SELF_GAS_INTERVAL);
}

// Round 30+: the quote half kept for an in-flight / refused LP swap.
get fun get_lp_relay_held(): coins {
    return loadCurve().lpRelayQuote;
}

// LP share waiting to be deposited: lpPool + a kept half left by a refused swap.
get fun get_lp_pool(): coins {
    val st = loadCurve();
    return st.lpPool + st.lpRelayQuote;
}

// net quote a seller receives: fee is skimmed from the QUOTE output
get fun get_quote_out(memeIn: coins): coins {
    val st = loadCurve();
    val gross = ammOutNoFee(memeIn, st.virtMeme - st.sold, st.virtQuote + st.raised);
    return gross - gross * st.feeBps / 10000;
}

get fun get_meme_out(quoteIn: coins): coins {
    val st = loadCurve();
    return ammOut(quoteIn, st.virtQuote + st.raised, st.virtMeme - st.sold, st.feeBps);
}

// trade fee in bps (always 100 = 1%)
get fun get_fee_bps(): int {
    return loadCurve().feeBps;
}

// AUDIT 2026-10-24: last seed attempt (quote leg, meme leg) and which leg
// bounced (bit 1 meme, bit 2 quote) — lets ops and anyone see when RSND applies.
// ROUND 31: 4th value = the query id that attempt's legs carry.
get fun get_seed_state(): (coins, coins, int, int) {
    val st = loadCurve();
    return (st.seedQuote, st.seedMeme, st.legBounced, st.seedQid);
}

// AUDIT 2026-10-25 (external H-1): the launch's fee configuration as stored
// on-chain — indexers derive the fee mode from this, never from a log.
get fun get_fee_config(): (int, int, int, int) {
    val st = loadCurve();
    return (st.creatorFeeBps, st.treasuryFeeBps, st.lpFeeBps, st.feeBps);
}

// ROUND 31: migration final (DeDust confirmed the seed), leftover tokens burned,
// and whether an LP relay is in flight.
get fun get_round31_state(): (bool, bool, bool) {
    val st = loadCurve();
    return (st.seeded, st.leftoverBurned, st.lpRelayQid != 0);
}
