import "@stdlib/gas-payments"
import "deal-signed-payloads"

tolk 1.4.2

enum Status: uint2 {
    Awaiting = 0,
    Completed = 1,
    Cancelled = 2,
    Funded = 3,
}

const OP_NFT_TRANSFER: int = 0x5fcc3d14;

const COMMENT_CANCEL: int = 0x63616e63656c;

const TOPIC_NFT_TRANSFER_BOUNCED: int = 0x4254424E;

const NFT_TRANSFER_VALUE = ton("0.05");
const NFT_NOTIFY_VALUE = ton("0.05");
const MIN_TOLL_PER_ASSET = ton("0.1");
const MONEY_MESSAGE_TOLL = ton("0.01");
const BASE_PAYOUT_GAS = ton("0.02");
const PER_ASSET_PAYOUT_GAS = ton("0.005");
const STORAGE_RESERVE = ton("0.001");

const MAX_LIFETIME = 0x1000000;
const MAX_SIDE_ASSETS = 10;

const ADDRESS_BITS = 267;
const ADDR_STD_TAG = 2;

struct AssetEntry {
    credited: bool
    held: bool
}

struct DealSide {
    ownerAddress: address
    assetCount: uint8
    offchainAssetCount: uint8
    receivedCount: uint8
    heldOnlyCount: uint8
    arrivedCount: uint8
    paid: coins
    assets: map<uint256, AssetEntry>
}

struct Terms {
    publicKey: uint256
    surcharge: coins
    platformFee: coins
    tollPerAsset: coins
    feePerAsset: coins
    surchargeFromInitiator: bool
    lifetime: uint32
}

struct Storage {
    status: Status
    deployerAddress: address
    marketplaceAddress: address
    marketplaceFeeAddress: address
    salt: uint64
    deadline: uint32
    terms: Cell<Terms>
    initiator: Cell<DealSide>
    taker: Cell<DealSide>
}

fun Storage.load() {
    return Storage.fromCell(contract.getData())
}

fun Storage.save(self) {
    contract.setData(self.toCell())
}

struct (0x00000000) TextComment {
    text: RemainingBitsAndRefs
}

struct (0x69cb28f3) AddDealAsset {
    queryId: uint64
    signedDeposit: Cell<SignedPayload>
}

struct (0x05138d91) OwnershipAssigned {
    rest: RemainingBitsAndRefs
}

struct (0x20c6b8fa) TopUp {}

struct (0x88103986) CancelDeal {
    queryId: uint64
}

struct (0x5d42014a) TouchDeal {
    queryId: uint64
}

struct (0x3ef2b4c1) FinalizeDeal {
    queryId: uint64
}

struct (0x7a06d5e8) AbortDeal {
    queryId: uint64
}

struct ProxiedMessage {
    mode: uint8
    message: cell
}

struct (0x0000022b) Emergency {
    queryId: uint64
    proxied: Cell<ProxiedMessage>
}

type DealMessage = TextComment | AddDealAsset | OwnershipAssigned | TopUp | CancelDeal | TouchDeal
    | FinalizeDeal | AbortDeal | Emergency

struct (0x9d1b4f07) DeclineDeal {
    signed: SignedPayload
}

struct (0x9d1b4f07) DeclinePayload {
    dealAddress: address
    validUntil: uint32
    comment: cell?
}

struct (0xcbaa2f44) ExpireDeal {}

type ExternalMessage = DeclineDeal | ExpireDeal

struct (0x5fcc3d14) NftTransfer {
    queryId: uint64
    newOwner: address
    responseDestination: address
    customPayload: cell?
    forwardTonAmount: coins
    forwardPayload: cell?
}

const ERR_PAYLOAD_FOR_ANOTHER_OP = 420;

@inline
fun payoutGas(assetCount: int): int {
    return BASE_PAYOUT_GAS + assetCount * PER_ASSET_PAYOUT_GAS;
}

@inline
fun termsAreUsable(terms: Terms): bool {
    return (terms.tollPerAsset >= MIN_TOLL_PER_ASSET)
        & (terms.platformFee <= terms.surcharge)
        & (terms.feePerAsset + NFT_TRANSFER_VALUE + PER_ASSET_PAYOUT_GAS <= terms.tollPerAsset)
        & (terms.lifetime > 0) & (terms.lifetime <= MAX_LIFETIME);
}

@inline
fun sideFits(side: DealSide): bool {
    return side.assetCount + side.offchainAssetCount <= MAX_SIDE_ASSETS;
}

