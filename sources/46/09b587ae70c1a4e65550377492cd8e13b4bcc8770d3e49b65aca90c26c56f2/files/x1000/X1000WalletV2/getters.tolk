// decompiled by @fiscaldev
import "compat"

@method_id(97376)
fun hasProgram(queryId: int): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var tail = skipBitsField(cursor2, 320);
    val refCell = tail.loadRef();
    var tail2 = tail;
    tail2.loadRef();
    requireEndOfSlice(tail2);
    val D = preloadMaybeDictionary(refCell.beginParse());
    var (_, status) = findUnsignedEntry(D, 64, queryId);
    if (!(status != 0)) {
        return 0;
    }
    return 1;
}

@method_id(98121)
fun amountsEmpty(): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var tail = skipBitsField(cursor2, 320);
    val refCell = tail.loadRef();
    var tail2 = tail;
    tail2.loadRef();
    requireEndOfSlice(tail2);
    return isVmNull((preloadMaybeDictionary(skipMaybeDictionary(refCell.beginParse())) as unknown));
}

@method_id(95507)
fun storageVersion(): int {
    val dataSlice = contract.getData().beginParse();
    return dataSlice.preloadUint(8);
}

@method_id(97027)
fun walletId(): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    return cursor2.preloadUint(32);
}

@method_id(118999)
fun programsEmptyAlias(): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var tail = skipBitsField(cursor2, 320);
    val refCell = tail.loadRef();
    var tail2 = tail;
    tail2.loadRef();
    requireEndOfSlice(tail2);
    return isVmNull((preloadMaybeDictionary(refCell.beginParse()) as unknown));
}

@method_id(94056)
fun retriesEmpty(): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var tail = skipBitsField(cursor2, 320);
    val refCell = tail.loadRef();
    var tail2 = tail;
    tail2.loadRef();
    requireEndOfSlice(tail2);
    return isVmNull(
        (preloadMaybeDictionary(
            skipMaybeDictionary(skipMaybeDictionary(refCell.beginParse())),
        ) as unknown),
    );
}

@method_id(83648)
fun walletBalance(): int {
    var (__result_0_0, __result_0_1) = unpackBalanceTuple((balanceTuple() as unknown as tuple));
    var element_0: int = (__result_0_0 as int);
    var element_1: cell = (__result_0_1 as unknown as cell);
    return element_0;
}

@method_id(89828)
fun amountHookHash(): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var tail = skipBitsField(cursor2, 320);
    tail.loadRef();
    var tail2 = tail;
    val refCell = tail2.loadRef();
    requireEndOfSlice(tail2);
    return refCell.hash();
}

@method_id(85802)
fun programsEmpty(): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var tail = skipBitsField(cursor2, 320);
    val refCell = tail.loadRef();
    var tail2 = tail;
    tail2.loadRef();
    requireEndOfSlice(tail2);
    return isVmNull((preloadMaybeDictionary(refCell.beginParse()) as unknown));
}

@method_id(91459)
fun sequenceNumberAlias(): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var (cursor22, _) = loadUint32(cursor2);
    return cursor22.preloadUint(32);
}

@method_id(85143)
fun seqno(): int {
    var dataSlice = contract.getData().beginParse();
    var (cursor2, version) = loadUint8(dataSlice);
    val result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var (cursor22, _) = loadUint32(cursor2);
    return cursor22.preloadUint(32);
}
