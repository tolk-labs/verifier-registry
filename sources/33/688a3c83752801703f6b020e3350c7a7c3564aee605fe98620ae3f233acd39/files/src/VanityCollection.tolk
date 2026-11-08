import "constants"
import "errors"
import "messages"
import "types"

contract VanityCollection {
    author: "TON Vanity"
    version: "2.0.0"
    description: "Vanity address NFT collection: signed-voucher sale and ops mint, TEP-62/64/66"
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
    | TextComment

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
            val sale = storage.sale.load();
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
            val sale = storage.sale.load();
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
            var sale = storage.sale.load();
            sale.minter = msg.minter;
            storage.sale = sale.toCell();
            storage.save();
        }

        SetSigner => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            var sale = storage.sale.load();
            sale.signerPublicKey = msg.signerPublicKey;
            storage.sale = sale.toCell();
            storage.save();
        }

        SetTreasury => {
            var storage = lazy CollectionStorage.load();
            assert (in.senderAddress == storage.owner) throw Errors.NotFromAdmin;
            assertBasechain(msg.treasury);
            var sale = storage.sale.load();
            sale.treasury = msg.treasury;
            storage.sale = sale.toCell();
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
    val sale = storage.sale.load();
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
