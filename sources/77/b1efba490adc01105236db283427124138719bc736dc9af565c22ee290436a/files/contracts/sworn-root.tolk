tolk 1.5

import "common/messages"
import "common/sworn"

// Sworn root: the TEP-62 NFT collection of the locks, their TEP-66 royalty, and the admin's console. It is
// the one trust anchor (lock and till addresses derive from it) and is never on the path of a creation, a
// top-up or a claim: locks are deployed and funded by their creators and pay their fees to tills.
// The message layouts are in common/messages.tolk; the constants, the address derivations and the costs it
// shares with the tills and the locks are in common/sworn.tolk.
//
// State is fixed-size: no registry, no counters, no record of any lock. A lock's index is the hash of its
// terms with its kind in the two low bits, so get_nft_address_by_index derives any lock, of jettons or of
// GRAM, from its index alone.
//
// The admin can only: set the fees and the royalty, within hard caps; change the metadata, in force
// CONTENT_DELAY after it is announced; stop and resume the creation of locks (through the tills' config);
// withdraw the fees the tills hold and the root's own GRAM, each account keeping a reserve of GRAM; send
// away what reached the root or a till by mistake, never a lock; and hand its role to an address that
// accepts it. No admin path reaches a lock.
//
// It spends no GRAM of its own for a message, whoever sends it (rule 1 of common/sworn.tolk): what it pays
// out of its balance, the message has brought, checked before anything is done; only the admin's withdrawal
// of its GRAM takes any out.
//
// Integrators: a root is genuine only if its address is contractAddress(code, data) for the published code
// and the canonical initial data (admin, fees within caps, the five code cells, content).

contract SwornRoot {
    description: "Sworn root: the TEP-62 collection of locks, their royalty, and the admin's console"
    version: "8"
    storage: RootStorage
    incomingMessages: RootMessage
    thrownErrors: RootErrors
}

enum RootErrors {
    NotAdmin = 501          // the sender is not the admin (for AcceptAdmin: not the proposed admin)
    FeeAboveCap = 502       // a fee or the royalty above its cap
    InsufficientValue = 503 // the message carries less GRAM than it needs
    BadTill = 504           // no till has that number
    BadContent = 505        // a collection content too large, or an item base URI not of the form required
    // a destination or a new owner off the basechain, or a jetton wallet on neither the basechain nor the
    // masterchain
    WrongWorkchain = 506
    Reserve = 507           // a withdrawal that would leave the root less than it keeps
    LockNft = 508           // a Sworn lock: no admin path moves a lock, whoever owns it
    BadNftState = 509       // the StateInit given does not hash to the NFT's address
    BadRoyalty = 510        // a royalty with no denominator
    UnknownOp = 0xFFFF      // no handler takes this message
}

// The initial data of a Sworn lock, of this version or any other, are LockInitData and nothing else: the
// collection, an addr_std on the basechain, then the index (LOCK_INIT_DATA_BITS in all). An NFT deployed
// with data of that shape is taken for a lock, so this root never moves a lock of a root it does not know
// either. Such data start with addr_std's header: tag 10, no anycast, workchain 0.
const LOCK_INIT_DATA_HEAD = 0x400
const LOCK_INIT_DATA_HEAD_BITS = 11

