import "@contracts/common/comments/constants"
import "@contracts/common/comments/messages"
import "@contracts/common/comments/refund_reason"
import "@contracts/common/gas/constants"
import "@contracts/common/gas/costs"
import "@contracts/common/gas/types"
import "constants"
import "deliveries"
import "deposits"
import "messages"

fun NftDeliveries.deliverDepositedTo(mutate self, items: ItemDeposits, newOwner: address) {
    val payload = nftForwardPayload(null);
    val queryId = blockchain.logicalTime() as uint64;
    // Весь batch имеет один recipient/queryId. Сериализация один раз сохраняет hard gas limit
    // на 100 NFT; словарь хранит ровно прежний inline NftDelivery, без дополнительной ссылки.
    val encoded = NftDelivery {
        recipient: newOwner,
        queryId,
    }
    .toCell()
    .beginParse();
    var deliveries = self as unknown as map<address, RemainingBitsAndRefs>;
    var entry = items.findFirst();
    while (entry.isFound) {
        if (entry.loadValue().isDeposited()) {
            val nft = entry.getKey();
            deliveries.set(nft, encoded);
            sendNftWithPayload(nft, newOwner, contract.getAddress(), payload, queryId);
        }
        entry = items.iterateNext(entry);
    }
    self = deliveries as unknown as NftDeliveries;
}

// Автоматический возврат относится только к подтверждённым депозитам. Иначе пустая отмена
// создаёт ложные delivery failures и тратит резерв на NFT, которые escrow никогда не владел.
// Потерянный notification обслуживает caller-funded retry на committed refundRecipient.
fun NftDeliveries.returnEachToItsDepositor(
    mutate self,
    items: ItemDeposits,
    reason: RefundReason,
): int {
    val comment = TextComment { text: reason.comment() }.toCell();
    val payload = nftForwardPayload(comment);
    val queryId = blockchain.logicalTime() as uint64;
    // The typed template fixes comment/query/status once. Only the recipient varies; the
    // map still stores the exact inline NftDelivery schema used by retry/receipt readers.
    var suffix = NftDelivery {
        recipient: contract.getAddress(),
        comment,
        queryId,
    }
    .toCell()
    .beginParse();
    suffix.loadAddress();
    var deliveries = self as unknown as map<address, RemainingBitsAndRefs>;
    var deliveryCount = 0;
    var entry = items.findFirst();
    while (entry.isFound) {
        val deposit = entry.loadValue();
        val recipient = deposit.depositor;
        if (recipient != null) {
            val nft = entry.getKey();
            val encoded = beginCell().storeAddress(recipient).storeSlice(suffix).toSlice();
            deliveries.set(nft, encoded);
            sendNftWithPayload(nft, recipient, contract.getAddress(), payload, queryId);
            deliveryCount += 1;
        }
        entry = items.iterateNext(entry);
    }
    self = deliveries as unknown as NftDeliveries;
    return deliveryCount;
}

@inline
fun NftDeliveries.deliver(
    mutate self,
    nft: address,
    recipient: address,
    comment: Cell<TextComment>?,
) {
    self.deliverWithPayload(
        nft,
        recipient,
        comment,
        nftForwardPayload(comment),
        blockchain.logicalTime() as uint64,
    );
}

@inline
fun NftDeliveries.deliverWithPayload(
    mutate self,
    nft: address,
    recipient: address,
    comment: Cell<TextComment>?,
    payload: slice,
    queryId: uint64,
    sponsor: address? = null,
) {
    self.set(
        nft,
        {
            recipient,
            queryId,
            sponsor,
            comment,
        },
    );
    sendNftWithPayload(nft, recipient, contract.getAddress(), payload, queryId);
}

fun NftDeliveries.returnDeposits(mutate self, items: ItemDeposits, reason: RefundReason) {
    val comment = TextComment { text: reason.comment() }.toCell();
    val payload = nftForwardPayload(comment);
    val queryId = blockchain.logicalTime() as uint64;
    var entry = items.findFirst();
    while (entry.isFound) {
        val deposit = entry.loadValue();
        val recipient = deposit.depositor != null ? deposit.depositor : deposit.refundRecipient;
        if (recipient != null) {
            self.deliverWithPayload(
                entry.getKey(),
                recipient,
                comment,
                payload,
                queryId,
                recipient,
            );
        }
        entry = items.iterateNext(entry);
    }
}

