// BondingCurveMaster.tolk
//
// Factory for the pad. Holds the whitelist of quote jetton masters, the curve
// code and the jetton-minter code, and deploys one BondingCurve per launch at a
// deterministic address derived from (master, creator, quote_master, salt).
//
// Storage:
//   admin:MsgAddress
//   treasury:MsgAddress          // fee recipient (hardcoded at deploy)
//   ^[ dedust_factory:MsgAddress lock_vault:MsgAddress quotes_head:^QuoteNode
//      native_curve_code:^Cell ]   // Round 28+: GRAM-paired curve variant
//   curve_code:^Cell
//   minter_code:^Cell
//   wallet_code:^Cell
//
// QuoteNode (linked list, one cell per whitelisted quote asset):
//   quote:MsgAddress vault:MsgAddress cap:Coins mig_fee:Coins
//   decimals:uint8 creator_bps:uint16 treasury_bps:uint16 lp_bps:uint16
//   enabled:uint1 community_only:uint1 next:(Maybe ^QuoteNode)
//
// The fee split is per asset: stable/commodity quotes (USDT, USDe, XAUt0)
// carry creator_bps=3000 treasury_bps=3000 lp_bps=4000 (creator split, no
// holder pool, creator exempt from the whale cap); stock quotes (SP500 and the
// xStocks) carry creator_bps=0 treasury_bps=1000 lp_bps=2000 (holders pool,
// creator subject to the 2% lifetime cap).
//
// The admin (a multisig on mainnet) may ONLY:
//   add_quote#41515445    — prepend a brand-new asset; duplicates are refused,
//                           so an existing entry can never be shadowed and no
//                           existing node cell is ever rewritten.
//   disable_quote#44515445 — flip an asset's enabled bit off (and only off).
// There is deliberately no opcode that edits a quote's vault, cap, migration
// fee or fee split: economics of a live asset are immutable once deployed.
//
// In:  create_launch#4c414e43 query_id:uint64 quote_master:MsgAddress salt:uint64
//        metadata:^[ name:^Snake symbol:^Snake image:^Snake description:^Snake ]
//        community:(Maybe uint1)   // Round 28+: 1 = creator fee share -> holder pool
//        dividend:(Maybe uint1)    // Round 32+: 1 = creator keeps 10%, 15% -> holders
//        whale:(Maybe uint1)       // Round 33+: 1 = 2% per-wallet curve limit ON
// Out: launch_created#4c4e4344 (external-out log)
//        curve:MsgAddress creator:MsgAddress quote_master:MsgAddress salt:uint64
//        metadata:^Cell community:uint1 dividend:uint1 fee_bps:uint16
//        whale:uint1               // Round 33+
//
// Whale protection (Round 33+): optional per launch and OFF unless the
// create_launch message sets the bit (user decision 2026-11-16). The choice
// is passed to the curve in CINT and frozen there forever.
//
// Dividend mode (Round 32+): the creator's 25% share is cut to 10% and the
// 15% difference accrues to the curve's holder pool, which the payout cycle
// pays out to holders as a cash dividend instead of burning it. The trade fee
// stays 1% and the treasury (55%) and locked-LP (10%) shares are untouched.

const OP_CREATE_LAUNCH = 0x4c414e43;   // "LANC"
const OP_LAUNCH_CREATED = 0x4c4e4344;  // "LNCD"
const OP_CURVE_INIT = 0x43494e54;      // "CINT"
const OP_ADD_QUOTE = 0x41515445;       // "AQTE"
const OP_DISABLE_QUOTE = 0x44515445;   // "DQTE"
const OP_QUOTE_ADDED = 0x51414444;     // "QADD" (external-out log)
const OP_QUOTE_DISABLED = 0x51444953;  // "QDIS" (external-out log)
const OP_MASTER_WITHDRAW = 0x4d574452; // "MWDR" admin pulls stray TON above the reserve (M-7)
const OP_SET_PAYOUT = 0x53504159;      // "SPAY" admin sets the stock holder payout hot wallet, once
const OP_SET_OPERATOR = 0x534f5052;    // "SOPR" admin sets the automated operator hot key

// Permanent operating reserve: MWDR can never pull the master below this.
const MASTER_MIN_RESERVE = 1000000000; // 1 TON

