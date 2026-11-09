import "constants"
import "errors"
import "messages"
import "types"

contract VanityCollection {
    author: "TON Vanity"
    version: "3.0.0"
    description: "Vanity address NFT collection: signed-voucher sale, ops mint, time-locked upgrades, TEP-62/64/66"
    storage: CollectionStorage
    incomingMessages: AllowedMessageToCollection
}

type AllowedMessageToCollection =
    | Buy
    | AdminMint
    | RequestRoyaltyParams
    | ChangeOwner
    | SetMinter
    | SetSigner
    | SetTreasury
    | SetContent
    | SetRoyalty
    | SetPaused
    | Withdraw
    | ProposeUpgrade
    | ApproveUpgrade
    | CancelUpgrade
    | Migrate
    | RequestItemCode
    | TextComment

fun emitUpgradeEvent<T>(body: T) {
    val log = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: UPGRADE_LOG_TOPIC },
        body,
    });
    log.send(SEND_MODE_REGULAR);
}

fun hashOrZero(c: cell?): uint256 {
    return c == null ? 0 : c!.hash();
}

/// max_acc_fixed_prefix_length from config param 43 (0 if the network doesn't support it).
fun maxFixedPrefixLength(): int {
    val param = blockchain.configParam(43);
    if (param == null) {
        return 0;
    }
    var s = param!.beginParse();
    val tag = s.loadUint(8);
    if (
        (tag != CONFIG43_TAG_V2 && tag != CONFIG43_TAG_V3) || s.remainingBitsCount() <
        CONFIG43_FIXED_PREFIX_OFFSET
    ) {
        return 0;
    }
    s.skipBits(CONFIG43_FIXED_PREFIX_OFFSET - 8);
    return s.loadUint(8);
}

fun assertBasechain(a: address) {
    val (wc, _) = a.getWorkchainAndHash();
    assert (wc == BASECHAIN) throw Errors.InvalidWorkchain;
}

fun assertValidCommonContent(c: Cell<CollectionContent>) {
    val content = c.load();
    val s = content.commonContent.beginParse();
    val (bits, refs) = s.remainingBitsAndRefsCount();
    // 0x01 + common must fit one cell next to the ^individual ref: ≤ 126 bytes, inline only.
    assert (refs == 0 && bits % 8 == 0 && bits <= 126 * 8) throw Errors.InvalidCommonContent;
}

