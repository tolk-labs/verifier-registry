// decompiled by @fiscaldev
import "@stdlib/exotic-cells"
import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "compat-address"
import "deployment-message"
import "stdlib-legacy-stateinit"
import "types"

// Frozen Uranus Meme V3: recovered names express behavior, not original identifiers.
// Library references below contain code hashes only; source-built dependencies are
// registered in the emulator for trading and complete deployment tests.
fun walletLibrary(): cell
    asm
        "<b 2 8 u, 0x891e5228e4300ae3ff22583163bbd50e3e1e8cd2304c0d57164f5318f9da1266 256 u, b>spec PUSHREF"

fun affiliateLibrary(): cell
    asm
        "<b 2 8 u, 0x4456fad12a434c4898b05ac65bab5de80db33f275c6020746de8e111a5cda4e6 256 u, b>spec PUSHREF"

fun poolLibrary(): cell
    asm
        "<b 2 8 u, 0x6045e67b617e73486aac445cfcad0dbead6d315ccc8f4aede3f2e23ad14da4b0 256 u, b>spec PUSHREF"

fun tokenDecimals(): cell
    asm "<b x{39} s, b> PUSHREF"

fun configBalance(): coins
    asm "11 GETPARAM FIRST"

fun incomingSender(): address
    asm "2 INMSGPARAM"

fun addressNone(): any_address
    asm "x{2_} PUSHSLICE"

fun zeroMintable(): int
    asm "0 PUSHINT"

fun emptyPayload(): slice
    asm "x{} PUSHSLICE"

fun any_address.isPlainStd(self): bool
    asm "x{A_} SDBEGINSQ NIP"

// No TVM instruction: keep a distinct operand snapshot until fee split/wire encoding.
// This retains the archived compiler's SSA lifetime without rewriting instructions.
fun snapshotFee(value: int): int
    asm " "

// Retain the complete owner while checking a separate prefix cursor.
fun checkedStandardOwner(owner: any_address, validation: any_address): address
    asm "x{A_} SDBEGINSQ NIP 9 THROWIFNOT"

fun dict.setMigrationWallet(self, key: int, value: builder): dict
    asm(value key self) "2 PUSHINT DICTUSETB"

@inline
fun migrationWalletRecord(wallet: any_address): builder {
    return beginCell().storeSlice(wallet as slice).storeUint(0x127500, 40);
}

fun builder.takeSlice(self): slice
    asm "BTOS"

fun builder.storeVarUint32(mutate self, value: int): self
    asm(value self) "STVARUINT32"

fun selectAddress(condition: bool, present: address, absent: address): address
    asm "CONDSEL"

@inline_ref
fun walletDeployment(code: cell, master: address, owner: address): AutoDeployAddress {
    return {
        workchain: 0,
        stateInit: {
            code,
            data: beginCell().storeCoins(0).storeAddress(owner).storeAddress(master).endCell(),
        },
        toShard: { fixedPrefixLength: 8, closeTo: owner },
    };
}

@inline_ref
fun affiliateDeployment(isPartner: uint1, id: uint256, share: uint16): AutoDeployAddress {
    val workchain = 0;
    val code = affiliateLibrary().loadSpecial();
    val authority = address("EQDDszIM08Ycwx8ycvz5Mn_hQdPj38FtG9bp0XQYw0j5E5D1");
    val data = AffiliateStorage {
        initialized: false,
        authority,
        kind: isPartner,
        metadata: null,
        id,
        share,
        owner: null,
    }.toCell();
    return { workchain, stateInit: { code, data } };
}

@inline_ref
fun Curve.buy(mutate self, amount: coins, minOut: coins, fee: int): (coins, coins, coins) {
    // Round buys down; at graduation round the required payment up twice.
    var net = mulDivFloor(amount, 10000, 10000 + fee);
    val virtualRaised = self.beta + self.raisedFunds;
    val remaining = self.alpha - self.currentSupply;
    var tokens = mulDivFloor(net, remaining, virtualRaised + net);
    val available = self.onSellSupply - self.currentSupply;
    var charged = amount;
    if (tokens > available) {
        net = mulDivCeil(
            available,
            self.beta + self.raisedFunds,
            (self.alpha - self.currentSupply) - available,
        );
        charged = mulDivCeil(net, 10000 + fee, 10000);
        tokens = available;
        self.graduated = true;
    }
    assert (tokens > 0 && tokens >= minOut) throw 21;
    self.raisedFunds += net;
    self.currentSupply += tokens;
    return (net, tokens, charged - net);
}