@inline
fun dealIsUsable(terms: Terms, initiator: DealSide, taker: DealSide): bool {
    return termsAreUsable(terms) & sideFits(initiator) & sideFits(taker);
}

@inline
fun sideDue(terms: Terms, side: DealSide, owesSurcharge: bool): int {
    val surchargeDue = owesSurcharge ? terms.surcharge as int : 0;
    return terms.feePerAsset * side.offchainAssetCount + surchargeDue;
}

@inline
fun sideIsFunded(terms: Terms, side: DealSide, owesSurcharge: bool): bool {
    return (side.arrivedCount == side.assetCount) & (side.paid >= sideDue(terms, side, owesSurcharge));
}

@inline
fun sideIsEmpty(side: DealSide): bool {
    return (side.receivedCount == 0) & (side.heldOnlyCount == 0) & (side.paid == 0);
}

@inline
fun takerStarted(taker: DealSide): bool {
    return (taker.receivedCount > 0) | (taker.paid > 0);
}

@inline
fun takerMayEnter(storage: Storage): bool {
    return (storage.deadline != 0) & (blockchain.now() <= storage.deadline);
}

@inline
fun takerWindowDeadline(deadline: int, terms: Terms): int {
    val opensAt = blockchain.now() + terms.lifetime;
    return opensAt > deadline ? opensAt : deadline;
}

@inline
fun hasOffchainLeg(initiator: DealSide, taker: DealSide): bool {
    return (initiator.offchainAssetCount + taker.offchainAssetCount) > 0;
}

fun hatchIsOpen(storage: Storage): bool {
    if ((storage.status == Status.Completed) | (storage.status == Status.Cancelled)) {
        return true;
    }
    if (storage.status != Status.Awaiting) {
        return false;
    }
    return sideIsEmpty(storage.initiator.load()) & sideIsEmpty(storage.taker.load());
}

@inline
fun isStdAddress(body: slice): bool {
    return body.preloadUint(2) == ADDR_STD_TAG;
}

@noinline
fun sendMoney(dest: address, amount: int, mode: int) {
    val msg = createMessage({
        bounce: BounceMode.NoBounce,
        value: amount,
        dest: dest,
    });
    msg.send(mode);
}

@inline
fun sendMoneyWithComment(dest: address, amount: int, mode: int, comment: cell) {
    val msg = createMessage({
        bounce: BounceMode.NoBounce,
        value: amount,
        dest: dest,
        body: comment,
    });
    msg.send(mode);
}

@noinline
fun transferNft(nftAddress: address, newOwner: address, responseAddress: address, queryId: int) {
    val msg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: NFT_TRANSFER_VALUE,
        dest: nftAddress,
        body: NftTransfer {
            queryId,
            newOwner,
            responseDestination: responseAddress,
            customPayload: null,
            forwardTonAmount: 1,
            forwardPayload: null,
        },
    });
    msg.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

@noinline
fun returnNft(nftAddress: address, newOwner: address, queryId: int) {
    val msg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: 0,
        dest: nftAddress,
        body: NftTransfer {
            queryId,
            newOwner,
            responseDestination: newOwner,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: null,
        },
    });
    msg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE + SEND_MODE_IGNORE_ERRORS);
}

@inline
fun refundDeposit(dest: address) {
    sendMoney(dest, 0, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE + SEND_MODE_IGNORE_ERRORS);
}

fun dispatchSideAssets(assets: map<uint256, AssetEntry>, newOwner: address, responseAddress: address,
                       queryId: int, creditedOnly: bool) {
    var entry = assets.findFirst();
    while (entry.isFound) {
        val asset = entry.loadValue();
        if (asset.credited | (asset.held & !creditedOnly)) {
            transferNft(address.fromWorkchainAndHash(BASECHAIN, entry.getKey()), newOwner, responseAddress, queryId);
        }
        entry = assets.iterateNext(entry);
    }
}

@inline
fun notifyRefund(side: DealSide): int {
    return NFT_NOTIFY_VALUE * side.arrivedCount;
}

fun executionPayouts(terms: Terms, initiator: DealSide, taker: DealSide) {
    val surchargeNet = terms.surcharge - terms.platformFee;
    val initiatorDue = sideDue(terms, initiator, terms.surchargeFromInitiator) - notifyRefund(initiator);
    val takerDue = sideDue(terms, taker, !terms.surchargeFromInitiator) - notifyRefund(taker);
    if (terms.surchargeFromInitiator) {
        return (initiator.paid - initiatorDue, taker.paid - takerDue + surchargeNet)
    }
    return (initiator.paid - initiatorDue + surchargeNet, taker.paid - takerDue)
}