// WithdrawRootGrams leaves the root this much, and its storage paid ROOT_STORAGE_HORIZON ahead as every
// advance of storage is (storageAdvance). Every lock's address derives from the root and every app reads
// it, and nothing but its admin's own messages brings it GRAM: at the floor price those twenty years are
// 4.52 GRAM for the 211 408 bits and 516 cells the network charges the root for
// (tests/StorageFloor.spec.ts).
const ROOT_RESERVE = grams("1")
const ROOT_STORAGE_HORIZON = 20 * SECONDS_PER_YEAR
// That storage is priced for the root's data, counted at the withdrawal, plus this allowance for its code,
// which has 28 681 bits in 95 cells (the same test). In all a withdrawal leaves the root 5.90 GRAM at the
// floor price, as the tests deploy it.
const ROOT_CODE_BITS = 60000
const ROOT_CODE_CELLS = 106
// The most cells the root's data are counted to at a withdrawal of its GRAM. They have 425 cells, and 555
// with a content of MAX_CONTENT_CELLS cells in force and another waiting (tests/StorageFloor.spec.ts, which
// holds them to nine tenths of this).
const ROOT_DATA_CELLS_BOUND = 1024
// The most bits an item base URI may have: 126 bytes. get_nft_content writes it after the one-byte tag of
// TEP-64 off-chain content, in the same cell
const MAX_ITEM_BASE_URI_BITS = 126 * 8
// The tag of TEP-64 off-chain content
const OFFCHAIN_CONTENT_TAG = 0x01
// A metadata change takes effect this long after SetContent: wallets, marketplaces and indexers see it
// coming (the pending content is public), so a compromised admin cannot switch it unnoticed
const CONTENT_DELAY = 3 * SECONDS_PER_DAY

// ============== Storage ==============

// What the admin sets besides the content: the address proposed as the next admin (none unless one is
// proposed), the fees pushed to the tills, and the royalty
struct RootConfig {
    pendingAdmin: address?
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
    royaltyNumerator: uint16
    royaltyDenominator: uint16
    royaltyDestination: address
}

// The code of each kind of lock: of jettons or of GRAM, a transferable NFT or soulbound
struct LockCodes {
    transferable: cell
    soulbound: cell
    gramTransferable: cell
    gramSoulbound: cell
}

struct RootCodes {
    locks: Cell<LockCodes>
    till: cell
}

struct ContentPair {
    collection: cell  // TEP-64 content of the collection
    itemBaseUri: cell // one cell: an item's content is this prefix followed by its index
}

struct PendingContent {
    content: Cell<ContentPair>
    effectiveAt: uint48
}

struct RootContent {
    current: Cell<ContentPair>
    pending: Cell<PendingContent>? // replaces `current` from its effectiveAt on
}

