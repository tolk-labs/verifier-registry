tolk 1.5

import "@stdlib/gas-payments"
import "common/messages"
import "common/sworn"

// Sworn root: TEP-62 NFT collection of lock items, TEP-66 royalty, admin console. It is the one
// trust anchor (lock and till addresses derive from it) and is never on the path of a creation,
// a top-up or a claim: locks are deployed and funded by their creators and pay their fees to tills.
//
// State is fixed-size: no registry, no counters, no record of any lock. A lock's index is the hash
// of its terms, so get_nft_address_by_index derives any lock from its index alone.
//
// The admin can only change fees within hard caps, metadata (CONTENT_DELAY after
// announcing it), pause new locks (via the tills' config), withdraw fees from the tills and its own
// GRAM, and send back what reached the root or a till by mistake. No admin path reaches a lock.
//
// Integrators: a root is genuine only if its address is contractAddress(code, data) for the
// published code and the canonical initial data (admin, fees within caps, the three code cells).

const ERROR_NOT_ADMIN = 501;
const ERROR_FEE_ABOVE_CAP = 502;
const ERROR_INSUFFICIENT_VALUE = 503;
const ERROR_BAD_TILL = 505;
const ERROR_BAD_CONTENT = 510;
const ERROR_WRONG_WORKCHAIN = 511;
const ERROR_RESERVE = 512;
const ERROR_LOCK_NFT = 513;         // a Sworn lock: no admin path moves a lock, whoever owns it
const ERROR_BAD_NFT_STATE = 514;    // the StateInit given does not hash to the NFT's address

// Lock codes of the Sworn versions before this one (testnet only), so that a lock of an older
// version sent to this root or its tills is never moved either
const OLDER_LOCK_CODE_HASHES_1 = 0xbf7c125a349355c82e8f61581a1f4490b03311f4de88cd46fb9f7b6f064238da;
const OLDER_LOCK_CODE_HASHES_2 = 0x20dfe44b58d96a5a712f44ddd2098e9e2dd32da7e6ad6e7da538456a92bc4eed;
const OLDER_LOCK_CODE_HASHES_3 = 0x6858e92c42c97c10ca7b1e2b70f582fb71c8f3af8c9001a4766a6769f11b7026;
const OLDER_LOCK_CODE_HASHES_4 = 0x650fe44f67c462e721a0204fd6540c836d0b83434f8a8444718cf4d9b31a289d;
const OLDER_LOCK_CODE_HASHES_5 = 0x95f046c6c518ebb97d9d468382a8aae8a1728465e3c750a8a7665e85ec59268a;
const OLDER_LOCK_CODE_HASHES_6 = 0xc04354ba755c327a04158dac4c633846b1fdb999a613f84944f7de7a90a6a1fb;
const OLDER_LOCK_CODE_HASHES_7 = 0x1443292306e3f38f80eb2d8f5f1f9de0030dcb2f8f0433fe2aadbbee4e626621;
const OLDER_LOCK_CODE_HASHES_8 = 0x1b003d145464cde80c78469223e1def727a577ed58cfac2128d08cabba0a4ef1;
const OLDER_LOCK_CODE_HASHES_9 = 0x01c0803ff0994e230f9ba8670759a21edc4f0689ba68a2da781fd94e744774e0;
const OLDER_LOCK_CODE_HASHES_10 = 0xc04274428092a19ea613953f180c922a1f138c0d661a38f164c318f4e3f03cce;
const OLDER_LOCK_CODE_HASHES_11 = 0xc512b5f65dd1f9a123acef7a1d79c67028c56a7ef0bf34b37050ba595de599f5;
const OLDER_LOCK_CODE_HASHES_12 = 0xb0269aee564cf2c8226b284be275698afa02aec0b226975b6527fae7ab9f8fec;
const OLDER_LOCK_CODE_HASHES_13 = 0x75c6cdb5d7472677d8f917ee98379ec771400e9860c79ed855ef849513bbe4f0;
const OLDER_LOCK_CODE_HASHES_14 = 0xfb7e0a38a7a903f94db67cdf1cadb87988a0e4120054723883eab601969a1ed0;
// Initial data of a lock of this version and every later one (LockInitData: the collection, an addr_std on
// the basechain, and the 256-bit index, nothing else): so this root never moves a lock of a version it cannot
// know. It starts with addr_std's header: tag 10, no anycast, workchain 0 (11 bits).
const LOCK_INIT_DATA_BITS = 267 + 256;
const LOCK_INIT_DATA_HEAD = 0x400;
const ERROR_UNKNOWN_OP = 0xFFFF;

