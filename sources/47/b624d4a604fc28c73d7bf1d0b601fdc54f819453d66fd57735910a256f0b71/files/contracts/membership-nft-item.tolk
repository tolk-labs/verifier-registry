tolk 1.5

import "membership-messages"

// CyberKonquest membership NFT item (TEP-62). It holds the tier and the time of the mint. The collection
// (membership-nft-collection.tolk) deploys it at a mint and initializes it with InitNftItem
// (membership-messages.tolk); from then on its owner transfers it as any NFT.

enum Errors {
    Unauthorized = 901          // InitNftItem not from the collection, or a transfer not from the owner
    NotInitialized = 902        // until it is initialized the item takes InitNftItem and nothing else
    InsufficientValue = 903     // a transfer the balance does not cover, a query that cannot pay its answer
    InvalidWorkchain = 904      // a new owner or a response destination that is not on the basechain
    MissingForwardPayload = 905 // forward_payload needs its Either bit
    UnknownOp = 0xFFFF
}

// The data of an initialized item: those it was deployed with (ItemDeploymentData), then its owner and
// its content
struct Storage {
    index: uint64
    collectionAddress: address
    ownerAddress: address
    content: MembershipContent
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

// Initialized once an owner follows the data the item was deployed with
fun isInitialized(): bool {
    var data = contract.getData().beginParse();
    data.skipAny<ItemDeploymentData>();
    return !data.isEmpty();
}

// ============== Messages ==============

// TEP-62 transfer (owner -> item)
struct (0x5fcc3d14) TransferNft {
    queryId: uint64
    newOwner: address
    responseDestination: address?        // addr_none: no excess wanted
    customPayload: cell?
    forwardAmount: coins
    forwardPayload: RemainingBitsAndRefs // Either Cell ^Cell, forwarded unchanged
}

// TEP-62 ownership_assigned (item -> new owner)
struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    prevOwner: address
    forwardPayload: RemainingBitsAndRefs
}

// TEP-62 get_static_data (anyone -> item)
struct (0x2fcb26a2) GetStaticData {
    queryId: uint64
}

// TEP-62 report_static_data (item -> requester): query_id:uint64 index:uint256 collection:MsgAddress
struct (0x8b771735) ReportStaticData {
    queryId: uint64
    index: uint256
    collection: address
}

// The bits of that answer, which is one cell: its opcode, the query id, the index and the collection. The
// answer's forward fee is charged on them (answerCost).
const STATIC_DATA_ANSWER_BITS: int = 619

// What an initialized item accepts
type NftItemMessage = TransferNft | GetStaticData

// ============== Entry point ==============

contract MembershipNftItem {
    description: "CyberKonquest membership NFT item (TEP-62): it holds the tier and the time of the mint"
    version: "3"
    storage: Storage
    storageAtDeployment: ItemDeploymentData
    incomingMessages: InitNftItem | NftItemMessage
    thrownErrors: Errors
}

