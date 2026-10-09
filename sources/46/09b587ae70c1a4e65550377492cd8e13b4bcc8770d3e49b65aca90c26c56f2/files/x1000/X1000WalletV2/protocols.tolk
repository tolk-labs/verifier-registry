// decompiled by @fiscaldev
import "compat"
import "messages"
import "queues"

// Dispatch kind 3; wire predicates and gas boundaries are preserved.
@method_id(22)
fun processProtocol3(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0xd53276db) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var dataSlice = secondLeg.beginParse();
            var (cursor25, protocolKind3) = loadUint4(dataSlice);
            var (cursor26, sourceAssetKind4) = loadUint4(cursor25);
            var (cursor27, targetAssetKind5) = loadUint4(cursor26);
            val D3 = preloadMaybeDictionary(cursor27);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            var (instructionTail28, tradeAmount6) = loadCoinsField(D3.beginParse());
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            val result6 = prepareTradeMessage(
                protocolKind3,
                sourceAssetKind4,
                targetAssetKind5,
                nextQueryId,
                body,
                instructionTail28,
                tradeAmount6,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                retriesState7 = retries;
                amountsState8 = amounts;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                val amountsState212 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount6),
                );
                retriesState7 = result8;
                amountsState8 = amountsState212;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 32736093)) {
            var (D213, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D215, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D213, D214, D215);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 32736093)) {
                var (D216, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D218, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D216, D217, D218);
            }
            val result11 = ((opcode == 0xd53276db) as int);

            if (result11 != 0) {
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D219, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D221, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D219, D220, D221);
                }
                if ((messageValue < 200000000)) {
                    return (programs, amounts, retries);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, tradeAmount8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor29, protocolKind9) = loadUint4(dataSlice3);
                var (cursor210, sourceAssetKind10) = loadUint4(cursor29);
                var (cursor211, targetAssetKind11) = loadUint4(cursor210);
                val D4 = preloadMaybeDictionary(cursor211);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D222, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D224, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D222, D223, D224);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState225 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail212, _) = loadCoinsField(D4.beginParse());
                val result12 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail212,
                    tradeAmount8,
                );
                val result13 = isVmNull((result12 as unknown));

                if (result13 != 0) {
                    (programsState4, amountsState5, retriesState3) = releaseSeven_0_5_4(
                        programsState225,
                        nextQueryId,
                        queryId,
                        tradeAmount8,
                        retries,
                        amounts,
                        result12,
                    );
                } else {
                    val result14 = sendOrQueueTrade(retries, queryId, result12);
                    val amountsState226 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), tradeAmount8),
                    );
                    retriesState3 = result14;
                    amountsState5 = amountsState226;
                    programsState4 = programsState225;
                }
                (retriesState3, programsState4, amountsState5) = pendingState(
                    retriesState3,
                    programsState4,
                    amountsState5,
                );
            } else {
                (retriesState3, programsState4, amountsState5) = keepEight_6_4_5(
                    messageValue,
                    nextQueryId,
                    queryId,
                    body,
                    programs,
                    amounts,
                    retries,
                    firstLeg,
                );
            }
        } else {
            val result15 = ((firstLegMode == 1) as int);
            var selectedValue10: int;
            if (result15 != 0) {
                val result16 = ((secondLegMode == 1) as int);
                selectedValue10 = ((result16 != 0) as int);
            } else {
                selectedValue10 = 0;
            }

            if (selectedValue10 != 0) {
                val result17 = ((opcode == 0xd53276db) as int);

                if (result17 != 0) {
                    if (isVmNull((secondLeg as unknown)) != 0) {
                        var (D227, _) = deleteUnsignedEntry(programs, 64, queryId);
                        var (D228, _) = deleteUnsignedEntry(amounts, 64, queryId);
                        var (D229, _) = deleteUnsignedEntry(retries, 64, queryId);
                        return (D227, D228, D229);
                    }
                    if ((messageValue < 200000000)) {
                        return (programs, amounts, retries);
                    }
                    var dataSlice5 = secondLeg.beginParse();
                    var (cursor213, protocolKind12) = loadUint4(dataSlice5);
                    var (cursor214, sourceAssetKind13) = loadUint4(cursor213);
                    var (cursor215, targetAssetKind14) = loadUint4(cursor214);
                    val D5 = preloadMaybeDictionary(cursor215);
                    if (isVmNull((D5 as unknown)) != 0) {
                        var (D230, _) = deleteUnsignedEntry(programs, 64, queryId);
                        var (D231, _) = deleteUnsignedEntry(amounts, 64, queryId);
                        var (D232, _) = deleteUnsignedEntry(retries, 64, queryId);
                        return (D230, D231, D232);
                    }
                    var (instructionTail216, tradeAmount15) = loadCoinsField(D5.beginParse());
                    val dataSlice6 = secondLeg.beginParse();
                    val programsState233 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice6);
                    val result18 = prepareTradeMessage(
                        protocolKind12,
                        sourceAssetKind13,
                        targetAssetKind14,
                        nextQueryId,
                        body,
                        instructionTail216,
                        tradeAmount15,
                    );
                    val result19 = isVmNull((result18 as unknown));

                    if (result19 != 0) {
                        (retriesState3, programsState4, amountsState5) = releasePreparedTrade(
                            retries,
                            nextQueryId,
                            queryId,
                            programsState233,
                            tradeAmount15,
                            amounts,
                            result18,
                        );
                    } else {
                        val result20 = sendOrQueueTrade(retries, queryId, result18);
                        amountsState5 = setUnsignedBuilder(
                            amounts,
                            64,
                            nextQueryId,
                            storeCoinsField(beginCell(), tradeAmount15),
                        );
                        retriesState3 = result20;

                        programsState4 = programsState233;
                    }
                    (retriesState3, programsState4, amountsState5) = pendingState(
                        retriesState3,
                        programsState4,
                        amountsState5,
                    );
                } else {
                    (retriesState3, programsState4, amountsState5) = keepEight_6_4_5(
                        messageValue,
                        nextQueryId,
                        queryId,
                        body,
                        programs,
                        amounts,
                        retries,
                        secondLeg,
                    );
                }
            } else {
                (retriesState3, programsState4, amountsState5) = keepNine_6_4_5(
                    messageValue,
                    opcode,
                    queryId,
                    body,
                    programs,
                    amounts,
                    retries,
                    secondLeg,
                    nextQueryId,
                );
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 12; wire predicates and gas boundaries are preserved.
@method_id(10)
fun processProtocol12(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var selectedValue3: cell;
    var programsState4: cell;
    var selectedValue5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0xd53276db) as int);

        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var dataSlice = secondLeg.beginParse();
            var (cursor25, protocolKind3) = loadUint4(dataSlice);
            var (cursor26, sourceAssetKind4) = loadUint4(cursor25);
            var (cursor27, targetAssetKind5) = loadUint4(cursor26);
            val D3 = preloadMaybeDictionary(cursor27);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            var (instructionTail28, tradeAmount6) = loadCoinsField(D3.beginParse());
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            val result6 = prepareTradeMessage(
                protocolKind3,
                sourceAssetKind4,
                targetAssetKind5,
                nextQueryId,
                body,
                instructionTail28,
                tradeAmount6,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                (programsState4, selectedValue5, selectedValue3) = releasePreparedTrade(
                    programsState211,
                    nextQueryId,
                    queryId,
                    retries,
                    tradeAmount6,
                    amounts,
                    result6,
                );
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                selectedValue3 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount6),
                );
                selectedValue5 = result8;
                programsState4 = programsState211;
            }
            (selectedValue5, programsState4, selectedValue3) = pendingState(
                selectedValue5,
                programsState4,
                selectedValue3,
            );
        } else {
            (selectedValue5, programsState4, selectedValue3) = keepUnmatchedTrade(
                body,
                secondLeg,
                queryId,
                retries,
                programs,
                amounts,
                nextQueryId,
            );
        }
    } else {
        (selectedValue5, programsState4, selectedValue3) = keepOtherTrade(
            body,
            opcode,
            queryId,
            retries,
            programs,
            amounts,
        );
    }
    return (programsState4, selectedValue3, selectedValue5);
}