const ROOT_RESERVE = grams("1");
// WithdrawGrams keeps the root's storage paid this far ahead
const ROOT_STORAGE_HORIZON = 20 * SECONDS_PER_YEAR;
const ROOT_CODE_BITS = 60000;       // allowance for the code next to the counted data
const ROOT_CODE_CELLS = 100;
const MAX_CONTENT_CELLS = 64;       // collection content (admin)
// A metadata change takes effect this long after SetContent: wallets, marketplaces and indexers see
// it coming (the pending content is public), so a compromised admin cannot switch it unnoticed
const CONTENT_DELAY = 3 * 86400;

// ============== Storage ==============

struct RootConfig {
    pendingAdmin: address?
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
    royaltyNumerator: uint16
    royaltyDenominator: uint16
    royaltyDestination: address
}

struct RootCodes {
    transferable: cell
    soulbound: cell
    till: cell
}

struct ContentPair {
    collection: cell                // TEP-64 content of the collection
    itemBaseUri: cell               // single cell: items' content is uri prefix + index
}

struct PendingContent {
    content: Cell<ContentPair>
    effectiveAt: uint48
}

struct RootContent {
    current: Cell<ContentPair>
    pending: Cell<PendingContent>?  // replaces `current` from its effectiveAt on
}

struct RootStorage {
    admin: address
    creationEnabled: bool
    config: Cell<RootConfig>
    codes: Cell<RootCodes>
    content: Cell<RootContent>
}

fun RootStorage.load(): RootStorage {
    return RootStorage.fromCell(contract.getData());
}

fun RootStorage.save(self) {
    contract.setData(self.toCell());
}

fun RootCodes.lockCode(self, index: int): cell {
    return isSoulboundIndex(index) ? self.soulbound : self.transferable;
}

fun lockAddress(codes: RootCodes, index: int): address {
    return lockDeployAddress(codes.lockCode(index), contract.getAddress(), index).calculateAddress();
}

fun tillAddress(codes: RootCodes, n: int): address {
    return tillDeployAddress(codes.till, contract.getAddress(), n).calculateAddress();
}

// Whether `nft` is a Sworn lock, of any version, judged by its StateInit, which must hash to its address
// (a lock's address commits to its code and initial data, so a lock cannot be passed off as anything
// else): the lock code of this version or an older one, or a lock's initial data, which every later
// version keeps
fun isSwornLock(nft: address, nftInit: cell, codes: RootCodes): bool {
    val (wc, hash) = nft.getWorkchainAndHash();
    assert(wc == BASECHAIN && hash == nftInit.hash()) throw ERROR_BAD_NFT_STATE;
    var s = nftInit.beginParse();
    if (s.loadBool()) {
        s.skipBits(5);      // fixed_prefix_length
    }
    if (s.loadBool()) {
        s.skipBits(2);      // special (tick, tock)
    }
    if (!s.loadBool()) {
        return false;       // no code
    }
    val code = s.loadRef().hash();
    if (code == codes.transferable.hash() || code == codes.soulbound.hash()
        || code == OLDER_LOCK_CODE_HASHES_1 || code == OLDER_LOCK_CODE_HASHES_2 || code == OLDER_LOCK_CODE_HASHES_3
        || code == OLDER_LOCK_CODE_HASHES_4 || code == OLDER_LOCK_CODE_HASHES_5 || code == OLDER_LOCK_CODE_HASHES_6
        || code == OLDER_LOCK_CODE_HASHES_7 || code == OLDER_LOCK_CODE_HASHES_8 || code == OLDER_LOCK_CODE_HASHES_9
        || code == OLDER_LOCK_CODE_HASHES_10 || code == OLDER_LOCK_CODE_HASHES_11 || code == OLDER_LOCK_CODE_HASHES_12
        || code == OLDER_LOCK_CODE_HASHES_13 || code == OLDER_LOCK_CODE_HASHES_14) {
        return true;
    }
    if (!s.loadBool()) {
        return false;       // no data
    }
    val data = s.loadRef().beginParse();
    return data.remainingBitsCount() == LOCK_INIT_DATA_BITS && data.remainingRefsCount() == 0
        && data.preloadUint(11) == LOCK_INIT_DATA_HEAD;
}