struct RootStorage {
    admin: address
    creationEnabled: bool // what the tills attest: a lock attested false cancels its creation
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

// The code of the lock with that index, whose two low bits are its kind
fun LockCodes.ofIndex(self, index: int): cell {
    if (isGramIndex(index)) {
        return isSoulboundIndex(index) ? self.gramSoulbound : self.gramTransferable;
    }
    return isSoulboundIndex(index) ? self.soulbound : self.transferable;
}

// The address of the lock with that index, whether or not it exists
fun lockAddress(codes: RootCodes, index: int): address {
    return lockDeployAddress(
        codes.locks.load().ofIndex(index),
        contract.getAddress(),
        index,
    ).calculateAddress();
}

// The address of till n, whether or not it is deployed
fun tillAddress(codes: RootCodes, n: int): address {
    return tillDeployAddress(codes.till, contract.getAddress(), n).calculateAddress();
}

// Whether `nft` is a Sworn lock, judged by its StateInit, which must hash to its address (a lock's address
// commits to its code and initial data, so a lock cannot be passed off as anything else): the lock code of
// this root, or the initial data a Sworn lock is deployed with, whatever code it runs. Throws BadNftState
// for a StateInit that is not the NFT's, or an NFT off the basechain.
fun isSwornLock(nft: address, nftInit: cell, codes: RootCodes): bool {
    val (wc, hash) = nft.getWorkchainAndHash();
    assert (wc == BASECHAIN && hash == nftInit.hash()) throw RootErrors.BadNftState;
    var s = nftInit.beginParse();
    if (s.loadBool()) {
        s.skipBits(5); // fixed_prefix_length
    }
    if (s.loadBool()) {
        s.skipBits(2); // special (tick, tock)
    }
    if (!s.loadBool()) {
        return false; // no code
    }
    val code = s.loadRef().hash();
    val locks = codes.locks.load();
    if (
        code == locks.transferable.hash() || code == locks.soulbound.hash() ||
        code == locks.gramTransferable.hash() ||
        code == locks.gramSoulbound.hash()
    ) {
        return true;
    }
    if (!s.loadBool()) {
        return false; // no data
    }
    val data = s.loadRef().beginParse();
    return data.remainingBitsCount() == LOCK_INIT_DATA_BITS && data.remainingRefsCount() == 0 &&
        data.preloadUint(LOCK_INIT_DATA_HEAD_BITS) == LOCK_INIT_DATA_HEAD;
}

// The content in force at `now`: the pending one once its time has come
fun RootContent.effective(self, now: int): ContentPair {
    if (self.pending != null) {
        val p = self.pending.load();
        if (now >= p.effectiveAt) {
            return p.content.load();
        }
    }
    return self.current.load();
}

// An item base URI is one cell of whole bytes, MAX_ITEM_BASE_URI_BITS at most
fun isValidItemBaseUri(c: cell): bool {
    val s = c.beginParse();
    return s.remainingRefsCount() == 0 && s.remainingBitsCount() <= MAX_ITEM_BASE_URI_BITS &&
        s.remainingBitsCount() % 8 == 0;
}

// ============== Events ==============
// External messages with no destination, for indexers. Each tag is four ASCII characters: "Sw" for the
// root, then two for the event. Every change of the root's own settings that takes effect has one; a fee or
// a pause is pushed to the tills, which emit theirs (TillConfigChangedEvent).

// A proposed admin accepted the role ("SwAD")
struct (0x53774144) AdminChangedEvent {
    admin: address
}

// SetContent ("SwCS"): the content that replaces the current one from effectiveAt on
struct (0x53774353) ContentScheduledEvent {
    effectiveAt: uint48
    content: Cell<ContentPair>
}

// SetRoyalty ("SwRC"): the royalty in force from then on
struct (0x53775243) RoyaltyChangedEvent {
    numerator: uint16
    denominator: uint16
    destination: address
}

// The workchain of a jetton wallet the admin names for a withdrawal: the basechain or the masterchain, the
// two chains a message can be sent to and the costs have prices for (the rule a lock holds a named account
// to: reachableWorkchain, in lock-base). A wallet on any other workchain is refused (WrongWorkchain) before
// anything is priced or sent: the network would take no transfer for it, and what the request carried would
// end on the root or on a till instead of going back.
fun reachableWalletWorkchain(wallet: address): int {
    val workchain = wallet.getWorkchain();
    assert (workchain == BASECHAIN || workchain == MASTERCHAIN) throw RootErrors.WrongWorkchain;
    return workchain;
}

// ============== Tills ==============

// The config the tills hold and attest: whether creation is enabled, and the fees
fun RootStorage.tillConfig(self, config: RootConfig, queryId: uint64): SetTillConfig {
    return {
        queryId,
        enabled: self.creationEnabled,
        flatFee: config.flatFee,
        topUpFlatFee: config.topUpFlatFee,
        feeBps: config.feeBps,
    };
}

// Pushes the config to every till. Each message carries what the till's handler and its event cost
// (tillConfigValue) and pays its forward fee on top (SEND_MODE_PAY_FEES_SEPARATELY), both out of the value
// the admin attached (broadcastCost). A till that does not exist bounces it back (DeployTill creates the
// till and gives it the config). TILL_COUNT messages is exactly the action limit, so this transaction emits
// no event: the tills do.
fun RootStorage.broadcastConfig(self, config: RootConfig, queryId: uint64) {
    val codes = self.codes.load();
    val body = self.tillConfig(config, queryId).toCell(); // one cell, referenced by every message
    val value = tillConfigValue();
    var n = 0;
    repeat (TILL_COUNT) {
        val configMessage = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            dest: tillAddress(codes, n),
            value,
            body,
        });
        configMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
        n += 1;
    }
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
    | WithdrawTillJetton
    | WithdrawTillGrams
    | WithdrawTillNft
    | WithdrawRootJetton
    | WithdrawRootGrams
    | WithdrawRootNft
    | ProposeAdmin
    | AcceptAdmin
    | Excesses