// Dispatch kind 13; wire predicates and gas boundaries are preserved.
@method_id(11)
fun processProtocol13(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var selectedValue3: cell;
    var programsState4: cell;
    var selectedValue5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0xd53276db) as int);

        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var dataSlice = secondLeg.beginParse();
            var (cursor25, protocolKind3) = loadUint4(dataSlice);
            var (cursor26, sourceAssetKind4) = loadUint4(cursor25);
            var (cursor27, targetAssetKind5) = loadUint4(cursor26);
            val D3 = preloadMaybeDictionary(cursor27);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            var (instructionTail28, tradeAmount6) = loadCoinsField(D3.beginParse());
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            val result6 = prepareTradeMessage(
                protocolKind3,
                sourceAssetKind4,
                targetAssetKind5,
                nextQueryId,
                body,
                instructionTail28,
                tradeAmount6,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                (programsState4, selectedValue5, selectedValue3) = releasePreparedTrade(
                    programsState211,
                    nextQueryId,
                    queryId,
                    retries,
                    tradeAmount6,
                    amounts,
                    result6,
                );
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                selectedValue3 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount6),
                );
                selectedValue5 = result8;
                programsState4 = programsState211;
            }
            (selectedValue5, programsState4, selectedValue3) = pendingState(
                selectedValue5,
                programsState4,
                selectedValue3,
            );
        } else {
            (selectedValue5, programsState4, selectedValue3) = keepUnmatchedTrade(
                body,
                secondLeg,
                queryId,
                retries,
                programs,
                amounts,
                nextQueryId,
            );
        }
    } else {
        (selectedValue5, programsState4, selectedValue3) = keepOtherTrade(
            body,
            opcode,
            queryId,
            retries,
            programs,
            amounts,
        );
    }
    return (programsState4, selectedValue3, selectedValue5);
}