fun cancelRequirement(storage: Storage): int {
    val initiator = storage.initiator.load();
    val taker = storage.taker.load();
    val assetCount = initiator.receivedCount + initiator.heldOnlyCount
        + taker.receivedCount + taker.heldOnlyCount;

    return assetCount * NFT_TRANSFER_VALUE + payoutGas(assetCount) + STORAGE_RESERVE;
}

fun settleCancel(storage: Storage, queryId: int, refundTo: address, refundAmount: coins, comment: cell?) {
    val forAssets = cancelRequirement(storage);
    assert(contract.getOriginalBalance() >= forAssets) throw 504;

    val terms = storage.terms.load();
    val initiator = storage.initiator.load();
    val taker = storage.taker.load();
    val takerAmount = taker.paid + terms.feePerAsset * taker.receivedCount + notifyRefund(taker);

    dispatchSideAssets(initiator.assets, initiator.ownerAddress, initiator.ownerAddress, queryId, false);
    dispatchSideAssets(taker.assets, taker.ownerAddress, taker.ownerAddress, queryId, false);

    var left = contract.getOriginalBalance() - forAssets;
    val takerPayout = takerAmount < left ? takerAmount : left;
    if (takerPayout > 0) {
        sendMoney(taker.ownerAddress, takerPayout, SEND_MODE_PAY_FEES_SEPARATELY);
        left = left - takerPayout;
    }
    val refund = refundAmount < left ? refundAmount : left;
    if ((refund > 0) & (refundTo != initiator.ownerAddress)) {
        sendMoney(refundTo, refund, SEND_MODE_PAY_FEES_SEPARATELY);
    }

    var updated = storage;
    updated.status = Status.Cancelled;
    updated.save();

    reserveToncoinsOnBalance(STORAGE_RESERVE, RESERVE_MODE_AT_MOST);
    val sweepMode = SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_IGNORE_ERRORS;
    if (comment != null) {
        sendMoneyWithComment(initiator.ownerAddress, 0, sweepMode, comment);
    } else {
        sendMoney(initiator.ownerAddress, 0, sweepMode);
    }
}

fun settleExecution(storage: Storage, terms: Terms, initiator: DealSide, taker: DealSide, queryId: int): bool {
    val (initiatorAmount, takerAmount) = executionPayouts(terms, initiator, taker);
    val assetCount = initiator.receivedCount + taker.receivedCount;
    val required = assetCount * NFT_TRANSFER_VALUE
        + initiatorAmount + takerAmount + terms.platformFee + payoutGas(assetCount) + STORAGE_RESERVE;
    if (contract.getOriginalBalance() < required) {
        return false;
    }

    dispatchSideAssets(initiator.assets, taker.ownerAddress, initiator.ownerAddress, queryId, true);
    dispatchSideAssets(taker.assets, initiator.ownerAddress, taker.ownerAddress, queryId, true);
    if (initiatorAmount > 0) {
        sendMoney(initiator.ownerAddress, initiatorAmount, SEND_MODE_PAY_FEES_SEPARATELY);
    }
    if (takerAmount > 0) {
        sendMoney(taker.ownerAddress, takerAmount, SEND_MODE_PAY_FEES_SEPARATELY);
    }

    var updated = storage;
    updated.status = Status.Completed;
    updated.save();

    reserveToncoinsOnBalance(STORAGE_RESERVE, RESERVE_MODE_AT_MOST);
    sendMoney(storage.marketplaceFeeAddress, 0, SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_IGNORE_ERRORS);
    return true;
}

fun tryExecute(storage: Storage, queryId: int) {
    if (storage.status != Status.Awaiting) {
        return;
    }

    val terms = storage.terms.load();
    val initiator = storage.initiator.load();
    val taker = storage.taker.load();

    if (!sideIsFunded(terms, initiator, terms.surchargeFromInitiator)) {
        return;
    }

    var updated = storage;
    if (updated.deadline == 0) {
        updated.deadline = blockchain.now() + terms.lifetime;
        updated.save();
    }

    if (blockchain.now() > updated.deadline) {
        return;
    }

    if (!sideIsFunded(terms, taker, !terms.surchargeFromInitiator)) {
        return;
    }

    if (hasOffchainLeg(initiator, taker)) {
        var funded = updated;
        funded.status = Status.Funded;
        funded.save();
        return;
    }

    settleExecution(updated, terms, initiator, taker, queryId);
}

