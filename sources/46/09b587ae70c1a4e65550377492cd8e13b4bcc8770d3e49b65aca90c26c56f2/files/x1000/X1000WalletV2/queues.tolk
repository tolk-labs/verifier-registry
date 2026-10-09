// decompiled by @fiscaldev
import "compat"

@method_id(3)
fun capAcknowledgements(queue: cell): cell {
    var (key, _, found) = firstUnsignedEntry(queue, 64);
    var count = 0;
    while (found != 0 && count < 11) {
        count += 1;
        if (count < 11) {
            (key, _, found) = nextUnsignedEntry(queue, 64, key);
        }
    }
    if (count > 10) {
        return (null as unknown as cell);
    }
    return queue;
}

@method_id(4)
fun acknowledgeQuery(acknowledgements: cell, queryId: int): (cell, int) {
    var (remaining, acknowledgement, status) = removeUnsignedEntry(acknowledgements, 64, queryId);
    if (!(status != 0)) {
        return (remaining, 0);
    }
    val originalQueryId = acknowledgement.preloadUint(64);
    var b = begin_BEAF9617();
    val c = b.storeUint(originalQueryId, 64).endCell();
    val constslice = "2_".hexToSlice();
    var b2 = begin_C().storeSlice(constslice);
    val c2 = b2.storeUint(1, 98).storeRef(c).endCell();
    sendArchivedMessage(c2, 0);
    val result = capAcknowledgements(remaining);
    return (result, 1);
}

@method_id(5)
fun bouncedQuery(body: slice): (int, int) {
    val bodyBits = body.remainingBitsCount();
    if ((bodyBits < 128)) {
        return (0, 0);
    }
    var (cursor2, bouncePrefix) = loadUint32(body);
    if ((bouncePrefix != 0xffffffff)) {
        return (0, 0);
    }
    var (cursor22, _) = loadUint32(cursor2);
    val queryId = cursor22.preloadUint(64);
    return (queryId, 1);
}

@method_id(6)
fun advanceAcknowledgement(acknowledgements: cell, programs: cell, queryId: int): cell {
    var (acknowledgement, status) = findUnsignedEntry(acknowledgements, 64, queryId);
    if (!(status != 0)) {
        return acknowledgements;
    }
    val originalQueryId = acknowledgement.preloadUint(64);
    val nextQueryId = (queryId + 1);
    var (_, status2) = findUnsignedEntry(programs, 64, nextQueryId);
    if (status2 != 0) {
        var (D2, _) = deleteUnsignedEntry(acknowledgements, 64, queryId);
        return setUnsignedBuilder(D2, 64, nextQueryId, beginCell().storeUint(originalQueryId, 64));
    }
    var (_, status3) = findUnsignedEntry(programs, 64, queryId);
    var selectedValue0: cell;
    if (status3 != 0) {
        selectedValue0 = acknowledgements;
    } else {
        var b = begin_BEAF9617();
        val c = b.storeUint(originalQueryId, 64).endCell();
        val constslice = "2_".hexToSlice();
        var b2 = begin_C().storeSlice(constslice);
        val c2 = b2.storeUint(1, 98).storeRef(c).endCell();
        sendArchivedMessage(c2, 0);
        var (D22, _) = deleteUnsignedEntry(acknowledgements, 64, queryId);
        selectedValue0 = capAcknowledgements(D22);
    }
    return selectedValue0;
}

@method_id(8)
fun sendOrQueueTrade(retries: cell, queryId: int, outgoingMessage: cell): cell {
    var (D2, status) = replaceUnsignedBuilder(
        retries,
        64,
        queryId,
        beginCell().storeRef(outgoingMessage),
    );
    if (status != 0) {
        var b = begin_01010201();
        val c = b.storeUint(queryId, 64).endCell();
        var b2 = begin_62_();
        var b22 = b2.storeAddress(
            ("9FF1C20FAD211DB1A2CF8EB1F9ADFE00FDBAE1DA1D95045A3F286262FC347B25835_".hexToSlice() as address),
        );
        var b23 = storeCoinsField(b22, 100000000);
        val c2 = b23.storeUint(1, 107).storeRef(c).endCell();
        sendArchivedMessage(c2, 3);
    } else {
        sendArchivedMessage(outgoingMessage, 3);
    }
    return D2;
}
