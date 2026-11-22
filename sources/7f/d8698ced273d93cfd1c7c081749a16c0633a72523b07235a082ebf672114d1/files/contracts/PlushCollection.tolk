// Chilled Cat plushie NFT collection.
//
// A standard TON NFT collection (TEP-62 items, TEP-64 metadata, TEP-66 royalty) built on the official Tolk NFT
// collection, with one difference in who may mint: ANYONE may mint, paying for it themselves, provided they bring a
// voucher the Relicade server signed for that one cat. The server decides who may mint what (a cat the player really
// built, at most 3 a day); this contract only checks the signature.
//
// One mint per cat is enforced here, not only by the server: a cat's NFT index IS its cat number, and an item's
// address follows from its index, so a second mint of the same cat lands on a contract that already exists, is
// refused by it and bounces back. Because indexes are cat numbers and not 0, 1, 2..., get_collection_data reports
// nextItemIndex = -1, which is how the standard says "not sequential".
//
// There is no way to change this contract's code after it is deployed, and no way for anyone, the admin included,
// to move or alter an NFT that has been minted.

import "@stdlib/strings"
import "errors"
import "storage"
import "messages"

contract PlushCollection {
    author: "Chilled Cat"
    incomingMessages: AllowedMessageToPlushCollection
    storage: PlushCollectionStorage
}

// ---- amounts ----
const ITEM_VALUE = ton("0.05")        // what a new item is given to live on (the item keeps 0.05 for storage)
const MIN_MINT_VALUE = ton("0.08")    // the least a mint message must carry; what is not used is sent back
const MIN_BALANCE = ton("0.05")       // what the collection itself always keeps for storage
const MINT_FEES_ALLOWANCE = MIN_MINT_VALUE - ITEM_VALUE   // what a mint must bring on top of the item's money, for fees

// ---- errors (401 and 333 are the standard collection's, in errors.tolk) ----
const ERROR_MINTING_CLOSED = 410
const ERROR_BAD_SIGNATURE = 411
const ERROR_WRONG_COLLECTION = 412
const ERROR_VOUCHER_EXPIRED = 413
const ERROR_NOT_ENOUGH_VALUE = 414
const ERROR_NOTHING_TO_WITHDRAW = 415
const ERROR_BAD_ROYALTY = 416

struct PlushCollectionStorage {
    adminAddress: address
    minted: uint64                        // how many cats have been minted
    lastSerial: uint64                    // the serial number given to the newest cat; only ever goes up
    signerKey: uint256                    // the key vouchers must be signed with; 0 = minting is closed
    content: Cell<CollectionContent>
    nftItemCode: cell
    royaltyParams: Cell<RoyaltyParams>
}

fun PlushCollectionStorage.load() {
    return PlushCollectionStorage.fromCell(contract.getData())
}

fun PlushCollectionStorage.save(self) {
    contract.setData(self.toCell())
}

// ---- messages ----

// What the server signs. A voucher is good for one cat, one receiving wallet and one collection, until it runs out.
struct MintVoucher {
    collection: address
    catId: uint64
    owner: address
    validUntil: uint32
    content: string           // the end of the item's metadata address, for example "123.json"
    recipe: string            // every piece on the cat; kept by the NFT for good
}

// From anyone: the voucher and the server's signature of it.
struct (0x6d696e74) MintWithVoucher {
    queryId: uint64
    signature: bits512
    voucher: Cell<MintVoucher>
}

// From the admin only: a mint without a voucher. The cat's builder is recorded as `ownerAddress`.
struct (0x00000001) AdminMint {
    queryId: uint64
    itemIndex: uint64
    attachTonAmount: coins
    ownerAddress: address
    content: string
    recipe: string
}

// From the admin only. ChangeCollectionAdmin (3) is the standard collection's, in messages.tolk.
struct (0x00000004) ChangeCollectionContent {
    queryId: uint64
    content: Cell<CollectionContent>
    royaltyParams: Cell<RoyaltyParams>
}

struct (0x00000005) SetSignerKey {
    queryId: uint64
    signerKey: uint256        // 0 closes minting
}

struct (0x00000006) WithdrawSurplus {
    queryId: uint64
}

type AllowedMessageToPlushCollection =
    | MintWithVoucher
    | RequestRoyaltyParams
    | AdminMint
    | ChangeCollectionAdmin
    | ChangeCollectionContent
    | SetSignerKey
    | WithdrawSurplus

