import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "@stdlib/exotic-cells"
// BondingCurveNative.tolk — GRAM-paired variant (Round 28+)
//
// Fork of BondingCurve.tolk where the quote asset is the native coin (GRAM)
// instead of a jetton. Differences, each marked NATIVE below:
//   * buy#42555921 query_id:uint64 min_out:Coins is sent to the curve as a
//     plain internal message; the attached value minus NATIVE_BUY_GAS is the
//     trade input. Rejections return the full inbound value (mode 64).
//   * sells, refunds, fee legs, CLAM and CLMC pay GRAM directly.
//   * the raise lives in the contract's own balance, so every gas-floor check
//     uses freeBalance() = balance - raised - holderPool - lpPool - creatorPool
//     and a buyer's gas can never be counted as raise money (or vice versa).
//   * graduation pays the quote leg with DeDust CPMM v2 PayNative#a5a7cbf8;
//     the pool is (assetX = native, assetY = meme).
//   * there is no quote wallet and no TEP-89 lookup: quoteWallet is pinned to
//     the master address at CINT purely as a "ready" marker and is never paid.
//
// Original header:
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
const OP_CLAIM_CREATOR = 0x434c4d43;      // "CLMC" fee owner claims the accrued creator fee share
const OP_SET_FEE_TO = 0x5346544f;         // "SFTO" multisig-approved community takeover: creator fees -> burns + LP, for good
const OP_LP_DEPOSIT = 0x4c504450;         // "LPDP" fulfil payload of a pool swap paid to this curve: deposit it as locked LP
const LP_DEPOSIT_GAS = 600000000;         // 0.6 GRAM of the forwarded value pays both deposit legs
const LP_DEPOSIT_MIN = 100000000;         // never relay a deposit of less than 0.1 GRAM
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
// AUDIT 2026-10-25: fees are collected in the QUOTE asset only (GRAM = asset X),
// so every harvest is GRAM — treasury, creator, burns and LP all paid in quote.
const DEDUST_FEE_IN_QUOTE = 1;                // FeeIn.AssetX
// AUDIT 2026-10-25: DeDust keeps 20% of every pool fee (fixed). creatorFeeBPS
// would route part of the other 80% to the pool creator, but that payout is
// untagged and cannot be booked on-chain, so it is 0 here.
const DEDUST_CREATOR_FEE_BPS = 0;
// AUDIT 2026-10-25 (external H-2): creatorFeeBPS is now 0, so the whole 80%
// accrues to the curve's locked position, and HRVS claims it back to THIS curve
// (Withdraw 0 + autoClaimFees, payout tagged HRVP). The curve splits it ON-CHAIN
// with the launch's own fee bps: treasury share straight to the multisig,
// creator share into creatorPool (CLMC), LP share into lpPool (deposited by
// LPRL), the rest into holderPool (CLAM). No post-migration fee sits as an
// off-chain IOU in a hot wallet any more.
const OP_DEDUST_SWAP_V2 = 0xc442500f;   // CPMM v2 SwapPayload
const OP_HARVEST_PAYOUT = 0x48525650;   // "HRVP" tag on the position-fee payout
const OP_DEDUST_PAYOUT = 0x3216ca09;    // DeDust native payout
const OP_LP_RELAY = 0x4c50524c;         // "LPRL" operator deposits lpPool into the locked pool
// LP refunds (user 2026-10-25): a refused LP swap comes back from the pool tagged
// LPRF and is booked into lpPool again.
const OP_LP_REFUND = 0x4c505246;        // "LPRF"
const LP_REFUND_FWD = 50000000;         // 0.05 GRAM forwarded with every LP refund payout
// SELF-FUNDED GAS (user 2026-10-25): the curve pays its own HRVS / LPRL gas out
// of its gas reserve (unused trade gas), so the automated key only sends pocket
// change. Bounded so a stolen key cannot drain it: at most once per
// SELF_GAS_INTERVAL per job, never below GAS_RESERVE_FLOOR, excess gas comes
// back to the curve, and the work itself only ever moves money along its
// hard-wired paths. A caller that attaches the full gas pays as before.
const SELF_GAS_INTERVAL = 9000;           // 2.5 h between self-funded runs of each job
const GAS_RESERVE_FLOOR = 500000000;      // 0.5 GRAM the curve always keeps
const HARVEST_GAS = 500000000;            // gas an HRVS needs (caller- or self-funded)
const OP_LP_ADD = 0x4c504144;           // "LPAD" add GRAM to this curve's LP share (deposited by the next LPRL)
const LP_ADD_GAS = 30000000;            // 0.03 GRAM on top of the added amount
const HARVEST_EXTRA_GAS = 150000000;    // 0.15 GRAM rides with the payout to fund the split
// AUDIT 2026-10-25 (external M-1): a seed refund only rewinds graduation within
// this window after the seed attempt; later "refunds" can never undo a migration.
const SEED_REFUND_WINDOW = 3600;
const OP_DEDUST_WITHDRAW = 0x20b5ef89;        // Withdraw: liquidity 0 + autoClaimFees claims position fees
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