const ERR_BAD_QUOTE = 101;
const ERR_LOW_GAS = 102;
const ERR_NOT_ADMIN = 103;
const ERR_DUP_QUOTE = 104;
const ERR_TOO_MANY_QUOTES = 105;
const ERR_BAD_PARAMS = 106;
const ERR_META_TOO_BIG = 107;
const ERR_BAD_MODE = 108;         // dividend asked for on a pair that cannot fund one

// Launch gas is sized for metadata up to this size (the site caps text at
// 1,000 chars = ~30 cells / ~10.2k bits). A bigger cell tree costs more to
// forward and store than the launch floor covers, so setup would fail on the
// curve and strand the creator's gas. Refuse it here instead: a throw in the
// master bounces the whole value back. (Gas simulation, 2026-10-24.)
const MAX_META_CELLS = 40;
const MAX_META_BITS = 14000;
const FEE_BPS_DEFAULT = 100;           // 1% trade fee

// Dividend launches (Round 32+): the creator's share is cut to this and the
// difference accrues to the holder pool for dividend payouts. Must stay below
// every dividend-eligible quote's configured creator_bps (2500 today), and the
// holder-pool split the payout cycle applies (burn 10 / dividend 15 of the
// 25% remainder) is derived from this number in src/lib/fee-constants.ts.
const DIVIDEND_CREATOR_BPS = 1000;

// GRAM (native coin) has no jetton master. Its whitelist entry uses this
// sentinel address (basechain, all-zero hash) as the quote key; launches on it
// deploy BondingCurveNative instead of the jetton curve.
const NATIVE_QUOTE = address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c");

const MIN_LAUNCH_GAS = 3200000000;     // 3.2 Gram: deploys + migration reserve parked on the curve
// GRAM pairs: chain fees only. The native curve funds its own migration gas
// out of the 25 GRAM migration fee at graduation, so no reserve is prepaid.
const MIN_LAUNCH_GAS_NATIVE = 600000000; // 0.6 Gram: setup with the largest accepted metadata needs ~0.35 (gas-margins sim 2026-10-24); less bounces back in full
const MAX_QUOTES = 64;                 // keeps findQuote() gas bounded
const MAX_BPS = 10000;


struct QuoteCfg {
    vault: address;
    cap: coins;
    migFee: coins;
    decimals: int;      // uint8 on-chain
    creatorBps: int;    // uint16 on-chain
    treasuryBps: int;   // uint16 on-chain
    lpBps: int;         // uint16 on-chain
    enabled: int;       // uint1 on-chain: 0 = closed to new launches
    communityOnly: int; // uint1 on-chain: 1 = every launch forced to Community fees
}

struct Storage {
    admin: address;
    treasury: address;
    payout: address; // holder-reward payout hot wallet (receives ONLY holderPool via CLAM)
    opKey: address;  // automated hot key: SETL/FSED/SWPE/SFTO-override/CLAM/HRVS on curves
    dedustFactory: address;
    lockVault: address;
    quotesHead: cell;   // first QuoteNode
    curveCode: cell;
    nativeCurveCode: cell;
    minterCode: cell;
    walletCode: cell;
}

fun loadStorage(): Storage {
    var cs = contract.getData().beginParse();
    val admin = cs.loadAddress();
    val treasury = cs.loadAddress();
    var infra = cs.loadRef().beginParse();
    val dedustFactory = infra.loadAddress();
    val lockVault = infra.loadAddress();
    val opKey = infra.loadAddress();
    val quotesHead = infra.loadRef();
    val nativeCurveCode = infra.loadRef();
    val payout = infra.loadRef().beginParse().loadAddress();
    return {
        admin: admin,
        treasury: treasury,
        opKey: opKey,
        payout: payout,
        dedustFactory: dedustFactory,
        lockVault: lockVault,
        quotesHead: quotesHead,
        curveCode: cs.loadRef(),
        nativeCurveCode: nativeCurveCode,
        minterCode: cs.loadRef(),
        walletCode: cs.loadRef(),
    };
}