// Mints one cat to `owner`, who goes down as its builder, and gives it the next serial number.
fun PlushCollectionStorage.mintCat(mutate self, itemIndex: int, attachTonAmount: coins, owner: address, content: string, recipe: string) {
    self.lastSerial += 1;
    self.minted += 1;
    val birth: CatBirth = {
        builder: owner,
        serial: self.lastSerial,
        mintedAt: blockchain.now(),
        recipe,
    };
    val initParams: NftItemInitAtDeployment = {
        ownerAddress: owner,
        content,
        birth: birth.toCell(),
    };
    deployNftItem(itemIndex, self.nftItemCode, attachTonAmount, initParams.toCell());
}

fun deployNftItem(itemIndex: int, nftItemCode: cell, attachTonAmount: coins, initParams: Cell<NftItemInitAtDeployment>) {
    val deployMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: calcDeployedNftItem(itemIndex, contract.getAddress(), nftItemCode),
        value: attachTonAmount,
        body: initParams,
    });
    deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

// What this contract held before the message it is handling arrived with `messageValue`.
fun balanceBeforeMessage(messageValue: coins): coins {
    return contract.getOriginalBalance() - messageValue;
}

// What a mint must bring besides the item's money and the fees: whatever the collection is short of its own storage
// money. Nothing, as a rule: the collection is deployed with more than MIN_BALANCE.
fun shortOfMinBalance(messageValue: coins): coins {
    return max(0, MIN_BALANCE - balanceBeforeMessage(messageValue));
}