// ROUND 31 (user go-ahead 2026-11-01)
// DeDust's position contract (this curve's locked LP position) tells its owner
// when a deposit has minted liquidity. Its address is derived on-chain from the
// pool (split_depth 8 StateInit, library code below), so the confirmation can't
// be forged. The first one after a seed makes the migration final.
const OP_POSITION_NOTIFY = 0x63554160;
const DEDUST_POSITION_LIBRARY_HASH = 0xdd82f24db614798ee7c579f8b3f07f0645d06d65cede368d80d0d74b180d2dd6;
const OP_BURN_LEFTOVER = 0x42524e4c;      // "BRNL" anyone retries the leftover-token burn (caller-funded)
// Refund reasons for integrators: every returned or partly returned trade
// carries refund_reason#52464e44 query_id:uint64 reason:uint8 as the GRAM
// message body / jetton forward payload (and as an external log). query_id =
// the trader's own query id of the message that reached the curve.
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
// wallet's hash; curve-internal legs set the top bit.
const QID_TAG = 0x8000000000000000;
const QID_SEED_TAG = 0x4000000000000000;  // seed attempts: QID_TAG | QID_SEED_TAG | lt
const QID_LP = 0x80000000004c5052;        // LP relay legs
const QID_BURN = 0x8000000042524e4c;      // leftover burn
const LEG_KEY_MASK = 0x7fffffffffffffff;
const LEFTOVER_BURN_GAS = 50000000;       // 0.05 GRAM for the burn + its notification

// AUDIT (high, fixed — external review H-5): the hot treasury key used to be
// able to redirect creator fees (SFTO), force-seed a skewed pool (FSED), pin
// the LP wallet (SETL) and sweep curve jettons (SWPE). Those four powers now
// belong to the ops MULTISIG, pinned once by the treasury via SOPS. The hot
// key keeps only what pays INTO the treasury (CLAM, HRVS), so a leaked hot
// key can no longer move user funds or fee rights anywhere but the treasury.
// Per the owner's decision there is no timelock: the multisig acts directly.

// AUDIT (high, fixed — external review H-1): if a sniper pre-seeds the
// deterministic pool and keeps it skewed, every honest seed reverts and the
// raise would sit in the curve forever. After ESCAPE_DELAY at the cap without
// a confirmed seed, the multisig may refund buyers pro-rata out of `raised`
// (ESCP). It can only pay OUT of the raise to named buyers — never to itself
// beyond what each buyer put in, which the off-chain ledger proves.
const ESCAPE_DELAY = 604800;              // 7 days stuck at cap before refunds open

// AUDIT (high, fixed — external review H-3): the lifetime buyer ledger grows
// with every unique buyer and would eventually cross TON's account-state
// limit, bricking the curve mid-sale. After MAX_BUYERS_TRACKED entries the
// curve stops recording new buyers and simply skips the per-wallet cap for
// them — trading continues, state never grows again.
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


// NATIVE: gas kept from every buy (meme leg + treasury leg + compute). What is
// not spent stays in freeBalance() and funds graduation.
const NATIVE_BUY_GAS = 120000000;
const NATIVE_PAY_GAS = 300000000;          // DeDust PayNative processing
const OP_DEDUST_PAY_NATIVE = 0xa5a7cbf8;
const NATIVE_GRAD_FLOOR = 1200000000;

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
    lpRelayHeld: coins;  // GRAM half kept by the curve while an LPRL swap is in flight (or after a refused one)
    lpRelayAt: int;      // unix ts of the last LPRL (self-funded rate limit)
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
    feeTo: address;      // owner + recipient of the creator fee share (SFTO: forwarding / CTO)
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
    seedAt: int;         // AUDIT 2026-10-25: unix time of the last seed attempt (refund window)
    liveAt: int;         // unix ts trading opened (mint landed); creator-only buys for CREATOR_ONLY_SECS
    seedQid: int;        // ROUND 31: query id of the last seed attempt's legs (bounce matching)
    lpRelayQid: int;     // ROUND 31: secret nonce of the in-flight LPRL swap (0 = none)
    leftoverBurned: bool; // ROUND 31: leftover tokens burned once DeDust confirmed the seed
    opsMultisig: address; // AUDIT 2026-10-25 (L-1): despite the name, the AUTOMATED operator hot key (pinned at launch); it may run SETL, SWPE (pre-cap), CLAM, HRVS, LPRL and trigger CLMC — every payout is hard-wired, so it can never redirect funds. SFTO is treasury-multisig only; FSED and ESCP are permissionless.
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
            lpRelayHeld: 0,
            lpRelayAt: 0,
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
            feeTo: creator,
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
    val lpRelayHeldV = b.loadCoins();
    val lpRelayAtV = b.loadUint(32);
    var c = b.loadRef().beginParse();
    // refs of `c`, in stored order: 0 = metadata, 1 = pinned DeDust vaults.
    // Popped up front so the bit fields below can stay inline.
    val metadataRef = c.loadRef();
    var vaults = c.loadRef().beginParse();
    // Ref order inside the vaults cell: 0 = buyers dict, 1 = feeTo + the
    // Round 29 security fields. Dict must be popped before the feeTo ref.
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
    var fe = vaults.loadRef().beginParse();
    var r31 = fe.loadRef().beginParse();   // ROUND 31 fields (the only ref of `fe`)
    val feeToAddr = fe.loadAddress();
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
        lpRelayHeld: lpRelayHeldV,
        lpRelayAt: lpRelayAtV,
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
        feeTo: feeToAddr,
        minted: fe.loadUint(1) != 0,
        seeded: fe.loadUint(1) != 0,
        capReachedAt: fe.loadUint(32),
        buyerCount: fe.loadUint(16),
        opsMultisig: fe.loadAddress(),
        holderPayout: fe.loadAddress(),
        initConfirmed: fe.loadUint(1) != 0,
        refunding: fe.loadUint(1) != 0,
        quoteBack: fe.loadUint(1) != 0,
        memeBack: fe.loadUint(1) != 0,
        seedMeme: fe.loadCoins(),
        legBounced: fe.loadUint(2),
        seedSlack: fe.loadUint(16),
        seedAt: fe.loadUint(32),
        liveAt: fe.loadUint(32),
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
                .storeAddress(st.feeTo)
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
        .storeCoins(st.lpRelayHeld)
        .storeUint(st.lpRelayAt, 32)
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
// NATIVE: TON that is NOT owed to the curve's books (raise + fee pools).
fun freeBalance(st: Curve): int {
    return contract.getOriginalBalance() - st.raised - st.holderPool - st.lpPool - st.creatorPool - st.lpRelayHeld;
}