fun onInternalMessage(in: InMessage) {
    // GRAM sent with an empty body is accepted. It stays on the item until the item's next transfer
    // that names a response destination, which sends there what the item then holds above what that
    // transfer sets aside, forwards and counts for fees. A message that carries a comment is a
    // message as any other: the item knows none of that kind, and refuses it
    if (in.body.isEmpty()) {
        return;
    }

    if (!isInitialized()) {
        // Until it is initialized the item takes one message: InitNftItem, read whole, from its
        // collection. The value it carries stays on the item: it is what a transfer sets aside.
        val init = InitNftItem.fromSlice(
            in.body,
            { throwIfOpcodeDoesNotMatch: Errors.NotInitialized },
        );
        val deployed = ItemDeploymentData.fromCell(contract.getData());
        assert (in.senderAddress == deployed.collectionAddress) throw Errors.Unauthorized;

        val storage = Storage {
            index: deployed.index,
            collectionAddress: deployed.collectionAddress,
            ownerAddress: init.minter,
            content: init.content,
        };
        storage.save();
        return;
    }

    // Every message is read whole: nothing may follow its fields (a transfer's last field is its payload,
    // which is all that follows), and an unknown one is refused
    val msg = NftItemMessage.fromSlice(in.body, { throwIfOpcodeDoesNotMatch: Errors.UnknownOp });
    var storage = lazy Storage.load();

    match (msg) {
        TransferNft => {
            assert (in.senderAddress == storage.ownerAddress) throw Errors.Unauthorized;

            // owners live on the basechain
            assert (msg.newOwner.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;

            assert (
                msg.forwardPayload.remainingBitsCount() >= 1
            ) throw Errors.MissingForwardPayload;

            // TEP-62: what is left goes to the response destination, or the transfer is refused. One
            // that is not on the basechain is refused (addr_none: none wanted)
            val response = msg.responseDestination;
            if (response != null) {
                assert (response.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            }

            // The budget is the TEP-62 reference item's, with an amount counted for gas besides: the
            // item's whole balance (this message included), less what a transfer sets aside (the
            // storage reserve and the amount counted for this transaction's gas), must cover what is
            // sent: the forward amount, and for each message the item sends a forward fee counted as
            // this message's own.
            var restAmount: int = contract.getOriginalBalance() - ITEM_TRANSFER_SETS_ASIDE;
            if (msg.forwardAmount > 0) {
                restAmount -= (msg.forwardAmount + in.originalForwardFee);
            }
            if (response != null) {
                restAmount -= in.originalForwardFee;
            }
            assert (restAmount >= 0) throw Errors.InsufficientValue;

            val prevOwner = storage.ownerAddress;

            storage.ownerAddress = msg.newOwner;
            storage.save();

            if (msg.forwardAmount > 0) {
                val ownershipAssigned = OwnershipAssigned {
                    queryId: msg.queryId,
                    prevOwner,
                    forwardPayload: msg.forwardPayload,
                };

                val notificationMessage = createMessage({
                    bounce: BounceMode.NoBounce, // the new owner may not be deployed yet
                    dest: msg.newOwner,
                    value: msg.forwardAmount,
                    body: ownershipAssigned,
                });
                // the forward amount arrives whole: its fee is paid on top, as counted above
                notificationMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            // What is left above what the transfer sets aside goes back to the response destination;
            // with none named it stays on the item
            if (response != null && restAmount > 0) {
                val excessesMessage = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: response,
                    value: restAmount,
                    body: Excesses { queryId: msg.queryId },
                });
                excessesMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
        }

        GetStaticData => {
            // TEP-62: the index and the collection, to whoever asks, on the request's own value. The
            // request carries what its answer costs (get_answer_cost), or it is refused, and bounces
            // with its value if it asked to
            assert (
                in.valueCoins >=
                answerCost(STATIC_DATA_ANSWER_BITS, in.senderAddress.getWorkchain())
            ) throw Errors.InsufficientValue;

            val staticData = ReportStaticData {
                queryId: msg.queryId,
                index: storage.index as uint256,
                collection: storage.collectionAddress,
            };

            val staticDataMessage = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: staticData,
            });
            staticDataMessage.send(ON_REQUEST_VALUE);
        }
    }
}

// ============== Get methods (TEP-62) ==============

// (init, index, collection_address, owner_address, individual_content). Until the item is initialized
// it has no owner (addr_none) and its content is an empty cell.
get fun get_nft_data(): (bool, int, slice, slice, cell) {
    if (!isInitialized()) {
        val deployed = ItemDeploymentData.fromCell(contract.getData());
        return (
            false,
            deployed.index,
            deployed.collectionAddress as slice,
            createAddressNone() as slice,
            createEmptyCell(),
        );
    }

    val storage = lazy Storage.load();
    return (
        true,
        storage.index,
        storage.collectionAddress as slice,
        storage.ownerAddress as slice,
        storage.content.toCell(),
    );
}

// ============== Membership get methods ==============

// (tier, time of the mint), or (-1, 0) until the item is initialized
get fun get_membership_data(): (int, int) {
    if (!isInitialized()) {
        return (-1, 0);
    }
    val storage = lazy Storage.load();
    return (storage.content.tier, storage.content.mintTimestamp);
}

// What a get_static_data must carry, at the network's live prices, when its sender is on `workchain`
// (0 for the basechain, -1 for the masterchain): the gas of answering it and the answer's forward fee to
// that chain. With less it is refused; what is sent above the costs goes back with the answer.
get fun get_answer_cost(workchain: int): int {
    return answerCost(STATIC_DATA_ANSWER_BITS, workchain);
}