// Every internal message. Stray tokens, a request for the royalty, DeployTill and plain GRAM come from
// anyone; AcceptAdmin from the proposed admin; everything else only from the admin.
fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return; // plain GRAM stays in the root
    }
    val msg = lazy RootMessage.fromSlice(in.body);
    var storage = RootStorage.load();

    // The value of a message stays in the root unless its handler sends it on
    match (msg) {
        TransferNotification => {
            // Nothing legitimate sends tokens here. When the notifying wallet names their sender and the
            // notification's GRAM covers a transfer (sendBackCost), they go back to that sender through
            // that wallet, with a notification when the GRAM covers that too (sendBackForward), so that a
            // lock that sent them records them. The transfer carries what is left of the notification's
            // value and no more, and cannot bounce: whatever the notifying wallet is, it is sent no more
            // GRAM than it brought; should it fail to be sent, it is dropped (SEND_MODE_IGNORE_ERRORS). In
            // every other case the tokens stay in that wallet, for the admin to send back
            // (WithdrawRootJetton), and the notification's GRAM stays in the root. The SDK refuses to build
            // a transfer to this address.
            sendBackUncredited(in.senderAddress, in.valueCoins, msg, msg.queryId);
        }

        GetRoyaltyParams => {
            // TEP-66: the royalty, to whoever asks, on the request's own value, which must cover the answer
            // (get_answer_cost of the asker's chain). The rule of the requests a lock answers.
            assert (
                in.valueCoins >= rootAnswerCost(in.senderAddress.getWorkchain())
            ) throw RootErrors.InsufficientValue;
            val config = storage.config.load();
            val royaltyMessage = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ReportRoyaltyParams {
                    queryId: msg.queryId,
                    numerator: config.royaltyNumerator,
                    denominator: config.royaltyDenominator,
                    destination: config.royaltyDestination,
                },
            });
            royaltyMessage.send(ON_REQUEST_VALUE);
        }

        DeployTill => {
            // Anyone may deploy a till: the sender pays (get_deploy_till_cost at least; rule 2 of
            // common/sworn.tolk). All that is left of the value goes to the till with its code, its initial
            // data and the current config, and stays there as its storage balance; the message cannot
            // bounce, so that GRAM is the till's whatever happens. Sent for a till that exists, it is a
            // plain config push.
            assert (msg.n < TILL_COUNT) throw RootErrors.BadTill;
            assert (in.valueCoins >= deployTillCost()) throw RootErrors.InsufficientValue;
            val codes = storage.codes.load();
            val deployMessage = createMessage({
                bounce: BounceMode.NoBounce,
                dest: tillDeployAddress(codes.till, contract.getAddress(), msg.n),
                value: 0,
                body: storage.tillConfig(storage.config.load(), msg.queryId),
            });
            deployMessage.send(ON_REQUEST_VALUE);
        }

        SetFees => {
            // The admin sets the fees, within the caps, and pushes them to every till in this same
            // transaction: the value must cover that (get_broadcast_cost)
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (
                msg.flatFee <= MAX_FLAT_FEE && msg.topUpFlatFee <= MAX_FLAT_FEE
            ) throw RootErrors.FeeAboveCap;
            assert (msg.feeBps <= MAX_FEE_BPS) throw RootErrors.FeeAboveCap;
            assert (in.valueCoins >= broadcastCost()) throw RootErrors.InsufficientValue;
            var config = storage.config.load();
            config.flatFee = msg.flatFee;
            config.topUpFlatFee = msg.topUpFlatFee;
            config.feeBps = msg.feeBps;
            storage.config = config.toCell();
            storage.save();
            storage.broadcastConfig(config, msg.queryId);
        }

        SetRoyalty => {
            // The TEP-66 royalty, MAX_ROYALTY_BPS of a sale at most. The message must carry what the
            // handler and its event cost (get_setting_cost): the event is paid out of the balance (rule 1
            // of common/sworn.tolk).
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (msg.denominator > 0) throw RootErrors.BadRoyalty;
            assert (
                msg.numerator * BPS_DENOMINATOR <= msg.denominator * MAX_ROYALTY_BPS
            ) throw RootErrors.FeeAboveCap;
            assert (in.valueCoins >= rootSettingCost()) throw RootErrors.InsufficientValue;
            var config = storage.config.load();
            config.royaltyNumerator = msg.numerator;
            config.royaltyDenominator = msg.denominator;
            config.royaltyDestination = msg.destination;
            storage.config = config.toCell();
            storage.save();
            emitEvent(RoyaltyChangedEvent {
                numerator: msg.numerator,
                denominator: msg.denominator,
                destination: msg.destination,
            });
        }

        SetContent => {
            // The new content takes effect CONTENT_DELAY later and is public meanwhile (the event,
            // get_pending_content). A SetContent sent before then replaces the change not yet in force:
            // sending the current content again cancels it. The message must carry what the handler and its
            // event, which carries the content, cost (get_setting_cost).
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (isValidItemBaseUri(msg.itemBaseUri)) throw RootErrors.BadContent;
            val (_, _, _, small) = msg.collectionContent.calculateSize(MAX_CONTENT_CELLS);
            assert (small) throw RootErrors.BadContent;
            assert (in.valueCoins >= rootSettingCost()) throw RootErrors.InsufficientValue;
            val now = blockchain.now();
            val next = ContentPair {
                collection: msg.collectionContent,
                itemBaseUri: msg.itemBaseUri,
            }.toCell();
            val effectiveAt = now + CONTENT_DELAY;
            storage.content = RootContent {
                current: storage.content.load().effective(now).toCell(),
                pending: PendingContent {
                    content: next,
                    effectiveAt,
                }.toCell(),
            }.toCell();
            storage.save();
            emitEvent(ContentScheduledEvent {
                effectiveAt,
                content: next,
            });
        }

        SetCreationEnabled => {
            // Stops or resumes the creation of locks: the tills attest it, and a lock whose attestation
            // says disabled cancels. It never stops claims, top-ups or refunds, which ask no till. The
            // value must cover the push to every till, as for SetFees.
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (in.valueCoins >= broadcastCost()) throw RootErrors.InsufficientValue;
            storage.creationEnabled = msg.enabled;
            storage.save();
            storage.broadcastConfig(storage.config.load(), msg.queryId);
        }

        WithdrawTillJetton => {
            // Tokens out of one of till n's jetton wallets, to `destination`. The till makes the transfer
            // on all that is left of this message's value, which must cover both handlers and the transfer,
            // priced on the wallet's chain (get_withdraw_jetton_cost; rule 2 of common/sworn.tolk).
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (msg.n < TILL_COUNT) throw RootErrors.BadTill;
            assert (msg.destination.getWorkchain() == BASECHAIN) throw RootErrors.WrongWorkchain;
            val walletWorkchain = reachableWalletWorkchain(msg.wallet);
            assert (
                in.valueCoins >= withdrawJettonCost(walletWorkchain)
            ) throw RootErrors.InsufficientValue;
            val tillMessage = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: tillAddress(storage.codes.load(), msg.n),
                value: 0,
                body: TillWithdrawJetton {
                    queryId: msg.queryId,
                    wallet: msg.wallet,
                    amount: msg.amount,
                    destination: msg.destination,
                },
            });
            tillMessage.send(ON_REQUEST_VALUE);
        }

        WithdrawTillGrams => {
            // GRAM out of till n, to `destination`: the till keeps its own reserve and refuses a withdrawal
            // that would leave less. The request travels on all that is left of this message's value, which
            // must cover both handlers, the request and the withdrawal's forward fee, which the till pays
            // on top of the amount (get_withdraw_grams_cost; rule 2 of common/sworn.tolk).
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (msg.n < TILL_COUNT) throw RootErrors.BadTill;
            assert (msg.destination.getWorkchain() == BASECHAIN) throw RootErrors.WrongWorkchain;
            assert (in.valueCoins >= withdrawGramsCost()) throw RootErrors.InsufficientValue;
            val tillMessage = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: tillAddress(storage.codes.load(), msg.n),
                value: 0,
                body: TillWithdrawGrams {
                    queryId: msg.queryId,
                    amount: msg.amount,
                    destination: msg.destination,
                },
            });
            tillMessage.send(ON_REQUEST_VALUE);
        }

        WithdrawTillNft => {
            // An NFT that till n owns by mistake, to `newOwner`: the till makes the transfer, on all that
            // is left of this message's value, which must cover both handlers, the request and the transfer
            // (get_withdraw_nft_cost). Never a Sworn lock (isSwornLock): no admin path moves a lock.
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (msg.n < TILL_COUNT) throw RootErrors.BadTill;
            assert (msg.newOwner.getWorkchain() == BASECHAIN) throw RootErrors.WrongWorkchain;
            val codes = storage.codes.load();
            assert (!isSwornLock(msg.nft, msg.nftInit, codes)) throw RootErrors.LockNft;
            assert (in.valueCoins >= withdrawNftCost()) throw RootErrors.InsufficientValue;
            val tillMessage = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: tillAddress(codes, msg.n),
                value: 0,
                body: TillWithdrawNft {
                    queryId: msg.queryId,
                    nft: msg.nft,
                    newOwner: msg.newOwner,
                },
            });
            tillMessage.send(ON_REQUEST_VALUE);
        }

        WithdrawRootJetton => {
            // Tokens that reached one of the root's jetton wallets by mistake, to `destination`, on this
            // message's value, which must cover the transfer on the wallet's chain
            // (get_withdraw_jetton_cost)
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (msg.destination.getWorkchain() == BASECHAIN) throw RootErrors.WrongWorkchain;
            val walletWorkchain = reachableWalletWorkchain(msg.wallet);
            assert (
                in.valueCoins >= withdrawJettonCost(walletWorkchain)
            ) throw RootErrors.InsufficientValue;
            sendWithdrawnJetton(msg.wallet, msg.queryId, msg.amount, msg.destination);
        }

        WithdrawRootGrams => {
            // GRAM out of the root, to `destination`, an account on the basechain. The root keeps
            // ROOT_RESERVE and its storage for ROOT_STORAGE_HORIZON, priced for its data as they are
            // (fixed-size: five code cells and bounded content, so counting them is bounded too) plus the
            // allowance for its own code. The message must carry what this handler and the withdrawal's
            // forward fee cost (get_withdraw_grams_cost), so that the root is left with all it keeps and
            // what it does not withdraw: `amount` leaves, and nothing else of the root's.
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (msg.destination.getWorkchain() == BASECHAIN) throw RootErrors.WrongWorkchain;
            assert (in.valueCoins >= withdrawGramsCost()) throw RootErrors.InsufficientValue;
            val (cells, bits, _refs, ok) = contract.getData().calculateSize(ROOT_DATA_CELLS_BOUND);
            assert (ok) throw RootErrors.Reserve;
            val reserve = ROOT_RESERVE +
                storageAdvance(
                    BASECHAIN,
                    ROOT_STORAGE_HORIZON,
                    bits! + ROOT_CODE_BITS,
                    cells! + ROOT_CODE_CELLS,
                );
            // getOriginalBalance() includes this message's value, which must not count
            assert (
                contract.getOriginalBalance() - in.valueCoins >= msg.amount + reserve
            ) throw RootErrors.Reserve;
            sendWithdrawnGrams(msg.destination, msg.queryId, msg.amount);
        }

        WithdrawRootNft => {
            // An NFT that the root owns by mistake, to `newOwner`, on this message's value, which must
            // cover the transfer (get_withdraw_nft_cost). Never a Sworn lock, as for a till's.
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            assert (msg.newOwner.getWorkchain() == BASECHAIN) throw RootErrors.WrongWorkchain;
            assert (
                !isSwornLock(msg.nft, msg.nftInit, storage.codes.load())
            ) throw RootErrors.LockNft;
            assert (in.valueCoins >= withdrawNftCost()) throw RootErrors.InsufficientValue;
            sendWithdrawnNft(msg.nft, msg.queryId, msg.newOwner);
        }

        ProposeAdmin => {
            // First step of a handover: the admin names the next admin, or none to withdraw a proposal.
            // Nothing changes until that address accepts, so a proposal has no event: the handover has one,
            // when it is accepted (AdminChangedEvent).
            assert (in.senderAddress == storage.admin) throw RootErrors.NotAdmin;
            var config = storage.config.load();
            config.pendingAdmin = msg.newAdmin;
            storage.config = config.toCell();
            storage.save();
        }

        AcceptAdmin => {
            // Second step: the proposed address takes the role, which shows it can send messages. Its
            // message must carry what the handler and its event cost (get_setting_cost).
            var config = storage.config.load();
            assert (
                config.pendingAdmin != null && in.senderAddress == config.pendingAdmin
            ) throw RootErrors.NotAdmin;
            assert (in.valueCoins >= rootSettingCost()) throw RootErrors.InsufficientValue;
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
            throw RootErrors.UnknownOp;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {
    // a config push to a till that does not exist, a withdrawal a till, a wallet or an NFT refused: nothing
    // to restore, and the GRAM that comes back stays in the root
}

// ============== Get methods ==============

// TEP-62: (next_item_index, collection_content, owner_address). Indexes are hashes (their two low bits the
// kind of lock), not a sequence, hence -1; the owner is the admin.
get fun get_collection_data(): (int, cell, address) {
    val storage = RootStorage.load();
    return (-1, storage.content.load().effective(blockchain.now()).collection, storage.admin);
}

// TEP-62: the address of the lock with that index, whether or not it exists. A lock is genuine only if its
// address is the one this returns for its index.
get fun get_nft_address_by_index(index: int): address {
    return lockAddress(RootStorage.load().codes.load(), index);
}

// TEP-62: an item's whole content: the tag of TEP-64 off-chain content, the item base URI, then, in a ref,
// the item's individual content (a lock's is its index in decimal)
get fun get_nft_content(_index: int, individualContent: cell): cell {
    val content = RootStorage.load().content.load().effective(blockchain.now());
    return beginCell()
        .storeUint(OFFCHAIN_CONTENT_TAG, 8)
        .storeSlice(content.itemBaseUri.beginParse())
        .storeRef(individualContent)
        .endCell();
}

// TEP-66: (numerator, denominator, destination)
get fun royalty_params(): (int, int, address) {
    val config = RootStorage.load().config.load();
    return (config.royaltyNumerator, config.royaltyDenominator, config.royaltyDestination);
}

// What get_root_data returns
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
    gramTransferableCodeHash: int
    gramSoulboundCodeHash: int
    tillCodeHash: int
}