// GRAM pairs launch with chain fees only (no prepaid migration reserve). When
// the cap is hit and the curve lacks migration gas, the shortfall is carved
// out of the fixed migration fee: `raised` and `migrationFee` drop together,
// so the LP seed (raised - migFee + lpPool) is unchanged and only the
// treasury's fee shrinks. Bounded by the fee itself — never touches the raise.
fun fundGradGasFromFee(mutate st: Curve, pending: int) {
    val free = freeBalance(st) - pending;
    if (free >= NATIVE_GRAD_FLOOR || st.migrationFee <= 0) { return; }
    var take = NATIVE_GRAD_FLOOR - free;
    if (take > st.migrationFee) { take = st.migrationFee; }
    if (take > st.raised) { take = st.raised; }
    st.migrationFee -= take;
    st.raised -= take;
    saveCurve(st);
}

// NATIVE: plain GRAM payout, non-bounceable (payees may be uninitialised
// wallets), fees paid from the curve's free balance.
fun quoteSend(to: address, amount: coins) {
    if (amount <= 0) { return; }
    sendRawMessage(beginCell()
        .storeUint(0x10, 6)
        .storeAddress(to)
        .storeCoins(amount)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .endCell(), 1);
}

// NATIVE: return the whole inbound value (reject path, funded by the sender).
// ROUND 31: `why` (a refund_reason cell) is the message body when given.
fun refundCarry(to: address, why: cell?) {
    var m = beginCell()
        .storeUint(0x10, 6)
        .storeAddress(to)
        .storeCoins(0)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1);
    if (why != null) {
        m = m.storeUint(1, 1).storeRef(why!);
    } else {
        m = m.storeUint(0, 1);
    }
    sendRawMessage(m.endCell(), 64 + 2);
}

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
    val quoteWallet = st.master;   // NATIVE: "ready" marker only, never paid

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
        .storeUint(0, 2)                      // assetX = native GRAM (addr_none)
        .storeAddress(st.memeMaster)          // assetY = meme
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
        .storeCoins(lpQuote as coins)         // amountX == native GRAM
        .storeCoins(lpMeme as coins)          // amountY == meme
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
    quoteSend(st.treasury, migFee as coins);
    // Both legs go straight to the pool; it credits the deposit once both have
    // arrived and mints 100%-locked liquidity. Unused TON on each leg returns
    // to the curve (not the treasury) so a retry is still funded.
    val selfAddr = contract.getAddress();
    jettonTransferQ(st.memeWallet, st.seedQid, lpMeme as coins, poolAddr, selfAddr, 200000000, payload, 250000000);
    // NATIVE: PayNative#a5a7cbf8 query_id amount ^DepositPayload ^PayoutConfig
    sendRawMessage(beginCell()
        .storeUint(0x18, 6)
        .storeAddress(poolAddr)
        .storeCoins((lpQuote + NATIVE_PAY_GAS) as coins)
        .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeRef(beginCell()
            .storeUint(OP_DEDUST_PAY_NATIVE, 32)
            .storeUint(st.seedQid, 64)
            .storeCoins(lpQuote as coins)
            .storeRef(depositPayload)
            .storeRef(dedustPayoutConfig(selfAddr))
            .endCell())
        .endCell(), 1);
}

// LPDP relay: deposit exactly the tokens + GRAM that one relayed swap brought
// in, as 100%-locked liquidity owned by this curve. Funded only by the
// incoming message (gram + LP_DEPOSIT_GAS); no curve-owned asset is touched.
// No minimal-liquidity floor: the depositor's own funds are at stake, never
// the curve's. Rejections/excesses return to the curve as gas.
fun relayLpDeposit(st: Curve, memeAmt: coins, gram: coins) {
    val selfAddr = contract.getAddress();
    val depositPayload = dedustDepositPayload(memeAmt, gram, 10000);
    jettonTransferQ(st.memeWallet, QID_LP, memeAmt, st.pool, selfAddr, 200000000,
        dedustPayJetton(depositPayload, dedustPayoutConfig(selfAddr)), 250000000);
    sendRawMessage(beginCell()
        .storeUint(0x18, 6)
        .storeAddress(st.pool)
        .storeCoins((gram + NATIVE_PAY_GAS) as coins)
        .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeRef(beginCell()
            .storeUint(OP_DEDUST_PAY_NATIVE, 32)
            .storeUint(QID_LP, 64)
            .storeCoins(gram)
            .storeRef(depositPayload)
            .storeRef(dedustPayoutConfig(selfAddr))
            .endCell())
        .endCell(), 1);
}



fun relayNonce(): int {
    random.initialize();
    return QID_TAG | (random.uint256() >> 193);
}

// ROUND 31: payments to a wallet carry that wallet's key as their query id, so
// a bounced payment is booked back to the right payee (see onBouncedMessage).
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