@inline
fun loadRuntime(): Runtime {
    var s = contract.getData().beginParse();
    val initialized = s.loadBool();
    val migrated = s.loadBits(1) as bits1;
    val config = s.loadRef();
    val baseFee = s.loadUint(16);
    val graduated = s.loadBool();
    val alpha = s.loadCoins();
    val beta = s.loadCoins();
    val onSellSupply = s.loadCoins();
    val raisedFunds = s.loadCoins();
    val currentSupply = s.loadCoins();
    val totalSupply = s.loadCoins();
    val creatorFee = s.loadCoins();
    val partnerFee = s.loadCoins();
    return {
        initialized,
        migrated,
        config,
        baseFee,
        curve: {
            graduated,
            alpha,
            beta,
            onSellSupply,
            raisedFunds,
            currentSupply,
        },
        totalSupply,
        creatorFee,
        partnerFee,
        tail: s,
    };
}

@inline
fun migrationPool(
    controller: address,
    partner: address,
    partnerShare: uint16,
    baseFee: uint16,
): (cell, cell) {
    val minter = contract.getAddress();
    var wallets: dict = null;
    wallets = wallets.setMigrationWallet(
        0,
        migrationWalletRecord(contract.getAddress() as any_address),
    );
    wallets = wallets.setMigrationWallet(1, migrationWalletRecord(addressNone()));
    val code = poolLibrary();
    val none = addressNone();
    val token = beginCell().storeUint(2, 8).storeAddress(minter).endCell();
    val config = PoolConfig {
        assetX: none,
        assetY: minter as any_address,
        creator: partner,
        baseFee,
        creatorFee: partnerShare,
        depositActivation: token,
        swapActivation: null,
        feeSelectorHigh: false,
        feeSelectorLow: true,
        customResolvers: null,
        allowedRewards: wallets,
    }.toCell();
    val balances = PoolBalances {
        emptyProtocolFees: 0,
        emptyCreatorFees: 0,
        xCheckpoint: 0,
        yCheckpoint: 0,
    }.toCell();
    val admin = PoolAdmin {
        controller,
        walletsByAssets: null,
        assetsByWallets: null,
        resolutions: null,
    }.toCell();
    val data = PoolRoot {
        config,
        fees: balances,
        extra: admin,
        rewards: null,
        emptyStatusAndBalances: 0,
    }.toCell();
    return (code, data);
}

@inline
fun affiliatePayment(isPartner: uint1, id: uint256, share: uint16, amount: coins, queryId: uint64) {
    val destination = affiliateDeployment(isPartner, id, share).calculateArchivedAddress();
    sendRawMessage(
        beginCell()
            .storeUint(0x18, 6)
            .storeAddress(destination)
            .storeCoins(amount)
            .storeUint(2000662320, 139)
            .storeUint(queryId, 64)
            .endCell(),
        2,
    );
}

@inline
fun sendPoolInitialization(value: coins, payload: cell?, queryId: uint64, code: cell, data: cell) {
    val wireQuery = snapshotFee(queryId);
    var outgoing = beginCell().storeUint(0x18, 6).storeUint(4, 3).storeInt(0, 8);
    outgoing
        .storeUint(archivedStateHash(code, data), 256)
        .storeCoins(value)
        .storeUint(140, 113)
        .storeRef(code)
        .storeRef(data)
        .storeUint(0xde8402ce, 32)
        .storeUint(wireQuery, 64)
        .storeMaybeRef(payload);
    sendRawMessage(outgoing.endCell(), 17);
}

@inline
fun sendMigrationTokens(value: coins, queryId: uint64, amount: coins, amounts: cell, payout: cell) {
    val code = walletLibrary();
    val minter = contract.getAddress();
    val destination = walletDeployment(code, minter, incomingSender());
    val body = WalletCreditRef {
        opcode: 0x178d4519,
        queryId,
        amount,
        from: contract.getAddress(),
        response: contract.getAddress(),
        forwardTon: 150000000,
        referenced: true,
        payload: MigrationPair {
            opcode: 0xcbc33949,
            amounts,
            payout,
        }.toCell(),
    }.toCell();
    sendRawMessage(
        archivedValuedRefDeploymentHeader(destination, value).storeRef(body).endCell(),
        1,
    );
}