// Persists storage with a new quotes head. Everything else (admin, treasury,
// operator, infra addresses, code cells) is written back byte-identical — the
// quote list is the only mutable part of this contract.
fun saveStorage(st: Storage, quotesHead: cell) {
    val infra = beginCell()
        .storeAddress(st.dedustFactory)
        .storeAddress(st.lockVault)
        .storeAddress(st.opKey)
        .storeRef(quotesHead)
        .storeRef(st.nativeCurveCode)
        .storeRef(beginCell().storeAddress(st.payout).endCell())
        .endCell();
    contract.setData(beginCell()
        .storeAddress(st.admin)
        .storeAddress(st.treasury)
        .storeRef(infra)
        .storeRef(st.curveCode)
        .storeRef(st.minterCode)
        .storeRef(st.walletCode)
        .endCell());
}

// Walk the quote linked list and return the config for `quote`, or throw
// ERR_BAD_QUOTE when the asset is not whitelisted. Disabled assets are still
// returned (with enabled=0) so callers can tell "closed" from "unknown".
fun findQuote(head: cell, quote: address): QuoteCfg {
    var cur: cell? = head;
    while (cur != null) {
        var s = cur.beginParse();
        val q = s.loadAddress();
        val vault = s.loadAddress();
        val cap = s.loadCoins();
        val mig = s.loadCoins();
        val dec = s.loadUint(8);
        val cb = s.loadUint(16);
        val tb = s.loadUint(16);
        val lb = s.loadUint(16);
        val en = s.loadUint(1);
        val co = s.loadUint(1);
        if (q == quote) {
            return {
                vault: vault,
                cap: cap,
                migFee: mig,
                decimals: dec,
                creatorBps: cb,
                treasuryBps: tb,
                lpBps: lb,
                enabled: en,
                communityOnly: co,
            };
        }
        cur = s.loadMaybeRef();
    }
    throw ERR_BAD_QUOTE;
}

// true when `quote` already has a node (enabled or not). Also enforces the
// MAX_QUOTES ceiling so the list can never grow past a walkable size.
fun quoteExists(head: cell, quote: address): bool {
    var cur: cell? = head;
    var count = 0;
    while (cur != null) {
        var s = cur.beginParse();
        val q = s.loadAddress();
        if (q == quote) { return true; }
        count += 1;
        assert(count < MAX_QUOTES, ERR_TOO_MANY_QUOTES);
        s.skipBits(267);              // vault
        s.loadCoins();                // cap
        s.loadCoins();                // migration fee
        s.skipBits(8 + 16 + 16 + 16 + 1 + 1);  // decimals, fee split, enabled, community only
        cur = s.loadMaybeRef();
    }
    return false;
}

// Rebuilds the list with `quote`'s enabled bit cleared. Every other field of
// every node — including the target's vault, cap, migration fee and fee split
// — is copied through unchanged, so economics can never be rewritten here.
fun disableQuote(node: cell, quote: address): cell {
    var s = node.beginParse();
    val q = s.loadAddress();
    val vault = s.loadAddress();
    val cap = s.loadCoins();
    val mig = s.loadCoins();
    val dec = s.loadUint(8);
    val cb = s.loadUint(16);
    val tb = s.loadUint(16);
    val lb = s.loadUint(16);
    val en = s.loadUint(1);
    val co = s.loadUint(1);
    val next: cell? = s.loadMaybeRef();
    val hit = (q == quote);
    val rebuiltNext: cell? = hit || next == null ? next : disableQuote(next!, quote);
    return beginCell()
        .storeAddress(q)
        .storeAddress(vault)
        .storeCoins(cap)
        .storeCoins(mig)
        .storeUint(dec, 8)
        .storeUint(cb, 16)
        .storeUint(tb, 16)
        .storeUint(lb, 16)
        .storeUint(hit ? 0 : en, 1)
        .storeUint(co, 1)
        .storeMaybeRef(rebuiltNext)
        .endCell();
}


// init data of a curve — MUST stay byte-identical to computeCurveAddress() in
// src/lib/launch.ts: master, creator, quote_master, salt.
fun curveData(creator: address, quoteMaster: address, salt: int): cell {
    return beginCell()
        .storeAddress(contract.getAddress())
        .storeAddress(creator)
        .storeAddress(quoteMaster)
        .storeUint(salt, 64)
        .endCell();
}

// canonical StateInit cell for the deploy message
fun codeFor(st: Storage, quoteMaster: address): cell {
    return quoteMaster == NATIVE_QUOTE ? st.nativeCurveCode : st.curveCode;
}