// Sends everything this contract holds beyond what was reserved, as the standard "excesses" message.
fun sendRest(to: address, queryId: uint64) {
    val restMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: ReturnExcessesBack { queryId },
    });
    // a failure here must not undo what was done before it
    restMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToPlushCollection.fromSlice(in.body);

    match (msg) {
        MintWithVoucher => {
            var storage = lazy PlushCollectionStorage.load();
            assert (storage.signerKey != 0) throw ERROR_MINTING_CLOSED;
            assert (isSignatureValid(msg.voucher.hash(), msg.signature as slice, storage.signerKey)) throw ERROR_BAD_SIGNATURE;

            val voucher = msg.voucher.load();
            assert (voucher.collection == contract.getAddress()) throw ERROR_WRONG_COLLECTION;
            assert (voucher.owner.getWorkchain() == BASECHAIN) throw ERROR_INVALID_WORKCHAIN;
            assert (blockchain.now() <= voucher.validUntil) throw ERROR_VOUCHER_EXPIRED;
            // The payment must cover the mint and, if the collection is below its storage money, the top-up too.
            // Refusing here, while the message is still being read, sends the whole payment back; a mint that ran
            // out of money later, when the item is sent, would keep the payment and make no cat.
            assert (in.valueCoins >= MIN_MINT_VALUE + shortOfMinBalance(in.valueCoins)) throw ERROR_NOT_ENOUGH_VALUE;

            // Keep what the collection had before this message (never less than its storage money); the item gets
            // its share, and whatever is left of the player's payment goes back to whoever paid.
            reserveToncoinsOnBalance(max(balanceBeforeMessage(in.valueCoins), MIN_BALANCE), RESERVE_MODE_EXACT_AMOUNT);
            storage.mintCat(voucher.catId, ITEM_VALUE, voucher.owner, voucher.content, voucher.recipe);
            sendRest(in.senderAddress, msg.queryId);
            storage.save();
        }

        RequestRoyaltyParams => {
            val storage = lazy PlushCollectionStorage.load();
            val respondMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ResponseRoyaltyParams {
                    queryId: msg.queryId,
                    royaltyParams: storage.royaltyParams.load(),
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        AdminMint => {
            var storage = lazy PlushCollectionStorage.load();
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_FROM_ADMIN;
            assert (msg.ownerAddress.getWorkchain() == BASECHAIN) throw ERROR_INVALID_WORKCHAIN;
            // An item needs its storage money, and the message must pay for it: an item sent with nothing would
            // count a cat that does not exist.
            assert (msg.attachTonAmount >= ITEM_VALUE) throw ERROR_NOT_ENOUGH_VALUE;
            assert (in.valueCoins >= msg.attachTonAmount + MINT_FEES_ALLOWANCE + shortOfMinBalance(in.valueCoins)) throw ERROR_NOT_ENOUGH_VALUE;

            // As for a player's mint, the collection keeps what it had (never less than its storage money). What
            // is left of the admin's payment stays in the collection, as before; WithdrawSurplus takes it out.
            reserveToncoinsOnBalance(max(balanceBeforeMessage(in.valueCoins), MIN_BALANCE), RESERVE_MODE_EXACT_AMOUNT);
            storage.mintCat(msg.itemIndex, msg.attachTonAmount, msg.ownerAddress, msg.content, msg.recipe);
            storage.save();
        }

        ChangeCollectionAdmin => {
            var storage = lazy PlushCollectionStorage.load();
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_FROM_ADMIN;
            assert (msg.newAdminAddress.getWorkchain() == BASECHAIN) throw ERROR_INVALID_WORKCHAIN;
            storage.adminAddress = msg.newAdminAddress;
            storage.save();
        }

        ChangeCollectionContent => {
            var storage = lazy PlushCollectionStorage.load();
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_FROM_ADMIN;
            val royalty = msg.royaltyParams.load();
            assert (royalty.denominator > 0 && royalty.numerator <= royalty.denominator) throw ERROR_BAD_ROYALTY;
            storage.content = msg.content;
            storage.royaltyParams = msg.royaltyParams;
            storage.save();
        }

        SetSignerKey => {
            var storage = lazy PlushCollectionStorage.load();
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_FROM_ADMIN;
            storage.signerKey = msg.signerKey;
            storage.save();
        }

        WithdrawSurplus => {
            val storage = lazy PlushCollectionStorage.load();
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_FROM_ADMIN;
            assert (contract.getOriginalBalance() - in.valueCoins > MIN_BALANCE) throw ERROR_NOTHING_TO_WITHDRAW;
            reserveToncoinsOnBalance(MIN_BALANCE, RESERVE_MODE_EXACT_AMOUNT);
            sendRest(storage.adminAddress, msg.queryId);
        }

        else => {
            // a plain transfer of coins is kept, for storage; "wrong opcode" for anything else
            assert (in.body.isEmpty()) throw 0xFFFF
        }
    }
}

// The only messages this contract sends that can bounce are item deployments, and one bounces only when that cat was
// minted before. So a bounce means the mint just counted did not happen. The count is put right; the serial number
// that mint was given is not handed out again, so no two cats can ever share one (a refused mint leaves a gap).
fun onBouncedMessage(in: InMessageBounced) {
    var storage = lazy PlushCollectionStorage.load();
    if (storage.minted > 0) {
        storage.minted -= 1;
        storage.save();
    }
}


struct CollectionDataReply {
    nextItemIndex: int
    collectionMetadata: cell
    adminAddress: address
}

// nextItemIndex is -1: the indexes are cat numbers, not a run from 0 (TEP-62).
get fun get_collection_data(): CollectionDataReply {
    val storage = lazy PlushCollectionStorage.load();
    val content = lazy storage.content.load();

    return {
        nextItemIndex: -1,
        collectionMetadata: content.collectionMetadata,
        adminAddress: storage.adminAddress,
    }
}

get fun get_nft_address_by_index(itemIndex: int): address {
    val storage = lazy PlushCollectionStorage.load();
    val nftDeployed = calcDeployedNftItem(itemIndex, contract.getAddress(), storage.nftItemCode);
    return nftDeployed.calculateAddress();
}

get fun royalty_params(): RoyaltyParams {
    val storage = lazy PlushCollectionStorage.load();
    return storage.royaltyParams.load();
}

get fun get_nft_content(itemIndex: int, individualNftContent: string): string_prefixed0x {
    val storage = lazy PlushCollectionStorage.load();
    val content = lazy storage.content.load();

    return StringBuilder.create()
        .append(content.commonContent)
        .append(individualNftContent)
        .build()
        .prefixWith01()     // to comply TEP: "off-chain content layout"
}

struct MintDataReply {
    minted: int
    lastSerial: int
    signerKey: uint256
    minMintValue: coins
}

// How many cats have been minted, the newest cat's serial number, the key vouchers must be signed with (0 = minting is closed), and the least a mint
// message must carry.
get fun get_mint_data(): MintDataReply {
    val storage = lazy PlushCollectionStorage.load();
    return {
        minted: storage.minted,
        lastSerial: storage.lastSerial,
        signerKey: storage.signerKey,
        minMintValue: MIN_MINT_VALUE,
    }
}