@method_id(4)
fun executeBuy(
    queryId: uint64,
    buyer: address,
    amount: coins,
    minOut: coins,
    partner: Partner?,
    referrer: Referrer?,
) {
    var s = contract.getData().beginParse();
    val initialized = s.loadBool();
    val migrated = s.loadBits(1);
    val configCell = s.loadRef();
    val baseFee = s.loadUint(16);
    val graduated = s.loadBool();
    val alpha = s.loadCoins();
    val beta = s.loadCoins();
    val onSellSupply = s.loadCoins();
    val raisedFunds = s.loadCoins();
    val currentSupply = s.loadCoins();
    val totalSupply = s.loadCoins();
    val creatorEarned = s.loadCoins();
    val partnerEarned = s.loadCoins();
    val savedTail = s;
    var curve: Curve = {
        graduated,
        alpha,
        beta,
        onSellSupply,
        raisedFunds,
        currentSupply,
    };
    var suffix = savedTail;
    val partnerShare = suffix.loadUint(16);
    val migration = suffix.preloadRef();
    assert (initialized) throw 28;
    assert (!curve.graduated) throw 29;
    var affiliateRate = 0;
    var referrerRate = 0;
    if (partner != null) {
        val rate = min(partner!.share, 500);
        if (referrer != null) {
            referrerRate = min(referrer!.share, 8000);
        }
        affiliateRate = rate;
    }
    val feeForTrade = snapshotFee(baseFee);
    val (net, tokens, fees) = curve.buy(
        amount,
        minOut,
        feeForTrade + (referrerRate > 0 ? mulDivFloor(affiliateRate, 5, 6) : affiliateRate),
    );
    val effectiveSplit = referrerRate > 0 ? mulDivFloor(affiliateRate, 5, 6) : affiliateRate;
    val baseFees = mulDivFloor(fees, feeForTrade, effectiveSplit + feeForTrade);
    val protocolFee = mulDivFloor(baseFees, 20, 100);
    val cappedShare = min(partnerShare, 6000);
    val partnerFee = mulDivFloor(baseFees, cappedShare, 10000);
    val affiliateFees = fees - baseFees;
    val fullAffiliateFees = mulDivFloor(affiliateFees, 6, 5);
    val referrerFee = mulDivFloor(fullAffiliateFees, referrerRate, 10000);
    val creatorFee = baseFees - protocolFee - partnerFee;
    val affiliateFee = affiliateFees - referrerFee;
    val updatedCreator = creatorEarned + creatorFee;
    val updatedPartner = partnerEarned + partnerFee;
    contract.setData(
        beginCell()
            .storeBool(initialized)
            .storeSlice(migrated as slice)
            .storeRef(configCell)
            .storeUint(baseFee, 16)
            .storeBool(curve.graduated)
            .storeCoins(curve.alpha)
            .storeCoins(curve.beta)
            .storeCoins(curve.onSellSupply)
            .storeCoins(curve.raisedFunds)
            .storeCoins(curve.currentSupply)
            .storeCoins(totalSupply)
            .storeCoins(updatedCreator)
            .storeCoins(updatedPartner)
            .storeSlice(savedTail)
            .endCell(),
    );
    val consumed = contract.getOriginalBalance() - configBalance();
    var keep = consumed + contract.getStoragePaidPayment() + net + protocolFee + creatorFee;
    if (curve.graduated) {
        var config = configCell.beginParse();
        var m = migration.beginParse();
        config.loadAddress();
        val controller = config.loadAddress();
        val partner = m.loadAddress();
        val share = m.loadUint(16);
        val fee = m.preloadUint(16);
        val (code, data) = migrationPool(controller, partner, share, fee);
        sendPoolInitialization(300000000, null, queryId, code, data);
        keep -= 300000000;
    }
    val none = addressNone();
    val event = beginCell()
        .storeUint(0xa0aa6bc2, 32)
        .storeAddress(buyer)
        .storeCoins(net)
        .storeCoins(tokens)
        .storeCoins(creatorFee)
        .storeCoins(protocolFee)
        .storeCoins(affiliateFee)
        .storeCoins(referrerFee)
        .storeCoins(curve.currentSupply)
        .storeCoins(curve.raisedFunds)
        .storeBool(curve.graduated)
        .endCell();
    sendRawMessage(
        beginCell()
            .storeUint(0b1100, 4)
            .storeSlice(none as slice)
            .storeUint(1, 98)
            .storeRef(event)
            .endCell(),
        1,
    );
    if (affiliateFee > 0) {
        affiliatePayment(1, partner!.id, partner!.share, affiliateFee, queryId);
        if (referrerFee > 0) {
            affiliatePayment(0, referrer!.id, referrer!.share, referrerFee, queryId);
        }
    }
    reserveToncoinsOnBalance(keep, 2);
    val code = walletLibrary();
    val dest = walletDeployment(code, contract.getAddress(), buyer);
    val body = WalletCredit {
        opcode: 0x178d4519,
        queryId,
        amount: tokens,
        from: null,
        response: buyer,
        forwardTon: 0,
        referenced: false,
        payload: emptyPayload(),
    }.toCell();
    sendRawMessage(archivedPoolRefDeploymentHeader(dest).storeRef(body).endCell(), 128);
}