fun findAsset(initiator: DealSide, taker: DealSide, nftHash: uint256) {
    val inInitiator = initiator.assets.get(nftHash);
    if (inInitiator.isFound) {
        return (true, initiator, inInitiator);
    }
    return (false, taker, taker.assets.get(nftHash));
}

fun Storage.putSide(mutate self, isInitiator: bool, side: DealSide) {
    if (isInitiator) {
        self.initiator = side.toCell();
    } else {
        self.taker = side.toCell();
    }
}

fun creditAsset(storage: Storage, nftAddress: address, prevOwner: address, signedToll: int,
                msgValue: int, queryId: int) {
    val (nftWorkchain, nftHash) = nftAddress.getWorkchainAndHash();

    var updated = storage;
    val initiator = updated.initiator.load();
    val taker = updated.taker.load();
    var (isInitiatorAsset, side, lookup) = findAsset(initiator, taker, nftHash);

    val terms = updated.terms.load();
    val acceptable = lookup.isFound
        & (nftWorkchain == BASECHAIN)
        & (side.ownerAddress == prevOwner)
        & (signedToll == terms.tollPerAsset)
        & (updated.status == Status.Awaiting)
        & dealIsUsable(terms, initiator, taker);

    if (!acceptable) {
        refundDeposit(prevOwner);
        return;
    }

    if (!isInitiatorAsset & !takerMayEnter(updated)) {
        if (msgValue > terms.tollPerAsset) {
            sendMoney(prevOwner, msgValue - terms.tollPerAsset, SEND_MODE_PAY_FEES_SEPARATELY + SEND_MODE_IGNORE_ERRORS);
        }
        return;
    }

    val asset = lookup.loadValue();
    if (asset.credited) {
        refundDeposit(prevOwner);
        return;
    }

    if (!isInitiatorAsset & !takerStarted(side)) {
        updated.deadline = takerWindowDeadline(updated.deadline, terms);
    }

    side.assets.set(nftHash, { credited: true, held: asset.held });
    side.receivedCount = side.receivedCount + 1;
    if (asset.held) {
        side.heldOnlyCount = side.heldOnlyCount - 1;
        side.arrivedCount = side.arrivedCount + 1;
    }
    if (msgValue > terms.tollPerAsset) {
        side.paid = side.paid + msgValue - terms.tollPerAsset;
    }

    updated.putSide(isInitiatorAsset, side);
    updated.save();
    tryExecute(updated, queryId);
}

fun noteAssetHeld(storage: Storage, nftAddress: address, depositor: address,
                  depositorIsKnown: bool, queryId: int) {
    val (nftWorkchain, nftHash) = nftAddress.getWorkchainAndHash();

    var updated = storage;
    val initiator = updated.initiator.load();
    val taker = updated.taker.load();
    var (isInitiatorAsset, side, lookup) = findAsset(initiator, taker, nftHash);

    val terms = updated.terms.load();
    val found = lookup.isFound & (nftWorkchain == BASECHAIN) & dealIsUsable(terms, initiator, taker);
    if (!found) {
        returnNft(nftAddress, depositor, queryId);
        return;
    }

    if (updated.status != Status.Awaiting) {
        returnNft(nftAddress, depositorIsKnown ? depositor : side.ownerAddress, queryId);
        return;
    }

    val asset = lookup.loadValue();

    if (asset.held) {
        return;
    }

    if (asset.credited) {
        side.assets.set(nftHash, { credited: true, held: true });
        side.arrivedCount = side.arrivedCount + 1;
        updated.putSide(isInitiatorAsset, side);
        updated.save();
        tryExecute(updated, queryId);
        return;
    }

    if (depositorIsKnown & (depositor != side.ownerAddress)) {
        returnNft(nftAddress, depositor, queryId);
        return;
    }

    side.assets.set(nftHash, { credited: false, held: true });
    side.heldOnlyCount = side.heldOnlyCount + 1;
    updated.putSide(isInitiatorAsset, side);
    updated.save();
}