// What identifies this root and its settings: the version, the admin and the address proposed to replace
// it, whether creation is enabled, the fees and their caps, the number of tills and the hashes of the five
// codes
get fun get_root_data(): RootInfo {
    val storage = RootStorage.load();
    val config = storage.config.load();
    val codes = storage.codes.load();
    val locks = codes.locks.load();
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
        transferableCodeHash: locks.transferable.hash(),
        soulboundCodeHash: locks.soulbound.hash(),
        gramTransferableCodeHash: locks.gramTransferable.hash(),
        gramSoulboundCodeHash: locks.gramSoulbound.hash(),
        tillCodeHash: codes.till.hash(),
    };
}

// A metadata change announced and not in force yet: (collection content, item base URI, effectiveAt), or
// (null, null, 0) when there is none
get fun get_pending_content(): (cell?, cell?, int) {
    val content = RootStorage.load().content.load();
    if (content.pending == null) {
        return (null, null, 0);
    }
    val p = content.pending.load();
    if (blockchain.now() >= p.effectiveAt) {
        return (null, null, 0);
    }
    val pair = p.content.load();
    return (pair.collection, pair.itemBaseUri, p.effectiveAt);
}

// The address of till n, whether or not it is deployed
get fun get_till_address(n: int): address {
    return tillAddress(RootStorage.load().codes.load(), n);
}

