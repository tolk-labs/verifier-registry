// decompiled by @fiscaldev
// Reconstructed from the archived code. Descriptive names are recovered roles, not claims about author symbols.
import "compat"
import "getters"
import "messages"
import "protocols"
import "queues"

fun onExternalMessage(body: slice): void {
    var signedPayload = body;
    var signature = signedPayload.loadBits(512);
    var (cursor2, requestSeqno) = loadUint32(signedPayload);
    var (cursor22, _) = loadUint32(cursor2);
    var dataSlice = contract.getData().beginParse();
    var (cursor23, version) = loadUint8(dataSlice);
    var result = ((version == 1) as int);
    assert (result != 0) throw 104;
    var (cursor24, walletIdValue) = loadUint32(cursor23);
    var (cursor25, storedSeqno) = loadUint32(cursor24);
    var (cursor26, publicKey) = loadUint256(cursor25);
    var tail2 = cursor26;
    var dictionaryState = tail2.loadRef();
    var dataSlice2 = dictionaryState.beginParse();
    var tail3 = tail2;
    var hookCode = tail3.loadRef();
    requireEndOfSlice(tail3);
    var (cursor27, programs) = loadMaybeDictionary(dataSlice2);
    var (cursor28, amounts) = loadMaybeDictionary(cursor27);
    var (cursor29, retries) = loadMaybeDictionary(cursor28);
    var (cursor210, acknowledgements) = loadMaybeDictionary(cursor29);
    requireEndOfSlice(cursor210);
    var result2 = ((requestSeqno == storedSeqno) as int);
    assert (result2 != 0) throw 102;
    var result3 = verifyArchivedSignature(
        hashArchivedBuilder(beginCell().storeSlice(signedPayload)),
        signature,
        publicKey,
    );
    assert (result3 != 0) throw 555;
    acceptExternalMessage();
    var nextSeqno = (storedSeqno + 1);
    var (cursor211, batchCount) = loadUint32(cursor22);
    var (zero, cursor212, saveRetry) = loadRequestFlag(cursor211);
    var (cursor213, hookArgument) = loadUint16(cursor212);
    var (cursor214, sendMode) = loadUint8(cursor213);
    var (cursor215, _) = loadUint32(cursor214);
    var (cursor216, receiptTag) = loadUint32(cursor215);
    var tail4 = cursor216.preloadRef().beginParse();
    var address = (tail4.loadAddress() as slice);
    var (cursor217, requestedTon) = loadCoinsField(tail4);
    var (cursor218, tradeAmount) = loadCoinsField(cursor217);
    var (cursor219, bodyByReference) = loadUint1(cursor218);
    var result5 = ((bodyByReference == 1) as int);
    assert (result5 != 0) throw 555;
    var tail5 = cursor219;
    var outgoingBody = tail5.loadRef();
    var (cursor220, amountOverrides) = loadMaybeDictionary(tail5);
    var (cursor221, queryId) = loadUint64(cursor220);
    var program = preloadMaybeDictionary(cursor221);
    var programAbsent = isVmNull((program as unknown));
    var result7 = ((sendMode == 128) as int);
    var selectedValue0 = 0;
    if (result7 != 0) {
        selectedValue0 = -1;
    } else {
        var result8 = ((sendMode == 160) as int);
        selectedValue0 = ((result8 != 0) as int);
    }
    var selectedValue2: int;
    if (selectedValue0 != 0) {
        var result9 = ((requestedTon == 0) as int);
        selectedValue2 = ((result9 != 0) as int);
    } else {
        selectedValue2 = zero;
    }
    var selectedValue3: int;
    if (selectedValue2 != 0) {
        selectedValue3 = ((programAbsent != 0) as int);
    } else {
        selectedValue3 = zero;
    }
    var needsReceipt = (~selectedValue3);
    var result11 = ((saveRetry == 1) as int);
    var selectedValue4: int;
    if (result11 != 0) {
        var result12 = (~programAbsent);
        selectedValue4 = ((result12 != 0) as int);
    } else {
        selectedValue4 = zero;
    }
    var nextRetries: cell;
    if (selectedValue4 != 0) {
        var builder = beginCell();
        nextRetries = setUnsignedBuilder(retries, 64, queryId, builder);
        (
            amounts,
            nextRetries,
            acknowledgements,
            nextSeqno,
            walletIdValue,
            programs,
            publicKey,
            hookCode,
            batchCount,
            zero,
            needsReceipt,
            hookArgument,
            sendMode,
            receiptTag,
            address,
            requestedTon,
            tradeAmount,
            outgoingBody,
            amountOverrides,
            queryId,
            program,
            programAbsent,
        ) = stage22(
            (
                amounts,
                nextRetries,
                acknowledgements,
                nextSeqno,
                walletIdValue,
                programs,
                publicKey,
                hookCode,
                batchCount,
                zero,
                needsReceipt,
                hookArgument,
                sendMode,
                receiptTag,
                address,
                requestedTon,
                tradeAmount,
                outgoingBody,
                amountOverrides,
                queryId,
                program,
                programAbsent,
            ),
        );
    } else {
        nextRetries = retries;
    }
    var nextPrograms: cell;
    var nextAmounts: cell;
    if (programAbsent != 0) {
        (
            nextAmounts,
            nextRetries,
            acknowledgements,
            nextSeqno,
            walletIdValue,
            nextPrograms,
            publicKey,
            hookCode,
            batchCount,
            zero,
            needsReceipt,
            hookArgument,
            sendMode,
            receiptTag,
            address,
            requestedTon,
            programAbsent,
            outgoingBody,
            amountOverrides,
            queryId,
        ) = releaseNoProgram(
            (
                amounts,
                nextRetries,
                acknowledgements,
                nextSeqno,
                walletIdValue,
                programs,
                publicKey,
                hookCode,
                batchCount,
                zero,
                needsReceipt,
                hookArgument,
                sendMode,
                receiptTag,
                address,
                requestedTon,
                tradeAmount,
                outgoingBody,
                amountOverrides,
                queryId,
                program,
                programAbsent,
            ),
        );
    } else {
        var dataSlice3 = program.beginParse();
        var D22 = setUnsignedSlice(programs, 64, queryId, dataSlice3);
        var result13 = ((tradeAmount > 0) as int);

        if (result13 != 0) {
            nextAmounts = setUnsignedBuilder(
                amounts,
                64,
                queryId,
                storeCoinsField(beginCell(), tradeAmount),
            );
            (
                nextAmounts,
                nextRetries,
                acknowledgements,
                nextSeqno,
                walletIdValue,
                programAbsent,
                publicKey,
                hookCode,
                batchCount,
                zero,
                needsReceipt,
                hookArgument,
                sendMode,
                receiptTag,
                address,
                requestedTon,
                D22,
                outgoingBody,
                amountOverrides,
                queryId,
            ) = feeState(
                (
                    nextAmounts,
                    nextRetries,
                    acknowledgements,
                    nextSeqno,
                    walletIdValue,
                    programAbsent,
                    publicKey,
                    hookCode,
                    batchCount,
                    zero,
                    needsReceipt,
                    hookArgument,
                    sendMode,
                    receiptTag,
                    address,
                    requestedTon,
                    D22,
                    outgoingBody,
                    amountOverrides,
                    queryId,
                ),
            );
        } else {
            nextAmounts = amounts;
        }
        nextPrograms = D22;
    }
    var nextAcknowledgements: cell;
    if (needsReceipt != 0) {
        var ackWidth: int;
        var builder2: builder;
        (queryId, ackWidth, builder2) = ackValue(queryId);
        nextAcknowledgements = setWithWidth(acknowledgements, queryId, ackWidth, builder2);
        (
            nextAmounts,
            nextRetries,
            nextAcknowledgements,
            nextSeqno,
            walletIdValue,
            nextPrograms,
            publicKey,
            hookCode,
            batchCount,
            zero,
            needsReceipt,
            hookArgument,
            sendMode,
            receiptTag,
            address,
            requestedTon,
            programAbsent,
            outgoingBody,
            amountOverrides,
            queryId,
        ) = ackState(
            (
                nextAmounts,
                nextRetries,
                nextAcknowledgements,
                nextSeqno,
                walletIdValue,
                nextPrograms,
                publicKey,
                hookCode,
                batchCount,
                zero,
                needsReceipt,
                hookArgument,
                sendMode,
                receiptTag,
                address,
                requestedTon,
                programAbsent,
                outgoingBody,
                amountOverrides,
                queryId,
            ),
        );
    } else {
        nextAcknowledgements = acknowledgements;
    }
    var result14 = ((batchCount > 0) as int);
    var batchSent = zero;
    if (result14 != 0) {
        var inmsg_8 = ownAddressSlice();
        var batchIndex = batchSent;
        while ((batchIndex < batchCount)) {
            var result15 = (batchIndex + 1);
            var b2 = begin_62_().storeAddress((inmsg_8 as address));
            var c = b2.storeUint(0, 111).endCell();
            sendArchivedMessage(c, 3);
            batchIndex = result15;
        }
        batchSent = batchIndex;
    } else {}
    if (isVmNull((previousBlockContext() as unknown)) != 0) {
        var b22 = storeCoinsField(begin_62_().storeAddress((address as address)), requestedTon);
        sendArchivedMessage(b22.storeUint(1, 107).storeRef(outgoingBody).endCell(), sendMode);
        if (needsReceipt != 0) {
            var b = begin_10937847();
            var b23 = b.storeUint(queryId, 64);
            var c2 = b23.storeUint(receiptTag, 32).endCell();
            var constslice = "2_".hexToSlice();
            var b24 = begin_C().storeSlice(constslice);
            var c3 = b24.storeUint(1, 98).storeRef(c2).endCell();
            sendArchivedMessage(c3, 0);
        } else {}
        var dataSlice4 = contract.getData().beginParse();
        var (cursor222, savedVersion) = loadUint8(dataSlice4);
        var result16 = ((savedVersion == 1) as int);
        assert (result16 != 0) throw 104;
        var tail6 = skipBitsField(cursor222, 320);
        tail6.loadRef();
        var tail7 = tail6;
        var retainedHook = tail7.loadRef();
        requireEndOfSlice(tail7);
        var c4 = storeNullableReference(
            storeNullableReference(
                storeNullableReference(
                    storeNullableReference(beginCell(), nextPrograms),
                    nextAmounts,
                ),
                nextRetries,
            ),
            nextAcknowledgements,
        ).endCell();
        var b3 = begin_01();
        var b25 = b3.storeUint(walletIdValue, 32);
        var b26 = b25.storeUint(nextSeqno, 32);
        contract.setData(
            b26.storeUint(publicKey, 256).storeRef(c4).storeRef(retainedHook).endCell(),
        );
        return;
    }
    var inmsg_5 = transactionLogicalTime();
    var inmsg_3 = currentUnixTime();
    var outgoingLogicalTime = ((inmsg_5 + 1) + batchSent);
    var result18 = (outgoingLogicalTime & 16777215);
    var result19 = (inmsg_3 & 15);
    var overrideKey = (result18 + (result19 << 24));
    var (amountOverride, status) = findUnsignedEntry(amountOverrides, 28, overrideKey);
    var sendTon: int;
    if (status != 0) {
        sendTon = amountOverride.preloadUint(64);
    } else {
        if ((hookArgument > 0)) {
            sendTon = (invokeAmountHook(
                hookCode,
                (outgoingLogicalTime as unknown),
                (inmsg_3 as unknown),
                (requestedTon as unknown),
                (address as unknown),
                (outgoingBody as unknown),
                (hookArgument as unknown),
            ) as int);
            (
                nextAmounts,
                nextRetries,
                nextAcknowledgements,
                nextSeqno,
                walletIdValue,
                nextPrograms,
                publicKey,
                sendTon,
                queryId,
                programAbsent,
                needsReceipt,
                outgoingBody,
                sendMode,
                receiptTag,
                address,
            ) = hookState(
                (
                    nextAmounts,
                    nextRetries,
                    nextAcknowledgements,
                    nextSeqno,
                    walletIdValue,
                    nextPrograms,
                    publicKey,
                    sendTon,
                    queryId,
                    programAbsent,
                    needsReceipt,
                    outgoingBody,
                    sendMode,
                    receiptTag,
                    address,
                ),
            );
        } else {
            (
                nextAmounts,
                nextRetries,
                nextAcknowledgements,
                nextSeqno,
                walletIdValue,
                nextPrograms,
                publicKey,
                sendTon,
                queryId,
                programAbsent,
                needsReceipt,
                outgoingBody,
                sendMode,
                receiptTag,
                address,
            ) = releaseNoHook(
                (
                    nextAmounts,
                    nextRetries,
                    nextAcknowledgements,
                    nextSeqno,
                    walletIdValue,
                    nextPrograms,
                    publicKey,
                    hookCode,
                    queryId,
                    inmsg_3,
                    needsReceipt,
                    hookArgument,
                    sendMode,
                    receiptTag,
                    address,
                    requestedTon,
                    programAbsent,
                    outgoingBody,
                    outgoingLogicalTime,
                ),
            );
        }
    }
    var b27 = storeCoinsField(begin_62_().storeAddress((address as address)), sendTon);
    sendArchivedMessage(b27.storeUint(1, 107).storeRef(outgoingBody).endCell(), sendMode);
    if (needsReceipt != 0) {
        var b4 = begin_10937847();
        var b28 = b4.storeUint(queryId, 64);
        var c5 = b28.storeUint(receiptTag, 32).endCell();
        var constslice2 = "2_".hexToSlice();
        var b29 = begin_C().storeSlice(constslice2);
        var c6 = b29.storeUint(1, 98).storeRef(c5).endCell();
        sendArchivedMessage(c6, 0);
    } else {}
    var finalPrograms = nextPrograms;
    var finalAmounts = nextAmounts;
    if (programAbsent != 0) {
        var constValue = (null as unknown as cell);
        var constValue2 = (null as unknown as cell);
        finalPrograms = constValue;
        finalAmounts = constValue2;
    }
    var dataSlice5 = contract.getData().beginParse();
    var (cursor223, savedVersion2) = loadUint8(dataSlice5);
    var result21 = ((savedVersion2 == 1) as int);
    assert (result21 != 0) throw 104;
    var tail8 = skipBitsField(cursor223, 320);
    tail8.loadRef();
    var tail9 = tail8;
    var retainedHook2 = tail9.loadRef();
    requireEndOfSlice(tail9);
    var c7 = storeNullableReference(
        storeNullableReference(
            storeNullableReference(
                storeNullableReference(beginCell(), finalPrograms),
                finalAmounts,
            ),
            nextRetries,
        ),
        nextAcknowledgements,
    ).endCell();
    var b5 = begin_01();
    var b210 = b5.storeUint(walletIdValue, 32);
    var b211 = b210.storeUint(nextSeqno, 32);
    contract.setData(b211.storeUint(publicKey, 256).storeRef(c7).storeRef(retainedHook2).endCell());
}

