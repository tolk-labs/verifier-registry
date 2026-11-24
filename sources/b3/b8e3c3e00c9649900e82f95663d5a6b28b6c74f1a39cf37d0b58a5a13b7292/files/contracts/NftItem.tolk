// Chilled Cat plushie NFT item: one cat.
//
// This is the official Tolk NFT item (ton-blockchain/tolk-bench, contracts_Tolk/02_nft/NftItem.tolk) with one
// addition. Besides what every NFT holds, a cat keeps its "birth": who built it, its serial number, when it was
// minted and its recipe (every piece it is made of). The birth is written once, when the collection mints the cat,
// and nothing can change it: a transfer changes the owner and nothing else. `get_cat_data` reads it.
// Everything a wallet or marketplace asks of an NFT (transfers, get_nft_data) is as in the official item.

import "errors"
import "storage"
import "messages"
import "fees-management"

contract NftItem {
    // the original item is the Tolk Team's; the cat's birth and get_cat_data are Chilled Cat's (see the top of this file)
    author: "Chilled Cat, from the Tolk Team's NFT item"
    incomingMessages: AllowedMessageToNftItem
    storage: NftItemStorage
    storageAtDeployment: NftItemStorageNotInitialized
}

type AllowedMessageToNftItem =
    | AskToChangeOwnership
    | RequestStaticData

fun onInternalMessage(in: InMessage) {
    var loadingStorage = startLoadingNftItemStorage();
    if (!loadingStorage.isInitialized()) {
        val uninitedSt = loadingStorage.parseNotInitialized();
        assert (in.senderAddress == uninitedSt.collectionAddress) throw ERROR_NOT_FROM_COLLECTION;

        // using a message from collection, convert "uninitialized" to "initialized" state
        val initParams = NftItemInitAtDeployment.fromSlice(in.body);
        val storage: NftItemStorage = {
            itemIndex: uninitedSt.itemIndex,
            collectionAddress: uninitedSt.collectionAddress,
            ownerAddress: initParams.ownerAddress,
            content: initParams.content,
            birth: initParams.birth,
        };
        storage.save();
        return;
    }

    var storage = loadingStorage.parseInitialized();

    val msg = lazy AllowedMessageToNftItem.fromSlice(in.body);

    match (msg) {
        AskToChangeOwnership => {
            assert (in.senderAddress == storage.ownerAddress) throw ERROR_NOT_FROM_OWNER;

            assert (msg.forwardPayload.remainingBitsCount() != 0) throw ERROR_INCORRECT_FORWARD_PAYLOAD;
            assert (msg.newOwnerAddress.getWorkchain() == BASECHAIN) throw ERROR_INVALID_WORKCHAIN;

            val fwdFee = in.originalForwardFee;
            var restAmount = contract.getOriginalBalance() - MIN_TONS_FOR_STORAGE;
            if (msg.forwardTonAmount != 0) {
                restAmount -= (msg.forwardTonAmount + fwdFee);
            }
            if (msg.sendExcessesTo != null) {
                assert (msg.sendExcessesTo.getWorkchain() == BASECHAIN) throw ERROR_INVALID_WORKCHAIN;
                restAmount -= fwdFee;
            }

            assert (restAmount >= 0) throw ERROR_TOO_SMALL_REST_AMOUNT; // base nft spends fixed amount of gas, will not check for response

            if (msg.forwardTonAmount != 0) {
                val ownershipMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.newOwnerAddress,
                    value: msg.forwardTonAmount,
                    body: NotificationForNewOwner {
                        queryId: msg.queryId,
                        oldOwnerAddress: storage.ownerAddress,
                        payload: msg.forwardPayload,
                    }
                });
                ownershipMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            if (msg.sendExcessesTo != null) {
                val excessesMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.sendExcessesTo,
                    value: restAmount,
                    body: ReturnExcessesBack {
                        queryId: msg.queryId,
                    }
                });
                excessesMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            storage.ownerAddress = msg.newOwnerAddress;
            storage.save();
        }

        RequestStaticData => {
            val respondMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                // why ever, in FunC implementation, item index was encoded as 256-bit (not 64-bit),
                // do the same here to pass FunC tests;
                // but since a response becomes too long (64 + 256 + address), the compiler will create a ref;
                // force the compiler not to create a ref, because it's guaranteed that with
                // value (coins) = 0 it will nevertheless fit into a message cell directly
                body: UnsafeBodyNoRef {
                    forceInline: ResponseStaticData {
                        queryId: msg.queryId,
                        itemIndex: storage.itemIndex as uint256,
                        collectionAddress: storage.collectionAddress,
                    }
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        else => {
            // ignore empty messages, "wrong opcode" for others
            assert (in.body.isEmpty()) throw 0xFFFF
        }
    }
}



struct NftDataReply {
    isInitialized: bool
    itemIndex: int
    collectionAddress: address
    ownerAddress: address? = null
    content: string? = null
}

get fun get_nft_data(): NftDataReply {
    var loadingStorage = startLoadingNftItemStorage();
    if (!loadingStorage.isInitialized()) {
        val uninitedSt = loadingStorage.parseNotInitialized();
        return {
            isInitialized: false,
            itemIndex: uninitedSt.itemIndex,
            collectionAddress: uninitedSt.collectionAddress,
        }
    }

    val storage = loadingStorage.parseInitialized();
    return {
        isInitialized: true,
        itemIndex: storage.itemIndex,
        collectionAddress: storage.collectionAddress,
        ownerAddress: storage.ownerAddress,
        content: storage.content,
    }
}

struct CatDataReply {
    builder: address
    serial: int
    mintedAt: int
    recipe: string
}

// The cat's birth. Only for a cat that has been minted.
get fun get_cat_data(): CatDataReply {
    var loadingStorage = startLoadingNftItemStorage();
    assert (loadingStorage.isInitialized()) throw ERROR_NOT_INITIALIZED;
    val birth = loadingStorage.parseInitialized().birth.load();
    return {
        builder: birth.builder,
        serial: birth.serial,
        mintedAt: birth.mintedAt,
        recipe: birth.recipe,
    }
}