// The till code, to put next to the terms in InitLock or InitGramLock
get fun get_till_code(): cell {
    return RootStorage.load().codes.load().till;
}

// GRAM to attach to InitLock for a lock ending at `end` whose creator accepts `maxFlatFee`, whose jetton
// wallet (as its master derives it) lives on `walletWorkchain`: 0 for the basechain, -1 for the
// masterchain. A lock refuses to be created with a wallet on any other workchain, whatever is quoted for
// it.
get fun get_create_cost(maxFlatFee: int, permanent: bool, end: int, walletWorkchain: int): int {
    return createCost(maxFlatFee, permanent, end, blockchain.now(), walletWorkchain);
}

// GRAM to attach to InitGramLock on top of the GRAM to lock, for a lock of GRAM ending at `end` whose
// creator accepts `maxFlatFee`
get fun get_gram_create_cost(maxFlatFee: int, permanent: bool, end: int): int {
    return gramCreateCost(maxFlatFee, permanent, end, blockchain.now());
}

// forward_ton_amount of the funding transfer to a lock whose jetton wallet lives on `walletWorkchain`
get fun get_fund_forward(walletWorkchain: int): int {
    return fundForward(walletWorkchain);
}

// GRAM a transfer by a jetton wallet of that workchain needs on top of its forward_ton_amount: TEP-74's
// bound on what it may cost (an app attaches this much plus get_fund_forward to the creator's transfer; the
// rest comes back)
get fun get_jetton_transfer_value(walletWorkchain: int): int {
    return jettonTransferValueOn(walletWorkchain);
}