@method_id(121862)
fun get_bonding_curve_data(): (
    bool,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
) {
    var s = contract.getData().beginParse();
    s.loadUint(2);
    val config = s.loadRef();
    s.loadUint(16);
    val graduated = s.loadBool();
    val alpha = s.loadCoins();
    val beta = s.loadCoins();
    val onSell = s.loadCoins();
    val raised = s.loadCoins();
    val current = s.loadCoins();
    val total = s.loadCoins();
    var c = config.beginParse();
    c.loadAddress();
    c.loadAddress();
    val raising = c.loadCoins();
    val liquidity = c.loadCoins();
    return (
        graduated,
        total,
        current,
        onSell,
        liquidity,
        raising,
        50000000000,
        raised,
        alpha,
        beta,
    );
}

@method_id(83180)
fun get_partner_data(): (int, int, address, int) {
    var s = contract.getData().beginParse();
    s.loadUint(2);
    s.loadRef();
    s.loadUint(17);
    s.loadCoins();
    s.loadCoins();
    s.loadCoins();
    s.loadCoins();
    s.loadCoins();
    s.loadCoins();
    s.loadCoins();
    val fee = s.loadCoins();
    val share = s.loadUint(16);
    var migration = s.preloadRef().beginParse();
    val partner = migration.loadAddress();
    return (fee, share, partner, migration.preloadUint(16));
}

get fun get_wallet_address(owner: address): address {
    val code = walletLibrary();
    val destination = walletDeployment(code, contract.getAddress(), owner);
    return destination.calculateArchivedAddress();
}

@method_id(101289)
fun get_meme_data(): (
    bool,
    bool,
    address,
    address,
    int,
    int,
    bool,
    int,
    int,
    int,
    int,
    int,
    int,
) {
    var s = contract.getData().beginParse();
    val initialized = s.loadBool();
    val migrated = s.loadBool();
    val config = s.loadRef();
    val fee = s.loadUint(16);
    val graduated = s.loadBool();
    val alpha = s.loadCoins();
    val beta = s.loadCoins();
    val onSell = s.loadCoins();
    val raised = s.loadCoins();
    val current = s.loadCoins();
    s.loadCoins();
    val creatorFee = s.loadCoins();
    var c = config.beginParse();
    val creator = c.loadAddress();
    val controller = c.loadAddress();
    c.loadCoins();
    c.loadCoins();
    return (
        initialized,
        migrated,
        controller,
        creator,
        creatorFee,
        c.preloadUint(128),
        graduated,
        alpha,
        beta,
        onSell,
        fee,
        raised,
        current,
    );
}

get fun get_jetton_data(): (int, int, any_address, cell, cell) {
    var s = contract.getData().beginParse();
    s.loadUint(2);
    val config = s.loadRef();
    s.loadUint(17);
    s.loadCoins();
    s.loadCoins();
    s.loadCoins();
    s.loadCoins();
    s.loadCoins();
    val total = s.loadCoins();
    val metadata = config.beginParse().preloadRef();
    val mintable = zeroMintable();
    val none = addressNone();
    val decimals = tokenDecimals();
    var fields: map<uint256, cell> = [];
    fields.set(
        51065135818459385347574250312853146822620586594996463797054414300406918686668,
        beginCell().storeUint(0, 8).storeRef(metadata).endCell(),
    );
    fields.set(
        107878361799212983662495570378745491379550006934010968359181619763835345146430,
        beginCell().storeUint(0, 8).storeRef(decimals).endCell(),
    );
    val content = beginCell().storeUint(0, 8).storeDict(fields.toLowLevelDict()).endCell();
    return (total, mintable, none, content, walletLibrary());
}

