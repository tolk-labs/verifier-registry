import "trade_types"

contract TradeFactory {
    author: "Tradegram"
    version: "0.1.0"
    description: "Factory for two-party Tradegram escrow rooms"
    storage: TradeFactoryStorage
    incomingMessages: FactoryMessage
}

type FactoryMessage =
    | CreateTrade
    | SweepFactoryDust
    | AddCollection
    | AddCollections
    | RemoveCollection
    | TransferOwnership

// V4-3: an allowlist entry whose schema the escrow does not implement would fall through the recompute's
// else-branch and be treated as STANDARD, so a typo'd schema silently produces a collection that can be
// deposited only by accident — or, worse, one whose items authenticate under the wrong layout. Neither
// is a state worth storing. Shared by the single and batch add paths so they cannot diverge.
fun assertKnownSchema(schema: uint8) {
    assert (
        schema == NFT_SCHEMA_STANDARD || schema == NFT_SCHEMA_TELEMINT
    ) throw TradeErrors.UnknownNftSchema;
}

// V5-3 (CR-2026-07-22-L1): `addrWorkchain` used to live here, hand-parsing addr_std with a FIXED
// 3-bit skip for "tag + anycast flag". That is only correct when the anycast flag is 0. `Maybe Anycast`
// is variable-length — a present anycast carries depth + rewrite_pfx after the flag — so an
// anycast-prefixed address had its workchain read out of the wrong bits.
//
// Deleted rather than fixed. Tolk's stdlib already exposes `address.getWorkchain()`, which is the TVM
// primitive REWRITESTDADDR: it parses addr_std and APPLIES the anycast rewrite by design. Replacing
// hand-rolled bit manipulation in a validation path with a purpose-built primitive is strictly less
// code and strictly less risk. See v5-plan.md §6b.

// sweepableBalance + sendTon are shared helpers defined in trade_types.tolk (S-1).

fun allowedCollectionCount(collections: map<address, CollectionEntry>): int {
    var count = 0;
    var entry = collections.findFirst();
    while (entry.isFound) {
        count += 1;
        entry = collections.iterateNext(entry);
    }
    return count;
}