// GRAM a DeployTill must carry at least
get fun get_deploy_till_cost(): int {
    return deployTillCost();
}

// GRAM a SetFees or a SetCreationEnabled must carry
get fun get_broadcast_cost(): int {
    return broadcastCost();
}

// GRAM a WithdrawTillJetton or WithdrawRootJetton through a jetton wallet of that workchain must carry
get fun get_withdraw_jetton_cost(walletWorkchain: int): int {
    return withdrawJettonCost(walletWorkchain);
}

// GRAM a WithdrawTillGrams or WithdrawRootGrams must carry
get fun get_withdraw_grams_cost(): int {
    return withdrawGramsCost();
}

// GRAM a WithdrawTillNft or WithdrawRootNft must carry
get fun get_withdraw_nft_cost(): int {
    return withdrawNftCost();
}

// GRAM a SetRoyalty, a SetContent or an AcceptAdmin must carry
get fun get_setting_cost(): int {
    return rootSettingCost();
}

// GRAM a GetRoyaltyParams must carry, which the root answers on the request's own value. `workchain` is
// the asker's: 0, or -1 for the masterchain, whose prices are those of any chain but the basechain.
get fun get_answer_cost(workchain: int): int {
    return rootAnswerCost(workchain);
}

// The version of the Sworn contracts this code is part of
get fun get_sworn_version(): int {
    return SWORN_VERSION;
}