// The content in force at `now`: the pending one once its time has come
fun RootContent.effective(self, now: int): ContentPair {
    if (self.pending != null) {
        val p = self.pending!!.load();
        if (now >= p.effectiveAt) {
            return p.content.load();
        }
    }
    return self.current.load();
}

// ============== Events ==============

struct (0x53774144) AdminChangedEvent {
    admin: address
}

struct (0x53774353) ContentScheduledEvent {
    effectiveAt: uint48
    content: Cell<ContentPair>
}

fun emitEvent<T>(body: T) {
    createExternalLogMessage({
        dest: createAddressNone(),
        body: body
    }).send(SEND_MODE_REGULAR);
}

// ============== Tills ==============

fun RootStorage.tillConfig(self, config: RootConfig, queryId: uint64): SetTillConfig {
    return {
        queryId: queryId,
        enabled: self.creationEnabled,
        flatFee: config.flatFee,
        topUpFlatFee: config.topUpFlatFee,
        feeBps: config.feeBps
    };
}

// Push the config to every till. Each message carries the till's handler gas; a till that does not
// exist bounces it back (DeployTill creates it). TILL_COUNT messages is exactly the action limit, so
// this transaction emits no event: the tills do.
fun RootStorage.broadcastConfig(self, config: RootConfig, queryId: uint64) {
    val codes = self.codes.load();
    val body = self.tillConfig(config, queryId).toCell();  // one cell, referenced by every message
    val value = tillConfigValue();
    var n = 0;
    repeat (TILL_COUNT) {
        createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            dest: tillAddress(codes, n),
            value: value,
            body: body
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);
        n += 1;
    }
}

// What reached the root by mistake goes back through the wallet or NFT it sits in
fun sendJettonFrom(wallet: address, queryId: uint64, amount: coins, destination: address) {
    createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: wallet,
        value: 0,
        body: JettonTransfer {
            queryId: queryId,
            amount: amount,
            destination: destination,
            responseDestination: destination,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: emptyForwardPayload()
        }
    }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// ============== Messages ==============

type RootMessage =
    | TransferNotification
    | GetRoyaltyParams
    | DeployTill
    | SetFees
    | SetRoyalty
    | SetContent
    | SetCreationEnabled
    | WithdrawTillFees
    | WithdrawTillGrams
    | WithdrawGrams
    | WithdrawRootJetton
    | WithdrawRootNft
    | WithdrawTillNft
    | ProposeAdmin
    | AcceptAdmin
    | Excesses;