@inline
fun sendNft(nft: address, newOwner: address, responseTo: address, comment: Cell<TextComment>?) {
    sendNftWithPayload(
        nft,
        newOwner,
        responseTo,
        nftForwardPayload(comment),
        blockchain.logicalTime() as uint64,
    );
}

// Длинные refund-комментарии идут ссылкой: существующие NFT могут собирать ownership_assigned
// прямо в root message, где inline-текст вызовет Cell overflow. Короткий settlement помещается.
@inline
fun nftForwardPayload(comment: Cell<TextComment>?): slice {
    if (comment != null) {
        return comment.forwardPayload();
    }
    return beginCell()
        .storeBool(false)
        .storeUint(0, 32)
        .storeSlice(SETTLEMENT_PAYMENT_COMMENT)
        .toSlice();
}

@inline
fun sendNftWithPayload(
    nft: address,
    newOwner: address,
    responseTo: address,
    payload: slice,
    queryId: uint64,
) {
    val body = NftTransfer {
        queryId,
        newOwner,
        responseDestination: responseTo,
        customPayload: null,
        forwardAmount: grams("0.000000001"),
        forwardPayload: payload,
    };
    val nftTransferMessage = createMessage({
        // Для классификации сбоя хватает opcode из обычного bounce. Полный body здесь только
        // раздувал forward fee; адрес назначения уже известен из immutable terms и watcher-а.
        bounce: BounceMode.Only256BitsOfBody,
        dest: nft,
        value: NFT_TRANSFER_VALUE,
        body,
    });
    nftTransferMessage.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun requiredNftRetryValue(): coins {
    return NFT_TRANSFER_VALUE +
        executionCost(
            GAS_ESCROW_SETTLEMENT.add(GAS_PER_ESCROW_ITEM.multiplyBy(2)),
            2,
        );
}

fun automaticNftDeliveryRetryReserve(itemCount: int): coins {
    return itemCount <= 0 ? (grams("0") as coins) : (requiredNftRetryValue() * itemCount) as coins;
}

fun sendFundedNftRetry(
    nft: address,
    recipient: address,
    sponsor: address,
    msgValue: coins,
    responseTo: address,
    comment: Cell<TextComment>?,
) {
    // Public retries must spend only their sponsor's message, including compute and forwarding.
    // Reserve the pre-message balance so an underestimated gas budget fails instead of subsidising it.
    val retainedBalance = max(0, contract.getOriginalBalance() - msgValue);
    reserveGramsOnBalance(retainedBalance, RESERVE_MODE_EXACT_AMOUNT);
    sendNft(nft, recipient, responseTo, comment);
    val change = createMessage({
        bounce: BounceMode.NoBounce,
        dest: sponsor,
        value: grams("0"),
        body: UnsafeBodyNoRef { forceInline: TextComment { text: GAS_REFUND_COMMENT } },
    });
    // SAFETY: the pre-message balance is reserved and the NFT transfer is funded before change.
    change.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

// NFT уже перешёл escrow до notification. Неподходящий предмет поэтому нужно вернуть, а не бросить
// исключение и навсегда оставить его у контракта. Возврат оплачивает входящее сообщение грифера.
fun returnStrayNft(strayNft: address, recipient: address, reason: RefundReason) {
    returnStrayNftWithComment(strayNft, recipient, TextComment { text: reason.comment() }.toCell());
}

fun returnStrayNftWithComment(strayNft: address, recipient: address, comment: Cell<TextComment>?) {
    val body = NftTransfer {
        queryId: 0,
        newOwner: recipient,
        responseDestination: recipient,
        customPayload: null,
        forwardAmount: grams("0.000000001"),
        forwardPayload: nftForwardPayload(comment),
    };
    val strayReturnMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: strayNft,
        value: grams("0"),
        body,
    });
    strayReturnMessage.send(
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
    );
}

// Запрос идёт после всех transfer escrow → NFT. Ответ NFT → escrow подтверждает их обработку,
// поскольку TON сохраняет порядок сообщений между одной парой контрактов. Обычный excesses
// этого не доказывает: владелец NFT может выбрать чужой response_destination и query_id.
fun requestNftDeliveryFence(nft: address, queryId: uint64) {
    val fenceRequest = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: nft,
        value: grams("0"),
        body: NftGetStaticData { queryId },
    });
    fenceRequest.send(
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
    );
}