fun curveStateInit(code: cell, data: cell): cell {
    return beginCell()
        .storeUint(0, 2)          // split_depth:0 special:0
        .storeMaybeRef(code)
        .storeMaybeRef(data)
        .storeUint(0, 1)          // library:0
        .endCell();
}

// deterministic curve address derived from (master, creator, quote_master, salt)
fun curveAddress(code: cell, data: cell): address {
    val cs: ContractState = { code: code, data: data };
    return AutoDeployAddress { stateInit: cs }.calculateAddress();
}

fun onInternalMessage(in: InMessage) {
    var body = in.body;
    if (body.isEmpty()) { return; }

    val op = body.loadUint(32);
    // Bounced messages (e.g. a curve deploy that ran out of gas) must not throw
    // inside the bounce handler — accept and ignore them.
    if (op == 0xffffffff) { return; }
    val queryId = body.loadUint(64);


    if (op == OP_CREATE_LAUNCH) {
        val st = loadStorage();
        val quoteMaster = body.loadAddress();
        val salt = body.loadUint(64);
        val metadata = body.loadRef();
        val (_, metaBits, _, metaOk) = metadata.calculateSize(MAX_META_CELLS);
        assert(metaOk && (metaBits! <= MAX_META_BITS), ERR_META_TOO_BIG);
        // Optional trailing flag (Round 28+): community:uint1. When set, the
        // creator gives up their share of the 1% fee and it accrues to the
        // curve's holder pool instead (curve sees creatorBps = 0). Old clients
        // that omit the bit get the creator split, exactly as before.
        var community = 0;
        if (body.remainingBitsCount() >= 1) { community = body.loadUint(1); }
        // Optional trailing flag (Round 32+): dividend:uint1. The creator keeps
        // DIVIDEND_CREATOR_BPS of the fee and the rest of their share accrues
        // to the holder pool for dividend payouts. Clients that omit the bit
        // launch exactly as before.
        var dividend = 0;
        if (body.remainingBitsCount() >= 1) { dividend = body.loadUint(1); }
        // Optional trailing flag (Round 33+): whale:uint1. 1 = the curve keeps
        // the 2% lifetime per-wallet buy limit (creator still exempt). Clients
        // that omit the bit launch WITHOUT whale protection — off by default.
        var whale = 0;
        if (body.remainingBitsCount() >= 1) { whale = body.loadUint(1); }

        val cfg = findQuote(st.quotesHead, quoteMaster);
        assert(cfg.enabled == 1, ERR_BAD_QUOTE);   // disabled asset: no new launches
        // Community-only assets (memecoin pairs): the Creator model does not
        // exist there, whatever the launch message asks for.
        if (cfg.communityOnly == 1) { community = 1; }
        // A dividend is a Creator-model variant: a Community launch has already
        // given its creator share away, and a pair with no creator share
        // (stocks) cannot fund one. Refuse both instead of ignoring the bit.
        assert(!(dividend == 1 && community == 1), ERR_BAD_MODE);
        assert(!(dividend == 1 && cfg.creatorBps < DIVIDEND_CREATOR_BPS), ERR_BAD_MODE);
        // GRAM only (2026-11-06): dividends pay flat 5 GRAM per holder.
        assert(!(dividend == 1 && quoteMaster != NATIVE_QUOTE), ERR_BAD_MODE);
        assert(in.valueCoins >= (quoteMaster == NATIVE_QUOTE ? MIN_LAUNCH_GAS_NATIVE : MIN_LAUNCH_GAS), ERR_LOW_GAS);
        // Single 1% trade fee on every launch — no fee tiers.
        val creatorBps = community == 1 ? 0 : (dividend == 1 ? DIVIDEND_CREATOR_BPS : cfg.creatorBps);
        val treasuryBps = cfg.treasuryBps;
        // Community launches: the forgone 25% creator share splits 12% to the
        // LP (pre-bond set-aside + post-bond share kept inside the DeDust pool)
        // and 13% to the holder pool, which funds burns — final totals:
        // 22% LP / 23% burns.
        // AUDIT (L-2, fixed): never underflow, and refuse Community mode on a
        // pair with no creator share (e.g. stocks) instead of silently moving
        // part of the LP share to holders.
        var lpBps = cfg.lpBps;
        if (community == 1) {
            assert(cfg.creatorBps > 0, ERR_BAD_QUOTE);
            lpBps = cfg.lpBps + cfg.creatorBps / 2 - 50;
            if (lpBps < 0) { lpBps = 0; }
        }
        val feeBps = FEE_BPS_DEFAULT;


        val creator = in.senderAddress;
        val data = curveData(creator, quoteMaster, salt);
        val code = codeFor(st, quoteMaster);
        val stateInit = curveStateInit(code, data);
        val curveAddr = curveAddress(code, data);

        // deploy the curve and hand it everything it needs.
        // Order MUST match initFromMaster() in BondingCurve.tolk.
        // Three addresses (267 bits each) do not fit next to the header in the
        // root cell — 1,023-bit limit, cell overflow (exit code 8). They live
        // in their own reference instead.
        val holderPayout = (st.payout == st.admin) ? st.treasury : st.payout;
        val opsRef = beginCell().storeAddress(st.opKey).storeAddress(holderPayout).endCell();
        // FIX 2026-10-24: a cell holds at most 4 refs. initBody carried 5
        // (infra, ops, metadata, minter, wallet), so every launch aborted with
        // exit 8. The ops ref now rides inside the infra ref.
        val infra = beginCell()
            .storeAddress(st.dedustFactory)
            .storeAddress(st.lockVault)
            .storeAddress(cfg.vault)
            .storeRef(opsRef)
            .endCell();
        // The operator hot key travels in its own ref (root cell bit limit) and
        // is pinned as the curve's opsMultisig automatically at launch — the
        // multisig treasury never has to sign per-launch operations.
        // Stock holder rewards (holderPool) go to a dedicated payout hot wallet,
        // never to the multisig treasury, so 6-hourly rounds need no signing.
        // Until SPAY pins it (admin sentinel), they fall back to the treasury.

        val initBody = beginCell()
            .storeUint(OP_CURVE_INIT, 32)
            .storeUint(queryId, 64)
            .storeAddress(st.treasury)
            .storeCoins(cfg.cap)
            .storeCoins(cfg.migFee)
            .storeUint(cfg.decimals, 8)
            .storeUint(creatorBps, 16)
            .storeUint(treasuryBps, 16)
            .storeUint(lpBps, 16)
            .storeUint(feeBps, 16)
            .storeUint(whale, 1)      // Round 33: whale protection on/off
            .storeRef(infra)
            .storeRef(metadata)
            .storeRef(st.minterCode)
            .storeRef(st.walletCode)
            .endCell();


        // external-out log the indexer (src/lib/ton-api.functions.ts) reads.
        // ext_out_msg_info$11 src:addr_none dest:addr_none created_lt:uint64
        //   created_at:uint32 init:0 body:^Cell
        val logBody = beginCell()
            .storeUint(OP_LAUNCH_CREATED, 32)
            .storeUint(queryId, 64)
            .storeAddress(curveAddr)
            .storeAddress(creator)
            .storeAddress(quoteMaster)
            .storeUint(salt, 64)
            .storeRef(metadata)
            .storeUint(community, 1)
            .storeUint(dividend, 1)
            .storeUint(feeBps, 16)
            .storeUint(whale, 1)
            .endCell();
        sendRawMessage(beginCell()
            .storeUint(0b11, 2)   // ext_out_msg_info$11
            .storeUint(0, 2)      // src:addr_none (rewritten by the system)
            .storeUint(0, 2)      // dest:addr_none
            .storeUint(0, 64)     // created_lt
            .storeUint(0, 32)     // created_at
            .storeUint(0, 1)      // no state init
            .storeUint(1, 1)      // body stored as a ref
            .storeRef(logBody)
            .endCell(), 0);

        // AUDIT (low, fixed): the log's fee used to come out of the master's
        // own balance on every launch. Keep the pre-launch balance reserved and
        // send everything else (launch value minus all fees) to the curve, so
        // the launcher pays for its own log and the master never drains.
        reserveToncoinsOnBalance(contract.getOriginalBalance() - in.valueCoins, 0);
        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(curveAddr)
            .storeCoins(0)
            .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
            .storeRef(stateInit)
            .storeRef(initBody)
            .endCell(), 128);  // carry everything above the reserve

        return;
    }

    // ---- admin (multisig) governance of the quote whitelist -----------------
    // Neither opcode can touch an existing asset's vault, cap, migration fee or
    // fee split, and neither can remove a node: launches already running on an
    // asset are unaffected by anything the admin does here.

    if (op == OP_ADD_QUOTE) {
        val st = loadStorage();
        assert(in.senderAddress == st.admin, ERR_NOT_ADMIN);

        val quote = body.loadAddress();
        val vault = body.loadAddress();
        val cap = body.loadCoins();
        val migFee = body.loadCoins();
        val dec = body.loadUint(8);
        val cb = body.loadUint(16);
        val tb = body.loadUint(16);
        val lb = body.loadUint(16);
        // Optional trailing flag: community_only:uint1. When set, every launch
        // on this asset is forced to Community fees (memecoin pairs). Frozen
        // forever like the rest of the entry.
        var co = 0;
        if (body.remainingBitsCount() >= 1) { co = body.loadUint(1); }

        // sanity: a nonsense asset would strand every launch created on it
        assert(cap > 0, ERR_BAD_PARAMS);
        assert(migFee <= cap, ERR_BAD_PARAMS);
        assert(dec > 0 && dec <= 18, ERR_BAD_PARAMS);
        assert(cb + tb + lb <= MAX_BPS, ERR_BAD_PARAMS);
        // Community-only needs a creator share to redirect (never on stocks).
        assert(co == 0 || cb > 0, ERR_BAD_PARAMS);
        // AUDIT (low, fixed): the only validation was on the numbers. There is
        // no edit opcode by design, so a fat-fingered address is permanent:
        // reject the obviously-broken shapes an admin can typo — the jetton
        // master and its DeDust vault must be distinct, non-null, basechain.
        assert(quote != vault, ERR_BAD_PARAMS);
        assert(quote.getWorkchain() == 0, ERR_BAD_PARAMS);
        assert(vault.getWorkchain() == 0, ERR_BAD_PARAMS);
        assert(quote != contract.getAddress(), ERR_BAD_PARAMS);
        assert(vault != contract.getAddress(), ERR_BAD_PARAMS);
        // duplicates are refused, so a new node can never shadow an existing
        // asset's economics (findQuote returns the first match).
        assert(!quoteExists(st.quotesHead, quote), ERR_DUP_QUOTE);

        // prepend: every existing node cell is reused untouched by reference.
        val head = beginCell()
            .storeAddress(quote)
            .storeAddress(vault)
            .storeCoins(cap)
            .storeCoins(migFee)
            .storeUint(dec, 8)
            .storeUint(cb, 16)
            .storeUint(tb, 16)
            .storeUint(lb, 16)
            .storeUint(1, 1)             // enabled
            .storeUint(co, 1)            // community only
            .storeMaybeRef(st.quotesHead)
            .endCell();
        saveStorage(st, head);

        val log = beginCell()
            .storeUint(OP_QUOTE_ADDED, 32)
            .storeUint(queryId, 64)
            .storeAddress(quote)
            .storeAddress(vault)
            .storeCoins(cap)
            .storeCoins(migFee)
            .storeUint(dec, 8)
            .storeUint(cb, 16)
            .storeUint(tb, 16)
            .storeUint(lb, 16)
            .endCell();
        sendRawMessage(beginCell()
            .storeUint(0b11, 2)
            .storeUint(0, 2)
            .storeUint(0, 2)
            .storeUint(0, 64)
            .storeUint(0, 32)
            .storeUint(0, 1)
            .storeUint(1, 1)
            .storeRef(log)
            .endCell(), 0);
        return;
    }

    if (op == OP_DISABLE_QUOTE) {
        val st = loadStorage();
        assert(in.senderAddress == st.admin, ERR_NOT_ADMIN);

        val quote = body.loadAddress();
        assert(quoteExists(st.quotesHead, quote), ERR_BAD_QUOTE);
        saveStorage(st, disableQuote(st.quotesHead, quote));

        val log = beginCell()
            .storeUint(OP_QUOTE_DISABLED, 32)
            .storeUint(queryId, 64)
            .storeAddress(quote)
            .endCell();
        sendRawMessage(beginCell()
            .storeUint(0b11, 2)
            .storeUint(0, 2)
            .storeUint(0, 2)
            .storeUint(0, 64)
            .storeUint(0, 32)
            .storeUint(0, 1)
            .storeUint(1, 1)
            .storeRef(log)
            .endCell(), 0);
        return;
    }

    // "MWDR" — AUDIT (medium, fixed — external review M-7): plain TON sent to
    // the master by mistake (a fat-fingered transfer, an over-funded launch)
    // used to be stranded forever: the master had no withdrawal path. The
    // admin multisig may pull any surplus ABOVE a permanent 1 TON operating
    // reserve. Curve funds are never held here — launches carry their own
    // value to the curve address — so everything above the reserve is stray.
    if (op == OP_MASTER_WITHDRAW) {
        val st = loadStorage();
        assert(in.senderAddress == st.admin, ERR_NOT_ADMIN);
        val to = body.loadAddress();
        val amount = body.loadCoins();
        assert(amount > 0, ERR_BAD_PARAMS);
        assert(contract.getOriginalBalance() - amount >= MASTER_MIN_RESERVE, ERR_BAD_PARAMS);
        sendRawMessage(beginCell()
            .storeUint(0x10, 6)
            .storeAddress(to)
            .storeCoins(amount)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .endCell(), 1);
        return;
    }

    // "SOPR" — the admin sets the automated operator hot key ONCE per master.
    // Every launch after that pins it as the curve's ops key automatically, so
    // the multisig treasury (which only receives fees) never signs daily ops.
    // The operator can never move user funds: curves only let it pin the LP
    // wallet, force-seed a stuck graduation, sweep stray jettons, override the
    // fee recipient after an approved CTO, and trigger fee claims/harvests —
    // all of which pay out to the treasury or fee owner, never to the operator.
    if (op == OP_SET_OPERATOR) {
        var st = loadStorage();
        assert(in.senderAddress == st.admin, ERR_NOT_ADMIN);
        // AUDIT (low, fixed): truly one-shot — only while still unset (admin
        // sentinel written at deploy). A key rotation needs a new master.
        assert(st.opKey == st.admin, ERR_BAD_PARAMS);
        val newKey = body.loadAddress();
        assert(newKey != st.admin && newKey != st.treasury && newKey != st.payout, ERR_BAD_PARAMS);
        st.opKey = newKey;
        saveStorage(st, st.quotesHead);
        return;
    }

    // "SPAY" — the admin pins the stock holder payout wallet ONCE per master.
    // It receives holderPool claims (CLAM: burn / holder-reward money awaiting
    // its cycle) and holds no role on any curve. Round 29 curves split all
    // other post-migration fees on-chain (audit 2026-10-25, H-2).
    if (op == OP_SET_PAYOUT) {
        var st = loadStorage();
        assert(in.senderAddress == st.admin, ERR_NOT_ADMIN);
        assert(st.payout == st.admin, ERR_BAD_PARAMS);
        val newPayout = body.loadAddress();
        assert(newPayout != st.admin && newPayout != st.treasury && newPayout != st.opKey, ERR_BAD_PARAMS);
        st.payout = newPayout;
        saveStorage(st, st.quotesHead);
        return;
    }

    // unknown op — bounce
    assert(false, 0xffff);
}