fun onInternalMessage(in: InMessage) {
    val message = Incoming.fromSlice(in.body, { throwIfOpcodeDoesNotMatch: 65535 });
    match (message) {
        Buy => {
            val required = contract.getStoragePaidPayment() + calculateGasFee(0, 22492) +
            in.originalForwardFee +
            calculateForwardFeeWithoutLumpPrice(0, 812, 3) +
            calculateStorageFee(0, 157680000, 970, 3) +
            calculateGasFee(0, 8862) +
            message.amount;
            assert (required <= in.valueCoins) throw 23;
            val buyer = in.senderAddress;
            val partner = message.partner == null ? null : message.partner!.load();
            val referrer = message.referrer == null ? null : message.referrer!.load();
            executeBuy(
                message.queryId,
                buyer,
                message.amount,
                message.minOut,
                partner,
                referrer,
            );
            return;
        }
        Sell => {
            val code = walletLibrary();
            val peer = walletDeployment(code, contract.getAddress(), message.owner);
            assert (peer.calculateArchivedAddress() == in.senderAddress) throw 25;
            var st = loadRuntime();
            val partnerShare = st.tail.preloadUint(16);
            assert (st.initialized) throw 28;
            assert (!st.curve.graduated) throw 29;
            // Declaration order retains the legacy join layout for absent attribution.
            var partnerSnapshot: AttributionSnapshot = { share: null, id: null };
            var referrerSnapshot: AttributionSnapshot = { share: null, id: null };
            var affiliateRate = 0;
            var referrerRate = 0;
            if (message.partner != null) {
                val partner = message.partner!.load();
                val rate = min(partner.share, 500);
                if (message.referrer != null) {
                    val referrer = message.referrer!.load();
                    referrerRate = min(referrer.share, 8000);
                    referrerSnapshot = { share: referrer.share, id: referrer.id };
                }
                partnerSnapshot = { share: partner.share, id: partner.id };
                affiliateRate = rate;
            }
            val feeForTrade = snapshotFee(st.baseFee);
            val rate = referrerRate > 0 ? mulDivFloor(affiliateRate, 5, 6) : affiliateRate;
            val fee = rate + feeForTrade;
            val remaining = st.curve.alpha - st.curve.currentSupply;
            val virtualRaised = st.curve.beta + st.curve.raisedFunds;
            val gross = mulDivFloor(message.amount, virtualRaised, remaining + message.amount);
            val received = mulDivFloor(gross, 10000, 10000 + fee);
            assert (received > 0 && received >= message.minOut) throw 21;
            val raised = st.curve.raisedFunds - gross;
            val circulating = st.curve.currentSupply - message.amount;
            val fees = gross - received;
            val effectiveSplit = referrerRate > 0
                ? mulDivFloor(affiliateRate, 5, 6)
                : affiliateRate;
            val baseFees = mulDivFloor(fees, feeForTrade, effectiveSplit + feeForTrade);
            val protocolFee = mulDivFloor(baseFees, 20, 100);
            val cappedShare = min(partnerShare, 6000);
            val partnerFee = mulDivFloor(baseFees, cappedShare, 10000);
            val affiliateFees = fees - baseFees;
            val fullAffiliateFees = mulDivFloor(affiliateFees, 6, 5);
            val referrerFee = mulDivFloor(fullAffiliateFees, referrerRate, 10000);
            val creatorFee = baseFees - protocolFee - partnerFee;
            val affiliateFee = affiliateFees - referrerFee;
            val updatedCreator = st.creatorFee + creatorFee;
            val updatedPartner = st.partnerFee + partnerFee;
            contract.setData(
                beginCell()
                    .storeBool(st.initialized)
                    .storeSlice(st.migrated as slice)
                    .storeRef(st.config)
                    .storeUint(st.baseFee, 16)
                    .storeBool(st.curve.graduated)
                    .storeCoins(st.curve.alpha)
                    .storeCoins(st.curve.beta)
                    .storeCoins(st.curve.onSellSupply)
                    .storeCoins(raised)
                    .storeCoins(circulating)
                    .storeCoins(st.totalSupply)
                    .storeCoins(updatedCreator)
                    .storeCoins(updatedPartner)
                    .storeSlice(st.tail)
                    .endCell(),
            );
            val none = addressNone();
            val event = beginCell()
                .storeUint(0x3ab0fccc, 32)
                .storeAddress(message.owner)
                .storeCoins(message.amount)
                .storeCoins(received)
                .storeCoins(creatorFee)
                .storeCoins(protocolFee)
                .storeCoins(affiliateFee)
                .storeCoins(referrerFee)
                .storeCoins(circulating)
                .storeCoins(raised)
                .endCell();
            sendRawMessage(
                beginCell()
                    .storeUint(0b1100, 4)
                    .storeSlice(none as slice)
                    .storeUint(1, 98)
                    .storeRef(event)
                    .endCell(),
                1,
            );
            if (affiliateFee > 0) {
                affiliatePayment(
                    1,
                    partnerSnapshot.id!,
                    partnerSnapshot.share!,
                    affiliateFee,
                    message.queryId,
                );
                if (referrerFee > 0) {
                    affiliatePayment(
                        0,
                        referrerSnapshot.id!,
                        referrerSnapshot.share!,
                        referrerFee,
                        message.queryId,
                    );
                }
            }
            val keep = contract.getOriginalBalance() - in.valueCoins - received - affiliateFee -
            referrerFee;
            reserveToncoinsOnBalance(keep, 2);
            sendRawMessage(
                beginCell()
                    .storeUint(0x10, 6)
                    .storeAddress(message.owner)
                    .storeCoins(received)
                    .storeUint(0x66c8ad72, 139)
                    .storeUint(message.queryId, 64)
                    .endCell(),
                17,
            );
            val to = selectAddress(
                message.receiver != null,
                message.receiver as unknown as address,
                message.owner,
            );
            sendRawMessage(
                beginCell()
                    .storeUint(0x10, 6)
                    .storeAddress(to)
                    .storeUint(0xd53276db, 143)
                    .storeUint(message.queryId, 64)
                    .endCell(),
                130,
            );
            return;
        }
        Initialize => {
            var data = contract.getData().beginParse();
            val initialized = data.loadBool();
            val config = data.preloadRef();
            assert (!initialized) throw 24;
            var c = config.beginParse();
            contract.setData(beginCell().storeBool(true).storeSlice(data).endCell());
            reserveToncoinsOnBalance(10000000, 2);
            val creator = c.loadAddress();
            if (message.amount > 0) {
                executeBuy(
                    message.queryId,
                    creator,
                    message.amount,
                    0,
                    message.partner,
                    message.referrer,
                );
            } else {
                sendRawMessage(
                    beginCell()
                        .storeUint(0x10, 6)
                        .storeAddress(creator)
                        .storeUint(0xd53276db, 143)
                        .storeUint(message.queryId, 64)
                        .endCell(),
                    130,
                );
            }
            return;
        }
        ResolveWallet => {
            var wallet: address? = null;
            if (
                message.owner.isPlainStd() &&
                (message.owner as unknown as address).getWorkchain() == 0
            ) {
                val code = walletLibrary();
                val minter = contract.getAddress();
                val owner = checkedStandardOwner(message.owner, message.owner);
                wallet = walletDeployment(
                    code,
                    minter,
                    owner as unknown as address,
                ).calculateArchivedAddress();
            }
            val sender = in.senderAddress;
            val owner = message.includeOwner
                ? beginCell().storeSlice(message.owner as slice).endCell()
                : null;
            sendRawMessage(
                beginCell()
                    .storeUint(0x10, 6)
                    .storeAddress(sender)
                    .storeUint(0xd1735400, 143)
                    .storeUint(message.queryId, 64)
                    .storeAddressOpt(wallet)
                    .storeMaybeRef(owner)
                    .endCell(),
                80,
            );
            return;
        }
        Burn => {
            var data = contract.getData().beginParse();
            val code = walletLibrary();
            val peer = walletDeployment(code, contract.getAddress(), message.owner);
            assert (peer.calculateArchivedAddress() == in.senderAddress) throw 25;
            val flags = data.loadBits(2);
            val config = data.loadRef();
            val fee = data.loadBits(16);
            val graduated = data.loadBool();
            val alpha = data.loadCoins();
            val beta = data.loadCoins();
            val onSell = data.loadCoins();
            val raised = data.loadCoins();
            val current = data.loadCoins();
            val total = data.loadCoins();
            val updated = total - message.amount;
            contract.setData(
                beginCell()
                    .storeSlice(flags)
                    .storeRef(config)
                    .storeSlice(fee)
                    .storeBool(graduated)
                    .storeCoins(alpha)
                    .storeCoins(beta)
                    .storeCoins(onSell)
                    .storeCoins(raised)
                    .storeCoins(current)
                    .storeCoins(updated)
                    .storeSlice(data)
                    .endCell(),
            );
            val to = selectAddress(
                message.receiver != null,
                message.receiver as unknown as address,
                message.owner,
            );
            sendRawMessage(
                beginCell()
                    .storeUint(0x10, 6)
                    .storeAddress(to)
                    .storeUint(0xd53276db, 143)
                    .storeUint(message.queryId, 64)
                    .endCell(),
                66,
            );
            return;
        }
        ClaimCreator => {
            var data = contract.getData().beginParse();
            val flags = data.loadBits(2);
            val config = data.loadRef();
            val fee = data.loadBits(16);
            val graduated = data.loadBool();
            val alpha = data.loadCoins();
            val beta = data.loadCoins();
            val onSell = data.loadCoins();
            val raised = data.loadCoins();
            val current = data.loadCoins();
            val total = data.loadCoins();
            val earned = data.loadCoins();
            val creator = config.beginParse().loadAddress();
            assert (creator == in.senderAddress) throw 25;
            val keep = contract.getOriginalBalance() + contract.getStoragePaidPayment() - earned;
            reserveToncoinsOnBalance(keep - in.valueCoins, 2);
            if (earned > 0) {
                val to = message.to != null ? message.to! : in.senderAddress;
                sendRawMessage(
                    beginCell()
                        .storeUint(0x10, 6)
                        .storeAddress(to)
                        .storeCoins(earned)
                        .storeUint(0x66c8ad72, 139)
                        .storeUint(message.queryId, 64)
                        .endCell(),
                    17,
                );
                contract.setData(
                    beginCell()
                        .storeSlice(flags)
                        .storeRef(config)
                        .storeSlice(fee)
                        .storeBool(graduated)
                        .storeCoins(alpha)
                        .storeCoins(beta)
                        .storeCoins(onSell)
                        .storeCoins(raised)
                        .storeCoins(current)
                        .storeCoins(total)
                        .storeCoins(0)
                        .storeSlice(data)
                        .endCell(),
                );
            }
            val receiver = message.receiver != null ? message.receiver! : in.senderAddress;
            sendRawMessage(
                beginCell()
                    .storeUint(0x10, 6)
                    .storeAddress(receiver)
                    .storeUint(0xd53276db, 143)
                    .storeUint(message.queryId, 64)
                    .endCell(),
                130,
            );
            return;
        }
        ClaimPartner => {
            var data = contract.getData().beginParse();
            val flags = data.loadBits(2);
            val config = data.loadRef();
            val fee = data.loadBits(16);
            val graduated = data.loadBool();
            val alpha = data.loadCoins();
            val beta = data.loadCoins();
            val onSell = data.loadCoins();
            val raised = data.loadCoins();
            val current = data.loadCoins();
            val total = data.loadCoins();
            val creatorFee = data.loadCoins();
            val earned = data.loadCoins();
            val partner = data.preloadRef().beginParse().loadAddress();
            assert (partner == in.senderAddress) throw 25;
            val keep = contract.getOriginalBalance() + contract.getStoragePaidPayment() -
            in.valueCoins -
            earned;
            reserveToncoinsOnBalance(keep, 2);
            if (earned > 0) {
                val to = message.to != null ? message.to! : in.senderAddress;
                sendRawMessage(
                    beginCell()
                        .storeUint(0x10, 6)
                        .storeAddress(to)
                        .storeCoins(earned)
                        .storeUint(0x66c8ad72, 139)
                        .storeUint(message.queryId, 64)
                        .endCell(),
                    17,
                );
                contract.setData(
                    beginCell()
                        .storeSlice(flags)
                        .storeRef(config)
                        .storeSlice(fee)
                        .storeBool(graduated)
                        .storeCoins(alpha)
                        .storeCoins(beta)
                        .storeCoins(onSell)
                        .storeCoins(raised)
                        .storeCoins(current)
                        .storeCoins(total)
                        .storeCoins(creatorFee)
                        .storeCoins(0)
                        .storeSlice(data)
                        .endCell(),
                );
            }
            val receiver = message.receiver != null ? message.receiver! : in.senderAddress;
            sendRawMessage(
                beginCell()
                    .storeUint(0x10, 6)
                    .storeAddress(receiver)
                    .storeUint(0xd53276db, 143)
                    .storeUint(message.queryId, 64)
                    .endCell(),
                130,
            );
            return;
        }
        SweepController => {
            var data = contract.getData().beginParse();
            data.loadUint(1);
            val migrated = data.loadBool();
            val config = data.loadRef();
            data.loadUint(16);
            data.loadBool();
            data.loadCoins();
            data.loadCoins();
            data.loadCoins();
            val raised = data.loadCoins();
            data.loadCoins();
            data.loadCoins();
            val creatorFee = data.loadCoins();
            val partnerFee = data.loadCoins();
            var c = config.beginParse();
            c.loadAddress();
            val controller = c.loadAddress();
            val raising = c.loadCoins();
            assert (in.senderAddress == controller) throw 25;
            val keep = migrated
                ? partnerFee + (10000000 + creatorFee)
                : partnerFee + ((1010000000 + min(raised, raising)) + creatorFee);
            reserveToncoinsOnBalance(keep, 2);
            val to = message.to != null ? message.to! : in.senderAddress;
            sendRawMessage(
                beginCell()
                    .storeUint(0x10, 6)
                    .storeAddress(to)
                    .storeUint(0xd53276db, 143)
                    .storeUint(message.queryId, 64)
                    .endCell(),
                130,
            );
            return;
        }
        PoolInitialized => {
            var data = contract.getData().beginParse();
            val flag = data.loadBits(1);
            data.loadBool();
            val savedTail = data;
            val config = data.loadRef();
            val migration = data.preloadRef();
            var c = config.beginParse();
            var m = migration.beginParse();
            c.loadAddress();
            val controller = c.loadAddress();
            val raising = c.loadCoins();
            val liquidity = c.loadCoins();
            val partner = m.loadAddress();
            val share = m.loadUint(16);
            val fee = m.loadUint(16);
            val owner = m.loadAddress();
            val (code, poolData) = migrationPool(controller, partner, share, fee);
            val hash = archivedStateHash(code, poolData);
            val pool = (beginCell()
                .storeUint(4, 3)
                .storeInt(0, 8)
                .storeUint(hash, 256)
                .takeSlice() as address);
            assert (pool == in.senderAddress) throw 25;
            val amounts = beginCell()
                .storeUint(0xc9a015da, 32)
                .storeCoins(raising)
                .storeCoins(liquidity)
                .storeUint(0x2710, 20)
                .endCell();
            val payout = MigrationPayout {
                owner,
                flags: 0,
                firstPayload: null,
                firstRequired: false,
                recipient: null,
                flags2: 0,
                secondPayload: null,
                secondRequired: false,
                excesses: contract.getAddress(),
            }.toCell();
            val tonAmount = 150000000 + raising;
            val sender = in.senderAddress;
            val tonDeposit = beginCell()
                .storeUint(0xa5a7cbf8, 32)
                .storeUint(message.queryId, 64)
                .storeCoins(raising)
                .storeRef(amounts)
                .storeRef(payout)
                .endCell();
            sendRawMessage(
                beginCell()
                    .storeUint(0x18, 6)
                    .storeAddress(sender)
                    .storeCoins(tonAmount)
                    .storeUint(1, 107)
                    .storeRef(tonDeposit)
                    .endCell(),
                1,
            );
            sendMigrationTokens(200000000, message.queryId, liquidity, amounts, payout);
            contract.setData(
                beginCell().storeSlice(flag).storeBool(true).storeSlice(savedTail).endCell(),
            );
            return;
        }
        Excesses => {
            return;
        }
    }
}
