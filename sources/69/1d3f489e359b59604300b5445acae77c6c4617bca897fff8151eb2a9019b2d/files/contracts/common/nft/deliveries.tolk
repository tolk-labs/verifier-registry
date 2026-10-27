import "@contracts/common/comments/messages"
import "deposits"
import "enums"

struct NftDelivery {
    recipient: address
    comment: Cell<TextComment>? = null
    queryId: uint64
    sponsor: address? = null
    hasReceipt: bool = false
    automaticAttempts: uint8 = 0
    status: NftDeliveryStatus = NftDeliveryStatus.Pending
}

type NftDeliveries = map<address, NftDelivery>

fun NftDeliveries.containsAny(self, items: ItemDeposits): bool {
    var entry = items.findFirst();
    while (entry.isFound) {
        if (self.exists(entry.getKey())) {
            return true;
        }
        entry = items.iterateNext(entry);
    }
    return false;
}