fun handleOwnershipAssigned(storage: Storage, nftAddress: address, body: slice) {
    var rest = body;
    val queryId = rest.remainingBitsCount() >= 64 ? rest.loadUint(64) : 0;
    if ((rest.remainingBitsCount() < ADDRESS_BITS) || !isStdAddress(rest)) {
        returnNft(nftAddress, storage.deployerAddress, queryId);
        return;
    }
    val prevOwner = rest.loadAddress();

    if (prevOwner != storage.deployerAddress) {
        returnNft(nftAddress, prevOwner, queryId);
        return;
    }

    var depositor = prevOwner;
    var depositorIsKnown = false;
    if (rest.remainingBitsCount() >= 1) {
        val payloadInRef = rest.loadBool();
        var payload = rest;
        var payloadIsThere = true;
        if (payloadInRef) {
            if (rest.remainingRefsCount() >= 1) {
                payload = rest.loadRef().beginParse();
            } else {
                payloadIsThere = false;
            }
        }
        if (payloadIsThere & (payload.remainingBitsCount() >= ADDRESS_BITS)) {
            if (isStdAddress(payload)) {
                depositor = payload.loadAddress();
                depositorIsKnown = true;
            }
        }
    }

    noteAssetHeld(storage, nftAddress, depositor, depositorIsKnown, queryId);
}

fun acceptTopUp(storage: Storage, senderAddress: address, msgValue: int) {
    assert(storage.status == Status.Awaiting) throw 501;
    val terms = storage.terms.load();
    var initiator = storage.initiator.load();
    var taker = storage.taker.load();
    assert(dealIsUsable(terms, initiator, taker)) throw 502;

    val credited = msgValue > MONEY_MESSAGE_TOLL ? msgValue - MONEY_MESSAGE_TOLL : 0;
    var updated = storage;

    if (senderAddress == initiator.ownerAddress) {
        initiator.paid = initiator.paid + credited;
        updated.initiator = initiator.toCell();
    } else {
        if (senderAddress != taker.ownerAddress) {
            assert(senderAddress == updated.marketplaceAddress) throw 405;
            tryExecute(updated, 0);
            return;
        }
        if (!takerMayEnter(updated)) {
            refundDeposit(senderAddress);
            return;
        }
        if (!takerStarted(taker) & (credited > 0)) {
            updated.deadline = takerWindowDeadline(updated.deadline, terms);
        }
        taker.paid = taker.paid + credited;
        updated.taker = taker.toCell();
    }

    updated.save();
    tryExecute(updated, 0);
}

fun cancelDeal(storage: Storage, senderAddress: address, msgValue: coins, queryId: int) {
    assert(storage.status == Status.Awaiting) throw 501;

    val initiator = storage.initiator.load();
    val taker = storage.taker.load();
    assert((senderAddress == initiator.ownerAddress) | (senderAddress == taker.ownerAddress)
        | (senderAddress == storage.marketplaceAddress)) throw 502;

    settleCancel(storage, queryId, senderAddress, msgValue, null);
}

fun abortDeal(storage: Storage, senderAddress: address, msgValue: coins, queryId: int) {
    assert(senderAddress == storage.marketplaceAddress) throw 403;
    assert((storage.status == Status.Awaiting) | (storage.status == Status.Funded)) throw 501;

    settleCancel(storage, queryId, senderAddress, msgValue, null);
}

fun finalizeDeal(storage: Storage, senderAddress: address, queryId: int) {
    assert(senderAddress == storage.marketplaceAddress) throw 403;
    assert(storage.status == Status.Funded) throw 501;

    val settled = settleExecution(storage, storage.terms.load(),
        storage.initiator.load(), storage.taker.load(), queryId);
    assert(settled) throw 504;
}