// Dispatch kind 0; wire predicates and gas boundaries are preserved.
@method_id(12)
fun processProtocol0(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0xd53276db) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var dataSlice = secondLeg.beginParse();
            var (cursor25, protocolKind3) = loadUint4(dataSlice);
            var (cursor26, sourceAssetKind4) = loadUint4(cursor25);
            var (cursor27, targetAssetKind5) = loadUint4(cursor26);
            val D3 = preloadMaybeDictionary(cursor27);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            var (instructionTail28, tradeAmount6) = loadCoinsField(D3.beginParse());
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            val result6 = prepareTradeMessage(
                protocolKind3,
                sourceAssetKind4,
                targetAssetKind5,
                nextQueryId,
                body,
                instructionTail28,
                tradeAmount6,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                amountsState8 = amounts;
                retriesState7 = retries;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                amountsState8 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount6),
                );
                retriesState7 = result8;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 0x7362d09c)) {
            var (D212, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D213, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D212, D213, D214);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 0x7362d09c)) {
                var (D215, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D216, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D215, D216, D217);
            }
            val result11 = ((opcode == 0xd53276db) as int);

            if (result11 != 0) {
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D218, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D219, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D218, D219, D220);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, tradeAmount8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor29, protocolKind9) = loadUint4(dataSlice3);
                var (cursor210, sourceAssetKind10) = loadUint4(cursor29);
                var (cursor211, targetAssetKind11) = loadUint4(cursor210);
                val D4 = preloadMaybeDictionary(cursor211);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D221, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D222, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D221, D222, D223);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState224 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail212, _) = loadCoinsField(D4.beginParse());
                val result12 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail212,
                    tradeAmount8,
                );
                val result13 = isVmNull((result12 as unknown));

                if (result13 != 0) {
                    amountsState5 = amounts;
                    retriesState3 = retries;
                } else {
                    val result14 = sendOrQueueTrade(retries, queryId, result12);
                    amountsState5 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), tradeAmount8),
                    );
                    retriesState3 = result14;
                }
                programsState4 = programsState224;
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        } else {
            val result15 = ((firstLegMode == 1) as int);
            var selectedValue10: int;
            if (result15 != 0) {
                val result16 = ((secondLegMode == 1) as int);
                selectedValue10 = ((result16 != 0) as int);
            } else {
                selectedValue10 = 0;
            }

            if (selectedValue10 != 0) {
                val result17 = ((opcode == 0xd53276db) as int);

                if (result17 != 0) {
                    var (_, status2) = findUnsignedEntry(amounts, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programs, amounts, retries);
                    }
                    var dataSlice5 = secondLeg.beginParse();
                    var (cursor213, protocolKind12) = loadUint4(dataSlice5);
                    var (cursor214, sourceAssetKind13) = loadUint4(cursor213);
                    var (cursor215, targetAssetKind14) = loadUint4(cursor214);
                    val D5 = preloadMaybeDictionary(cursor215);
                    if (isVmNull((D5 as unknown)) != 0) {
                        var (D225, _) = deleteUnsignedEntry(programs, 64, queryId);
                        var (D226, _) = deleteUnsignedEntry(amounts, 64, queryId);
                        var (D227, _) = deleteUnsignedEntry(retries, 64, queryId);
                        return (D225, D226, D227);
                    }
                    var (instructionTail216, tradeAmount15) = loadCoinsField(D5.beginParse());
                    val dataSlice6 = secondLeg.beginParse();
                    val programsState228 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice6);
                    val result18 = prepareTradeMessage(
                        protocolKind12,
                        sourceAssetKind13,
                        targetAssetKind14,
                        nextQueryId,
                        body,
                        instructionTail216,
                        tradeAmount15,
                    );
                    val result19 = isVmNull((result18 as unknown));

                    if (result19 != 0) {
                        (programsState4, retriesState3, amountsState5) = releasePreparedTrade(
                            programsState228,
                            nextQueryId,
                            queryId,
                            retries,
                            tradeAmount15,
                            amounts,
                            result18,
                        );
                    } else {
                        val result20 = sendOrQueueTrade(retries, queryId, result18);
                        amountsState5 = setUnsignedBuilder(
                            amounts,
                            64,
                            nextQueryId,
                            storeCoinsField(beginCell(), tradeAmount15),
                        );
                        retriesState3 = result20;

                        programsState4 = programsState228;
                    }
                    (retriesState3, programsState4, amountsState5) = pendingState(
                        retriesState3,
                        programsState4,
                        amountsState5,
                    );
                } else {
                    (retriesState3, programsState4, amountsState5) = keepUnmatchedProgram(
                        body,
                        nextQueryId,
                        queryId,
                        retries,
                        programs,
                        amounts,
                        secondLeg,
                    );
                }
            } else {
                (retriesState3, programsState4, amountsState5) = keepOtherTrade(
                    body,
                    opcode,
                    queryId,
                    retries,
                    programs,
                    amounts,
                );
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 1; wire predicates and gas boundaries are preserved.
@method_id(13)
fun processProtocol1(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                amountsState8 = amounts;
                retriesState7 = retries;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                amountsState8 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState7 = result8;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 0x474f86cf)) {
            var (D212, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D213, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D212, D213, D214);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 0x474f86cf)) {
                var (D215, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D216, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D215, D216, D217);
            }
            val result11 = ((opcode == 0x7362d09c) as int);

            if (result11 != 0) {
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D218, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D219, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D218, D219, D220);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, x8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D221, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D222, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D221, D222, D223);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState224 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, x12) = loadCoinsField(D4.beginParse());
                val result12 = ((x12 > 0) as int);
                var selectedValue10 = x8;
                if (result12 != 0) {
                    selectedValue10 = x12;
                } else {}
                val result13 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    selectedValue10,
                );
                val result14 = isVmNull((result13 as unknown));

                if (result14 != 0) {
                    amountsState5 = amounts;
                    retriesState3 = retries;
                } else {
                    val result15 = sendOrQueueTrade(retries, queryId, result13);
                    amountsState5 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), selectedValue10),
                    );
                    retriesState3 = result15;
                }
                programsState4 = programsState224;
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        } else {
            val result16 = ((firstLegMode == 1) as int);
            var selectedValue11: int;
            if (result16 != 0) {
                val result17 = ((secondLegMode == 1) as int);
                selectedValue11 = ((result17 != 0) as int);
            } else {
                selectedValue11 = 0;
            }

            if (selectedValue11 != 0) {
                val result18 = ((opcode == 0x7362d09c) as int);

                if (result18 != 0) {
                    var (x13, status2) = findUnsignedEntry(amounts, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programs, amounts, retries);
                    }
                    var (_, tradeAmount14) = loadCoinsField(x13);
                    var (callbackTail214, tradeAmount15) = loadCoinsField(body);
                    val result19 = ((tradeAmount14 == tradeAmount15) as int);

                    if (result19 != 0) {
                        if (isVmNull((firstLeg as unknown)) != 0) {
                            var (D225, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D226, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D227, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D225, D226, D227);
                        }
                        var dataSlice5 = firstLeg.beginParse();
                        var (cursor215, protocolKind16) = loadUint4(dataSlice5);
                        var (cursor216, sourceAssetKind17) = loadUint4(cursor215);
                        var (cursor217, targetAssetKind18) = loadUint4(cursor216);
                        val D5 = preloadMaybeDictionary(cursor217);
                        if (isVmNull((D5 as unknown)) != 0) {
                            var (D228, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D229, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D230, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D228, D229, D230);
                        }
                        val dataSlice6 = firstLeg.beginParse();
                        val programsState231 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice6,
                        );
                        var (instructionTail218, _) = loadCoinsField(D5.beginParse());
                        val result20 = prepareTradeMessage(
                            protocolKind16,
                            sourceAssetKind17,
                            targetAssetKind18,
                            nextQueryId,
                            callbackTail214,
                            instructionTail218,
                            tradeAmount14,
                        );
                        val result21 = isVmNull((result20 as unknown));

                        if (result21 != 0) {
                            (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                                tradeAmount14,
                                programsState231,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result20,
                            );
                        } else {
                            val result22 = sendOrQueueTrade(retries, queryId, result20);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount14),
                            );
                            retriesState3 = result22;

                            programsState4 = programsState231;
                        }
                    } else {
                        if (isVmNull((secondLeg as unknown)) != 0) {
                            var (D232, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D233, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D234, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D232, D233, D234);
                        }
                        var dataSlice7 = secondLeg.beginParse();
                        var (cursor219, protocolKind19) = loadUint4(dataSlice7);
                        var (cursor220, sourceAssetKind20) = loadUint4(cursor219);
                        var (cursor221, targetAssetKind21) = loadUint4(cursor220);
                        val D6 = preloadMaybeDictionary(cursor221);
                        if (isVmNull((D6 as unknown)) != 0) {
                            var (D235, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D236, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D237, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D235, D236, D237);
                        }
                        val dataSlice8 = secondLeg.beginParse();
                        val programsState238 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice8,
                        );
                        var (instructionTail222, _) = loadCoinsField(D6.beginParse());
                        val result23 = prepareTradeMessage(
                            protocolKind19,
                            sourceAssetKind20,
                            targetAssetKind21,
                            nextQueryId,
                            callbackTail214,
                            instructionTail222,
                            tradeAmount15,
                        );
                        val result24 = isVmNull((result23 as unknown));

                        if (result24 != 0) {
                            (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                                tradeAmount15,
                                programsState238,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result23,
                            );
                        } else {
                            val result25 = sendOrQueueTrade(retries, queryId, result23);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount15),
                            );
                            retriesState3 = result25;

                            programsState4 = programsState238;
                        }
                    }
                } else {
                    amountsState5 = amounts;
                    programsState4 = programs;
                    retriesState3 = retries;
                }
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 6; wire predicates and gas boundaries are preserved.
@method_id(14)
fun processProtocol6(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                retriesState7 = retries;
                amountsState8 = amounts;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                val amountsState212 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState7 = result8;
                amountsState8 = amountsState212;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 0xc0ffee32)) {
            var (D213, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D215, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D213, D214, D215);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 0xc0ffee32)) {
                var (D216, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D218, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D216, D217, D218);
            }
            val result11 = ((opcode == 0xd53276db) as int);

            if (result11 != 0) {
                if ((messageValue < 100000000)) {
                    return (programs, amounts, retries);
                }
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D219, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D221, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D219, D220, D221);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, x8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D222, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D224, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D222, D223, D224);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState225 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, x12) = loadCoinsField(D4.beginParse());
                val result12 = ((x12 > 0) as int);
                var selectedValue10 = x8;
                if (result12 != 0) {
                    selectedValue10 = x12;
                } else {}
                val result13 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    selectedValue10,
                );
                val result14 = isVmNull((result13 as unknown));

                if (result14 != 0) {
                    (programsState4, amountsState5, retriesState3) = releaseSeven_0_5_4(
                        programsState225,
                        nextQueryId,
                        queryId,
                        selectedValue10,
                        retries,
                        amounts,
                        result13,
                    );
                } else {
                    val result15 = sendOrQueueTrade(retries, queryId, result13);
                    val amountsState226 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), selectedValue10),
                    );
                    retriesState3 = result15;
                    amountsState5 = amountsState226;
                    programsState4 = programsState225;
                }
                (retriesState3, programsState4, amountsState5) = pendingState(
                    retriesState3,
                    programsState4,
                    amountsState5,
                );
            } else {
                (retriesState3, programsState4, amountsState5) = keepEight_6_4_5(
                    messageValue,
                    nextQueryId,
                    queryId,
                    body,
                    programs,
                    amounts,
                    retries,
                    firstLeg,
                );
            }
        } else {
            val result16 = ((firstLegMode == 1) as int);
            var selectedValue11: int;
            if (result16 != 0) {
                val result17 = ((secondLegMode == 1) as int);
                selectedValue11 = ((result17 != 0) as int);
            } else {
                selectedValue11 = 0;
            }

            if (selectedValue11 != 0) {
                val result18 = ((opcode == 0x7362d09c) as int);

                if (result18 != 0) {
                    var (x13, status2) = findUnsignedEntry(amounts, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programs, amounts, retries);
                    }
                    var (_, tradeAmount14) = loadCoinsField(x13);
                    var (callbackTail214, tradeAmount15) = loadCoinsField(body);
                    val result19 = ((tradeAmount14 == tradeAmount15) as int);

                    if (result19 != 0) {
                        if (isVmNull((firstLeg as unknown)) != 0) {
                            var (D227, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D228, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D229, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D227, D228, D229);
                        }
                        var dataSlice5 = firstLeg.beginParse();
                        var (cursor215, protocolKind16) = loadUint4(dataSlice5);
                        var (cursor216, sourceAssetKind17) = loadUint4(cursor215);
                        var (cursor217, targetAssetKind18) = loadUint4(cursor216);
                        val D5 = preloadMaybeDictionary(cursor217);
                        if (isVmNull((D5 as unknown)) != 0) {
                            var (D230, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D231, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D232, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D230, D231, D232);
                        }
                        val dataSlice6 = firstLeg.beginParse();
                        val programsState233 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice6,
                        );
                        var (instructionTail218, _) = loadCoinsField(D5.beginParse());
                        val result20 = prepareTradeMessage(
                            protocolKind16,
                            sourceAssetKind17,
                            targetAssetKind18,
                            nextQueryId,
                            callbackTail214,
                            instructionTail218,
                            tradeAmount14,
                        );
                        val result21 = isVmNull((result20 as unknown));

                        if (result21 != 0) {
                            (amountsState5, programsState4, retriesState3) = releaseSeven_5_1_4(
                                nextQueryId,
                                programsState233,
                                queryId,
                                tradeAmount14,
                                retries,
                                amounts,
                                result20,
                            );
                        } else {
                            val result22 = sendOrQueueTrade(retries, queryId, result20);
                            val amountsState234 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount14),
                            );
                            retriesState3 = result22;
                            amountsState5 = amountsState234;
                            programsState4 = programsState233;
                        }
                    } else {
                        if (isVmNull((secondLeg as unknown)) != 0) {
                            var (D235, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D236, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D237, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D235, D236, D237);
                        }
                        var dataSlice7 = secondLeg.beginParse();
                        var (cursor219, protocolKind19) = loadUint4(dataSlice7);
                        var (cursor220, sourceAssetKind20) = loadUint4(cursor219);
                        var (cursor221, targetAssetKind21) = loadUint4(cursor220);
                        val D6 = preloadMaybeDictionary(cursor221);
                        if (isVmNull((D6 as unknown)) != 0) {
                            var (D238, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D239, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D240, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D238, D239, D240);
                        }
                        val dataSlice8 = secondLeg.beginParse();
                        val programsState241 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice8,
                        );
                        var (instructionTail222, _) = loadCoinsField(D6.beginParse());
                        val result23 = prepareTradeMessage(
                            protocolKind19,
                            sourceAssetKind20,
                            targetAssetKind21,
                            nextQueryId,
                            callbackTail214,
                            instructionTail222,
                            tradeAmount15,
                        );
                        val result24 = isVmNull((result23 as unknown));

                        if (result24 != 0) {
                            amountsState5 = amounts;
                            retriesState3 = retries;
                        } else {
                            val result25 = sendOrQueueTrade(retries, queryId, result23);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount15),
                            );
                            retriesState3 = result25;
                        }
                        programsState4 = programsState241;
                        (amountsState5, programsState4, retriesState3) = pendingState(
                            amountsState5,
                            programsState4,
                            retriesState3,
                        );
                    }
                    (retriesState3, programsState4, amountsState5) = pendingState(
                        retriesState3,
                        programsState4,
                        amountsState5,
                    );
                } else {
                    (retriesState3, programsState4, amountsState5) = keepEight_6_4_5(
                        nextQueryId,
                        firstLeg,
                        queryId,
                        body,
                        programs,
                        amounts,
                        retries,
                        secondLeg,
                    );
                }
            } else {
                (retriesState3, programsState4, amountsState5) = keepNine_6_4_5(
                    nextQueryId,
                    opcode,
                    queryId,
                    body,
                    programs,
                    amounts,
                    retries,
                    secondLeg,
                    firstLeg,
                );
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 7; wire predicates and gas boundaries are preserved.
@method_id(15)
fun processProtocol7(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                amountsState8 = amounts;
                retriesState7 = retries;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                amountsState8 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState7 = result8;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 0xc47c1f57)) {
            var (D212, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D213, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D212, D213, D214);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 0xcb7f38d6)) {
                var (D215, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D216, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D215, D216, D217);
            }
            val result11 = ((opcode == 0x7362d09c) as int);

            if (result11 != 0) {
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D218, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D219, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D218, D219, D220);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, x8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D221, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D222, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D221, D222, D223);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState224 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, x12) = loadCoinsField(D4.beginParse());
                val result12 = ((x12 > 0) as int);
                var selectedValue10 = x8;
                if (result12 != 0) {
                    selectedValue10 = x12;
                } else {}
                val result13 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    selectedValue10,
                );
                val result14 = isVmNull((result13 as unknown));

                if (result14 != 0) {
                    (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                        selectedValue10,
                        programsState224,
                        queryId,
                        retries,
                        nextQueryId,
                        amounts,
                        result13,
                    );
                } else {
                    val result15 = sendOrQueueTrade(retries, queryId, result13);
                    amountsState5 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), selectedValue10),
                    );
                    retriesState3 = result15;

                    programsState4 = programsState224;
                }
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        } else {
            amountsState5 = amounts;
            programsState4 = programs;
            retriesState3 = retries;
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 8; wire predicates and gas boundaries are preserved.
@method_id(16)
fun processProtocol8(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                amountsState8 = amounts;
                retriesState7 = retries;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                amountsState8 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState7 = result8;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 0xff32da99)) {
            var (D212, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D213, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D212, D213, D214);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 0x9d142643)) {
                var (D215, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D216, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D215, D216, D217);
            }
            val result11 = ((opcode == 0x7362d09c) as int);

            if (result11 != 0) {
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D218, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D219, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D218, D219, D220);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, x8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D221, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D222, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D221, D222, D223);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState224 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, x12) = loadCoinsField(D4.beginParse());
                val result12 = ((x12 > 0) as int);
                var selectedValue10 = x8;
                if (result12 != 0) {
                    selectedValue10 = x12;
                } else {}
                val result13 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    selectedValue10,
                );
                val result14 = isVmNull((result13 as unknown));

                if (result14 != 0) {
                    amountsState5 = amounts;
                    retriesState3 = retries;
                } else {
                    val result15 = sendOrQueueTrade(retries, queryId, result13);
                    amountsState5 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), selectedValue10),
                    );
                    retriesState3 = result15;
                }
                programsState4 = programsState224;
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        } else {
            val result16 = ((firstLegMode == 1) as int);
            var selectedValue11: int;
            if (result16 != 0) {
                val result17 = ((secondLegMode == 1) as int);
                selectedValue11 = ((result17 != 0) as int);
            } else {
                selectedValue11 = 0;
            }

            if (selectedValue11 != 0) {
                val result18 = ((opcode == 0x7362d09c) as int);

                if (result18 != 0) {
                    var (x13, status2) = findUnsignedEntry(amounts, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programs, amounts, retries);
                    }
                    var (_, tradeAmount14) = loadCoinsField(x13);
                    var (callbackTail214, tradeAmount15) = loadCoinsField(body);
                    val result19 = ((tradeAmount14 == tradeAmount15) as int);

                    if (result19 != 0) {
                        if (isVmNull((firstLeg as unknown)) != 0) {
                            var (D225, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D226, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D227, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D225, D226, D227);
                        }
                        var dataSlice5 = firstLeg.beginParse();
                        var (cursor215, protocolKind16) = loadUint4(dataSlice5);
                        var (cursor216, sourceAssetKind17) = loadUint4(cursor215);
                        var (cursor217, targetAssetKind18) = loadUint4(cursor216);
                        val D5 = preloadMaybeDictionary(cursor217);
                        if (isVmNull((D5 as unknown)) != 0) {
                            var (D228, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D229, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D230, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D228, D229, D230);
                        }
                        val dataSlice6 = firstLeg.beginParse();
                        val programsState231 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice6,
                        );
                        var (instructionTail218, _) = loadCoinsField(D5.beginParse());
                        val result20 = prepareTradeMessage(
                            protocolKind16,
                            sourceAssetKind17,
                            targetAssetKind18,
                            nextQueryId,
                            callbackTail214,
                            instructionTail218,
                            tradeAmount14,
                        );
                        val result21 = isVmNull((result20 as unknown));

                        if (result21 != 0) {
                            (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                                tradeAmount14,
                                programsState231,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result20,
                            );
                        } else {
                            val result22 = sendOrQueueTrade(retries, queryId, result20);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount14),
                            );
                            retriesState3 = result22;

                            programsState4 = programsState231;
                        }
                    } else {
                        if (isVmNull((secondLeg as unknown)) != 0) {
                            var (D232, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D233, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D234, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D232, D233, D234);
                        }
                        var dataSlice7 = secondLeg.beginParse();
                        var (cursor219, protocolKind19) = loadUint4(dataSlice7);
                        var (cursor220, sourceAssetKind20) = loadUint4(cursor219);
                        var (cursor221, targetAssetKind21) = loadUint4(cursor220);
                        val D6 = preloadMaybeDictionary(cursor221);
                        if (isVmNull((D6 as unknown)) != 0) {
                            var (D235, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D236, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D237, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D235, D236, D237);
                        }
                        val dataSlice8 = secondLeg.beginParse();
                        val programsState238 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice8,
                        );
                        var (instructionTail222, _) = loadCoinsField(D6.beginParse());
                        val result23 = prepareTradeMessage(
                            protocolKind19,
                            sourceAssetKind20,
                            targetAssetKind21,
                            nextQueryId,
                            callbackTail214,
                            instructionTail222,
                            tradeAmount15,
                        );
                        val result24 = isVmNull((result23 as unknown));

                        if (result24 != 0) {
                            (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                                tradeAmount15,
                                programsState238,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result23,
                            );
                        } else {
                            val result25 = sendOrQueueTrade(retries, queryId, result23);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount15),
                            );
                            retriesState3 = result25;

                            programsState4 = programsState238;
                        }
                    }
                } else {
                    amountsState5 = amounts;
                    programsState4 = programs;
                    retriesState3 = retries;
                }
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 9; wire predicates and gas boundaries are preserved.
@method_id(17)
fun processProtocol9(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                amountsState8 = amounts;
                retriesState7 = retries;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                amountsState8 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState7 = result8;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 0xff32da99)) {
            var (D212, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D213, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D212, D213, D214);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 0x9d142643)) {
                var (D215, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D216, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D215, D216, D217);
            }
            val result11 = ((opcode == 0x7362d09c) as int);

            if (result11 != 0) {
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D218, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D219, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D218, D219, D220);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, x8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D221, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D222, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D221, D222, D223);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState224 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, x12) = loadCoinsField(D4.beginParse());
                val result12 = ((x12 > 0) as int);
                var selectedValue10 = x8;
                if (result12 != 0) {
                    selectedValue10 = x12;
                } else {}
                val result13 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    selectedValue10,
                );
                val result14 = isVmNull((result13 as unknown));

                if (result14 != 0) {
                    amountsState5 = amounts;
                    retriesState3 = retries;
                } else {
                    val result15 = sendOrQueueTrade(retries, queryId, result13);
                    amountsState5 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), selectedValue10),
                    );
                    retriesState3 = result15;
                }
                programsState4 = programsState224;
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        } else {
            val result16 = ((firstLegMode == 1) as int);
            var selectedValue11: int;
            if (result16 != 0) {
                val result17 = ((secondLegMode == 1) as int);
                selectedValue11 = ((result17 != 0) as int);
            } else {
                selectedValue11 = 0;
            }

            if (selectedValue11 != 0) {
                val result18 = ((opcode == 0x7362d09c) as int);

                if (result18 != 0) {
                    var (x13, status2) = findUnsignedEntry(amounts, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programs, amounts, retries);
                    }
                    var (_, tradeAmount14) = loadCoinsField(x13);
                    var (callbackTail214, tradeAmount15) = loadCoinsField(body);
                    val result19 = ((tradeAmount14 == tradeAmount15) as int);

                    if (result19 != 0) {
                        if (isVmNull((firstLeg as unknown)) != 0) {
                            var (D225, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D226, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D227, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D225, D226, D227);
                        }
                        var dataSlice5 = firstLeg.beginParse();
                        var (cursor215, protocolKind16) = loadUint4(dataSlice5);
                        var (cursor216, sourceAssetKind17) = loadUint4(cursor215);
                        var (cursor217, targetAssetKind18) = loadUint4(cursor216);
                        val D5 = preloadMaybeDictionary(cursor217);
                        if (isVmNull((D5 as unknown)) != 0) {
                            var (D228, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D229, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D230, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D228, D229, D230);
                        }
                        val dataSlice6 = firstLeg.beginParse();
                        val programsState231 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice6,
                        );
                        var (instructionTail218, _) = loadCoinsField(D5.beginParse());
                        val result20 = prepareTradeMessage(
                            protocolKind16,
                            sourceAssetKind17,
                            targetAssetKind18,
                            nextQueryId,
                            callbackTail214,
                            instructionTail218,
                            tradeAmount14,
                        );
                        val result21 = isVmNull((result20 as unknown));

                        if (result21 != 0) {
                            (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                                tradeAmount14,
                                programsState231,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result20,
                            );
                        } else {
                            val result22 = sendOrQueueTrade(retries, queryId, result20);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount14),
                            );
                            retriesState3 = result22;

                            programsState4 = programsState231;
                        }
                    } else {
                        if (isVmNull((secondLeg as unknown)) != 0) {
                            var (D232, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D233, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D234, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D232, D233, D234);
                        }
                        var dataSlice7 = secondLeg.beginParse();
                        var (cursor219, protocolKind19) = loadUint4(dataSlice7);
                        var (cursor220, sourceAssetKind20) = loadUint4(cursor219);
                        var (cursor221, targetAssetKind21) = loadUint4(cursor220);
                        val D6 = preloadMaybeDictionary(cursor221);
                        if (isVmNull((D6 as unknown)) != 0) {
                            var (D235, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D236, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D237, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D235, D236, D237);
                        }
                        val dataSlice8 = secondLeg.beginParse();
                        val programsState238 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice8,
                        );
                        var (instructionTail222, _) = loadCoinsField(D6.beginParse());
                        val result23 = prepareTradeMessage(
                            protocolKind19,
                            sourceAssetKind20,
                            targetAssetKind21,
                            nextQueryId,
                            callbackTail214,
                            instructionTail222,
                            tradeAmount15,
                        );
                        val result24 = isVmNull((result23 as unknown));

                        if (result24 != 0) {
                            (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                                tradeAmount15,
                                programsState238,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result23,
                            );
                        } else {
                            val result25 = sendOrQueueTrade(retries, queryId, result23);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount15),
                            );
                            retriesState3 = result25;

                            programsState4 = programsState238;
                        }
                    }
                } else {
                    amountsState5 = amounts;
                    programsState4 = programs;
                    retriesState3 = retries;
                }
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 5; wire predicates and gas boundaries are preserved.
@method_id(18)
fun processProtocol5(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                retriesState7 = retries;
                amountsState8 = amounts;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                val amountsState212 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState7 = result8;
                amountsState8 = amountsState212;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 0x6edd65f0)) {
            var (D213, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D215, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D213, D214, D215);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 0x6edd65f0)) {
                var (D216, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D218, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D216, D217, D218);
            }
            val result11 = ((opcode == 0xd53276db) as int);

            if (result11 != 0) {
                if ((messageValue < 100000000)) {
                    return (programs, amounts, retries);
                }
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D219, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D221, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D219, D220, D221);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, x8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D222, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D224, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D222, D223, D224);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState225 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, x12) = loadCoinsField(D4.beginParse());
                val result12 = ((x12 > 0) as int);
                var selectedValue10 = x8;
                if (result12 != 0) {
                    selectedValue10 = x12;
                } else {}
                val result13 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    selectedValue10,
                );
                val result14 = isVmNull((result13 as unknown));

                if (result14 != 0) {
                    (programsState4, amountsState5, retriesState3) = releaseSeven_0_5_4(
                        programsState225,
                        nextQueryId,
                        queryId,
                        selectedValue10,
                        retries,
                        amounts,
                        result13,
                    );
                } else {
                    val result15 = sendOrQueueTrade(retries, queryId, result13);
                    val amountsState226 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), selectedValue10),
                    );
                    retriesState3 = result15;
                    amountsState5 = amountsState226;
                    programsState4 = programsState225;
                }
                (retriesState3, programsState4, amountsState5) = pendingState(
                    retriesState3,
                    programsState4,
                    amountsState5,
                );
            } else {
                (retriesState3, programsState4, amountsState5) = keepEight_6_4_5(
                    messageValue,
                    nextQueryId,
                    queryId,
                    body,
                    programs,
                    amounts,
                    retries,
                    firstLeg,
                );
            }
        } else {
            val result16 = ((firstLegMode == 1) as int);
            var selectedValue11: int;
            if (result16 != 0) {
                val result17 = ((secondLegMode == 1) as int);
                selectedValue11 = ((result17 != 0) as int);
            } else {
                selectedValue11 = 0;
            }

            if (selectedValue11 != 0) {
                val result18 = ((opcode == 0x7362d09c) as int);

                if (result18 != 0) {
                    var (x13, status2) = findUnsignedEntry(amounts, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programs, amounts, retries);
                    }
                    var (_, tradeAmount14) = loadCoinsField(x13);
                    var (callbackTail214, tradeAmount15) = loadCoinsField(body);
                    val result19 = ((tradeAmount14 == tradeAmount15) as int);

                    if (result19 != 0) {
                        if (isVmNull((firstLeg as unknown)) != 0) {
                            var (D227, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D228, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D229, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D227, D228, D229);
                        }
                        var dataSlice5 = firstLeg.beginParse();
                        var (cursor215, protocolKind16) = loadUint4(dataSlice5);
                        var (cursor216, sourceAssetKind17) = loadUint4(cursor215);
                        var (cursor217, targetAssetKind18) = loadUint4(cursor216);
                        val D5 = preloadMaybeDictionary(cursor217);
                        if (isVmNull((D5 as unknown)) != 0) {
                            var (D230, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D231, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D232, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D230, D231, D232);
                        }
                        val dataSlice6 = firstLeg.beginParse();
                        val programsState233 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice6,
                        );
                        var (instructionTail218, _) = loadCoinsField(D5.beginParse());
                        val result20 = prepareTradeMessage(
                            protocolKind16,
                            sourceAssetKind17,
                            targetAssetKind18,
                            nextQueryId,
                            callbackTail214,
                            instructionTail218,
                            tradeAmount14,
                        );
                        val result21 = isVmNull((result20 as unknown));

                        if (result21 != 0) {
                            (amountsState5, programsState4, retriesState3) = releaseSeven_5_1_4(
                                nextQueryId,
                                programsState233,
                                queryId,
                                tradeAmount14,
                                retries,
                                amounts,
                                result20,
                            );
                        } else {
                            val result22 = sendOrQueueTrade(retries, queryId, result20);
                            val amountsState234 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount14),
                            );
                            retriesState3 = result22;
                            amountsState5 = amountsState234;
                            programsState4 = programsState233;
                        }
                    } else {
                        if (isVmNull((secondLeg as unknown)) != 0) {
                            var (D235, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D236, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D237, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D235, D236, D237);
                        }
                        var dataSlice7 = secondLeg.beginParse();
                        var (cursor219, protocolKind19) = loadUint4(dataSlice7);
                        var (cursor220, sourceAssetKind20) = loadUint4(cursor219);
                        var (cursor221, targetAssetKind21) = loadUint4(cursor220);
                        val D6 = preloadMaybeDictionary(cursor221);
                        if (isVmNull((D6 as unknown)) != 0) {
                            var (D238, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D239, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D240, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D238, D239, D240);
                        }
                        val dataSlice8 = secondLeg.beginParse();
                        val programsState241 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice8,
                        );
                        var (instructionTail222, _) = loadCoinsField(D6.beginParse());
                        val result23 = prepareTradeMessage(
                            protocolKind19,
                            sourceAssetKind20,
                            targetAssetKind21,
                            nextQueryId,
                            callbackTail214,
                            instructionTail222,
                            tradeAmount15,
                        );
                        val result24 = isVmNull((result23 as unknown));

                        if (result24 != 0) {
                            amountsState5 = amounts;
                            retriesState3 = retries;
                        } else {
                            val result25 = sendOrQueueTrade(retries, queryId, result23);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount15),
                            );
                            retriesState3 = result25;
                        }
                        programsState4 = programsState241;
                        (amountsState5, programsState4, retriesState3) = pendingState(
                            amountsState5,
                            programsState4,
                            retriesState3,
                        );
                    }
                    (retriesState3, programsState4, amountsState5) = pendingState(
                        retriesState3,
                        programsState4,
                        amountsState5,
                    );
                } else {
                    (retriesState3, programsState4, amountsState5) = keepEight_6_4_5(
                        nextQueryId,
                        firstLeg,
                        queryId,
                        body,
                        programs,
                        amounts,
                        retries,
                        secondLeg,
                    );
                }
            } else {
                (retriesState3, programsState4, amountsState5) = keepNine_6_4_5(
                    nextQueryId,
                    opcode,
                    queryId,
                    body,
                    programs,
                    amounts,
                    retries,
                    secondLeg,
                    firstLeg,
                );
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 10; wire predicates and gas boundaries are preserved.
@method_id(19)
fun processProtocol10(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                amountsState8 = amounts;
                retriesState7 = retries;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                amountsState8 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState7 = result8;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 0x6edd65f0)) {
            var (D212, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D213, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D212, D213, D214);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 0x6edd65f0)) {
                var (D215, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D216, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D215, D216, D217);
            }
            val result11 = ((opcode == 0x7362d09c) as int);

            if (result11 != 0) {
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D218, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D219, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D218, D219, D220);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, x8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D221, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D222, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D221, D222, D223);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState224 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, x12) = loadCoinsField(D4.beginParse());
                val result12 = ((x12 > 0) as int);
                var selectedValue10 = x8;
                if (result12 != 0) {
                    selectedValue10 = x12;
                } else {}
                val result13 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    selectedValue10,
                );
                val result14 = isVmNull((result13 as unknown));

                if (result14 != 0) {
                    amountsState5 = amounts;
                    retriesState3 = retries;
                } else {
                    val result15 = sendOrQueueTrade(retries, queryId, result13);
                    amountsState5 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), selectedValue10),
                    );
                    retriesState3 = result15;
                }
                programsState4 = programsState224;
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        } else {
            val result16 = ((firstLegMode == 1) as int);
            var selectedValue11: int;
            if (result16 != 0) {
                val result17 = ((secondLegMode == 1) as int);
                selectedValue11 = ((result17 != 0) as int);
            } else {
                selectedValue11 = 0;
            }

            if (selectedValue11 != 0) {
                val result18 = ((opcode == 0x7362d09c) as int);

                if (result18 != 0) {
                    var (x13, status2) = findUnsignedEntry(amounts, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programs, amounts, retries);
                    }
                    var (_, tradeAmount14) = loadCoinsField(x13);
                    var (callbackTail214, tradeAmount15) = loadCoinsField(body);
                    val result19 = ((tradeAmount14 == tradeAmount15) as int);

                    if (result19 != 0) {
                        if (isVmNull((firstLeg as unknown)) != 0) {
                            var (D225, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D226, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D227, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D225, D226, D227);
                        }
                        var dataSlice5 = firstLeg.beginParse();
                        var (cursor215, protocolKind16) = loadUint4(dataSlice5);
                        var (cursor216, sourceAssetKind17) = loadUint4(cursor215);
                        var (cursor217, targetAssetKind18) = loadUint4(cursor216);
                        val D5 = preloadMaybeDictionary(cursor217);
                        if (isVmNull((D5 as unknown)) != 0) {
                            var (D228, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D229, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D230, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D228, D229, D230);
                        }
                        val dataSlice6 = firstLeg.beginParse();
                        val programsState231 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice6,
                        );
                        var (instructionTail218, _) = loadCoinsField(D5.beginParse());
                        val result20 = prepareTradeMessage(
                            protocolKind16,
                            sourceAssetKind17,
                            targetAssetKind18,
                            nextQueryId,
                            callbackTail214,
                            instructionTail218,
                            tradeAmount14,
                        );
                        val result21 = isVmNull((result20 as unknown));

                        if (result21 != 0) {
                            (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                                tradeAmount14,
                                programsState231,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result20,
                            );
                        } else {
                            val result22 = sendOrQueueTrade(retries, queryId, result20);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount14),
                            );
                            retriesState3 = result22;

                            programsState4 = programsState231;
                        }
                    } else {
                        if (isVmNull((secondLeg as unknown)) != 0) {
                            var (D232, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D233, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D234, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D232, D233, D234);
                        }
                        var dataSlice7 = secondLeg.beginParse();
                        var (cursor219, protocolKind19) = loadUint4(dataSlice7);
                        var (cursor220, sourceAssetKind20) = loadUint4(cursor219);
                        var (cursor221, targetAssetKind21) = loadUint4(cursor220);
                        val D6 = preloadMaybeDictionary(cursor221);
                        if (isVmNull((D6 as unknown)) != 0) {
                            var (D235, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D236, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D237, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D235, D236, D237);
                        }
                        val dataSlice8 = secondLeg.beginParse();
                        val programsState238 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice8,
                        );
                        var (instructionTail222, _) = loadCoinsField(D6.beginParse());
                        val result23 = prepareTradeMessage(
                            protocolKind19,
                            sourceAssetKind20,
                            targetAssetKind21,
                            nextQueryId,
                            callbackTail214,
                            instructionTail222,
                            tradeAmount15,
                        );
                        val result24 = isVmNull((result23 as unknown));

                        if (result24 != 0) {
                            (retriesState3, programsState4, amountsState5) = releaseRejectedTrade(
                                tradeAmount15,
                                programsState238,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result23,
                            );
                        } else {
                            val result25 = sendOrQueueTrade(retries, queryId, result23);
                            amountsState5 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount15),
                            );
                            retriesState3 = result25;

                            programsState4 = programsState238;
                        }
                    }
                } else {
                    amountsState5 = amounts;
                    programsState4 = programs;
                    retriesState3 = retries;
                }
            } else {
                amountsState5 = amounts;
                programsState4 = programs;
                retriesState3 = retries;
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}

