import "constants"
import "errors"
import "messages"
import "types"

contract VanityItem {
    author: "TON Vanity"
    version: "2.0.0"
    description: "NFT item (TEP-62) that is also a smart account controlled by the NFT holder; holder-only opt-in upgrades"
    storage: ItemStorage
    storageAtDeployment: ItemInitData
    incomingMessages: AllowedMessageToItem
}

type AllowedMessageToItem =
    | Transfer
    | RequestStaticData
    | MirrorExec
    | SetForwarding
    | SetClaim
    | UpgradeItem
    | InstallItemCode
    | MigrateItem
    | TextComment
    | ItemInit
    | JettonTransferNotification
    | OwnershipAssigned
    | Excesses

fun onInternalMessage(in: InMessage) {
    var loader = ItemStorage.startLoading();

    if (!loader.isInitialized()) {
        // Before the collection initializes the item, only the collection's init is meaningful.
        // Anything else (e.g. someone deploying the same StateInit early, or a top-up) is accepted
        // silently: TON stays on the address and goes to the future owner.
        if (in.senderAddress == loader.collection) {
            initialize(loader.collection, loader.index, ItemInit.fromSlice(in.body));
        }
        return;
    }

    var storage = loader.endLoading();

    if (in.body.isEmpty()) {
        forwardIfEnabled(storage, in.senderAddress, in.valueCoins);
        return;
    }

    val msg = lazy AllowedMessageToItem.fromSlice(in.body);

    match (msg) {
        MirrorExec => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            executeMirrorActions(msg.actions);
        }

        Transfer => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            transferOwnership(mutate storage, msg, in.valueCoins, in.originalForwardFee);
        }

        SetForwarding => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            storage.forwarding = msg.enabled;
            storage.save();
        }

        SetClaim => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            val (_, myHash) = contract.getAddress().getWorkchainAndHash();
            assert (msg.claim.load().isTrueFor(myHash)) throw Errors.InvalidClaim;
            storage.claim = msg.claim;
            storage.save();
        }

        UpgradeItem => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            assert (in.valueCoins >= ITEM_UPGRADE_ALLOWANCE) throw Errors.NotEnoughValue;
            // Remember what the holder signed: only this exact code will be installed.
            storage.upgradeRequest = ItemUpgradeRequest { codeHash: msg.codeHash }.toCell();
            storage.save();
            val request = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: storage.collection,
                value: 0,
                body: RequestItemCode {
                    queryId: msg.queryId,
                    index: storage.index,
                    codeHash: msg.codeHash,
                },
            });
            request.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        InstallItemCode => {
            assert (in.senderAddress == storage.collection) throw Errors.NotFromCollection;
            // The collection alone can't push code: it must be the hash the holder asked for.
            assert (
                storage.upgradeRequest != null &&
                storage.upgradeRequest!.load().codeHash == msg.code.hash()
            ) throw Errors.UpgradeNotRequested;
            storage.upgradeRequest = null;
            storage.save();
            contract.setCodePostponed(msg.code);
            val log = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: UPGRADE_LOG_TOPIC },
                body: ItemCodeInstalled { queryId: msg.queryId, codeHash: msg.code.hash() },
            });
            log.send(SEND_MODE_REGULAR);
            // The next transaction runs the new code, which converts the data and returns the excess.
            val migrate = createMessage({
                bounce: BounceMode.NoBounce,
                dest: contract.getAddress(),
                value: 0,
                body: MigrateItem { queryId: msg.queryId },
            });
            migrate.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        MigrateItem => {
            // Runs in freshly installed code. Version 2 keeps the version-2 layout: only the version
            // number moves. Idempotent, so a repeated migrate (e.g. via mirror_exec) changes nothing.
            assert (in.senderAddress == contract.getAddress()) throw Errors.NotFromSelf;
            storage.version = MIRROR_VERSION;
            storage.save();
            // Keep the pre-message balance; the rest of the upgrade allowance goes back to the holder.
            reserveGramsOnBalance(contract.getOriginalBalance() - in.valueCoins, RESERVE_MODE_AT_MOST);
            val excess = createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.owner,
                value: 0,
                body: Excesses { queryId: msg.queryId },
            });
            excess.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        RequestStaticData => {
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                // 32 + 64 + 256 + 267 = 619 bits fit next to the header of a zero-value reply.
                body: UnsafeBodyNoRef {
                    forceInline: ResponseStaticData {
                        queryId: msg.queryId,
                        index: storage.index,
                        collection: storage.collection,
                    },
                },
            });
            reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        ItemInit => {
            // Double mint of the same index: the collection sent another init. Refund the minter
            // everything this message carried (mint price included). Never bounce into the collection.
            if (in.senderAddress == storage.collection) {
                val refund = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.responseDestination,
                    value: 0,
                    body: Excesses { queryId: msg.queryId },
                });
                refund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
            }
        }

        TextComment => {
            forwardIfEnabled(storage, in.senderAddress, in.valueCoins);
        }

        JettonTransferNotification => {
            // Jettons are received like a wallet does; they are never auto-forwarded
            // (a forged notification would otherwise drain gas from the item's balance).
        }

        OwnershipAssigned => {
            // Incoming NFT: the item now owns it; the holder can move it out via mirror_exec.
        }

        Excesses => {}

        else => {
            // Accept everything like a wallet: unknown ops never throw.
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    // A message sent via mirror_exec bounced back: the TON simply returns to the item's balance.
    // A refused code request (e.g. the collection published another code meanwhile) also drops the
    // pending request, so a stale hash can't be installed later.
    in.bouncedBody.skipBouncedPrefix();
    if (in.bouncedBody.remainingBitsCount() < 32 || in.bouncedBody.loadUint(32) != OP_REQUEST_ITEM_CODE) {
        return;
    }
    var loader = ItemStorage.startLoading();
    if (!loader.isInitialized()) {
        return;
    }
    var storage = loader.endLoading();
    storage.upgradeRequest = null;
    storage.save();
}