// Item base URI: one cell, whole bytes, room for the 0x01 prefix (TEP-64 snake head)
fun isValidItemBaseUri(c: cell): bool {
    val s = c.beginParse();
    return s.remainingRefsCount() == 0 && s.remainingBitsCount() <= 1008 && s.remainingBitsCount() % 8 == 0;
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }
    val msg = lazy RootMessage.fromSlice(in.body);
    var storage = RootStorage.load();

    match (msg) {
        TransferNotification => {
            // Nothing legitimate sends tokens here. Back through the notifying wallet when the GRAM
            // allows (safe whatever that wallet is), with enough for a lock to record them should a
            // lock have sent them; otherwise they stay in that wallet and the admin sends them back
            // (WithdrawRootJetton). The SDK refuses to build a transfer to this address.
            val previousOwner = msg.sender;
            val workchain = in.senderAddress.getWorkchain();
            if (previousOwner != null && in.valueCoins >= lockRefundCost(workchain)) {
                val forward = sendBackForward(in.valueCoins, workchain);
                createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: in.senderAddress,
                    value: 0,
                    body: JettonTransfer {
                        queryId: msg.queryId,
                        amount: msg.amount,
                        destination: previousOwner!!,
                        responseDestination: previousOwner!!,
                        customPayload: null,
                        forwardTonAmount: forward,
                        forwardPayload: emptyForwardPayload()
                    }
                }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
            }
        }

        GetRoyaltyParams => {
            val config = storage.config.load();
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ReportRoyaltyParams {
                    queryId: msg.queryId,
                    numerator: config.royaltyNumerator,
                    denominator: config.royaltyDenominator,
                    destination: config.royaltyDestination
                }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        DeployTill => {
            // Permissionless: the sender pays, and what is attached above the cost stays on the till
            // as its storage balance. A second deploy is a plain config push.
            assert(msg.n < TILL_COUNT) throw ERROR_BAD_TILL;
            assert(in.valueCoins >= deployTillCost()) throw ERROR_INSUFFICIENT_VALUE;
            val codes = storage.codes.load();
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: tillDeployAddress(codes.till, contract.getAddress(), msg.n),
                value: 0,
                body: storage.tillConfig(storage.config.load(), msg.queryId)
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        SetFees => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(msg.flatFee <= MAX_FLAT_FEE && msg.topUpFlatFee <= MAX_FLAT_FEE) throw ERROR_FEE_ABOVE_CAP;
            assert(msg.feeBps <= MAX_FEE_BPS) throw ERROR_FEE_ABOVE_CAP;
            assert(in.valueCoins >= broadcastCost()) throw ERROR_INSUFFICIENT_VALUE;
            var config = storage.config.load();
            config.flatFee = msg.flatFee;
            config.topUpFlatFee = msg.topUpFlatFee;
            config.feeBps = msg.feeBps;
            storage.config = config.toCell();
            storage.save();
            storage.broadcastConfig(config, msg.queryId);
        }

        SetRoyalty => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(msg.denominator > 0) throw ERROR_FEE_ABOVE_CAP;
            assert(msg.numerator * BPS_DENOMINATOR <= msg.denominator * MAX_ROYALTY_BPS) throw ERROR_FEE_ABOVE_CAP;
            var config = storage.config.load();
            config.royaltyNumerator = msg.numerator;
            config.royaltyDenominator = msg.denominator;
            config.royaltyDestination = msg.destination;
            storage.config = config.toCell();
            storage.save();
        }

        SetContent => {
            // takes effect CONTENT_DELAY later; a new SetContent replaces a change not yet in force
            // (the current content again cancels it)
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(isValidItemBaseUri(msg.itemBaseUri)) throw ERROR_BAD_CONTENT;
            val (_, _, _, small) = msg.collectionContent.calculateSize(MAX_CONTENT_CELLS);
            assert(small) throw ERROR_BAD_CONTENT;
            val now = blockchain.now();
            val next = ContentPair { collection: msg.collectionContent, itemBaseUri: msg.itemBaseUri }.toCell();
            val effectiveAt = now + CONTENT_DELAY;
            storage.content = RootContent {
                current: storage.content.load().effective(now).toCell(),
                pending: PendingContent { content: next, effectiveAt: effectiveAt }.toCell()
            }.toCell();
            storage.save();
            emitEvent(ContentScheduledEvent { effectiveAt: effectiveAt, content: next });
        }

        SetCreationEnabled => {
            // stops new locks (the tills attest "disabled" and locks cancel); never claims,
            // top-ups or refunds
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(in.valueCoins >= broadcastCost()) throw ERROR_INSUFFICIENT_VALUE;
            storage.creationEnabled = msg.enabled;
            storage.save();
            storage.broadcastConfig(storage.config.load(), msg.queryId);
        }

        WithdrawTillFees => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(msg.n < TILL_COUNT) throw ERROR_BAD_TILL;
            assert(msg.destination.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert(in.valueCoins >= tillWithdrawCost(msg.wallet.getWorkchain())) throw ERROR_INSUFFICIENT_VALUE;
            createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: tillAddress(storage.codes.load(), msg.n),
                value: 0,
                body: TillWithdrawJetton { queryId: msg.queryId, wallet: msg.wallet, amount: msg.amount, destination: msg.destination }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        WithdrawTillGrams => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(msg.n < TILL_COUNT) throw ERROR_BAD_TILL;
            assert(msg.destination.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: tillAddress(storage.codes.load(), msg.n),
                value: 0,
                body: TillWithdrawGrams { queryId: msg.queryId, amount: msg.amount, destination: msg.destination }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        WithdrawGrams => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            // keep the root's storage paid for decades: the state is fixed-size (three code cells
            // and bounded content), so counting it is bounded too
            val (cells, bits, refs, ok) = contract.getData().calculateSize(1024);
            assert(ok) throw ERROR_RESERVE;
            val reserve = ROOT_RESERVE + storageAdvance(BASECHAIN, ROOT_STORAGE_HORIZON, bits!! + ROOT_CODE_BITS, cells!! + ROOT_CODE_CELLS);
            // getOriginalBalance() includes this message's value, which must not count
            assert(contract.getOriginalBalance() - in.valueCoins >= msg.amount + reserve) throw ERROR_RESERVE;
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: msg.destination,
                value: msg.amount,
                body: Excesses { queryId: msg.queryId }
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);
        }

        WithdrawRootJetton => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(msg.destination.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert(in.valueCoins >= tillWithdrawCost(msg.wallet.getWorkchain())) throw ERROR_INSUFFICIENT_VALUE;
            sendJettonFrom(msg.wallet, msg.queryId, msg.amount, msg.destination);
        }

        WithdrawRootNft => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(msg.newOwner.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert(!isSwornLock(msg.nft, msg.nftInit, storage.codes.load())) throw ERROR_LOCK_NFT;
            createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: msg.nft,
                value: 0,
                body: NftTransfer {
                    queryId: msg.queryId,
                    newOwner: msg.newOwner,
                    responseDestination: msg.newOwner,
                    customPayload: null,
                    forwardAmount: 0,
                    forwardPayload: emptyForwardPayload()
                }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        WithdrawTillNft => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            assert(msg.n < TILL_COUNT) throw ERROR_BAD_TILL;
            assert(msg.newOwner.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            val codes = storage.codes.load();
            assert(!isSwornLock(msg.nft, msg.nftInit, codes)) throw ERROR_LOCK_NFT;
            createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: tillAddress(codes, msg.n),
                value: 0,
                body: TillWithdrawNft { queryId: msg.queryId, nft: msg.nft, newOwner: msg.newOwner }
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        ProposeAdmin => {
            assert(in.senderAddress == storage.admin) throw ERROR_NOT_ADMIN;
            var config = storage.config.load();
            config.pendingAdmin = msg.newAdmin;
            storage.config = config.toCell();
            storage.save();
        }

        AcceptAdmin => {
            var config = storage.config.load();
            assert(config.pendingAdmin != null && in.senderAddress == config.pendingAdmin!!) throw ERROR_NOT_ADMIN;
            storage.admin = in.senderAddress;
            config.pendingAdmin = null;
            storage.config = config.toCell();
            storage.save();
            emitEvent(AdminChangedEvent { admin: in.senderAddress });
        }

        Excesses => {
            // excess GRAM from tills and jetton wallets
        }

        else => {
            throw ERROR_UNKNOWN_OP;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    // a config push to a till that does not exist, a withdrawal a till, a wallet or an NFT refused:
    // nothing to restore
}

// ============== Getters ==============

// TEP-62. Indexes are hashes (even = transferable, odd = soulbound), hence -1.
get fun get_collection_data(): (int, cell, address) {
    val storage = RootStorage.load();
    return (-1, storage.content.load().effective(blockchain.now()).collection, storage.admin);
}

get fun get_nft_address_by_index(index: int): address {
    return lockAddress(RootStorage.load().codes.load(), index);
}

get fun get_nft_content(index: int, individualContent: cell): cell {
    val content = RootStorage.load().content.load().effective(blockchain.now());
    return beginCell()
        .storeUint(0x01, 8)
        .storeSlice(content.itemBaseUri.beginParse())
        .storeRef(individualContent)
        .endCell();
}

// TEP-66
get fun royalty_params(): (int, int, address) {
    val config = RootStorage.load().config.load();
    return (config.royaltyNumerator, config.royaltyDenominator, config.royaltyDestination);
}

struct RootInfo {
    version: int
    admin: address
    pendingAdmin: address?
    creationEnabled: bool
    flatFee: int
    topUpFlatFee: int
    feeBps: int
    maxFlatFee: int
    maxFeeBps: int
    tillCount: int
    transferableCodeHash: int
    soulboundCodeHash: int
    tillCodeHash: int
}

get fun get_root_data(): RootInfo {
    val storage = RootStorage.load();
    val config = storage.config.load();
    val codes = storage.codes.load();
    return {
        version: SWORN_VERSION,
        admin: storage.admin,
        pendingAdmin: config.pendingAdmin,
        creationEnabled: storage.creationEnabled,
        flatFee: config.flatFee,
        topUpFlatFee: config.topUpFlatFee,
        feeBps: config.feeBps,
        maxFlatFee: MAX_FLAT_FEE,
        maxFeeBps: MAX_FEE_BPS,
        tillCount: TILL_COUNT,
        transferableCodeHash: codes.transferable.hash(),
        soulboundCodeHash: codes.soulbound.hash(),
        tillCodeHash: codes.till.hash()
    };
}

// A metadata change announced and not in force yet: (collection content, item base URI, effectiveAt),
// or nulls
get fun get_pending_content(): (cell?, cell?, int) {
    val content = RootStorage.load().content.load();
    if (content.pending == null) {
        return (null, null, 0);
    }
    val p = content.pending!!.load();
    if (blockchain.now() >= p.effectiveAt) {
        return (null, null, 0);
    }
    val pair = p.content.load();
    return (pair.collection, pair.itemBaseUri, p.effectiveAt);
}

get fun get_till_address(n: int): address {
    return tillAddress(RootStorage.load().codes.load(), n);
}

// The till code, to put next to the terms in InitLock
get fun get_till_code(): cell {
    return RootStorage.load().codes.load().till;
}

// GRAM to attach to InitLock for a lock ending at `end` whose creator accepts `maxFlatFee`, whose jetton
// wallet (as its master derives it) lives on `walletWorkchain`
get fun get_create_cost(maxFlatFee: int, permanent: bool, end: int, walletWorkchain: int): int {
    return createCost(maxFlatFee, permanent, end, blockchain.now(), walletWorkchain);
}

// forward_ton_amount of the funding transfer to a lock whose jetton wallet lives on `walletWorkchain`
get fun get_fund_forward(walletWorkchain: int): int {
    return fundForward(walletWorkchain);
}

// GRAM a transfer by a jetton wallet of that workchain needs on top of its forward_ton_amount: TEP-74's
// bound on what it may cost (an app attaches this much plus get_fund_forward to the creator's transfer;
// the rest comes back)
get fun get_jetton_transfer_value(walletWorkchain: int): int {
    return jettonTransferValueOn(walletWorkchain);
}

// GRAM a CancelCreation of a lock whose jetton wallet lives on `walletWorkchain` must carry
get fun get_cancel_cost(walletWorkchain: int): int {
    return cancelCost(walletWorkchain);
}

get fun get_deploy_till_cost(): int {
    return deployTillCost();
}

get fun get_broadcast_cost(): int {
    return broadcastCost();
}

// GRAM a WithdrawTillFees or WithdrawRootJetton through a jetton wallet of that workchain must carry
get fun get_till_withdraw_cost(walletWorkchain: int): int {
    return tillWithdrawCost(walletWorkchain);
}