// Dispatch kind 11; wire predicates and gas boundaries are preserved.
@method_id(9)
fun processProtocol11(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var amountsState3: cell;
    var programsState4: cell;
    var retriesState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);

        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                (retriesState5, programsState4, amountsState3) = releaseRejectedTrade(
                    nextQueryId,
                    programsState211,
                    queryId,
                    retries,
                    tradeAmount3,
                    amounts,
                    result6,
                );
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                amountsState3 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState5 = result8;
                programsState4 = programsState211;
            }
        } else {
            amountsState3 = amounts;
            programsState4 = programs;
            retriesState5 = retries;
        }
    } else {
        amountsState3 = amounts;

        programsState4 = programs;

        retriesState5 = retries;
    }
    return (programsState4, amountsState3, retriesState5);
}

// Dispatch kind 4; wire predicates and gas boundaries are preserved.
@method_id(20)
fun processProtocol4(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var amountsState3: cell;
    var retriesState4: cell;
    var programsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var retriesState6: cell;
        var amountsState7: cell;
        var programsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                (programsState8, opcode, amountsState7, retriesState6) = releaseCompletedTrade(
                    programsState211,
                    opcode,
                    queryId,
                    retries,
                    tradeAmount3,
                    amounts,
                    nextQueryId,
                    result6,
                );
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                val amountsState212 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState6 = result8;
                amountsState7 = amountsState212;
                programsState8 = programsState211;
            }
        } else {
            retriesState6 = retries;

            amountsState7 = amounts;

            programsState8 = programs;
        }
        if ((opcode == 0xd53276db)) {
            return (programsState8, amountsState7, retriesState6);
        }
        amountsState3 = amountsState7;
        retriesState4 = retriesState6;
        programsState5 = programsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            val result11 = ((opcode == 0x7362d09c) as int);

            if (result11 != 0) {
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D213, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D214, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D215, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D213, D214, D215);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, tradeAmount8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D216, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D217, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D218, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D216, D217, D218);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState219 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, _) = loadCoinsField(D4.beginParse());
                val result12 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    tradeAmount8,
                );
                val result13 = isVmNull((result12 as unknown));

                if (result13 != 0) {
                    amountsState3 = amounts;
                    retriesState4 = retries;
                } else {
                    val result14 = sendOrQueueTrade(retries, queryId, result12);
                    amountsState3 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), tradeAmount8),
                    );
                    retriesState4 = result14;
                }
                programsState5 = programsState219;
            } else {
                amountsState3 = amounts;
                programsState5 = programs;
                retriesState4 = retries;
            }
        } else {
            val result15 = ((firstLegMode == 1) as int);
            var selectedValue10: int;
            if (result15 != 0) {
                val result16 = ((secondLegMode == 1) as int);
                selectedValue10 = ((result16 != 0) as int);
            } else {
                selectedValue10 = 0;
            }

            if (selectedValue10 != 0) {
                val result17 = ((opcode == 0x7362d09c) as int);

                if (result17 != 0) {
                    var (x12, status2) = findUnsignedEntry(amounts, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programs, amounts, retries);
                    }
                    var (_, tradeAmount13) = loadCoinsField(x12);
                    var (callbackTail214, tradeAmount14) = loadCoinsField(body);
                    val result18 = ((tradeAmount13 == tradeAmount14) as int);

                    if (result18 != 0) {
                        if (isVmNull((firstLeg as unknown)) != 0) {
                            var (D220, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D221, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D222, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D220, D221, D222);
                        }
                        var dataSlice5 = firstLeg.beginParse();
                        var (cursor215, protocolKind15) = loadUint4(dataSlice5);
                        var (cursor216, sourceAssetKind16) = loadUint4(cursor215);
                        var (cursor217, targetAssetKind17) = loadUint4(cursor216);
                        val D5 = preloadMaybeDictionary(cursor217);
                        if (isVmNull((D5 as unknown)) != 0) {
                            var (D223, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D224, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D225, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D223, D224, D225);
                        }
                        val dataSlice6 = firstLeg.beginParse();
                        val programsState226 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice6,
                        );
                        var (instructionTail218, _) = loadCoinsField(D5.beginParse());
                        val result19 = prepareTradeMessage(
                            protocolKind15,
                            sourceAssetKind16,
                            targetAssetKind17,
                            nextQueryId,
                            callbackTail214,
                            instructionTail218,
                            tradeAmount13,
                        );
                        val result20 = isVmNull((result19 as unknown));

                        if (result20 != 0) {
                            (retriesState4, programsState5, amountsState3) = releaseRejectedTrade(
                                tradeAmount13,
                                programsState226,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result19,
                            );
                        } else {
                            val result21 = sendOrQueueTrade(retries, queryId, result19);
                            amountsState3 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount13),
                            );
                            retriesState4 = result21;

                            programsState5 = programsState226;
                        }
                    } else {
                        if (isVmNull((secondLeg as unknown)) != 0) {
                            var (D227, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D228, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D229, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D227, D228, D229);
                        }
                        var dataSlice7 = secondLeg.beginParse();
                        var (cursor219, protocolKind18) = loadUint4(dataSlice7);
                        var (cursor220, sourceAssetKind19) = loadUint4(cursor219);
                        var (cursor221, targetAssetKind20) = loadUint4(cursor220);
                        val D6 = preloadMaybeDictionary(cursor221);
                        if (isVmNull((D6 as unknown)) != 0) {
                            var (D230, _) = deleteUnsignedEntry(programs, 64, queryId);
                            var (D231, _) = deleteUnsignedEntry(amounts, 64, queryId);
                            var (D232, _) = deleteUnsignedEntry(retries, 64, queryId);
                            return (D230, D231, D232);
                        }
                        val dataSlice8 = secondLeg.beginParse();
                        val programsState233 = setUnsignedSlice(
                            programs,
                            64,
                            nextQueryId,
                            dataSlice8,
                        );
                        var (instructionTail222, _) = loadCoinsField(D6.beginParse());
                        val result22 = prepareTradeMessage(
                            protocolKind18,
                            sourceAssetKind19,
                            targetAssetKind20,
                            nextQueryId,
                            callbackTail214,
                            instructionTail222,
                            tradeAmount14,
                        );
                        val result23 = isVmNull((result22 as unknown));

                        if (result23 != 0) {
                            (retriesState4, programsState5, amountsState3) = releaseRejectedTrade(
                                tradeAmount14,
                                programsState233,
                                queryId,
                                retries,
                                nextQueryId,
                                amounts,
                                result22,
                            );
                        } else {
                            val result24 = sendOrQueueTrade(retries, queryId, result22);
                            amountsState3 = setUnsignedBuilder(
                                amounts,
                                64,
                                nextQueryId,
                                storeCoinsField(beginCell(), tradeAmount14),
                            );
                            retriesState4 = result24;

                            programsState5 = programsState233;
                        }
                    }
                } else {
                    amountsState3 = amounts;
                    programsState5 = programs;
                    retriesState4 = retries;
                }
            } else {
                amountsState3 = amounts;
                programsState5 = programs;
                retriesState4 = retries;
            }
        }
    }
    return (programsState5, amountsState3, retriesState4);
}