fun onInternalMessage(inMsg: InMessage) {
    val senderAddress = inMsg.senderAddress;
    val msgValue = inMsg.valueCoins;
    var storage = lazy Storage.load();

    if (inMsg.body.remainingBitsCount() < 32) {
        acceptTopUp(storage, senderAddress, msgValue);
        return;
    }

    val msg = lazy DealMessage.fromSlice(inMsg.body);
    match (msg) {
        TextComment => {
            var text = msg.text;
            val isCancelComment = (text.remainingBitsCount() == 48) & (text.remainingRefsCount() == 0)
                && (text.loadUint(48) == COMMENT_CANCEL);
            if (isCancelComment) {
                cancelDeal(storage, senderAddress, msgValue, 0);
            } else {
                acceptTopUp(storage, senderAddress, msgValue);
            }
        }
        AddDealAsset => {
            assert(senderAddress == storage.deployerAddress) throw 402;

            val signed = msg.signedDeposit.load();
            val terms = storage.terms.load();
            assert(isSignatureValid(signed.payload.hash(), signed.signature as slice, terms.publicKey)) throw 35;

            val payload = DepositPayload.fromCell(signed.payload, { throwIfOpcodeDoesNotMatch: ERR_PAYLOAD_FOR_ANOTHER_OP });
            assert(payload.dealAddress == contract.getAddress()) throw 419;

            creditAsset(storage, payload.nftAddress, payload.prevOwner, payload.toll, msgValue, msg.queryId);
        }
        OwnershipAssigned => {
            handleOwnershipAssigned(storage, senderAddress, msg.rest);
        }
        TopUp => {
            acceptTopUp(storage, senderAddress, msgValue);
        }
        TouchDeal => {
            acceptTopUp(storage, senderAddress, msgValue);
        }
        CancelDeal => {
            cancelDeal(storage, senderAddress, msgValue, msg.queryId);
        }
        AbortDeal => {
            abortDeal(storage, senderAddress, msgValue, msg.queryId);
        }
        FinalizeDeal => {
            finalizeDeal(storage, senderAddress, msg.queryId);
        }
        Emergency => {
            assert(senderAddress == storage.marketplaceAddress) throw 403;
            assert(hatchIsOpen(storage)) throw 501;

            val proxied = msg.proxied.load();
            assert((proxied.mode & SEND_MODE_DESTROY) != SEND_MODE_DESTROY) throw 505;
            val out: OutMessage = { messageCell: proxied.message };
            out.send(proxied.mode);
        }
        else => {
            throw 0xffff;
        }
    }
}

fun onExternalMessage(inMsg: slice) {
    var storage = lazy Storage.load();

    val msg = lazy ExternalMessage.fromSlice(inMsg);
    match (msg) {
        DeclineDeal => {
            assert(storage.status == Status.Awaiting) throw 501;
            val terms = storage.terms.load();
            val signed = msg.signed;
            assert(isSignatureValid(signed.payload.hash(), signed.signature as slice, terms.publicKey)) throw 35;

            val payload = DeclinePayload.fromCell(signed.payload, { throwIfOpcodeDoesNotMatch: ERR_PAYLOAD_FOR_ANOTHER_OP });
            assert(payload.dealAddress == contract.getAddress()) throw 419;
            assert(blockchain.now() <= payload.validUntil) throw 507;
            assert(contract.getOriginalBalance() >= cancelRequirement(storage)) throw 504;

            acceptExternalMessage();
            settleCancel(storage, 0, storage.marketplaceFeeAddress, 0, payload.comment);
        }
        ExpireDeal => {
            assert(storage.status == Status.Awaiting) throw 501;
            assert(storage.deadline != 0) throw 503;
            assert(blockchain.now() > storage.deadline) throw 503;
            assert(contract.getOriginalBalance() >= cancelRequirement(storage)) throw 504;

            acceptExternalMessage();
            settleCancel(storage, 0, storage.marketplaceFeeAddress, 0, null);
        }
        else => {
            throw 0xffff;
        }
    }
}

fun onBouncedMessage(inMsg: InMessageBounced) {
    var bouncedBody = inMsg.bouncedBody;
    bouncedBody.skipBouncedPrefix();
    if (bouncedBody.remainingBitsCount() < 32 + 64) {
        return;
    }

    val op = bouncedBody.loadUint(32);
    if (op != OP_NFT_TRANSFER) {
        return;
    }
    val queryId = bouncedBody.loadUint(64);

    val logMsg = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: TOPIC_NFT_TRANSFER_BOUNCED },
        body: beginCell()
            .storeAddress(inMsg.senderAddress)
            .storeUint(queryId, 64)
            .endCell(),
    });
    logMsg.send(SEND_MODE_REGULAR);
}

get fun get_deal_data() {
    var storage = lazy Storage.load();
    val terms = storage.terms.load();
    val initiator = storage.initiator.load();
    val taker = storage.taker.load();

    return (
        storage.status as int,
        storage.deployerAddress,
        storage.marketplaceAddress,
        storage.marketplaceFeeAddress,
        storage.salt,
        storage.deadline,
        terms.surcharge,
        terms.platformFee,
        terms.tollPerAsset,
        terms.feePerAsset,
        terms.surchargeFromInitiator,
        terms.lifetime,
        initiator.ownerAddress,
        initiator.assetCount,
        initiator.offchainAssetCount,
        initiator.receivedCount,
        initiator.heldOnlyCount,
        initiator.arrivedCount,
        initiator.paid,
        initiator.assets,
        taker.ownerAddress,
        taker.assetCount,
        taker.offchainAssetCount,
        taker.receivedCount,
        taker.heldOnlyCount,
        taker.arrivedCount,
        taker.paid,
        taker.assets,
    )
}