fun onInternalMessage(balance: int, messageValue: int, message: cell, body: slice): void {
    if (body.isEmpty()) {
        return;
    }
    var dataSlice = message.beginParse();
    var (cursor2, messageFlags) = loadUint4(dataSlice);
    if ((messageFlags & 1) != 0) {
        var (result, result2) = bouncedQuery(body);
        if (result2 != 0) {
            var dataSlice2 = contract.getData().beginParse();
            var (cursor22, versionBounce) = loadUint8(dataSlice2);
            val result3 = ((versionBounce == 1) as int);
            assert (result3 != 0) throw 104;
            var (cursor23, walletIdBounce) = loadUint32(cursor22);
            var (cursor24, seqnoBounce) = loadUint32(cursor23);
            var (cursor25, keyBounce) = loadUint256(cursor24);
            var tail = cursor25;
            val refCell = tail.loadRef();
            var dataSlice3 = refCell.beginParse();
            var tail2 = tail;
            tail2.loadRef();
            requireEndOfSlice(tail2);
            var (cursor26, programsBounce) = loadMaybeDictionary(dataSlice3);
            var (cursor27, amountsBounce) = loadMaybeDictionary(cursor26);
            var (cursor28, retriesBounce) = loadMaybeDictionary(cursor27);
            var (cursor29, acksBounce) = loadMaybeDictionary(cursor28);
            requireEndOfSlice(cursor29);
            var (result4, result5) = acknowledgeQuery(acksBounce, result);
            if (result5 != 0) {
                var dataSlice4 = contract.getData().beginParse();
                var (cursor210, savedVersionBounce) = loadUint8(dataSlice4);
                val result6 = ((savedVersionBounce == 1) as int);
                assert (result6 != 0) throw 104;
                var tail3 = skipBitsField(cursor210, 320);
                tail3.loadRef();
                var tail4 = tail3;
                val refCell2 = tail4.loadRef();
                requireEndOfSlice(tail4);
                val c = storeNullableReference(
                    storeNullableReference(
                        storeNullableReference(
                            storeNullableReference(beginCell(), programsBounce),
                            amountsBounce,
                        ),
                        retriesBounce,
                    ),
                    result4,
                ).endCell();
                var b = begin_01();
                var b2 = b.storeUint(walletIdBounce, 32);
                var b22 = b2.storeUint(seqnoBounce, 32);
                contract.setData(
                    b22.storeUint(keyBounce, 256).storeRef(c).storeRef(refCell2).endCell(),
                );
            } else {
                discardBounceState(
                    retriesBounce,
                    walletIdBounce,
                    seqnoBounce,
                    keyBounce,
                    programsBounce,
                    amountsBounce,
                    result4,
                );
            }
            completeBounce();
            return;
        }
        return;
    }
    var (cursor211, opcode) = loadUint32(body);
    var (cursor212, queryId) = loadUint64(cursor211);
    var dataSlice5 = contract.getData().beginParse();
    var (cursor213, version) = loadUint8(dataSlice5);
    val result7 = ((version == 1) as int);
    assert (result7 != 0) throw 104;
    var (cursor214, walletIdValue) = loadUint32(cursor213);
    var (cursor215, storedSeqno) = loadUint32(cursor214);
    var (cursor216, publicKey) = loadUint256(cursor215);
    var tail5 = cursor216;
    val refCell3 = tail5.loadRef();
    var dataSlice6 = refCell3.beginParse();
    var tail6 = tail5;
    tail6.loadRef();
    requireEndOfSlice(tail6);
    var (cursor217, programs) = loadMaybeDictionary(dataSlice6);
    if ((opcode == 16843266)) {
        var (cursor218, amountsRetry) = loadMaybeDictionary(cursor217);
        var (cursor219, retriesRetry) = loadMaybeDictionary(cursor218);
        var (cursor220, acksRetry) = loadMaybeDictionary(cursor219);
        requireEndOfSlice(cursor220);
        val address = (cursor2.loadAddress() as slice);
        if (
            !(address.bitsEqual(
                "9FF1C20FAD211DB1A2CF8EB1F9ADFE00FDBAE1DA1D95045A3F286262FC347B25835_".hexToSlice(),
            ))
        ) {
            throw 555;
        }
        var (D22, retryEntry, status) = removeUnsignedEntry(retriesRetry, 64, queryId);
        if (!(status != 0)) {
            throw 103;
        }
        val c2 = retryEntry.preloadRef();
        sendArchivedMessage(c2, 3);
        var dataSlice7 = contract.getData().beginParse();
        var (cursor221, savedVersionRetry) = loadUint8(dataSlice7);
        val result8 = ((savedVersionRetry == 1) as int);
        assert (result8 != 0) throw 104;
        var tail7 = skipBitsField(cursor221, 320);
        tail7.loadRef();
        var tail8 = tail7;
        val refCell4 = tail8.loadRef();
        requireEndOfSlice(tail8);
        val c3 = storeNullableReference(
            storeNullableReference(
                storeNullableReference(storeNullableReference(beginCell(), programs), amountsRetry),
                D22,
            ),
            acksRetry,
        ).endCell();
        var b3 = begin_01();
        var b23 = b3.storeUint(walletIdValue, 32);
        var b24 = b23.storeUint(storedSeqno, 32);
        contract.setData(b24.storeUint(publicKey, 256).storeRef(c3).storeRef(refCell4).endCell());
        return;
    }
    var (recipeEntry, status2) = findUnsignedEntry(programs, 64, queryId);
    if (!(status2 != 0)) {
        var (cursor222, amountsAck) = loadMaybeDictionary(cursor217);
        var (cursor223, retriesAck) = loadMaybeDictionary(cursor222);
        var (cursor224, acksAck) = loadMaybeDictionary(cursor223);
        requireEndOfSlice(cursor224);
        var (result9, result10) = acknowledgeQuery(acksAck, queryId);
        if (result10 != 0) {
            var dataSlice8 = contract.getData().beginParse();
            var (cursor225, savedVersionAck) = loadUint8(dataSlice8);
            val result11 = ((savedVersionAck == 1) as int);
            assert (result11 != 0) throw 104;
            var tail9 = skipBitsField(cursor225, 320);
            tail9.loadRef();
            var tail10 = tail9;
            val refCell5 = tail10.loadRef();
            requireEndOfSlice(tail10);
            val c4 = storeNullableReference(
                storeNullableReference(
                    storeNullableReference(
                        storeNullableReference(beginCell(), programs),
                        amountsAck,
                    ),
                    retriesAck,
                ),
                result9,
            ).endCell();
            var b4 = begin_01();
            var b25 = b4.storeUint(walletIdValue, 32);
            var b26 = b25.storeUint(storedSeqno, 32);
            contract.setData(
                b26.storeUint(publicKey, 256).storeRef(c4).storeRef(refCell5).endCell(),
            );
            return;
        }
        return;
    }
    var (cursor226, amounts) = loadMaybeDictionary(cursor217);
    var (cursor227, retries) = loadMaybeDictionary(cursor226);
    var (cursor228, acknowledgements) = loadMaybeDictionary(cursor227);
    requireEndOfSlice(cursor228);
    var (cursor229, protocolKind) = loadUint4(recipeEntry);
    var nextRetries: cell;
    var nextAmounts: cell;
    var nextPrograms: cell;
    if (protocolKind != 0) {
        val result12 = ((protocolKind == 1) as int);

        if (result12 != 0) {
            var (result13, result14, result15) = processProtocol1(
                messageValue,
                opcode,
                queryId,
                cursor229,
                programs,
                amounts,
                retries,
                cursor212,
            );
            nextRetries = result15;
            nextAmounts = result14;
            nextPrograms = result13;
        } else {
            val result16 = ((protocolKind == 2) as int);

            if (result16 != 0) {
                var (result17, result18, result19) = processProtocol2(
                    messageValue,
                    opcode,
                    queryId,
                    cursor229,
                    programs,
                    amounts,
                    retries,
                    cursor212,
                );
                nextRetries = result19;
                nextAmounts = result18;
                nextPrograms = result17;
            } else {
                val result20 = ((protocolKind == 3) as int);

                if (result20 != 0) {
                    var (result21, result22, result23) = processProtocol3(
                        messageValue,
                        opcode,
                        queryId,
                        cursor229,
                        programs,
                        amounts,
                        retries,
                        cursor212,
                    );
                    nextRetries = result23;
                    nextAmounts = result22;
                    nextPrograms = result21;
                } else {
                    val result24 = ((protocolKind == 4) as int);

                    if (result24 != 0) {
                        var (result25, result26, result27) = processProtocol4(
                            messageValue,
                            opcode,
                            queryId,
                            cursor229,
                            programs,
                            amounts,
                            retries,
                            cursor212,
                        );
                        nextRetries = result27;
                        nextAmounts = result26;
                        nextPrograms = result25;
                    } else {
                        val result28 = ((protocolKind == 5) as int);

                        if (result28 != 0) {
                            var (result29, result30, result31) = processProtocol5(
                                messageValue,
                                opcode,
                                queryId,
                                cursor229,
                                programs,
                                amounts,
                                retries,
                                cursor212,
                            );
                            nextRetries = result31;
                            nextAmounts = result30;
                            nextPrograms = result29;
                        } else {
                            val result32 = ((protocolKind == 10) as int);

                            if (result32 != 0) {
                                var (result33, result34, result35) = processProtocol10(
                                    messageValue,
                                    opcode,
                                    queryId,
                                    cursor229,
                                    programs,
                                    amounts,
                                    retries,
                                    cursor212,
                                );
                                nextRetries = result35;
                                nextAmounts = result34;
                                nextPrograms = result33;
                            } else {
                                val result36 = ((protocolKind == 6) as int);

                                if (result36 != 0) {
                                    var (result37, result38, result39) = processProtocol6(
                                        messageValue,
                                        opcode,
                                        queryId,
                                        cursor229,
                                        programs,
                                        amounts,
                                        retries,
                                        cursor212,
                                    );
                                    nextRetries = result39;
                                    nextAmounts = result38;
                                    nextPrograms = result37;
                                } else {
                                    val result40 = ((protocolKind == 7) as int);

                                    if (result40 != 0) {
                                        var (result41, result42, result43) = processProtocol7(
                                            messageValue,
                                            opcode,
                                            queryId,
                                            cursor229,
                                            programs,
                                            amounts,
                                            retries,
                                            cursor212,
                                        );
                                        nextRetries = result43;
                                        nextAmounts = result42;
                                        nextPrograms = result41;
                                    } else {
                                        val result44 = ((protocolKind == 8) as int);

                                        if (result44 != 0) {
                                            var (result45, result46, result47) = processProtocol8(
                                                messageValue,
                                                opcode,
                                                queryId,
                                                cursor229,
                                                programs,
                                                amounts,
                                                retries,
                                                cursor212,
                                            );
                                            nextRetries = result47;
                                            nextAmounts = result46;
                                            nextPrograms = result45;
                                        } else {
                                            val result48 = ((protocolKind == 9) as int);

                                            if (result48 != 0) {
                                                var (
                                                    result49,
                                                    result50,
                                                    result51,
                                                ) = processProtocol9(
                                                    messageValue,
                                                    opcode,
                                                    queryId,
                                                    cursor229,
                                                    programs,
                                                    amounts,
                                                    retries,
                                                    cursor212,
                                                );
                                                nextRetries = result51;
                                                nextAmounts = result50;
                                                nextPrograms = result49;
                                            } else {
                                                val result52 = ((protocolKind == 11) as int);

                                                if (result52 != 0) {
                                                    var (
                                                        result53,
                                                        result54,
                                                        result55,
                                                    ) = processProtocol11(
                                                        messageValue,
                                                        opcode,
                                                        queryId,
                                                        cursor229,
                                                        programs,
                                                        amounts,
                                                        retries,
                                                        cursor212,
                                                    );
                                                    nextRetries = result55;
                                                    nextAmounts = result54;
                                                    nextPrograms = result53;
                                                } else {
                                                    val result56 = ((protocolKind == 12) as int);

                                                    if (result56 != 0) {
                                                        var (
                                                            result57,
                                                            result58,
                                                            result59,
                                                        ) = processProtocol12(
                                                            messageValue,
                                                            opcode,
                                                            queryId,
                                                            cursor229,
                                                            programs,
                                                            amounts,
                                                            retries,
                                                            cursor212,
                                                        );
                                                        nextRetries = result59;
                                                        nextAmounts = result58;
                                                        nextPrograms = result57;
                                                    } else {
                                                        val result60 = ((protocolKind ==
                                                        13) as int);

                                                        if (result60 != 0) {
                                                            var (
                                                                result61,
                                                                result62,
                                                                result63,
                                                            ) = processProtocol13(
                                                                messageValue,
                                                                opcode,
                                                                queryId,
                                                                cursor229,
                                                                programs,
                                                                amounts,
                                                                retries,
                                                                cursor212,
                                                            );
                                                            nextRetries = result63;
                                                            nextAmounts = result62;
                                                            nextPrograms = result61;
                                                            (
                                                                acknowledgements,
                                                                nextPrograms,
                                                                nextAmounts,
                                                                queryId,
                                                                nextRetries,
                                                                walletIdValue,
                                                                storedSeqno,
                                                                publicKey,
                                                            ) = stage8(
                                                                acknowledgements,
                                                                nextPrograms,
                                                                nextAmounts,
                                                                queryId,
                                                                nextRetries,
                                                                walletIdValue,
                                                                storedSeqno,
                                                                publicKey,
                                                            );
                                                        } else {
                                                            (
                                                                acknowledgements,
                                                                nextPrograms,
                                                                nextAmounts,
                                                                queryId,
                                                                nextRetries,
                                                                walletIdValue,
                                                                storedSeqno,
                                                                publicKey,
                                                            ) = fallbackDispatch(
                                                                acknowledgements,
                                                                messageValue,
                                                                opcode,
                                                                queryId,
                                                                cursor212,
                                                                walletIdValue,
                                                                storedSeqno,
                                                                publicKey,
                                                                programs,
                                                                amounts,
                                                                retries,
                                                                cursor229,
                                                            );
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        var (result64, result65, result66) = processProtocol0(
            messageValue,
            opcode,
            queryId,
            cursor229,
            programs,
            amounts,
            retries,
            cursor212,
        );
        nextRetries = result66;
        nextAmounts = result65;
        nextPrograms = result64;
    }
    val result67 = advanceAcknowledgement(acknowledgements, nextPrograms, queryId);
    var dataSlice9 = contract.getData().beginParse();
    var (cursor230, savedVersionTrade) = loadUint8(dataSlice9);
    val result68 = ((savedVersionTrade == 1) as int);
    assert (result68 != 0) throw 104;
    var tail11 = skipBitsField(cursor230, 320);
    tail11.loadRef();
    var tail12 = tail11;
    val refCell6 = tail12.loadRef();
    requireEndOfSlice(tail12);
    val c5 = storeNullableReference(
        storeNullableReference(
            storeNullableReference(storeNullableReference(beginCell(), nextPrograms), nextAmounts),
            nextRetries,
        ),
        result67,
    ).endCell();
    var b5 = begin_01();
    var b27 = b5.storeUint(walletIdValue, 32);
    var b28 = b27.storeUint(storedSeqno, 32);
    contract.setData(b28.storeUint(publicKey, 256).storeRef(c5).storeRef(refCell6).endCell());
}
