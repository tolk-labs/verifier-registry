// Ключ фиксирует NFT. Refund recipient коммитится до transfer, а depositor появляется только из
// authenticated TEP-62 ownership_assigned. Разделять эти факты обязательно: если NFT уже сменил
// owner, но notification потерялся, escrow всё равно знает единственный допустимый адрес возврата.
struct ItemDeposit {
    refundRecipient: address?
    depositor: address?
}

type ItemDeposits = map<address, ItemDeposit>

type ItemRefundRecipients = map<address, address>

fun pendingItemDeposit(refundRecipient: address? = null): ItemDeposit {
    return { refundRecipient, depositor: null };
}

fun ItemDeposit.isDeposited(self): bool {
    return self.depositor != null;
}

fun ItemDeposit.acceptsDepositor(self, depositor: address): bool {
    return !self.isDeposited() && self.refundRecipient != null && self.refundRecipient == depositor;
}

// Execution binding commits one refund wallet for every exact taker NFT. The set must match the
// StateInit keys exactly; recipients must be contributor wallets and cannot change on retries.
fun ItemDeposits.commitRefundRecipients(
    mutate self,
    recipients: ItemRefundRecipients,
    allowed: map<address, bool>,
): bool {
    var count = 0;
    var entry = self.findFirst();
    while (entry.isFound) {
        count += 1;
        val recipient = recipients.get(entry.getKey());
        if (
            !recipient.isFound || recipient.loadValue().getWorkchain() != BASECHAIN ||
            !allowed.exists(recipient.loadValue())
        ) {
            return false;
        }
        var deposit = entry.loadValue();
        if (
            deposit.depositor != null ||
            (deposit.refundRecipient != null && deposit.refundRecipient != recipient.loadValue())
        ) {
            return false;
        }
        // The sole caller asserts the returned result. Any later count mismatch throws and TVM
        // rolls these writes back atomically; keeping two bounded passes matters at the 100-NFT cap.
        deposit.refundRecipient = recipient.loadValue();
        self.set(entry.getKey(), deposit);
        entry = self.iterateNext(entry);
    }

    var recipientCount = 0;
    var recipientEntry = recipients.findFirst();
    while (recipientEntry.isFound) {
        recipientCount += 1;
        if (
            !self.exists(recipientEntry.getKey()) ||
            recipientEntry.loadValue().getWorkchain() != BASECHAIN
        ) {
            return false;
        }
        recipientEntry = recipients.iterateNext(recipientEntry);
    }
    return count == recipientCount;
}

fun ItemDeposits.hasRefundRecipients(self, recipients: ItemRefundRecipients): bool {
    var count = 0;
    var entry = self.findFirst();
    while (entry.isFound) {
        count += 1;
        val recipient = recipients.get(entry.getKey());
        if (
            !recipient.isFound || entry.loadValue().refundRecipient == null ||
            entry.loadValue().refundRecipient! != recipient.loadValue()
        ) {
            return false;
        }
        entry = self.iterateNext(entry);
    }
    var recipientCount = 0;
    var recipientEntry = recipients.findFirst();
    while (recipientEntry.isFound) {
        recipientCount += 1;
        recipientEntry = recipients.iterateNext(recipientEntry);
    }
    return count == recipientCount;
}

fun ItemDeposits.refundRecipientsAreAllowedBy(
    self,
    allowed: map<address, bool>,
    allowUnset: bool,
): bool {
    var entry = self.findFirst();
    while (entry.isFound) {
        val recipient = entry.loadValue().refundRecipient;
        if (
            (recipient == null && !allowUnset) ||
            (recipient != null &&
                (recipient.getWorkchain() != BASECHAIN || !allowed.exists(recipient)))
        ) {
            return false;
        }
        entry = self.iterateNext(entry);
    }
    return true;
}

fun ItemDeposits.refundAllTo(self, recipient: address): ItemRefundRecipients {
    var recipients: ItemRefundRecipients = [];
    var entry = self.findFirst();
    while (entry.isFound) {
        recipients.set(entry.getKey(), recipient);
        entry = self.iterateNext(entry);
    }
    return recipients;
}

// Ограниченный снимок лота за один проход. Платёжный путь не имеет права трижды обходить один и
// тот же map: на максимальном лоте это уже сотни тысяч gas, а не косметическая разница.
struct BoundedDepositProgress {
    isWithinLimit: bool
    isComplete: bool
    promisedCount: int
    depositedCount: int
}

fun ItemDeposits.progressWithin(self, cap: int): BoundedDepositProgress {
    var promisedCount = 0;
    var depositedCount = 0;
    var entry = self.findFirst();
    while (entry.isFound) {
        promisedCount += 1;
        if (promisedCount > cap) {
            return {
                isWithinLimit: false,
                isComplete: false,
                promisedCount,
                depositedCount,
            };
        }
        if (entry.loadValue().isDeposited()) {
            depositedCount += 1;
        }
        entry = self.iterateNext(entry);
    }

    return {
        isWithinLimit: true,
        isComplete: depositedCount == promisedCount,
        promisedCount,
        depositedCount,
    };
}