fun allowedCollectionAt(collections: map<address, CollectionEntry>, index: int): address {
    assert (index >= 0) throw TradeErrors.InvalidAmount;

    var current = 0;
    var entry = collections.findFirst();
    while (entry.isFound) {
        if (current == index) {
            return entry.getKey();
        }
        current += 1;
        entry = collections.iterateNext(entry);
    }

    assert (false) throw TradeErrors.InvalidAmount;
    return contract.getAddress();
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    val msg = lazy FactoryMessage.fromSlice(in.body);

    match (msg) {
        CreateTrade => {
            assert (msg.userA != msg.userB) throw TradeErrors.SameUsers;
            // M-06: both participants must be on workchain 0. Masterchain (-1) addresses incur higher
            // forward fees, can behave unexpectedly with some TON tooling, and are never valid user wallets.
            // V5-3: `getWorkchain()` is the TVM primitive REWRITESTDADDR, which applies the anycast
            // rewrite as part of parsing — unlike the hand-rolled bit-skip it replaces.
            assert (msg.userA.getWorkchain() == 0) throw TradeErrors.InvalidMessage;
            assert (msg.userB.getWorkchain() == 0) throw TradeErrors.InvalidMessage;
            // H-02: the sender must be one of the two named participants. This blocks deploying an
            // escrow between two addresses the sender controls neither of. It does NOT stop an
            // attacker from naming themselves as one side and an arbitrary victim as the other —
            // targeted spam/phishing rooms aimed at a specific victim remain possible on-chain (as
            // they inherently are on TON, where anyone may deploy a contract naming anyone), and must
            // be handled off-chain. Nothing is at risk on-chain: the victim never deposits. The app
            // always sends CreateTrade from the creator's own wallet, which is userA, so this never
            // blocks a real creation.
            assert (
                in.senderAddress == msg.userA || in.senderAddress == msg.userB
            ) throw TradeErrors.NotParticipant;
            assert (msg.deployValue >= MIN_ESCROW_DEPLOY_VALUE) throw TradeErrors.InvalidAmount;
            assert (
                in.valueCoins >= msg.deployValue + MIN_CREATE_TRADE_VALUE
            ) throw TradeErrors.InsufficientMessageValue;

            var storage = lazy TradeFactoryStorage.load();
            val tradeId = storage.nextTradeId;
            val escrowStorage = TradeEscrowStorage {
                tradeId,
                factory: contract.getAddress(),
                feeRecipient: storage.owner,
                participants: TradeParticipants {
                    userA: msg.userA,
                    userB: msg.userB,
                }.toCell(),
                acceptedA: false,
                acceptedB: false,
                depositedTonA: 0,
                depositedTonB: 0,
                assets: TradeAssets {
                    nftA: [],
                    nftB: [],
                    nftCountA: 0,
                    nftCountB: 0,
                    pendingReturns: [],
                }.toCell(),
                status: TRADE_STATUS_OPEN,
                // Set when settlement/refund begins; 0 at deploy keeps the escrow address independent
                // of creation time (see TradeEscrowStorage / H-01).
                statusChangedAt: 0,
                // Set on the first participant action; 0 until then (M-03 expiry clock).
                lastActivityAt: 0,
                // Snapshot the current allowlist so each escrow authenticates deposits independently
                // of later factory changes — a trade's tradable collections are fixed at creation.
                allowedCollections: storage.allowedCollections,
            };
            val stateInit = ContractState {
                code: storage.escrowCode,
                data: escrowStorage.toCell(),
            };

            createMessage({
                bounce: BounceMode.NoBounce,
                value: msg.deployValue,
                dest: { stateInit },
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);

            storage.nextTradeId += 1;
            storage.save();
        }
        SweepFactoryDust => {
            val storage = lazy TradeFactoryStorage.load();
            assert (in.senderAddress == storage.owner) throw TradeErrors.NotOwner;
            val amount = sweepableBalance(in.valueCoins, MIN_FACTORY_DUST_RESERVE);
            assert (amount > 0) throw TradeErrors.NothingToSweep;
            sendTon(storage.owner, amount);
            sendTon(in.senderAddress, in.valueCoins);
        }
        AddCollection => {
            var storage = lazy TradeFactoryStorage.load();
            assert (in.senderAddress == storage.owner) throw TradeErrors.NotOwner;
            assertKnownSchema(msg.schema);
            storage
                .allowedCollections
                .set(
                    msg.collection,
                    CollectionEntry {
                        schema: msg.schema,
                        itemCode: msg.itemCode,
                    },
                );
            storage.save();
        }
        AddCollections => {
            // V4-3: the batch form. Identical per-entry semantics to AddCollection above — same owner
            // check, same schema validation, same set() — just applied to a map in one transaction.
            // A throw anywhere in the loop reverts the whole transaction, so a batch containing one bad
            // entry commits none of it; there is no partial-apply state to reason about.
            var storage = lazy TradeFactoryStorage.load();
            assert (in.senderAddress == storage.owner) throw TradeErrors.NotOwner;

            var count = 0;
            var entry = msg.entries.findFirst();
            while (entry.isFound) {
                val collection = entry.getKey();
                val value = entry.loadValue();
                assertKnownSchema(value.schema);
                storage.allowedCollections.set(collection, value);
                count += 1;
                entry = msg.entries.iterateNext(entry);
            }

            assert (count > 0) throw TradeErrors.EmptyBatch;
            storage.save();
        }
        RemoveCollection => {
            var storage = lazy TradeFactoryStorage.load();
            assert (in.senderAddress == storage.owner) throw TradeErrors.NotOwner;
            storage.allowedCollections.delete(msg.collection);
            storage.save();
        }
        TransferOwnership => {
            var storage = lazy TradeFactoryStorage.load();
            assert (in.senderAddress == storage.owner) throw TradeErrors.NotOwner;
            assert (msg.newOwner != storage.owner) throw TradeErrors.SameUsers;
            storage.owner = msg.newOwner;
            storage.save();
        }
        else => {
            assert (in.body.isEmpty()) throw TradeErrors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {}

get fun getNextTradeId(): uint64 {
    val storage = lazy TradeFactoryStorage.load();
    return storage.nextTradeId;
}

get fun isCollectionAllowed(collection: address): bool {
    val storage = lazy TradeFactoryStorage.load();
    return storage.allowedCollections.exists(collection);
}

get fun getAllowedCollections(): map<address, CollectionEntry> {
    val storage = lazy TradeFactoryStorage.load();
    return storage.allowedCollections;
}

get fun getAllowedCollectionCount(): int {
    val storage = lazy TradeFactoryStorage.load();
    return allowedCollectionCount(storage.allowedCollections);
}

get fun getAllowedCollectionAt(index: int): address {
    val storage = lazy TradeFactoryStorage.load();
    return allowedCollectionAt(storage.allowedCollections, index);
}

get fun getAllowedCollectionInfo(index: int): (address, uint256) {
    val storage = lazy TradeFactoryStorage.load();
    val collection = allowedCollectionAt(storage.allowedCollections, index);
    return (collection, storage.allowedCollections.mustGet(collection).itemCode.hash());
}

get fun getAllowedCollectionItemCodeHash(collection: address): uint256 {
    val storage = lazy TradeFactoryStorage.load();
    return storage.allowedCollections.mustGet(collection).itemCode.hash();
}

// Item address-recompute schema registered for a collection (NFT_SCHEMA_STANDARD / NFT_SCHEMA_TELEMINT).
// Lets the indexer/SDK build a deposit's forward payload at the correct index width.
get fun getAllowedCollectionSchema(collection: address): uint8 {
    val storage = lazy TradeFactoryStorage.load();
    return storage.allowedCollections.mustGet(collection).schema;
}

get fun getOwner(): address {
    val storage = lazy TradeFactoryStorage.load();
    return storage.owner;
}

// I-05: numeric code version so the indexer can route by version after a code upgrade.
get fun getVersion(): uint16 {
    return CONTRACT_VERSION;
}

get fun getConfig(): EscrowConfig {
    return {
        minTradeActionValue: MIN_TRADE_ACTION_VALUE,
        nftTransferValue: NFT_TRANSFER_VALUE,
        minEscrowDeployValue: MIN_ESCROW_DEPLOY_VALUE,
        minCreateTradeValue: MIN_CREATE_TRADE_VALUE,
        maxNftsPerSide: MAX_NFTS_PER_SIDE,
        tradeFeeBps: TRADE_FEE_BPS,
        stuckSettlementTimeout: STUCK_SETTLEMENT_TIMEOUT,
        openTradeTimeout: OPEN_TRADE_TIMEOUT,
    };
}