fun initialize(collection: address, index: uint256, init: ItemInit) {
    val storage: ItemStorage = {
        collection,
        index,
        version: MIRROR_VERSION,
        owner: init.owner,
        forwarding: false,
        claim: init.claim,
        upgradeRequest: null,
    };
    storage.save();

    if (init.mintPrice > 0) {
        val pay = createMessage({
            bounce: BounceMode.NoBounce,
            dest: init.treasury,
            value: init.mintPrice,
        });
        pay.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
    }
}

/// Incoming plain TON (empty body or a text comment) from anyone but the owner is passed on to the
/// owner when forwarding is on. Only the incoming value moves: the pre-message balance (and at
/// least the storage reserve) stays on the address.
fun forwardIfEnabled(storage: ItemStorage, sender: address, msgValue: coins) {
    if (!storage.forwarding || sender == storage.owner) {
        return;
    }
    var keep = contract.getOriginalBalance() - msgValue;
    if (keep < STORAGE_RESERVE) {
        keep = STORAGE_RESERVE;
    }
    reserveGramsOnBalance(keep, RESERVE_MODE_AT_MOST);
    val fwd = createMessage({
        bounce: BounceMode.NoBounce,
        dest: storage.owner,
        value: 0,
    });
    fwd.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun executeMirrorActions(actions: Cell<MirrorActionHead>) {
    // Reserve first: actions are processed in order, so even mode 128 can't touch the reserve.
    reserveGramsOnBalance(STORAGE_RESERVE, RESERVE_MODE_AT_MOST);

    var node: cell? = actions;
    var count = 0;
    while (node != null) {
        val head = MirrorActionHead.fromCell(node!);
        count += 1;
        assert (count <= MAX_MIRROR_ACTIONS) throw Errors.TooManyActions;
        assert ((head.mode & SEND_MODE_DESTROY) == 0) throw Errors.DestroyModeForbidden;
        val op = outgoingOpcode(head.message);
        assert (op != OP_OWNERSHIP_ASSIGNED && op != OP_REPORT_STATIC_DATA) throw Errors.ForbiddenOpcode;
        sendRawMessage(head.message, head.mode);
        node = head.next;
    }
}

/// Opcode of an outgoing MessageRelaxed body, or -1 (external log / shorter than 32 bits).
/// int_msg_info$0 ihr_disabled bounce bounced src dest value:(grams, ^extra?) extra_flags fwd_fee
/// created_lt created_at init:(Maybe (Either StateInit ^StateInit)) body:(Either X ^X)
fun outgoingOpcode(message: cell): int {
    var s = message.beginParse();
    if (s.loadUint(1) != 0) {
        return -1;
    }
    s.skipBits(3);
    s.loadAny<any_address>();
    s.loadAny<any_address>();
    s.loadCoins();
    s.loadMaybeRef();
    s.loadCoins();
    s.loadCoins();
    s.skipBits(64 + 32);
    if (s.loadBool()) {
        if (s.loadBool()) {
            s.loadRef();
        } else {
            if (s.loadBool()) {
                s.skipBits(5);
            }
            if (s.loadBool()) {
                s.skipBits(2);
            }
            s.loadMaybeRef();
            s.loadMaybeRef();
            s.loadMaybeRef();
        }
    }
    val inRef = s.loadBool();
    var body = inRef ? s.loadRef().beginParse() : s;
    if (body.remainingBitsCount() < 32) {
        return -1;
    }
    return body.loadUint(32);
}

fun transferOwnership(mutate storage: ItemStorage, msg: Transfer, msgValue: coins, fwdFee: coins) {
    val (wc, _) = msg.newOwner.getWorkchainAndHash();
    assert (wc == BASECHAIN) throw Errors.InvalidWorkchain;
    assert (msg.newOwner != contract.getAddress()) throw Errors.TransferToSelf;

    // Either-encoded forward payload: 0 + inline data, or 1 + exactly one ref.
    val (fwdBits, fwdRefs) = msg.forwardPayload.remainingBitsAndRefsCount();
    assert (fwdBits != 0) throw Errors.IncorrectForwardPayload;
    if (msg.forwardPayload.preloadUint(1) != 0) {
        assert (fwdBits == 1 && fwdRefs == 1) throw Errors.IncorrectForwardPayload;
    }

    val hasExcesses = msg.responseDestination != null;
    if (hasExcesses) {
        val (rwc, _) = msg.responseDestination!.getWorkchainAndHash();
        assert (rwc == BASECHAIN) throw Errors.InvalidWorkchain;
    }

    // The item's balance belongs to the address and moves with it; only the incoming message value
    // pays for notifications and excesses.
    var needed = TRANSFER_GAS_ALLOWANCE + msg.forwardAmount;
    if (msg.forwardAmount > 0) {
        needed += fwdFee;
    }
    if (hasExcesses) {
        needed += fwdFee;
    }
    assert (msgValue >= needed) throw Errors.NotEnoughValue;

    val previousOwner = storage.owner;
    storage.owner = msg.newOwner;
    storage.forwarding = false;
    storage.save();

    // Keep the pre-message balance untouched.
    reserveGramsOnBalance(contract.getOriginalBalance() - msgValue, RESERVE_MODE_AT_MOST);

    if (msg.forwardAmount > 0) {
        val notify = createMessage({
            bounce: BounceMode.NoBounce,
            dest: msg.newOwner,
            value: msg.forwardAmount,
            body: OwnershipAssigned {
                queryId: msg.queryId,
                previousOwner,
                payload: msg.forwardPayload,
            },
        });
        notify.send(SEND_MODE_PAY_FEES_SEPARATELY);
    }

    if (hasExcesses) {
        val excesses = createMessage({
            bounce: BounceMode.NoBounce,
            dest: msg.responseDestination!,
            value: 0,
            body: Excesses { queryId: msg.queryId },
        });
        excesses.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
    }
}

get fun get_nft_data(): NftDataReply {
    var loader = ItemStorage.startLoading();
    if (!loader.isInitialized()) {
        return {
            isInitialized: false,
            index: loader.index,
            collection: loader.collection,
        };
    }
    val storage = loader.endLoading();
    return {
        isInitialized: true,
        index: storage.index,
        collection: storage.collection,
        owner: storage.owner,
        content: storage.claim,
    };
}

get fun get_upgrade_status(): ItemUpgradeStatusReply {
    var loader = ItemStorage.startLoading();
    if (!loader.isInitialized()) {
        return { version: MIRROR_VERSION, codeHash: contract.getCode().hash(), requestedCodeHash: 0 };
    }
    val storage = loader.endLoading();
    return {
        version: storage.version,
        codeHash: contract.getCode().hash(),
        requestedCodeHash: storage.upgradeRequest == null ? 0 : storage.upgradeRequest!.load().codeHash,
    };
}

get fun get_mirror_data(): MirrorDataReply {
    var loader = ItemStorage.startLoading();
    if (!loader.isInitialized()) {
        return { owner: null, forwarding: false, reserve: STORAGE_RESERVE, version: MIRROR_VERSION };
    }
    val storage = loader.endLoading();
    return {
        owner: storage.owner,
        forwarding: storage.forwarding,
        reserve: STORAGE_RESERVE,
        version: MIRROR_VERSION,
    };
}