/// Deploys the item at prefix(index) || hash(StateInit) and initializes it for `owner`.
/// The claim is bounded (≤ 42 alphanumerics, one cell) and must really be in the address.
/// `price` travels with the deployment: the item pays it to `treasury` on its first init, or refunds
/// the whole value to `responseDestination` if the index already exists.
fun deployItem(
    itemCode: cell,
    queryId: uint64,
    index: uint256,
    owner: address,
    responseDestination: address,
    treasury: address,
    price: coins,
    claim: Cell<PatternClaim>,
) {
    assertBasechain(owner);
    assert (maxFixedPrefixLength() >= FIXED_PREFIX_LENGTH) throw Errors.FixedPrefixNotAllowed;

    val item = calcItemAddress(contract.getAddress(), index, itemCode);
    val (_, itemHash) = item.calculateAddress().getWorkchainAndHash();
    assert (claim.load().isTrueFor(itemHash)) throw Errors.InvalidClaim;

    val treasuryAllowance: coins = price > 0 ? TREASURY_FEE_ALLOWANCE : (0 as coins);
    val deploy = createMessage({
        bounce: BounceMode.NoBounce,
        dest: item,
        value: ITEM_INIT_VALUE + price + treasuryAllowance,
        body: ItemInit {
            queryId,
            owner,
            responseDestination,
            treasury,
            mintPrice: price,
            claim,
        },
    });
    deploy.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

/// Value a mint must carry: price (+ the item's treasury fee allowance) + item value + collection gas.
fun requiredMintValue(price: coins): coins {
    val treasuryAllowance: coins = price > 0 ? TREASURY_FEE_ALLOWANCE : (0 as coins);
    return price + treasuryAllowance + ITEM_INIT_VALUE + MINT_GAS_ALLOWANCE;
}

/// Keeps the collection's own balance; everything else this message brought goes to `dest`.
fun returnExcess(dest: address, queryId: uint64, msgValue: coins) {
    reserveGramsOnBalance(contract.getOriginalBalance() - msgValue, RESERVE_MODE_AT_MOST);
    val excess = createMessage({
        bounce: BounceMode.NoBounce,
        dest,
        value: 0,
        body: Excesses { queryId },
    });
    // Safe: the reserve above keeps the pre-message balance, so mode 128 only moves what this
    // message brought minus what was already sent; invariant: called last, after reserveGramsOnBalance.
    excess.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return; // top-up
    }

    val msg = lazy AllowedMessageToCollection.fromSlice(in.body);

    match (msg) {
        Buy => {
            var storage = lazy CollectionStorage.load();
            assert (!storage.paused) throw Errors.MintPaused;
            val sale = storage.ext.load().sale;
            // The signature covers the whole voucher cell: collection, index, owner, price, expiry, claim.
            assert (
                isSignatureValid(msg.voucher.hash(), msg.signature as slice, sale.signerPublicKey)
            ) throw Errors.InvalidSignature;
            val voucher = msg.voucher.load({ throwIfOpcodeDoesNotMatch: Errors.InvalidVoucher });
            assert (voucher.collection == contract.getAddress()) throw Errors.WrongCollection;
            assert (blockchain.now() <= voucher.validUntil) throw Errors.VoucherExpired;
            assert (in.valueCoins >= requiredMintValue(voucher.price)) throw Errors.NotEnoughValue;

            deployItem(
                storage.itemCode,
                msg.queryId,
                voucher.index,
                voucher.owner,
                in.senderAddress,
                sale.treasury,
                voucher.price,
                voucher.claim,
            );
            storage.mintedCount += 1;
            storage.save();
            returnExcess(in.senderAddress, msg.queryId, in.valueCoins);
        }

        AdminMint => {
            var storage = lazy CollectionStorage.load();
            // Pause is the emergency stop for a leaked minter key too; the admin can rotate the minter.
            assert (!storage.paused) throw Errors.MintPaused;
            val sale = storage.ext.load().sale;
            assert (in.senderAddress == sale.minter) throw Errors.NotFromMinter;
            assert (in.valueCoins >= requiredMintValue(0)) throw Errors.NotEnoughValue;

            deployItem(
                storage.itemCode,
                msg.queryId,
                msg.index,
                msg.owner,
                msg.responseDestination,
                sale.treasury,
                0,
                msg.claim,
            );
            storage.mintedCount += 1;
            storage.save();
            returnExcess(msg.responseDestination, msg.queryId, in.valueCoins);
        }

        RequestRoyaltyParams => {
            val storage = lazy CollectionStorage.load();
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ResponseRoyaltyParams {
                    queryId: msg.queryId,
                    royaltyParams: storage.royalty.load(),
                },
            });
            reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        ChangeOwner => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            assertBasechain(msg.newOwner);
            storage.owner = msg.newOwner;
            storage.save();
        }

        SetMinter => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            assertBasechain(msg.minter);
            var ext = storage.ext.load();
            ext.sale.minter = msg.minter;
            storage.ext = ext.toCell();
            storage.save();
        }

        SetSigner => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            var ext = storage.ext.load();
            ext.sale.signerPublicKey = msg.signerPublicKey;
            storage.ext = ext.toCell();
            storage.save();
        }

        SetTreasury => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            assertBasechain(msg.treasury);
            var ext = storage.ext.load();
            ext.sale.treasury = msg.treasury;
            storage.ext = ext.toCell();
            storage.save();
        }

        SetContent => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            assertValidCommonContent(msg.content);
            storage.content = msg.content;
            storage.save();
        }

        SetRoyalty => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            val r = msg.royalty.load();
            assert (r.denominator > 0 && r.numerator <= r.denominator) throw Errors.InvalidRoyalty;
            storage.royalty = msg.royalty;
            storage.save();
        }

        SetPaused => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            storage.paused = msg.paused;
            storage.save();
        }

        Withdraw => {
            val storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            reserveGramsOnBalance(COLLECTION_RESERVE, RESERVE_MODE_AT_MOST);
            val out = createMessage({
                bounce: BounceMode.NoBounce,
                dest: msg.destination,
                value: msg.amount,
                body: Excesses { queryId: msg.queryId },
            });
            if (msg.amount == 0) {
                // Safe: admin-only, and COLLECTION_RESERVE is reserved first, so the collection keeps it.
                out.send(SEND_MODE_CARRY_ALL_BALANCE);
            } else {
                out.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
        }

        ProposeUpgrade => {
            var storage = lazy CollectionStorage.load();
            var ext = storage.ext.load();
            var up = ext.upgrades.load();
            assert (in.senderAddress == up.authority) throw Errors.NotFromUpgradeAuthority;
            assertBasechain(msg.authority);
            assert (msg.delay <= MAX_UPGRADE_DELAY) throw Errors.InvalidUpgradeDelay;
            // Migration parameters only make sense for new code.
            assert (msg.migration == null || msg.code != null) throw Errors.EmptyProposal;
            assert (
                msg.code != null || msg.itemCode != null || msg.authority != up.authority ||
                msg.delay != up.delay
            ) throw Errors.EmptyProposal;

            val readyAt = blockchain.now() + up.delay;
            val proposal: UpgradeProposal = {
                readyAt,
                authority: msg.authority,
                delay: msg.delay,
                code: msg.code,
                migration: msg.migration,
                itemCode: msg.itemCode,
            };
            val proposalCell = proposal.toCell();
            up.pending = proposalCell;
            ext.upgrades = up.toCell();
            storage.ext = ext.toCell();
            storage.save();
            emitUpgradeEvent(UpgradeProposed {
                queryId: msg.queryId,
                proposalHash: proposalCell.hash(),
                readyAt,
            });
        }

        ApproveUpgrade => {
            var storage = lazy CollectionStorage.load();
            var ext = storage.ext.load();
            var up = ext.upgrades.load();
            assert (in.senderAddress == up.authority) throw Errors.NotFromUpgradeAuthority;
            assert (up.pending != null) throw Errors.NoPendingUpgrade;
            val pendingCell = up.pending!;
            assert (pendingCell.hash() == msg.proposalHash) throw Errors.ProposalMismatch;
            val p = pendingCell.load();
            assert (blockchain.now() >= p.readyAt) throw Errors.UpgradeTimelocked;

            up.authority = p.authority;
            up.delay = p.delay;
            if (p.itemCode != null) {
                up.itemCode = p.itemCode!;
            }
            up.pending = null;
            ext.upgrades = up.toCell();
            storage.ext = ext.toCell();
            // The address code (storage.itemCode) is never touched: item addresses can't move.
            storage.save();
            emitUpgradeEvent(UpgradeApproved {
                queryId: msg.queryId,
                proposalHash: msg.proposalHash,
                codeHash: hashOrZero(p.code),
                itemCodeHash: hashOrZero(p.itemCode),
            });

            if (p.code != null) {
                // Takes effect after this transaction; the new code then handles `migrate`.
                contract.setCodePostponed(p.code!);
                val migrate = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: contract.getAddress(),
                    value: 0,
                    body: Migrate {
                        queryId: msg.queryId,
                        fromVersion: storage.version,
                        migration: p.migration,
                    },
                });
                migrate.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            } else {
                val excess = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: in.senderAddress,
                    value: 0,
                    body: Excesses { queryId: msg.queryId },
                });
                excess.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
            }
        }

        CancelUpgrade => {
            var storage = lazy CollectionStorage.load();
            var ext = storage.ext.load();
            var up = ext.upgrades.load();
            assert (in.senderAddress == up.authority) throw Errors.NotFromUpgradeAuthority;
            assert (up.pending != null) throw Errors.NoPendingUpgrade;
            val proposalHash = up.pending!.hash();
            up.pending = null;
            ext.upgrades = up.toCell();
            storage.ext = ext.toCell();
            storage.save();
            emitUpgradeEvent(UpgradeCancelled { queryId: msg.queryId, proposalHash });
        }

        Migrate => {
            // Runs in the code that was just installed. Version 3 keeps the version-3 layout, so the
            // only conversion is the version number; later versions convert from `fromVersion`.
            assert (in.senderAddress == contract.getAddress()) throw Errors.NotFromSelf;
            var storage = lazy CollectionStorage.load();
            storage.version = COLLECTION_VERSION;
            storage.save();
            val authority = storage.ext.load().upgrades.load().authority;
            val excess = createMessage({
                bounce: BounceMode.NoBounce,
                dest: authority,
                value: 0,
                body: Excesses { queryId: msg.queryId },
            });
            excess.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
        }

        RequestItemCode => {
            // Holder-initiated: the item asks for the published code with the hash its holder signed.
            val storage = lazy CollectionStorage.load();
            val item = calcItemAddress(contract.getAddress(), msg.index, storage.itemCode);
            assert (in.senderAddress == item.calculateAddress()) throw Errors.NotFromItem;
            val itemCode = storage.ext.load().upgrades.load().itemCode;
            assert (itemCode.hash() == msg.codeHash) throw Errors.ItemCodeMismatch;
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: InstallItemCode { queryId: msg.queryId, code: itemCode },
            });
            reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        TextComment => {
            // Donations / royalties with a comment are accepted.
        }

        else => {
            throw Errors.UnknownOp;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {
    // Item deployments are sent non-bounceable; nothing to restore.
}

get fun get_collection_data(): CollectionDataReply {
    val storage = lazy CollectionStorage.load();
    val content = lazy storage.content.load();
    return {
        // Indices are not sequential (like TON DNS): -1 per TEP-62.
        nextItemIndex: -1,
        collectionMetadata: content.collectionMetadata,
        owner: storage.owner,
    };
}

get fun get_nft_address_by_index(index: int): address {
    // TVM integers are 257-bit signed: any non-negative int is a valid uint256.
    assert (index >= 0) throw Errors.InvalidIndex;
    val storage = lazy CollectionStorage.load();
    return calcItemAddress(contract.getAddress(), index, storage.itemCode).calculateAddress();
}

/// "<index_hex>.json?p=<pattern>&m=<start|end|both>&c=<0|1>" — at most 64+8+42+3+5+3+1 = 126 bytes.
fun individualUrl(index: int, claim: PatternClaim): cell {
    var b = beginCell();
    var i = 63;
    while (i >= 0) {
        val nibble = (index >> (i * 4)) & 15;
        b.storeUint(nibble < 10 ? 48 + nibble : 87 + nibble, 8);
        i -= 1;
    }
    b.storeUint(0x2e6a736f6e3f703d, 64); // ".json?p="
    b.storeSlice(claim.pattern);
    b.storeUint(0x266d3d, 24);           // "&m="
    if (claim.mode == 0) {
        b.storeUint(0x7374617274, 40); // "start"
    } else if (claim.mode == 1) {
        b.storeUint(0x656e64, 24); // "end"
    } else {
        b.storeUint(0x626f7468, 32); // "both"
    }
    b.storeUint(0x26633d, 24);           // "&c="
    b.storeUint(claim.caseSensitive ? 0x31 : 0x30, 8);
    return b.endCell();
}

/// TEP-64 off-chain reference layout: 0x01 || common prefix (inline) || ^individual part.
/// The URL is built from the index itself, so an item can never point at another item's metadata.
get fun get_nft_content(index: int, individualContent: cell): cell {
    val storage = lazy CollectionStorage.load();
    val content = lazy storage.content.load();
    val claim = PatternClaim.fromCell(individualContent);
    return beginCell()
        .storeUint(0x01, 8)
        .storeSlice(content.commonContent.beginParse())
        .storeRef(individualUrl(index, claim))
        .endCell();
}

get fun royalty_params(): RoyaltyParams {
    val storage = lazy CollectionStorage.load();
    return storage.royalty.load();
}

get fun get_sale_config(): SaleConfigReply {
    val storage = lazy CollectionStorage.load();
    val sale = storage.ext.load().sale;
    return {
        minter: sale.minter,
        signerPublicKey: sale.signerPublicKey,
        treasury: sale.treasury,
        paused: storage.paused,
    };
}

get fun get_minted_count(): int {
    val storage = lazy CollectionStorage.load();
    return storage.mintedCount;
}

/// What a buyer needs to attach: price + (price > 0 ? treasury_fee_allowance : 0) + item_init_value
/// + mint_gas_allowance; item_code_hash is the code the GPU fleet mines against.
get fun get_buy_params(): BuyParamsReply {
    val storage = lazy CollectionStorage.load();
    return {
        itemInitValue: ITEM_INIT_VALUE,
        mintGasAllowance: MINT_GAS_ALLOWANCE,
        treasuryFeeAllowance: TREASURY_FEE_ALLOWANCE,
        itemCodeHash: storage.itemCode.hash(),
    };
}

get fun get_fixed_prefix_limit(): int {
    return maxFixedPrefixLength();
}

get fun get_version(): CollectionVersionReply {
    val storage = lazy CollectionStorage.load();
    return {
        version: storage.version,
        codeVersion: COLLECTION_VERSION,
        codeHash: contract.getCode().hash(),
    };
}

get fun get_upgrade_state(): UpgradeStateReply {
    val storage = lazy CollectionStorage.load();
    val up = storage.ext.load().upgrades.load();
    return {
        authority: up.authority,
        delay: up.delay,
        addressCodeHash: storage.itemCode.hash(),
        itemCodeHash: up.itemCode.hash(),
        pending: up.pending,
    };
}

/// The approved item code `upgrade_item` installs (wallets and the app read it to show what a
/// holder would sign).
get fun get_item_code(): cell {
    val storage = lazy CollectionStorage.load();
    return storage.ext.load().upgrades.load().itemCode;
}