// NATIVE: GRAM payout with a body (refund reason), non-bounceable.
fun quoteSendWith(to: address, amount: coins, why: cell) {
    if (amount <= 0) { return; }
    sendRawMessage(beginCell()
        .storeUint(0x10, 6)
        .storeAddress(to)
        .storeCoins(amount)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1)
        .storeUint(1, 1)
        .storeRef(why)
        .endCell(), 1);
}

// NATIVE: return a rejected GRAM buy in full, its body = the refund reason.
fun rejectNative(to: address, queryId: int, reason: int, value: int) {
    val why = refundReason(queryId, reason);
    if (value >= MIN_TRADE_GRAM) { emitLog(why); }
    refundCarry(to, why);
}

/// Real bounces are routed here by the runtime (unforgeable).
/// ROUND 31 (audit 2026-10-26): curve-internal legs are booked back. GRAM
/// payouts are non-bounceable; what can bounce:
///   - token legs at the curve's own meme wallet: seed leg (matched by the
///     attempt's own query id -> RSND) and the leftover burn (re-armed for BRNL)
///   - PayNative at the pool: seed leg (RSND) or an LP relay leg (-> lpPool)
/// Tokens of a bounced payment to any other wallet simply stay on the curve
/// (owner decision 2026-11-01: no claim-back).
fun onBouncedMessage(in: InMessageBounced) {
    var st = loadCurve();
    var b = in.bouncedBody;
    b.skipBouncedPrefix();
    if (b.remainingBitsCount() < 32 + 64) { return; }
    val op = b.loadUint(32);
    val qid = b.loadUint(64);
    if (st.memeMaster != contract.getAddress() && in.senderAddress == st.memeWallet) {
        if (op == OP_JETTON_BURN) {
            if (qid == QID_BURN && st.leftoverBurned) {
                st.leftoverBurned = false;
                saveCurve(st);
            }
            return;
        }
        if (op != OP_JETTON_TRANSFER) { return; }
        if (st.seedQid != 0 && qid == st.seedQid && st.graduated) {
            st.legBounced = st.legBounced | 1;
            saveCurve(st);
        }
        return;
    }
    if (st.pool != st.lockVault && in.senderAddress == st.pool && op == OP_DEDUST_PAY_NATIVE) {
        if (b.remainingBitsCount() < 4) { return; }
        val qlen = b.preloadUint(4);
        if (b.remainingBitsCount() < 4 + qlen * 8) { return; }
        val amount = b.loadCoins();
        if (amount <= 0) { return; }
        if (st.seedQid != 0 && qid == st.seedQid) {
            if (st.graduated) {
                st.legBounced = st.legBounced | 2;
                saveCurve(st);
            }
        } else if (qid == QID_LP) {
            st.lpPool += amount;
            saveCurve(st);
        }
        return;
    }
}



