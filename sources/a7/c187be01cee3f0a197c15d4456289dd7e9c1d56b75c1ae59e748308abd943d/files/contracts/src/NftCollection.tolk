import "@stdlib/strings"
import "errors"
import "fees-management"
import "messages"
import "types"

contract NftCollection {
    author: "therenovatio"
    version: "1.0.0"
    description: "Standard NFT Collection. TEP-62 and TEP-64 compliant"
    storage: NftCollectionStorage
    incomingMessages: AllowedMessageToNftCollection
}

fun deployNftItem(
    itemIndex: int,
    nftItemCode: cell,
    attachTonAmount: coins,
    initParams: Cell<NftItemInitAtDeployment>,
) {
    val deployMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: calcDeployedNftItem(itemIndex, contract.getAddress(), nftItemCode),
        value: attachTonAmount,
        body: initParams,
    });
    // bounce the whole mint if this action fails (e.g. fees rose), so the sender gets the value back
    deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

type AllowedMessageToNftCollection =
    | RequestRoyaltyParams
    | Mint
    | Withdraw
    | ChangeCollectionAdmin
    | EditContent

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToNftCollection.fromSlice(in.body);

    match (msg) {
        Mint => {
            var storage = lazy NftCollectionStorage.load();
            assert (
                in.valueCoins >= storage.mintPrice + MINT_OVERHEAD
            ) throw Errors.InsufficientMintValue;
            assert (in.senderAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            // item indexes start at 1 by deploy convention (nextItemIndex = 1 at deploy), so
            // maxSupply is the highest index allowed: a cap of N allows exactly items 1..N
            assert (
                storage.maxSupply == 0 || storage.nextItemIndex <= storage.maxSupply
            ) throw Errors.SoldOut;
            assert (
                storage.mintUntil == 0 || blockchain.now() <= storage.mintUntil
            ) throw Errors.MintClosed;

            val itemIndex = storage.nextItemIndex;
            val mintedAt = blockchain.now();
            // mix the block random seed with this transaction's logical time; see
            // `SeedPreimage.blockRandom` for why the seed needs a value the minter cannot predict
            random.initialize();
            val blockRandom = random.uint256();
            val preimage = SeedPreimage {
                sender: in.senderAddress,
                itemIndex,
                createdLt: in.createdLt,
                mintedAt,
                blockRandom,
            };
            val content = ArtSeed {
                seed: preimage.toCell().hash(),
                mintedAt,
            };

            deployNftItem(
                itemIndex,
                storage.nftItemCode,
                NFT_ITEM_VALUE,
                NftItemInitAtDeployment {
                    ownerAddress: in.senderAddress,
                    content: content.toCell(),
                }.toCell(),
            );

            // the balance at the start of the compute phase already includes the incoming value,
            // so keep the pre-message balance plus exactly `mintPrice`; the item value, gas and
            // forwarding fees are paid out of the sender's excess, and the rest is refunded
            reserveGramsOnBalance(
                contract.getOriginalBalance() - in.valueCoins + storage.mintPrice,
                RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
            );
            val refundMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            // SAFETY: the reserve above keeps the pre-mint balance plus mintPrice on the contract;
            // only the sender's excess above that is carried out
            refundMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);

            storage.nextItemIndex += 1;
            storage.save();
        }

        Withdraw => {
            val storage = lazy NftCollectionStorage.load();
            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;

            reserveGramsOnBalance(MIN_COLLECTION_BALANCE, RESERVE_MODE_EXACT_AMOUNT);
            val withdrawMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.adminAddress,
                value: 0,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            // SAFETY: admin only; the reserve above keeps MIN_COLLECTION_BALANCE on the contract
            withdrawMsg.send(SEND_MODE_CARRY_ALL_BALANCE);
        }

        RequestRoyaltyParams => {
            val storage = lazy NftCollectionStorage.load();
            val respondMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ResponseRoyaltyParams {
                    queryId: msg.queryId,
                    royaltyParams: storage.royaltyParams.load(),
                },
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        ChangeCollectionAdmin => {
            var storage = lazy NftCollectionStorage.load();
            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;
            storage.adminAddress = msg.newAdminAddress;
            storage.save();
        }

        EditContent => {
            var storage = lazy NftCollectionStorage.load();
            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;
            // the collection becomes immutable once any piece exists; indexes start at 1 by deploy
            // convention, so nextItemIndex > 1 means item #1 has been minted
            assert (storage.nextItemIndex <= 1) throw Errors.CollectionSealed;
            // parse the new content so a malformed cell fails the edit instead of breaking the
            // getters; storing the re-serialized value keeps the parse from being optimized away
            var parsed: CollectionContent;
            try {
                parsed = msg.content.load();
            } catch {
                throw Errors.InvalidContent;
            }
            storage.content = parsed.toCell();
            storage.save();
        }

        else => {
            // accept empty messages as top-ups, "wrong opcode" for others
            assert (in.body.isEmpty()) throw 0xFFFF;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {
    // a bounced item deploy returns its funds here; the item index is intentionally not rolled back
}

get fun get_collection_data(): CollectionDataReply {
    val storage = lazy NftCollectionStorage.load();
    val content = lazy storage.content.load();

    return {
        nextItemIndex: storage.nextItemIndex,
        collectionMetadata: content.collectionMetadata,
        adminAddress: storage.adminAddress,
    };
}

get fun get_nft_address_by_index(itemIndex: int): address {
    val storage = lazy NftCollectionStorage.load();
    val nftDeployed = calcDeployedNftItem(itemIndex, contract.getAddress(), storage.nftItemCode);
    return nftDeployed.calculateAddress();
}

get fun royalty_params(): RoyaltyParams {
    val storage = lazy NftCollectionStorage.load();
    return storage.royaltyParams.load();
}

get fun mint_info(): MintInfoReply {
    val storage = lazy NftCollectionStorage.load();
    return {
        mintPrice: storage.mintPrice,
        maxSupply: storage.maxSupply,
        mintUntil: storage.mintUntil,
        nextItemIndex: storage.nextItemIndex,
    };
}

/// Converts a 256-bit value into exactly 64 lowercase hex characters (zero-padded on the left)
fun uint256ToLowerHex(value: uint256): string {
    var b = beginCell();
    var shift = 252;
    repeat (64) {
        val nibble = (value >> shift) & 0xF;
        b.storeUint(nibble < 10 ? 48 + nibble : 87 + nibble, 8); // '0'..'9' or 'a'..'f'
        shift -= 4;
    }
    return b.endCell() as unknown as string;
}

get fun get_nft_content(
    itemIndex: int,
    individualContent: Cell<ArtSeed>,
): Cell<OffchainMetadataReply> {
    val storage = lazy NftCollectionStorage.load();
    val content = lazy storage.content.load();
    val art = individualContent.load();

    // off-chain URL: commonContent + "<index>-<seedHex>-<mintedAt>.json",
    // e.g. "https://example.com/nft/" + "7-00ab...00-1790000000.json"
    var b = StringBuilder.create();
    b.append(content.commonContent);
    b.appendInt(itemIndex);
    b.append("-");
    b.append(uint256ToLowerHex(art.seed));
    b.append("-");
    b.appendInt(art.mintedAt);
    b.append(".json");
    return OffchainMetadataReply { string: b.build() }.toCell();
}