get fun get_master_data(): (address, address, cell) {
    val st = loadStorage();
    return (st.admin, st.treasury, st.curveCode);
}

get fun get_curve_address(creator: address, quoteMaster: address, salt: int): address {
    val st = loadStorage();
    return curveAddress(codeFor(st, quoteMaster), curveData(creator, quoteMaster, salt));
}

// returns the full config of a whitelisted quote; throws 101 otherwise
get fun get_quote_config(quoteMaster: address): (address, coins, coins, int, int, int, int) {
    val st = loadStorage();
    val cfg = findQuote(st.quotesHead, quoteMaster);
    return (cfg.vault, cfg.cap, cfg.migFee, cfg.decimals, cfg.creatorBps, cfg.treasuryBps, cfg.lpBps);
}

// 1 while the asset accepts new launches, 0 once the admin disabled it.
// Throws 101 for an asset that was never whitelisted.
get fun get_quote_enabled(quoteMaster: address): int {
    val st = loadStorage();
    return findQuote(st.quotesHead, quoteMaster).enabled;
}

// 1 when every launch on this asset is forced to Community fees (memecoin pairs).
get fun get_quote_community_only(quoteMaster: address): int {
    val st = loadStorage();
    return findQuote(st.quotesHead, quoteMaster).communityOnly;
}

get fun get_native_curve_code(): cell {
    return loadStorage().nativeCurveCode;
}