// Dispatch kind 2; wire predicates and gas boundaries are preserved.
@method_id(21)
fun processProtocol2(
    messageValue: int,
    opcode: int,
    queryId: int,
    recipe: slice,
    programs: cell,
    amounts: cell,
    retries: cell,
    body: slice,
): (cell, cell, cell) {
    var (cursor2, firstLegMode) = loadUint4(recipe);
    var (cursor22, secondLegMode) = loadUint4(cursor2);
    var (cursor23, _) = loadMaybeDictionary(cursor22);
    var (cursor24, firstLeg) = loadMaybeDictionary(cursor23);
    val secondLeg = preloadMaybeDictionary(cursor24);
    val result = isVmNull((secondLeg as unknown));
    var selectedValue0: int;
    if (result != 0) {
        val result2 = isVmNull((firstLeg as unknown));
        selectedValue0 = ((result2 != 0) as int);
    } else {
        selectedValue0 = 0;
    }
    if (selectedValue0 != 0) {
        var (D22, _) = deleteUnsignedEntry(programs, 64, queryId);
        var (D23, _) = deleteUnsignedEntry(amounts, 64, queryId);
        var (D24, _) = deleteUnsignedEntry(retries, 64, queryId);
        return (D22, D23, D24);
    }
    var nextQueryId = (queryId + 1);
    var selectedValue2: int;
    if (firstLegMode != 0) {
        selectedValue2 = 0;
    } else {
        val result4 = ((secondLegMode == 1) as int);
        selectedValue2 = ((result4 != 0) as int);
    }
    var retriesState3: cell;
    var programsState4: cell;
    var amountsState5: cell;
    if (selectedValue2 != 0) {
        val result5 = ((opcode == 0x7362d09c) as int);
        var programsState6: cell;
        var retriesState7: cell;
        var amountsState8: cell;
        if (result5 != 0) {
            if (isVmNull((secondLeg as unknown)) != 0) {
                var (D25, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D26, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D27, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D25, D26, D27);
            }
            var (callbackTail25, tradeAmount3) = loadCoinsField(body);
            var dataSlice = secondLeg.beginParse();
            var (cursor26, protocolKind4) = loadUint4(dataSlice);
            var (cursor27, sourceAssetKind5) = loadUint4(cursor26);
            var (cursor28, targetAssetKind6) = loadUint4(cursor27);
            val D3 = preloadMaybeDictionary(cursor28);
            if (isVmNull((D3 as unknown)) != 0) {
                var (D28, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D29, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D210, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D28, D29, D210);
            }
            val dataSlice2 = secondLeg.beginParse();
            val programsState211 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice2);
            var (instructionTail29, _) = loadCoinsField(D3.beginParse());
            val result6 = prepareTradeMessage(
                protocolKind4,
                sourceAssetKind5,
                targetAssetKind6,
                nextQueryId,
                callbackTail25,
                instructionTail29,
                tradeAmount3,
            );
            val result7 = isVmNull((result6 as unknown));

            if (result7 != 0) {
                retriesState7 = retries;
                amountsState8 = amounts;
            } else {
                val result8 = sendOrQueueTrade(retries, queryId, result6);
                val amountsState212 = setUnsignedBuilder(
                    amounts,
                    64,
                    nextQueryId,
                    storeCoinsField(beginCell(), tradeAmount3),
                );
                retriesState7 = result8;
                amountsState8 = amountsState212;
            }
            programsState6 = programsState211;
            (amountsState8, opcode, queryId, retriesState7, programsState6) = activeState(
                amountsState8,
                opcode,
                queryId,
                retriesState7,
                programsState6,
            );
        } else {
            programsState6 = programs;

            retriesState7 = retries;

            amountsState8 = amounts;
        }
        if ((opcode == 32736093)) {
            var (D213, _) = deleteUnsignedEntry(programsState6, 64, queryId);
            var (D214, _) = deleteUnsignedEntry(amountsState8, 64, queryId);
            var (D215, _) = deleteUnsignedEntry(retriesState7, 64, queryId);
            return (D213, D214, D215);
        }
        retriesState3 = retriesState7;
        programsState4 = programsState6;
        amountsState5 = amountsState8;
    } else {
        val result9 = ((firstLegMode == 1) as int);
        var selectedValue9: int;
        if (result9 != 0) {
            val result10 = ((secondLegMode == 0) as int);
            selectedValue9 = ((result10 != 0) as int);
        } else {
            selectedValue9 = 0;
        }

        if (selectedValue9 != 0) {
            if ((opcode == 32736093)) {
                var (D216, _) = deleteUnsignedEntry(programs, 64, queryId);
                var (D217, _) = deleteUnsignedEntry(amounts, 64, queryId);
                var (D218, _) = deleteUnsignedEntry(retries, 64, queryId);
                return (D216, D217, D218);
            }
            val result11 = ((opcode == 0xd53276db) as int);

            if (result11 != 0) {
                if ((messageValue < 100000000)) {
                    return (programs, amounts, retries);
                }
                if (isVmNull((firstLeg as unknown)) != 0) {
                    var (D219, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D220, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D221, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D219, D220, D221);
                }
                var (x7, status) = findUnsignedEntry(amounts, 64, queryId);
                if (!(status != 0)) {
                    return (programs, amounts, retries);
                }
                var (_, tradeAmount8) = loadCoinsField(x7);
                var dataSlice3 = firstLeg.beginParse();
                var (cursor210, protocolKind9) = loadUint4(dataSlice3);
                var (cursor211, sourceAssetKind10) = loadUint4(cursor210);
                var (cursor212, targetAssetKind11) = loadUint4(cursor211);
                val D4 = preloadMaybeDictionary(cursor212);
                if (isVmNull((D4 as unknown)) != 0) {
                    var (D222, _) = deleteUnsignedEntry(programs, 64, queryId);
                    var (D223, _) = deleteUnsignedEntry(amounts, 64, queryId);
                    var (D224, _) = deleteUnsignedEntry(retries, 64, queryId);
                    return (D222, D223, D224);
                }
                val dataSlice4 = firstLeg.beginParse();
                val programsState225 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice4);
                var (instructionTail213, _) = loadCoinsField(D4.beginParse());
                val result12 = prepareTradeMessage(
                    protocolKind9,
                    sourceAssetKind10,
                    targetAssetKind11,
                    nextQueryId,
                    body,
                    instructionTail213,
                    tradeAmount8,
                );
                val result13 = isVmNull((result12 as unknown));

                if (result13 != 0) {
                    (programsState4, amountsState5, retriesState3) = releaseSeven_0_5_4(
                        programsState225,
                        nextQueryId,
                        queryId,
                        tradeAmount8,
                        retries,
                        amounts,
                        result12,
                    );
                } else {
                    val result14 = sendOrQueueTrade(retries, queryId, result12);
                    val amountsState226 = setUnsignedBuilder(
                        amounts,
                        64,
                        nextQueryId,
                        storeCoinsField(beginCell(), tradeAmount8),
                    );
                    retriesState3 = result14;
                    amountsState5 = amountsState226;
                    programsState4 = programsState225;
                }
                (retriesState3, programsState4, amountsState5) = pendingState(
                    retriesState3,
                    programsState4,
                    amountsState5,
                );
            } else {
                (retriesState3, programsState4, amountsState5) = keepEight_6_4_5(
                    messageValue,
                    nextQueryId,
                    queryId,
                    body,
                    programs,
                    amounts,
                    retries,
                    firstLeg,
                );
            }
        } else {
            val result15 = ((firstLegMode == 1) as int);
            var selectedValue10: int;
            if (result15 != 0) {
                val result16 = ((secondLegMode == 1) as int);
                selectedValue10 = ((result16 != 0) as int);
            } else {
                selectedValue10 = 0;
            }

            if (selectedValue10 != 0) {
                val result17 = ((opcode == 0x7362d09c) as int);
                var retriesState11: cell;
                var amountsState12: cell;
                var programsState13: cell;
                var selectedValue14: slice;
                if (result17 != 0) {
                    if (isVmNull((secondLeg as unknown)) != 0) {
                        var (D227, _) = deleteUnsignedEntry(programs, 64, queryId);
                        var (D228, _) = deleteUnsignedEntry(amounts, 64, queryId);
                        var (D229, _) = deleteUnsignedEntry(retries, 64, queryId);
                        return (D227, D228, D229);
                    }
                    var (callbackTail214, tradeAmount12) = loadCoinsField(body);
                    var dataSlice5 = secondLeg.beginParse();
                    var (cursor215, protocolKind13) = loadUint4(dataSlice5);
                    var (cursor216, sourceAssetKind14) = loadUint4(cursor215);
                    var (cursor217, targetAssetKind15) = loadUint4(cursor216);
                    val D5 = preloadMaybeDictionary(cursor217);
                    if (isVmNull((D5 as unknown)) != 0) {
                        var (D230, _) = deleteUnsignedEntry(programs, 64, queryId);
                        var (D231, _) = deleteUnsignedEntry(amounts, 64, queryId);
                        var (D232, _) = deleteUnsignedEntry(retries, 64, queryId);
                        return (D230, D231, D232);
                    }
                    val dataSlice6 = secondLeg.beginParse();
                    val programsState233 = setUnsignedSlice(programs, 64, nextQueryId, dataSlice6);
                    var (instructionTail218, _) = loadCoinsField(D5.beginParse());
                    val result18 = prepareTradeMessage(
                        protocolKind13,
                        sourceAssetKind14,
                        targetAssetKind15,
                        nextQueryId,
                        callbackTail214,
                        instructionTail218,
                        tradeAmount12,
                    );
                    val result19 = isVmNull((result18 as unknown));

                    if (result19 != 0) {
                        retriesState11 = retries;
                        amountsState12 = amounts;
                    } else {
                        val result20 = sendOrQueueTrade(retries, queryId, result18);
                        val amountsState234 = setUnsignedBuilder(
                            amounts,
                            64,
                            nextQueryId,
                            storeCoinsField(beginCell(), tradeAmount12),
                        );
                        retriesState11 = result20;
                        amountsState12 = amountsState234;
                    }
                    programsState13 = programsState233;
                    selectedValue14 = callbackTail214;
                    (
                        messageValue,
                        opcode,
                        queryId,
                        selectedValue14,
                        programsState13,
                        amountsState12,
                        retriesState11,
                        nextQueryId,
                        firstLeg,
                    ) = twoStageState(
                        messageValue,
                        opcode,
                        queryId,
                        selectedValue14,
                        programsState13,
                        amountsState12,
                        retriesState11,
                        nextQueryId,
                        firstLeg,
                    );
                } else {
                    retriesState11 = retries;

                    amountsState12 = amounts;

                    programsState13 = programs;

                    selectedValue14 = body;
                }
                val result21 = ((opcode == 0xd53276db) as int);

                if (result21 != 0) {
                    if ((messageValue < 170000000)) {
                        return (programsState13, amountsState12, retriesState11);
                    }
                    if (isVmNull((firstLeg as unknown)) != 0) {
                        var (D235, _) = deleteUnsignedEntry(programsState13, 64, queryId);
                        var (D236, _) = deleteUnsignedEntry(amountsState12, 64, queryId);
                        var (D237, _) = deleteUnsignedEntry(retriesState11, 64, queryId);
                        return (D235, D236, D237);
                    }
                    var (x16, status2) = findUnsignedEntry(amountsState12, 64, queryId);
                    if (!(status2 != 0)) {
                        return (programsState13, amountsState12, retriesState11);
                    }
                    var (_, tradeAmount17) = loadCoinsField(x16);
                    var dataSlice7 = firstLeg.beginParse();
                    var (cursor219, protocolKind18) = loadUint4(dataSlice7);
                    var (cursor220, sourceAssetKind19) = loadUint4(cursor219);
                    var (cursor221, targetAssetKind20) = loadUint4(cursor220);
                    val D6 = preloadMaybeDictionary(cursor221);
                    if (isVmNull((D6 as unknown)) != 0) {
                        var (D238, _) = deleteUnsignedEntry(programsState13, 64, queryId);
                        var (D239, _) = deleteUnsignedEntry(amountsState12, 64, queryId);
                        var (D240, _) = deleteUnsignedEntry(retriesState11, 64, queryId);
                        return (D238, D239, D240);
                    }
                    val dataSlice8 = firstLeg.beginParse();
                    val D241 = setUnsignedSlice(programsState13, 64, nextQueryId, dataSlice8);
                    var (instructionTail222, _) = loadCoinsField(D6.beginParse());
                    val result22 = prepareTradeMessage(
                        protocolKind18,
                        sourceAssetKind19,
                        targetAssetKind20,
                        nextQueryId,
                        selectedValue14,
                        instructionTail222,
                        tradeAmount17,
                    );
                    val result23 = isVmNull((result22 as unknown));

                    if (result23 != 0) {
                        (amountsState5, programsState4, retriesState3) = releaseSeven_5_1_4(
                            nextQueryId,
                            D241,
                            queryId,
                            tradeAmount17,
                            retriesState11,
                            amountsState12,
                            result22,
                        );
                    } else {
                        val result24 = sendOrQueueTrade(retriesState11, queryId, result22);
                        val D242 = setUnsignedBuilder(
                            amountsState12,
                            64,
                            nextQueryId,
                            storeCoinsField(beginCell(), tradeAmount17),
                        );
                        retriesState3 = result24;
                        amountsState5 = D242;

                        programsState4 = D241;
                    }
                    (retriesState3, programsState4, amountsState5) = pendingState(
                        retriesState3,
                        programsState4,
                        amountsState5,
                    );
                } else {
                    (retriesState3, programsState4, amountsState5) = keepEight_6_4_5(
                        messageValue,
                        firstLeg,
                        queryId,
                        selectedValue14,
                        programsState13,
                        amountsState12,
                        retriesState11,
                        nextQueryId,
                    );
                }
            } else {
                (retriesState3, programsState4, amountsState5) = keepTen_6_4_5(
                    messageValue,
                    opcode,
                    queryId,
                    body,
                    programs,
                    amounts,
                    retries,
                    nextQueryId,
                    secondLeg,
                    firstLeg,
                );
            }
        }
    }
    return (programsState4, amountsState5, retriesState3);
}