fun onInternalMessage(in: InMessage) {
    var body = in.body;
    // NATIVE: a rejected PayNative deposit comes back from the pool as GRAM.
    // AUDIT (H-2 / M-1, fixed): a seed counts as REJECTED only when BOTH legs
    // come back — this GRAM leg at >= 99% of what was sent, and the meme leg
    // at >= 99% of seedMeme (transfer-notification branch below), in any
    // order. Smaller pool payments are just kept as gas and can never rewind.
    {
        var pre = loadCurve();
        if (pre.graduated && pre.pool != pre.lockVault && in.senderAddress == pre.pool
            && !pre.seeded
            && pre.seedQuote > 0 && !pre.quoteBack
            && in.valueCoins * 100 >= pre.seedQuote * 99) {
            pre.quoteBack = true;
            pre.seedQuote = in.valueCoins > pre.seedQuote ? pre.seedQuote : in.valueCoins;
            if (pre.memeBack) {
                pre.raised += pre.seedQuote;
                pre.graduated = false;
                pre.prepared = false;
                pre.quoteBack = false;
                pre.memeBack = false;
                pre.seedQuote = 0;
                pre.seedMeme = 0;
                pre.legBounced = 0;
            }
            saveCurve(pre);
            return;
        }
    }
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
        // into the master, which ignores bounces, stranding the launcher's gas.
        // The re-sender is always this curve's creator (the address commits to
        // it), so the attached value goes straight back to them.
        if (st.cap != 0) {
            refundCarry(st.creator, null);
            return;
        }
        initFromMaster(st, in.senderAddress, body);
        return;
    }

    // TEP-89 reply from the quote jetton master: learn our quote wallet.
    // Accepted only once, while the wallet is still unknown, so a later reply
    // can never re-point the curve's quote wallet at another contract.
    // NATIVE BUY: buy#42555921 query_id:uint64 min_out:Coins, value = input + gas.
    if (op == OP_BUY) {
        val from = in.senderAddress;
        val minOut = body.loadCoins();
        // ROUND 31: every returned or partly returned buy carries a refund
        // reason as the GRAM message body (and an external log); `queryId` is
        // the buyer's own query id of this buy message.
        // AUDIT (low, fixed): non-basechain buyers could pay but never receive
        // tokens (the meme transfer bounced and was ignored). Refund them.
        if (from.getWorkchain() != 0) {
            rejectNative(from, queryId, REASON_WORKCHAIN, in.valueCoins);
            return;
        }
        if (in.valueCoins <= NATIVE_BUY_GAS + MIN_TRADE_GRAM / 10) {
            rejectNative(from, queryId, REASON_LOW_GAS, in.valueCoins);
            return;
        }
        if (st.cap == 0 || st.memeMaster == contract.getAddress()) {
            rejectNative(from, queryId, REASON_NOT_LIVE, in.valueCoins);
            return;
        }
        val amount = (in.valueCoins - NATIVE_BUY_GAS) as coins;
        if (st.graduated || st.capReached || st.raised >= st.cap) {
            rejectNative(from, queryId, REASON_CLOSED, in.valueCoins);
            return;
        }
        // AUDIT (high, fixed — external review H-1): if the minter deploy or
        // the full-supply mint failed, buys would debit `raised` for tokens
        // the buyer never receives. Refund-only until the mint lands.
        if (!st.minted) {
            rejectNative(from, queryId, REASON_NOT_LIVE, in.valueCoins);
            return;
        }
        // Creator-first window: only the creator may buy right after launch,
        // so the dev buy is always first. Everyone else gets a full refund.
        if (from != st.creator && blockchain.now() < st.liveAt + CREATOR_ONLY_SECS) {
            rejectNative(from, queryId, REASON_CREATOR_WINDOW, in.valueCoins);
            return;
        }
        val room = st.cap - st.raised;
        val maxGross = (room * 10000 / (10000 - st.feeBps) + 1) as coins;
        var accepted = amount < maxGross ? amount : maxGross;
        var fee = accepted * st.feeBps / 10000;
        var swapAmount = accepted - fee;
        if (swapAmount > room) {
            swapAmount = room;
            accepted = swapAmount + fee;
        }
        // User decision 2026-10-25: the creator is exempt from the 2% per-wallet
        // limit on their own launch, on every fee profile.
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
                rejectNative(from, queryId, REASON_WALLET_LIMIT, in.valueCoins);
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
        val memeLeft = MEME_CURVE_SUPPLY - st.sold;
        if (out > memeLeft) { out = memeLeft; }
        if (out < minOut || out <= 0) {
            // a wallet whose last allowance rounds to nothing is at its limit
            rejectNative(from, queryId, (out <= 0 && whaleClamped) ? REASON_WALLET_LIMIT : REASON_SLIPPAGE, in.valueCoins);
            return;
        }
        st.raised += swapAmount;
        st.sold += out;
        // AUDIT (high, fixed — external review H-3): the buyer ledger stops
        // growing at MAX_BUYERS_TRACKED entries so account state can never
        // cross TON's size limit and brick the curve. New wallets beyond the
        // cap simply skip the per-wallet purchase limit and keep trading.
        if (boughtFound || st.buyerCount < MAX_BUYERS_TRACKED) {
            st.buyers.uDictSet(BUYER_KEY_LEN, buyerKey,
                beginCell().storeCoins((bought + out) as coins).endCell().beginParse());
            if (!boughtFound) { st.buyerCount += 1; }
        }
        if (st.raised >= st.cap && !st.capReached) {
            st.capReached = true;
            st.capReachedAt = blockchain.now();   // ESCP refund clock starts here
        }
        val lpFee = fee * st.lpFeeBps / 10000;
        st.lpPool += lpFee;
        st.creatorPool += creatorFee;
        st.holderPool += fee - treasuryFee - creatorFee - lpFee;
        saveCurve(st);
        quoteSend(st.treasury, treasuryFee as coins);
        jettonTransfer(st.memeWallet, out, from, from, 1000000, null, TRADE_LEG_GRAM);
        if (refund > 0) {
            val why = refundReason(queryId, whaleClamped ? REASON_WALLET_LIMIT_PARTIAL : REASON_CAP_PARTIAL);
            emitLog(why);
            quoteSendWith(from, refund as coins, why);
        }
        // AUDIT 2026-10-24: the original balance still holds every value this
        // buy just queued (treasury fee, token-transfer leg, refund), so all of
        // it counts as pending — not only the refund.
        val pending = treasuryFee + TRADE_LEG_GRAM + refund;
        if (st.capReached && !st.prepared) { fundGradGasFromFee(mutate st, pending); }
        if (st.capReached && !st.prepared && freeBalance(st) - pending >= NATIVE_GRAD_FLOOR) {
            graduateToDeDust(st, 0);
        }
        return;
    }

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
        // AUDIT (H-2, fixed): the meme leg of a rejected seed. Together with
        // the GRAM leg (top-level handler) it rewinds the migration, in either
        // order. Any other meme from the pool simply stays locked here.
        if (st.graduated && from == st.pool && amount > 0) {
            // LP DEPOSIT RELAY (2026-10-24, CTO burns + LP): the pool's own
            // deposit lock only accepts deposits initiated by this curve, so
            // post-migration LP deposits are relayed here. The payout wallet
            // swaps half of an LP share into tokens with this curve as the
            // recipient; the fulfil payload is LPDP and the other half of the
            // GRAM rides along as forward value. The curve deposits EXACTLY
            // what arrived in this message — tokens `amount` and the forwarded
            // GRAM minus LP_DEPOSIT_GAS — as 100%-locked liquidity. It never
            // spends its own tokens or GRAM, so anyone may trigger it: the
            // worst case is a donation to the locked pool. Checked BEFORE the
            // refund detection, so a relayed swap can never mark a seed leg
            // as refunded.
            if (in.senderAddress == st.memeWallet && st.pool != st.lockVault) {
                var ps = body;
                val pref = ps.loadMaybeRef();
                var pp = pref == null ? ps : pref!.beginParse();
                if (pp.remainingBitsCount() >= 32) {
                    val pop = pp.loadUint(32);
                    // GRAM to deposit = what rode along with this message (payout-
                    // wallet relays) + the half this curve kept for its own LPRL.
                    var ride: int = 0;
                    if (in.valueCoins > LP_DEPOSIT_GAS) { ride = in.valueCoins - LP_DEPOSIT_GAS; }
                    // ROUND 31 (audit 2026-10-26): the kept half only joins the
                    // deposit of the curve's OWN in-flight relay (secret nonce in
                    // its fulfil payload). Anyone else's LPDP deposits only what
                    // it brought itself.
                    var own = false;
                    if (st.lpRelayQid != 0 && pp.remainingBitsCount() >= 64) { own = pp.preloadUint(64) == st.lpRelayQid; }
                    val held: int = own ? st.lpRelayHeld : 0;
                    val gram = ride + held;
                    if (pop == OP_LP_DEPOSIT && in.valueCoins >= LP_DEPOSIT_GAS && gram >= LP_DEPOSIT_MIN) {
                        if (own) {
                            st.lpRelayHeld = 0;
                            st.lpRelayQid = 0;
                            saveCurve(st);
                        }
                        relayLpDeposit(st, amount, gram as coins);
                        return;
                    }
                }
            }
            if (in.senderAddress == st.memeWallet && !st.memeBack
                && !st.seeded
                && st.seedMeme > 0 && amount <= st.seedMeme
                && amount * 100 >= st.seedMeme * 99) {
                st.memeBack = true;
                if (st.quoteBack) {
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
            }
            return;
        }
        // AUDIT 2026-10-24: a malformed forward payload must never throw (a
        // throw does NOT undo the jetton transfer — TEP-74 notifications are a
        // separate transaction) and must not strand the sender's tokens either.
        // Every read is bounds-checked first: the Either bit, the reference,
        // op + query id, and the full variable-length Coins. Anything we cannot
        // parse is handed back to the sender when the notification carries
        // enough GRAM for the return transfer; only an unfunded one is kept.
        // ROUND 31: every return carries a refund reason (see OP_REFUND_REASON).
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


        // NATIVE: buys are native messages; a jetton "buy" is returned.
        if (innerOp == OP_BUY) {
            if (amount > 0) { rejectJetton(in.senderAddress, amount, from, queryId, REASON_WRONG_ASSET, in.valueCoins); }
            return;
        }

        if (innerOp == OP_SELL) {
            // AUDIT (low, fixed): a "sell" from any other wallet used to throw
            // and strand the tokens. Hand them back through the very wallet
            // that sent them — it can only ever return its own tokens.
            if (in.senderAddress != st.memeWallet) {
                if (amount > 0) { rejectJetton(in.senderAddress, amount, from, queryId, REASON_WRONG_ASSET, in.valueCoins); }
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
                quoteSend(from, refundOut);
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
            st.raised -= grossOut;
            st.sold -= amount;
            val lpFee = fee * st.lpFeeBps / 10000;
            st.lpPool += lpFee;
            st.creatorPool += creatorFee;
            st.holderPool += fee - treasuryFee - creatorFee - lpFee;
            saveCurve(st);
            // treasury + creator shares of the quote fee, then output -> seller
            quoteSend(st.treasury, treasuryFee as coins);
            quoteSend(from, out as coins);
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
        fundGradGasFromFee(mutate st, 0);
        assert(freeBalance(st) >= NATIVE_GRAD_FLOOR, ERR_LOW_GAS);
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
            sendRawMessage(beginCell()
                .storeUint(0x18, 6)
                .storeAddress(st.pool)
                .storeCoins((st.seedQuote + NATIVE_PAY_GAS) as coins)
                .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeRef(beginCell()
                    .storeUint(OP_DEDUST_PAY_NATIVE, 32)
                    .storeUint(st.seedQid, 64)
                    .storeCoins(st.seedQuote)
                    .storeRef(depositPayload)
                    .storeRef(dedustPayoutConfig(selfAddr))
                    .endCell())
                .endCell(), 1);
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
    // SWPE, the SFTO override and ESCP are all UNREACHABLE — fail-closed.
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
        quoteSend(st.holderPayout, amount);
        return;
    }


    // The current fee owner (the creator, unless forwarded / taken over)
    // sweeps the accrued creator share of the trade fee. Only the pinned
    // feeTo wallet may claim and it is always paid to itself. `raised`,
    // holderPool and lpPool are tracked separately, so this can never touch
    // the curve reserve.
    // The pinned operator may also trigger it — the payout destination is
    // hard-wired to st.feeTo, so the operator can never redirect a coin.
    if (op == OP_CLAIM_CREATOR) {
        assert(in.senderAddress == st.feeTo || (in.senderAddress == st.opsMultisig && st.opsMultisig != contract.getAddress()), ERR_NOT_ALLOWED);
        // Creator fees unlock only after bonding (accrue until graduation).
        assert(st.graduated, ERR_NOT_ALLOWED);
        assert(in.valueCoins >= 80000000, ERR_LOW_GAS);
        val creatorAmount = st.creatorPool;
        assert(creatorAmount > 0, ERR_NOTHING);
        st.creatorPool = 0;
        saveCurve(st);
        quoteSend(st.feeTo, creatorAmount);
        return;
    }

    // "SFTO" — multisig-approved community takeover (CTO), 2026-10-24.
    // A takeover never hands the creator fees to another person: the fee
    // rights (future fees AND any unclaimed creatorPool) move to the pinned
    // payout hot wallet, which splits them into burns and locked-LP deposits
    // (the Community model). Rules:
    //   - only the treasury MULTISIG may send it (vetting is off-chain:
    //     1% supply burn, creator holds 0 tokens, review up to 48h)
    //   - takes NO address: the destination is always st.holderPayout, so not
    //     even the multisig can point fees at a person's wallet
    //   - terminal: once taken over, the fee owner can never change again
    //   - the fee owner can no longer forward fees anywhere (fee forwarding
    //     is not part of this launchpad)
    // Never touches raised / holderPool / lpPool / LP.
    if (op == OP_SET_FEE_TO) {
        assert(st.feeBps == FEE_BPS_DEFAULT, ERR_NOT_ALLOWED);
        assert(st.creatorFeeBps > 0, ERR_NOT_ALLOWED);
        assert(in.senderAddress == st.treasury, ERR_NOT_ALLOWED);
        assert(st.treasury != st.opsMultisig, ERR_NOT_ALLOWED);
        val payout = st.holderPayout;
        // SPAY must be pinned: an unpinned master falls back to the treasury
        assert(payout != st.treasury, ERR_NOT_READY);
        assert(payout != st.master, ERR_NOT_READY);
        assert(payout != st.opsMultisig, ERR_NOT_ALLOWED);
        assert(payout != contract.getAddress(), ERR_NOT_ALLOWED);
        assert(st.feeTo != payout, ERR_ALREADY_INIT);
        // Round 32 dividend launches convert both reward shares on-chain.
        // Preserve the legacy Creator takeover path for older fee profiles.
        if (st.creatorFeeBps == 1000 && st.treasuryFeeBps == 5500 && st.lpFeeBps == 1000) {
            val dividends = st.holderPool * 15 / 25;
            val toLp = (st.creatorPool + dividends) * 12 / 25;
            st.lpPool += toLp;
            st.holderPool += st.creatorPool - toLp;
            st.creatorPool = 0;
            st.creatorFeeBps = 0;
            st.lpFeeBps = 2200;
        }
        st.feeTo = payout;
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
    // HRVS — collect the pool's trading fees back INTO this curve.
    // AUDIT 2026-10-25 (external H-2): the whole curve share (80% of the pool
    // fee; DeDust keeps 20%) accrues to the curve's 100%-locked position.
    // Withdraw with liquidity 0 + autoClaimFees pays ONLY those fees, to this
    // curve, tagged HRVP; the split happens on arrival (bookHarvest). DeDust
    // refuses any non-zero withdrawal of locked liquidity (exit 36), so the
    // liquidity never moves. Operator-triggered, caller-funded, once an hour.
    if (op == OP_HARVEST) {
        assert(in.senderAddress == st.opsMultisig, ERR_NOT_ALLOWED);
        assert(st.graduated, ERR_NOT_READY);
        assert(st.pool != st.lockVault, ERR_NOT_READY);   // real DeDust pool pinned
        assert(blockchain.now() >= st.lpUnlockAt + HARVEST_INTERVAL, ERR_NOT_ALLOWED);
        // self-funded when the caller attaches less than the full gas
        val selfPay = in.valueCoins < HARVEST_GAS;
        if (selfPay) {
            assert(blockchain.now() >= st.lpUnlockAt + SELF_GAS_INTERVAL, ERR_NOT_ALLOWED);
            assert(freeBalance(st) >= HARVEST_GAS + GAS_RESERVE_FLOOR, ERR_LOW_GAS);
        }

        st.lpUnlockAt = blockchain.now();   // last-claim stamp (rate limit)
        saveCurve(st);

        // withdraw#20b5ef89 query_id liquidity:coins minX minY autoClaimFees ^PayoutOptions+excesses
        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(st.pool)
            .storeCoins(300000000 + HARVEST_EXTRA_GAS)
            .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeRef(beginCell()
                .storeUint(OP_DEDUST_WITHDRAW, 32)
                .storeUint(queryId, 64)
                .storeCoins(0)                         // liquidity: none
                .storeCoins(0).storeCoins(0)           // minimal outs
                .storeBool(true)                       // autoClaimFees
                .storeRef(beginCell()
                    .storeAddress(contract.getAddress())   // fees come back to this curve
                    .storeCoins(HARVEST_EXTRA_GAS)         // gas for the on-chain split
                    .storeMaybeRef(beginCell().storeUint(OP_HARVEST_PAYOUT, 32).endCell())
                    .storeBool(false)
                    .storeAddress(selfPay ? contract.getAddress() : st.opsMultisig) // excess gas back to whoever paid
                    .endCell())
                .endCell())
            .endCell(), 1);
        return;
    }

    // HRVP — the harvested GRAM arrives from the pool as a DeDust payout.
    // Split with the launch's own fee bps: treasury share straight to the
    // multisig, creator share -> creatorPool (CLMC), LP -> lpPool (LPRL),
    // remainder -> holderPool (CLAM). Only a payout from the pinned pool carrying
    // the HRVP tag is booked; anyone else tagging a swap to the curve simply
    // donates it into the same split.
    if (op == OP_DEDUST_PAYOUT && st.graduated && in.senderAddress == st.pool) {
        // op and query_id were already read by the dispatcher
        if (body.remainingBitsCount() < 4 || body.remainingRefsCount() < 1) { return; }
        val len = body.preloadUint(4);
        if (body.remainingBitsCount() < 4 + len * 8) { return; }
        val amt = body.loadCoins();
        var tagged = false;
        var refund = false;
        var rs = body;
        while (rs.remainingRefsCount() > 0 && !tagged && !refund) {
            var t = rs.loadRef().beginParse();
            if (t.remainingBitsCount() >= 32 && t.preloadUint(32) == OP_HARVEST_PAYOUT) { tagged = true; }
            else if (t.remainingBitsCount() >= 32 && t.preloadUint(32) == OP_LP_REFUND) { refund = true; }
        }
        // LPRF: a refused LP swap goes back into the
        // LP share. Only adds to lpPool (a stranger tagging their own swap here
        // simply donates to the locked LP).
        if (refund && amt > 0 && amt <= in.valueCoins) {
            st.lpPool += amt;
            saveCurve(st);
            return;
        }
        if (!tagged || amt <= 0 || amt > in.valueCoins) { return; }
        val treasuryAmt = amt * st.treasuryFeeBps / 10000;
        val creatorAmt = amt * st.creatorFeeBps / 10000;
        val lpAmt = amt * st.lpFeeBps / 10000;
        st.creatorPool += creatorAmt;
        st.lpPool += lpAmt;
        st.holderPool += amt - treasuryAmt - creatorAmt - lpAmt;
        saveCurve(st);
        quoteSend(st.treasury, treasuryAmt as coins);
        return;
    }

    // LPRL — deposit the accrued post-migration LP share (lpPool) into the
    // locked pool. Only the curve may deposit, so it swaps half of lpPool into
    // tokens with ITSELF as the recipient (fulfil payload LPDP) and KEEPS the
    // other half (lpRelayHeld); the LPDP handler deposits both as 100%-locked
    // liquidity. A rejected swap (minOut) returns its GRAM to this curve tagged
    // LPRF -> lpPool; the kept half is folded into the next LPRL. Nothing ever
    // leaves for another wallet. Operator-triggered with its slippage bound,
    // caller-funded.
    // LPAD (user 2026-10-25) — add GRAM to this curve's LP share; the next LPRL
    // deposits it into the locked pool with the same refused-swap protection.
    // The payout wallet uses it for taken-over creator shares. Anyone may call
    // it: the only effect is a donation to the locked LP.
    if (op == OP_LP_ADD) {
        assert(st.graduated && st.pool != st.lockVault, ERR_NOT_READY);
        val amt = body.loadCoins();
        assert(amt > 0 && in.valueCoins >= amt + LP_ADD_GAS, ERR_LOW_GAS);
        st.lpPool += amt;
        saveCurve(st);
        return;
    }

    if (op == OP_LP_RELAY) {
        assert(in.senderAddress == st.opsMultisig, ERR_NOT_ALLOWED);
        assert(st.graduated && st.pool != st.lockVault, ERR_NOT_READY);
        val selfPay = in.valueCoins < LP_DEPOSIT_GAS + 400000000;
        if (selfPay) {
            assert(blockchain.now() >= st.lpRelayAt + SELF_GAS_INTERVAL, ERR_NOT_ALLOWED);
            assert(freeBalance(st) >= LP_DEPOSIT_GAS + 400000000 + GAS_RESERVE_FLOOR, ERR_LOW_GAS);
        }
        st.lpRelayAt = blockchain.now();
        val minOut = body.loadCoins();
        val total = st.lpPool + st.lpRelayHeld;
        assert(total >= LP_DEPOSIT_MIN, ERR_NOTHING);
        st.lpPool = 0;
        val half = total / 2;
        st.lpRelayHeld = total - half;
        st.lpRelayQid = relayNonce();   // ROUND 31: secret nonce for this relay's LPDP
        saveCurve(st);
        val swap = beginCell()
            .storeUint(OP_DEDUST_SWAP_V2, 32)
            .storeCoins(minOut)
            .storeUint(0, 40)
            .storeMaybeRef(null)
            .storeBool(false)
            .storeBool(false)
            .endCell();
        val payout = beginCell()
            .storeAddress(contract.getAddress())
            .storeCoins(LP_DEPOSIT_GAS)
            .storeMaybeRef(beginCell().storeUint(OP_LP_DEPOSIT, 32).storeUint(st.lpRelayQid, 64).endCell())
            .storeBool(false)
            .storeAddress(contract.getAddress())
            .storeCoins(LP_REFUND_FWD)
            .storeMaybeRef(beginCell().storeUint(OP_LP_REFUND, 32).endCell())
            .storeBool(false)
            .storeAddress(selfPay ? contract.getAddress() : st.opsMultisig)
            .endCell();
        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(st.pool)
            .storeCoins((half + LP_DEPOSIT_GAS + 300000000) as coins)
            .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeRef(beginCell()
                .storeUint(OP_DEDUST_PAY_NATIVE, 32)
                .storeUint(QID_LP, 64)
                .storeCoins(half as coins)
                .storeRef(swap)
                .storeRef(payout)
                .endCell())
            .endCell(), 1);
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

// wallet that currently owns + receives the creator fee share (SFTO)
get fun get_fee_to(): address {
    return loadCurve().feeTo;
}

// Pinned operator hot key (see opsMultisig, audit L-1). Returns the
// curve's own address while unpinned — the keeper pins it once via SOPS.
get fun get_holder_payout(): address {
    return loadCurve().holderPayout;
}

get fun get_ops_multisig(): address {
    return loadCurve().opsMultisig;
}

// Round 30+: self-funded gas state — spendable reserve above the floor, and the
// earliest unix time a self-funded HRVS / LPRL is accepted.
get fun get_self_gas(): (int, int, int) {
    val st = loadCurve();
    val spare = freeBalance(st) - GAS_RESERVE_FLOOR;
    return (spare > 0 ? spare : 0, st.lpUnlockAt + SELF_GAS_INTERVAL, st.lpRelayAt + SELF_GAS_INTERVAL);
}

// Round 30+: the half kept for an in-flight / refused LP swap (also marks LPAD support).
get fun get_lp_relay_held(): coins {
    return loadCurve().lpRelayHeld;
}

// LP share waiting to be deposited: lpPool + a kept half left by a refused swap.
get fun get_lp_pool(): coins {
    val st = loadCurve();
    return st.lpPool + st.lpRelayHeld;
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
