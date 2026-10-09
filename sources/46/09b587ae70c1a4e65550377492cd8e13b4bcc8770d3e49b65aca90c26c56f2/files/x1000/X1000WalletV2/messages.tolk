// decompiled by @fiscaldev
import "compat"

@inline_ref
fun invokeAmountHook(
    hookCode: cell,
    logicalTime: unknown,
    timestamp: unknown,
    tonAmount: unknown,
    destination: unknown,
    messageBody: unknown,
    hookArgument: unknown,
): unknown {
    val savedContinuation = getExecutionContinuation();
    val hookContinuation = blessCode(hookCode.beginParse());
    setExecutionContinuation(hookContinuation);
    val hookResult = callAmountHookAbi(
        logicalTime,
        timestamp,
        tonAmount,
        destination,
        messageBody,
        hookArgument,
        83527,
        hookContinuation,
    );
    setExecutionContinuation(savedContinuation);
    return hookResult;
}

@method_id(2)
fun jettonTransferBody(
    queryId: int,
    amount: int,
    destination: slice,
    responseAddress: int,
    customPayload: cell,
    forwardTon: int,
    forwardPayload: cell,
): cell {
    var b = begin_0F8A7EA5();
    var b2 = storeCoinsField(b.storeUint(queryId, 64), amount).storeAddress(
        (destination as address),
    );
    val result = isVmNull((responseAddress as unknown));
    var builder = beginCell();
    if (result != 0) {
        builder = store_2_(b2);
    } else {
        builder = storeStandardAddress(b2, (responseAddress as unknown as slice));
    }
    return storeNullableReference(
        storeCoinsField(storeNullableReference(builder, customPayload), forwardTon),
        forwardPayload,
    ).endCell();
}

@method_id(7)
fun prepareTradeMessage(
    protocolKind: int,
    sourceAssetKind: int,
    targetAssetKind: int,
    queryId: int,
    callbackBody: slice,
    instruction: slice,
    amount: int,
): cell {
    val constValue = (null as unknown as cell);
    val result = ((protocolKind == 1) as int);
    var selectedValue0: cell;
    if (result != 0) {
        val result2 = ((sourceAssetKind == 1) as int);
        var selectedValue2: int;
        if (result2 != 0) {
            val result3 = ((targetAssetKind == 0) as int);
            selectedValue2 = ((result3 != 0) as int);
        } else {
            selectedValue2 = 0;
        }
        var selectedValue3 = constValue;
        if (selectedValue2 != 0) {
            var (cursor2, x) = loadCoinsField(instruction);
            var tail = cursor2;
            val refCell = tail.loadRef();
            var dataSlice = refCell.beginParse();
            var dataSlice2 = tail.preloadRef().beginParse();
            var tail2 = dataSlice;
            val address = (tail2.loadAddress() as slice);
            val address2 = (tail2.loadAddress() as slice);
            var tail3 = dataSlice2;
            val address3 = (tail3.loadAddress() as slice);
            val address4 = (tail3.loadAddress() as slice);
            var b = begin_00000000().store_2_().store_2_();
            var b2 = storeNullableReference(b, (null as unknown as cell));
            val c = storeNullableReference(b2, (null as unknown as cell)).endCell();
            var b22 = storeCoinsField(
                begin_E3A0D482().storeAddress((address4 as address)).store_4_(),
                x,
            );
            val c2 = storeNullableReference(b22, (null as unknown as cell)).storeRef(c).endCell();
            val constValue2 = (null as unknown as cell);
            val result4 = jettonTransferBody(
                queryId,
                amount,
                address3,
                (address as unknown as int),
                constValue2,
                200000000,
                c2,
            );
            var b23 = begin_62_().storeAddress((address2 as address));
            var b24 = storeCoinsField(b23, 250000000);
            selectedValue3 = storeNullableReference(b24.storeUint(0, 106), result4).endCell();
        }
        val result5 = ((sourceAssetKind == 1) as int);
        var selectedValue4: int;
        if (result5 != 0) {
            val result6 = ((targetAssetKind == 1) as int);
            selectedValue4 = ((result6 != 0) as int);
        } else {
            selectedValue4 = 0;
        }
        if (selectedValue4 != 0) {
            var (cursor22, x2) = loadCoinsField(instruction);
            var tail4 = cursor22;
            val refCell2 = tail4.loadRef();
            var dataSlice3 = refCell2.beginParse();
            var dataSlice4 = tail4.preloadRef().beginParse();
            var tail5 = dataSlice3;
            tail5.loadAddress();
            val address5 = (tail5.loadAddress() as slice);
            var tail6 = dataSlice4;
            val address6 = (tail6.loadAddress() as slice);
            val address7 = (tail6.loadAddress() as slice);
            var b3 = begin_00000000().store_2_().store_2_();
            var b25 = storeNullableReference(b3, (null as unknown as cell));
            val c3 = storeNullableReference(b25, (null as unknown as cell)).endCell();
            var b26 = storeCoinsField(
                begin_E3A0D482().storeAddress((address7 as address)).store_4_(),
                x2,
            );
            val c4 = storeNullableReference(b26, (null as unknown as cell)).storeRef(c3).endCell();
            val constValue3 = (null as unknown as int);
            val constValue4 = (null as unknown as cell);
            val result7 = jettonTransferBody(
                queryId,
                amount,
                address6,
                constValue3,
                constValue4,
                200000000,
                c4,
            );
            var b27 = begin_62_().storeAddress((address5 as address));
            var b28 = storeCoinsField(b27, 250000000);
            selectedValue0 = storeNullableReference(b28.storeUint(0, 106), result7).endCell();
        } else {
            selectedValue0 = selectedValue3;
        }
    } else {
        if ((protocolKind == 2)) {
            val result8 = ((sourceAssetKind == 1) as int);
            var selectedValue5: int;
            if (result8 != 0) {
                val result9 = ((targetAssetKind == 0) as int);
                selectedValue5 = ((result9 != 0) as int);
            } else {
                selectedValue5 = 0;
            }
            var selectedValue6 = constValue;
            if (selectedValue5 != 0) {
                var (cursor23, x3) = loadCoinsField(instruction);
                var tail7 = cursor23;
                val refCell3 = tail7.loadRef();
                var dataSlice5 = refCell3.beginParse();
                var dataSlice6 = tail7.preloadRef().beginParse();
                var tail8 = dataSlice5;
                val address8 = (tail8.loadAddress() as slice);
                val address9 = (tail8.loadAddress() as slice);
                var tail9 = dataSlice6;
                val address10 = (tail9.loadAddress() as slice);
                val address11 = (tail9.loadAddress() as slice);
                var b29 = storeCoinsField(beginCell(), x3).storeAddress((address8 as address));
                var b210 = storeCoinsField(b29, 70000000);
                var b4 = storeNullableReference(b210, (null as unknown as cell)).store_0();
                val c5 = storeNullableReference(b4, (null as unknown as cell))
                    .store_0000()
                    .store_2_()
                    .endCell();
                var b211 = begin_6664DE2A()
                    .storeAddress((address11 as address))
                    .storeAddress((address8 as address))
                    .storeAddress((address8 as address));
                val inmsg_3 = currentUnixTime();
                val result10 = (inmsg_3 + 300);
                val c6 = b211.storeUint(result10, 64).storeRef(c5).endCell();
                val constValue5 = (null as unknown as cell);
                val result11 = jettonTransferBody(
                    queryId,
                    amount,
                    address10,
                    (address8 as unknown as int),
                    constValue5,
                    0x1ad27480,
                    c6,
                );
                var b212 = begin_62_().storeAddress((address9 as address));
                var b213 = storeCoinsField(b212, 0x26be3680);
                selectedValue6 = storeNullableReference(b213.storeUint(0, 106), result11).endCell();
            }
            val result12 = ((sourceAssetKind == 1) as int);
            var selectedValue7: int;
            if (result12 != 0) {
                val result13 = ((targetAssetKind == 1) as int);
                selectedValue7 = ((result13 != 0) as int);
            } else {
                selectedValue7 = 0;
            }
            if (selectedValue7 != 0) {
                var (cursor24, x4) = loadCoinsField(instruction);
                var tail10 = cursor24;
                val refCell4 = tail10.loadRef();
                var dataSlice7 = refCell4.beginParse();
                var dataSlice8 = tail10.preloadRef().beginParse();
                var tail11 = dataSlice7;
                val address12 = (tail11.loadAddress() as slice);
                val address13 = (tail11.loadAddress() as slice);
                var tail12 = dataSlice8;
                val address14 = (tail12.loadAddress() as slice);
                val address15 = (tail12.loadAddress() as slice);
                var b214 = storeCoinsField(beginCell(), x4).storeAddress((address12 as address));
                var b215 = storeCoinsField(b214, 70000000);
                var b5 = storeNullableReference(b215, (null as unknown as cell)).store_0();
                val c7 = storeNullableReference(b5, (null as unknown as cell))
                    .store_0000()
                    .store_2_()
                    .endCell();
                var b216 = begin_6664DE2A()
                    .storeAddress((address15 as address))
                    .storeAddress((address12 as address))
                    .storeAddress((address12 as address));
                val inmsg_32 = currentUnixTime();
                val result14 = (inmsg_32 + 300);
                val c8 = b216.storeUint(result14, 64).storeRef(c7).endCell();
                val constValue6 = (null as unknown as cell);
                val result15 = jettonTransferBody(
                    queryId,
                    amount,
                    address14,
                    (address12 as unknown as int),
                    constValue6,
                    0x1ad27480,
                    c8,
                );
                var b217 = begin_62_().storeAddress((address13 as address));
                var b218 = storeCoinsField(b217, 0x26be3680);
                selectedValue0 = storeNullableReference(b218.storeUint(0, 106), result15).endCell();
            } else {
                selectedValue0 = selectedValue6;
            }
        } else {
            if (protocolKind != 0) {
                if ((protocolKind == 3)) {
                    val result16 = ((sourceAssetKind == 1) as int);
                    var selectedValue8: int;
                    if (result16 != 0) {
                        val result17 = ((targetAssetKind == 0) as int);
                        selectedValue8 = ((result17 != 0) as int);
                    } else {
                        selectedValue8 = 0;
                    }
                    var selectedValue9 = constValue;
                    if (selectedValue8 != 0) {
                        var (cursor25, x5) = loadCoinsField(instruction);
                        var tail13 = cursor25.preloadRef().beginParse();
                        val address16 = (tail13.loadAddress() as slice);
                        val address17 = (tail13.loadAddress() as slice);
                        var b6 = begin_A7FB58F8();
                        var b219 = b6.storeAddress(
                            ("8010E3B5242B6292042CDE1D4542DB6AC4F1AA502106EFF02B18BE999FBFBA45C2F_".hexToSlice() as address),
                        );
                        val c9 = storeCoinsField(b219.storeUint(0, 160), x5)
                            .storeAddress((address16 as address))
                            .store_4_()
                            .endCell();
                        val constslice = "8017FF5BA4E14E70A63B4F627751F880704D84B0C2E7F3DBD3862DF56A778B3590D_".hexToSlice();
                        val constValue7 = (null as unknown as cell);
                        val result18 = jettonTransferBody(
                            queryId,
                            amount,
                            constslice,
                            (address16 as unknown as int),
                            constValue7,
                            0x1dcd6500,
                            c9,
                        );
                        var b220 = begin_62_().storeAddress((address17 as address));
                        var b221 = storeCoinsField(b220, 0x23c34600);
                        selectedValue9 = storeNullableReference(
                            b221.storeUint(0, 106),
                            result18,
                        ).endCell();
                    }
                    val result19 = ((sourceAssetKind == 1) as int);
                    var selectedValue10: int;
                    if (result19 != 0) {
                        val result20 = ((targetAssetKind == 1) as int);
                        selectedValue10 = ((result20 != 0) as int);
                    } else {
                        selectedValue10 = 0;
                    }
                    if (selectedValue10 != 0) {
                        var (cursor26, x6) = loadCoinsField(instruction);
                        var tail14 = cursor26;
                        val refCell5 = tail14.loadRef();
                        var dataSlice9 = refCell5.beginParse();
                        var dataSlice10 = tail14.preloadRef().beginParse();
                        var tail15 = dataSlice9;
                        val address18 = (tail15.loadAddress() as slice);
                        val address19 = (tail15.loadAddress() as slice);
                        val address20 = (dataSlice10.loadAddress() as slice);
                        var b222 = begin_A7FB58F8().storeAddress((address20 as address));
                        val c10 = storeCoinsField(b222.storeUint(0, 160), x6)
                            .storeAddress((address18 as address))
                            .store_4_()
                            .endCell();
                        val constslice2 = "8017FF5BA4E14E70A63B4F627751F880704D84B0C2E7F3DBD3862DF56A778B3590D_".hexToSlice();
                        val constValue8 = (null as unknown as cell);
                        val result21 = jettonTransferBody(
                            queryId,
                            amount,
                            constslice2,
                            (address18 as unknown as int),
                            constValue8,
                            0x1dcd6500,
                            c10,
                        );
                        var b223 = begin_62_().storeAddress((address19 as address));
                        var b224 = storeCoinsField(b223, 0x23c34600);
                        selectedValue0 = storeNullableReference(
                            b224.storeUint(0, 106),
                            result21,
                        ).endCell();
                    } else {
                        selectedValue0 = selectedValue9;
                    }
                } else {
                    if ((protocolKind == 4)) {
                        val result22 = ((sourceAssetKind == 1) as int);
                        var selectedValue11: int;
                        if (result22 != 0) {
                            val result23 = ((targetAssetKind == 0) as int);
                            selectedValue11 = ((result23 != 0) as int);
                        } else {
                            selectedValue11 = 0;
                        }
                        var selectedValue12 = constValue;
                        if (selectedValue11 != 0) {
                            var (cursor27, x7) = loadCoinsField(instruction);
                            var tail16 = cursor27;
                            val refCell6 = tail16.loadRef();
                            var dataSlice11 = refCell6.beginParse();
                            var dataSlice12 = tail16.preloadRef().beginParse();
                            var tail17 = dataSlice11;
                            val address21 = (tail17.loadAddress() as slice);
                            val address22 = (tail17.loadAddress() as slice);
                            val address23 = (dataSlice12.loadAddress() as slice);
                            var b225 = beginCell()
                                .storeAddress((address21 as address))
                                .store_06_()
                                .storeAddress((address21 as address));
                            val c11 = storeCoinsField(b225, 200000000)
                                .store_2_()
                                .storeAddress((address21 as address))
                                .endCell();
                            var b226 = storeCoinsField(begin_C442500F(), x7);
                            val inmsg_33 = currentUnixTime();
                            val result24 = (inmsg_33 + 300);
                            val c12 = b226.storeUint(result24, 40).store_1_().endCell();
                            val c13 = begin_CBC33949().storeRef(c12).storeRef(c11).endCell();
                            val constValue9 = (null as unknown as cell);
                            val result25 = jettonTransferBody(
                                queryId,
                                amount,
                                address23,
                                (address21 as unknown as int),
                                constValue9,
                                0x17d78400,
                                c13,
                            );
                            var b227 = begin_62_().storeAddress((address22 as address));
                            var b228 = storeCoinsField(b227, 0x1ad27480);
                            selectedValue12 = storeNullableReference(
                                b228.storeUint(0, 106),
                                result25,
                            ).endCell();
                        }
                        val result26 = ((sourceAssetKind == 1) as int);
                        var selectedValue13: int;
                        if (result26 != 0) {
                            val result27 = ((targetAssetKind == 1) as int);
                            selectedValue13 = ((result27 != 0) as int);
                        } else {
                            selectedValue13 = 0;
                        }
                        if (selectedValue13 != 0) {
                            var (cursor28, x8) = loadCoinsField(instruction);
                            var tail18 = cursor28;
                            val refCell7 = tail18.loadRef();
                            var dataSlice13 = refCell7.beginParse();
                            var dataSlice14 = tail18.preloadRef().beginParse();
                            var tail19 = dataSlice13;
                            val address24 = (tail19.loadAddress() as slice);
                            val address25 = (tail19.loadAddress() as slice);
                            val address26 = (dataSlice14.loadAddress() as slice);
                            var b229 = beginCell().storeAddress((address24 as address));
                            var b230 = storeCoinsField(b229, 0x11e1a300)
                                .store_6_()
                                .storeAddress((address24 as address));
                            val c14 = storeCoinsField(b230, 200000000)
                                .store_2_()
                                .storeAddress((address24 as address))
                                .endCell();
                            var b231 = storeCoinsField(begin_C442500F(), x8);
                            val inmsg_34 = currentUnixTime();
                            val result28 = (inmsg_34 + 300);
                            val c15 = b231.storeUint(result28, 40).store_1_().endCell();
                            val c16 = begin_CBC33949().storeRef(c15).storeRef(c14).endCell();
                            val constValue10 = (null as unknown as cell);
                            val result29 = jettonTransferBody(
                                queryId,
                                amount,
                                address26,
                                (address24 as unknown as int),
                                constValue10,
                                0x17d78400,
                                c16,
                            );
                            var b232 = begin_62_().storeAddress((address25 as address));
                            var b233 = storeCoinsField(b232, 0x1ad27480);
                            selectedValue0 = storeNullableReference(
                                b233.storeUint(0, 106),
                                result29,
                            ).endCell();
                        } else {
                            selectedValue0 = selectedValue12;
                        }
                    } else {
                        if ((protocolKind == 5)) {
                            val result30 = ((sourceAssetKind == 1) as int);
                            var selectedValue14: int;
                            if (result30 != 0) {
                                val result31 = ((targetAssetKind == 0) as int);
                                selectedValue14 = ((result31 != 0) as int);
                            } else {
                                selectedValue14 = 0;
                            }
                            var selectedValue15 = constValue;
                            if (selectedValue14 != 0) {
                                var (cursor29, x9) = loadCoinsField(instruction);
                                var tail20 = cursor29;
                                val refCell8 = tail20.loadRef();
                                var dataSlice15 = refCell8.beginParse();
                                var dataSlice16 = tail20.preloadRef().beginParse();
                                var tail21 = dataSlice15;
                                val address27 = (tail21.loadAddress() as slice);
                                val address28 = (tail21.loadAddress() as slice);
                                val address29 = (dataSlice16.loadAddress() as slice);
                                var b7 = storeCoinsField(
                                    begin_DD79732C().storeAddress((address27 as address)),
                                    x9,
                                )
                                    .storeAddress((address27 as address))
                                    .store_0();
                                var b234 = storeNullableReference(b7, (null as unknown as cell));
                                var b235 = storeNullableReference(b234, (null as unknown as cell));
                                val c17 = storeNullableReference(
                                    b235,
                                    (null as unknown as cell),
                                ).endCell();
                                val constValue11 = (null as unknown as cell);
                                val result32 = jettonTransferBody(
                                    queryId,
                                    amount,
                                    address29,
                                    (address27 as unknown as int),
                                    constValue11,
                                    0x1dcd6500,
                                    c17,
                                );
                                var b236 = begin_62_().storeAddress((address28 as address));
                                var b237 = storeCoinsField(b236, 0x2160ec00);
                                selectedValue15 = storeNullableReference(
                                    b237.storeUint(0, 106),
                                    result32,
                                ).endCell();
                            }
                            val result33 = ((sourceAssetKind == 1) as int);
                            var selectedValue16: int;
                            if (result33 != 0) {
                                val result34 = ((targetAssetKind == 1) as int);
                                selectedValue16 = ((result34 != 0) as int);
                            } else {
                                selectedValue16 = 0;
                            }
                            if (selectedValue16 != 0) {
                                var (cursor210, x10) = loadCoinsField(instruction);
                                var tail22 = cursor210;
                                val refCell9 = tail22.loadRef();
                                var dataSlice17 = refCell9.beginParse();
                                var dataSlice18 = tail22.preloadRef().beginParse();
                                var tail23 = dataSlice17;
                                val address30 = (tail23.loadAddress() as slice);
                                val address31 = (tail23.loadAddress() as slice);
                                val address32 = (dataSlice18.loadAddress() as slice);
                                val c18 = begin_00000000().endCell();
                                var b8 = storeCoinsField(
                                    begin_DD79732C().storeAddress((address30 as address)),
                                    x10,
                                )
                                    .storeAddress((address30 as address))
                                    .store_0();
                                val c19 = storeNullableReference(
                                    storeNullableReference(
                                        storeNullableReference(b8, (null as unknown as cell)),
                                        c18,
                                    ),
                                    c18,
                                ).endCell();
                                val constValue12 = (null as unknown as cell);
                                val result35 = jettonTransferBody(
                                    queryId,
                                    amount,
                                    address32,
                                    (address30 as unknown as int),
                                    constValue12,
                                    0x1dcd6500,
                                    c19,
                                );
                                var b238 = begin_62_().storeAddress((address31 as address));
                                var b239 = storeCoinsField(b238, 0x2160ec00);
                                selectedValue0 = storeNullableReference(
                                    b239.storeUint(0, 106),
                                    result35,
                                ).endCell();
                            } else {
                                selectedValue0 = selectedValue15;
                            }
                        } else {
                            if ((protocolKind == 10)) {
                                val result36 = ((sourceAssetKind == 1) as int);
                                var selectedValue17: int;
                                if (result36 != 0) {
                                    val result37 = ((targetAssetKind == 0) as int);
                                    selectedValue17 = ((result37 != 0) as int);
                                } else {
                                    selectedValue17 = 0;
                                }
                                var selectedValue18 = constValue;
                                if (selectedValue17 != 0) {
                                    var (cursor211, x11) = loadCoinsField(instruction);
                                    var tail24 = cursor211;
                                    val refCell10 = tail24.loadRef();
                                    var dataSlice19 = refCell10.beginParse();
                                    var dataSlice20 = tail24.preloadRef().beginParse();
                                    var tail25 = dataSlice19;
                                    val address33 = (tail25.loadAddress() as slice);
                                    val address34 = (tail25.loadAddress() as slice);
                                    val address35 = (dataSlice20.loadAddress() as slice);
                                    val c20 = beginCell()
                                        .storeAddress((address33 as address))
                                        .store_2_()
                                        .endCell();
                                    val c21 = begin_00000000().endCell();
                                    var b240 = storeNullableReference(
                                        storeNullableReference(
                                            storeCoinsField(
                                                begin_C09DA84E()
                                                    .storeAddress((address33 as address))
                                                    .store_4_(),
                                                x11,
                                            ).store_0(),
                                            c20,
                                        ),
                                        c21,
                                    );
                                    val c22 = storeNullableReference(
                                        b240,
                                        (null as unknown as cell),
                                    ).endCell();
                                    val constValue13 = (null as unknown as cell);
                                    val result38 = jettonTransferBody(
                                        queryId,
                                        amount,
                                        address35,
                                        (address33 as unknown as int),
                                        constValue13,
                                        0x1dcd6500,
                                        c22,
                                    );
                                    var b241 = begin_62_().storeAddress((address34 as address));
                                    var b242 = storeCoinsField(b241, 0x2160ec00);
                                    selectedValue18 = storeNullableReference(
                                        b242.storeUint(0, 106),
                                        result38,
                                    ).endCell();
                                }
                                val result39 = ((sourceAssetKind == 1) as int);
                                var selectedValue19: int;
                                if (result39 != 0) {
                                    val result40 = ((targetAssetKind == 1) as int);
                                    selectedValue19 = ((result40 != 0) as int);
                                } else {
                                    selectedValue19 = 0;
                                }
                                if (selectedValue19 != 0) {
                                    var (cursor212, x12) = loadCoinsField(instruction);
                                    var tail26 = cursor212;
                                    val refCell11 = tail26.loadRef();
                                    var dataSlice21 = refCell11.beginParse();
                                    var dataSlice22 = tail26.preloadRef().beginParse();
                                    var tail27 = dataSlice21;
                                    val address36 = (tail27.loadAddress() as slice);
                                    val address37 = (tail27.loadAddress() as slice);
                                    val address38 = (dataSlice22.loadAddress() as slice);
                                    val c23 = beginCell()
                                        .storeAddress((address36 as address))
                                        .store_2_()
                                        .endCell();
                                    val c24 = begin_00000000().endCell();
                                    val c25 = storeNullableReference(
                                        storeNullableReference(
                                            storeNullableReference(
                                                storeCoinsField(
                                                    begin_C09DA84E()
                                                        .storeAddress((address36 as address))
                                                        .store_4_(),
                                                    x12,
                                                ).store_0(),
                                                c23,
                                            ),
                                            c24,
                                        ),
                                        c24,
                                    ).endCell();
                                    val constValue14 = (null as unknown as cell);
                                    val result41 = jettonTransferBody(
                                        queryId,
                                        amount,
                                        address38,
                                        (address36 as unknown as int),
                                        constValue14,
                                        0x1dcd6500,
                                        c25,
                                    );
                                    var b243 = begin_62_().storeAddress((address37 as address));
                                    var b244 = storeCoinsField(b243, 0x2160ec00);
                                    selectedValue0 = storeNullableReference(
                                        b244.storeUint(0, 106),
                                        result41,
                                    ).endCell();
                                } else {
                                    selectedValue0 = selectedValue18;
                                }
                            } else {
                                if ((protocolKind == 6)) {
                                    val result42 = ((sourceAssetKind == 1) as int);
                                    var selectedValue20: int;
                                    if (result42 != 0) {
                                        val result43 = ((targetAssetKind == 0) as int);
                                        selectedValue20 = ((result43 != 0) as int);
                                    } else {
                                        selectedValue20 = 0;
                                    }
                                    var selectedValue21 = constValue;
                                    if (selectedValue20 != 0) {
                                        var (cursor213, x13) = loadCoinsField(instruction);
                                        var tail28 = cursor213;
                                        val refCell12 = tail28.loadRef();
                                        var dataSlice23 = refCell12.beginParse();
                                        var dataSlice24 = tail28.preloadRef().beginParse();
                                        var tail29 = dataSlice23;
                                        val address39 = (tail29.loadAddress() as slice);
                                        val address40 = (tail29.loadAddress() as slice);
                                        var tail30 = dataSlice24;
                                        val address41 = (tail30.loadAddress() as slice);
                                        val x14 = tail30.preloadUint(256);
                                        val inmsg_35 = currentUnixTime();
                                        val result44 = (inmsg_35 + 60);
                                        var builder = beginCell();
                                        var b9 = builder
                                            .storeUint(result44, 32)
                                            .storeAddress((address39 as address))
                                            .store_2_();
                                        val c26 = storeNullableReference(
                                            b9,
                                            (null as unknown as cell),
                                        ).endCell();
                                        var b10 = begin_C0FFEE10();
                                        var b245 = storeCoinsField(b10.storeUint(x14, 256), x13);
                                        val c27 = storeNullableReference(
                                            storeNullableReference(b245, (null as unknown as cell)),
                                            c26,
                                        ).endCell();
                                        val constValue15 = (null as unknown as cell);
                                        val result45 = jettonTransferBody(
                                            queryId,
                                            amount,
                                            address41,
                                            (address39 as unknown as int),
                                            constValue15,
                                            0x14dc9380,
                                            c27,
                                        );
                                        var b246 = begin_62_().storeAddress((address40 as address));
                                        var b247 = storeCoinsField(b246, 0x17d78400);
                                        selectedValue21 = storeNullableReference(
                                            b247.storeUint(0, 106),
                                            result45,
                                        ).endCell();
                                    }
                                    val result46 = ((sourceAssetKind == 1) as int);
                                    var selectedValue22: int;
                                    if (result46 != 0) {
                                        val result47 = ((targetAssetKind == 1) as int);
                                        selectedValue22 = ((result47 != 0) as int);
                                    } else {
                                        selectedValue22 = 0;
                                    }
                                    if (selectedValue22 != 0) {
                                        var (cursor214, x15) = loadCoinsField(instruction);
                                        var tail31 = cursor214;
                                        val refCell13 = tail31.loadRef();
                                        var dataSlice25 = refCell13.beginParse();
                                        var dataSlice26 = tail31.preloadRef().beginParse();
                                        var tail32 = dataSlice25;
                                        val address42 = (tail32.loadAddress() as slice);
                                        val address43 = (tail32.loadAddress() as slice);
                                        var tail33 = dataSlice26;
                                        val address44 = (tail33.loadAddress() as slice);
                                        val x16 = tail33.preloadUint(256);
                                        var b248 = beginCell().storeAddress((address42 as address));
                                        var b249 = storeCoinsField(b248, 100000000);
                                        val c28 = b249
                                            .storeRef(begin_00003039().endCell())
                                            .endCell();
                                        val c29 = storeNullableReference(
                                            storeNullableReference(beginCell(), c28),
                                            c28,
                                        ).endCell();
                                        val inmsg_36 = currentUnixTime();
                                        val result48 = (inmsg_36 + 60);
                                        var builder2 = beginCell();
                                        val c30 = storeNullableReference(
                                            builder2
                                                .storeUint(result48, 32)
                                                .storeAddress((address42 as address))
                                                .store_2_(),
                                            c29,
                                        ).endCell();
                                        var b11 = begin_C0FFEE10();
                                        var b250 = storeCoinsField(b11.storeUint(x16, 256), x15);
                                        val c31 = storeNullableReference(
                                            storeNullableReference(b250, (null as unknown as cell)),
                                            c30,
                                        ).endCell();
                                        val constValue16 = (null as unknown as cell);
                                        val result49 = jettonTransferBody(
                                            queryId,
                                            amount,
                                            address44,
                                            (address42 as unknown as int),
                                            constValue16,
                                            0x14dc9380,
                                            c31,
                                        );
                                        var b251 = begin_62_().storeAddress((address43 as address));
                                        var b252 = storeCoinsField(b251, 0x17d78400);
                                        selectedValue0 = storeNullableReference(
                                            b252.storeUint(0, 106),
                                            result49,
                                        ).endCell();
                                    } else {
                                        selectedValue0 = selectedValue21;
                                    }
                                } else {
                                    if ((protocolKind == 7)) {
                                        val result50 = ((sourceAssetKind == 1) as int);
                                        var selectedValue23: int;
                                        if (result50 != 0) {
                                            val result51 = ((targetAssetKind == 0) as int);
                                            selectedValue23 = ((result51 != 0) as int);
                                        } else {
                                            selectedValue23 = 0;
                                        }
                                        if (selectedValue23 != 0) {
                                            var (cursor215, x17) = loadCoinsField(instruction);
                                            var tail34 = cursor215;
                                            val refCell14 = tail34.loadRef();
                                            var dataSlice27 = refCell14.beginParse();
                                            var dataSlice28 = tail34.preloadRef().beginParse();
                                            var tail35 = dataSlice27;
                                            val address45 = (tail35.loadAddress() as slice);
                                            val address46 = (tail35.loadAddress() as slice);
                                            val address47 = (dataSlice28.loadAddress() as slice);
                                            var b12 = begin_CB7F38D6();
                                            val c32 = b12.storeUint(queryId, 64).endCell();
                                            var b13 = begin_C47C1F57();
                                            val c33 = b13.storeUint(queryId, 64).endCell();
                                            val c34 = storeNullableReference(
                                                beginCell().storeAddress((address45 as address)),
                                                c32,
                                            ).endCell();
                                            val c35 = storeNullableReference(
                                                beginCell().storeAddress((address45 as address)),
                                                c33,
                                            ).endCell();
                                            var b253 = storeCoinsField(begin_B37A900B(), x17);
                                            val inmsg_37 = currentUnixTime();
                                            val result52 = (inmsg_37 + 300);
                                            val c36 = storeNullableReference(
                                                storeNullableReference(
                                                    b253
                                                        .storeUint(result52, 64)
                                                        .storeAddress((address45 as address))
                                                        .store_2_(),
                                                    c34,
                                                ),
                                                c35,
                                            ).endCell();
                                            val constValue17 = (null as unknown as cell);
                                            val result53 = jettonTransferBody(
                                                queryId,
                                                amount,
                                                address47,
                                                (address45 as unknown as int),
                                                constValue17,
                                                150000000,
                                                c36,
                                            );
                                            var b254 = begin_62_().storeAddress(
                                                (address46 as address),
                                            );
                                            var b255 = storeCoinsField(b254, 0x17d78400);
                                            selectedValue0 = storeNullableReference(
                                                b255.storeUint(0, 106),
                                                result53,
                                            ).endCell();
                                        } else {
                                            selectedValue0 = constValue;
                                        }
                                    } else {
                                        if ((protocolKind == 8)) {
                                            val result54 = ((sourceAssetKind == 1) as int);
                                            var selectedValue24: int;
                                            if (result54 != 0) {
                                                val result55 = ((targetAssetKind == 0) as int);
                                                selectedValue24 = ((result55 != 0) as int);
                                            } else {
                                                selectedValue24 = 0;
                                            }
                                            var selectedValue25 = constValue;
                                            if (selectedValue24 != 0) {
                                                var (cursor216, x18) = loadCoinsField(instruction);
                                                var tail36 = cursor216;
                                                val refCell15 = tail36.loadRef();
                                                var dataSlice29 = refCell15.beginParse();
                                                var dataSlice30 = tail36.preloadRef().beginParse();
                                                var tail37 = dataSlice29;
                                                val address48 = (tail37.loadAddress() as slice);
                                                val address49 = (tail37.loadAddress() as slice);
                                                val address50 = (dataSlice30.loadAddress() as slice);
                                                val c37 = beginCell()
                                                    .storeAddress((address48 as address))
                                                    .endCell();
                                                val c38 = storeNullableReference(
                                                    storeNullableReference(
                                                        storeCoinsField(
                                                            begin_FA45056B().storeAddress(
                                                                (address48 as address),
                                                            ),
                                                            x18,
                                                        ),
                                                        c37,
                                                    ),
                                                    c37,
                                                ).endCell();
                                                val constValue18 = (null as unknown as cell);
                                                val result56 = jettonTransferBody(
                                                    queryId,
                                                    amount,
                                                    address50,
                                                    (address48 as unknown as int),
                                                    constValue18,
                                                    150000000,
                                                    c38,
                                                );
                                                var b256 = begin_62_().storeAddress(
                                                    (address49 as address),
                                                );
                                                var b257 = storeCoinsField(b256, 200000000);
                                                selectedValue25 = storeNullableReference(
                                                    b257.storeUint(0, 106),
                                                    result56,
                                                ).endCell();
                                            }
                                            val result57 = ((sourceAssetKind == 1) as int);
                                            var selectedValue26: int;
                                            if (result57 != 0) {
                                                val result58 = ((targetAssetKind == 1) as int);
                                                selectedValue26 = ((result58 != 0) as int);
                                            } else {
                                                selectedValue26 = 0;
                                            }
                                            if (selectedValue26 != 0) {
                                                var (cursor217, x19) = loadCoinsField(instruction);
                                                var tail38 = cursor217;
                                                val refCell16 = tail38.loadRef();
                                                var dataSlice31 = refCell16.beginParse();
                                                var dataSlice32 = tail38.preloadRef().beginParse();
                                                var tail39 = dataSlice31;
                                                val address51 = (tail39.loadAddress() as slice);
                                                val address52 = (tail39.loadAddress() as slice);
                                                val address53 = (dataSlice32.loadAddress() as slice);
                                                val c39 = beginCell()
                                                    .storeAddress((address51 as address))
                                                    .endCell();
                                                val c40 = storeNullableReference(
                                                    storeNullableReference(
                                                        storeCoinsField(
                                                            begin_FA45056B().storeAddress(
                                                                (address51 as address),
                                                            ),
                                                            x19,
                                                        ),
                                                        c39,
                                                    ),
                                                    c39,
                                                ).endCell();
                                                val constValue19 = (null as unknown as cell);
                                                val result59 = jettonTransferBody(
                                                    queryId,
                                                    amount,
                                                    address53,
                                                    (address51 as unknown as int),
                                                    constValue19,
                                                    150000000,
                                                    c40,
                                                );
                                                var b258 = begin_62_().storeAddress(
                                                    (address52 as address),
                                                );
                                                var b259 = storeCoinsField(b258, 200000000);
                                                selectedValue0 = storeNullableReference(
                                                    b259.storeUint(0, 106),
                                                    result59,
                                                ).endCell();
                                            } else {
                                                selectedValue0 = selectedValue25;
                                            }
                                        } else {
                                            if ((protocolKind == 9)) {
                                                val result60 = ((sourceAssetKind == 1) as int);
                                                var selectedValue27: int;
                                                if (result60 != 0) {
                                                    val result61 = ((targetAssetKind == 0) as int);
                                                    selectedValue27 = ((result61 != 0) as int);
                                                } else {
                                                    selectedValue27 = 0;
                                                }
                                                var selectedValue28 = constValue;
                                                if (selectedValue27 != 0) {
                                                    var (cursor218, x20) = loadUint256(instruction);
                                                    var tail40 = cursor218;
                                                    val refCell17 = tail40.loadRef();
                                                    var dataSlice33 = refCell17.beginParse();
                                                    var dataSlice34 = tail40
                                                        .preloadRef()
                                                        .beginParse();
                                                    var tail41 = dataSlice33;
                                                    val address54 = (tail41.loadAddress() as slice);
                                                    val address55 = (tail41.loadAddress() as slice);
                                                    val address56 = (dataSlice34.loadAddress() as slice);
                                                    val c41 = beginCell()
                                                        .storeAddress((address54 as address))
                                                        .endCell();
                                                    var b260 = begin_D151210F().storeAddress(
                                                        (address54 as address),
                                                    );
                                                    val c42 = storeNullableReference(
                                                        storeNullableReference(
                                                            b260.storeUint(x20, 256),
                                                            c41,
                                                        ),
                                                        c41,
                                                    ).endCell();
                                                    val constValue20 = (null as unknown as cell);
                                                    val result62 = jettonTransferBody(
                                                        queryId,
                                                        amount,
                                                        address56,
                                                        (address54 as unknown as int),
                                                        constValue20,
                                                        250000000,
                                                        c42,
                                                    );
                                                    var b261 = begin_62_().storeAddress(
                                                        (address55 as address),
                                                    );
                                                    var b262 = storeCoinsField(b261, 0x11e1a300);
                                                    selectedValue28 = storeNullableReference(
                                                        b262.storeUint(0, 106),
                                                        result62,
                                                    ).endCell();
                                                }
                                                val result63 = ((sourceAssetKind == 1) as int);
                                                var selectedValue29: int;
                                                if (result63 != 0) {
                                                    val result64 = ((targetAssetKind == 1) as int);
                                                    selectedValue29 = ((result64 != 0) as int);
                                                } else {
                                                    selectedValue29 = 0;
                                                }
                                                if (selectedValue29 != 0) {
                                                    var (cursor219, x21) = loadUint256(instruction);
                                                    var tail42 = cursor219;
                                                    val refCell18 = tail42.loadRef();
                                                    var dataSlice35 = refCell18.beginParse();
                                                    var dataSlice36 = tail42
                                                        .preloadRef()
                                                        .beginParse();
                                                    var tail43 = dataSlice35;
                                                    val address57 = (tail43.loadAddress() as slice);
                                                    val address58 = (tail43.loadAddress() as slice);
                                                    val address59 = (dataSlice36.loadAddress() as slice);
                                                    val c43 = beginCell()
                                                        .storeAddress((address57 as address))
                                                        .endCell();
                                                    var b263 = begin_D151210F().storeAddress(
                                                        (address57 as address),
                                                    );
                                                    val c44 = storeNullableReference(
                                                        storeNullableReference(
                                                            b263.storeUint(x21, 256),
                                                            c43,
                                                        ),
                                                        c43,
                                                    ).endCell();
                                                    val constValue21 = (null as unknown as cell);
                                                    val result65 = jettonTransferBody(
                                                        queryId,
                                                        amount,
                                                        address59,
                                                        (address57 as unknown as int),
                                                        constValue21,
                                                        250000000,
                                                        c44,
                                                    );
                                                    var b264 = begin_62_().storeAddress(
                                                        (address58 as address),
                                                    );
                                                    var b265 = storeCoinsField(b264, 0x11e1a300);
                                                    selectedValue0 = storeNullableReference(
                                                        b265.storeUint(0, 106),
                                                        result65,
                                                    ).endCell();
                                                } else {
                                                    selectedValue0 = selectedValue28;
                                                }
                                            } else {
                                                if ((protocolKind == 11)) {
                                                    val result66 = ((sourceAssetKind == 1) as int);
                                                    var selectedValue30: int;
                                                    if (result66 != 0) {
                                                        val result67 = ((targetAssetKind ==
                                                        0) as int);
                                                        selectedValue30 = ((result67 != 0) as int);
                                                    } else {
                                                        selectedValue30 = 0;
                                                    }
                                                    if (selectedValue30 != 0) {
                                                        var (cursor220, x22) = loadCoinsField(
                                                            instruction,
                                                        );
                                                        var tail44 = cursor220
                                                            .preloadRef()
                                                            .beginParse();
                                                        val address60 = (tail44.loadAddress() as slice);
                                                        val address61 = (tail44.loadAddress() as slice);
                                                        var b14 = begin_CC1A97AF();
                                                        val c45 = storeCoinsField(
                                                            storeCoinsField(
                                                                b14.storeUint(queryId, 64),
                                                                amount,
                                                            ).storeAddress((address60 as address)),
                                                            x22,
                                                        ).endCell();
                                                        var b266 = begin_62_().storeAddress(
                                                            (address61 as address),
                                                        );
                                                        var b267 = storeCoinsField(b266, 80000000);
                                                        selectedValue0 = storeNullableReference(
                                                            b267.storeUint(0, 106),
                                                            c45,
                                                        ).endCell();
                                                    } else {
                                                        selectedValue0 = constValue;
                                                    }
                                                } else {
                                                    if ((protocolKind == 12)) {
                                                        val result68 = ((sourceAssetKind ==
                                                        1) as int);
                                                        var selectedValue31: int;
                                                        if (result68 != 0) {
                                                            val result69 = ((targetAssetKind ==
                                                            0) as int);
                                                            selectedValue31 = ((result69 !=
                                                            0) as int);
                                                        } else {
                                                            selectedValue31 = 0;
                                                        }
                                                        if (selectedValue31 != 0) {
                                                            var (cursor221, x23) = loadCoinsField(
                                                                instruction,
                                                            );
                                                            var tail45 = cursor221
                                                                .preloadRef()
                                                                .beginParse();
                                                            val address62 = (tail45.loadAddress() as slice);
                                                            val address63 = (tail45.loadAddress() as slice);
                                                            var b15 = begin_B7459E2C();
                                                            var b268 = storeCoinsField(
                                                                storeCoinsField(
                                                                    b15.storeUint(queryId, 64),
                                                                    amount,
                                                                ),
                                                                x23,
                                                            ).storeAddress((address62 as address));
                                                            var b269 = storeNullableReference(
                                                                b268,
                                                                (null as unknown as cell),
                                                            );
                                                            val c46 = storeNullableReference(
                                                                b269,
                                                                (null as unknown as cell),
                                                            ).endCell();
                                                            var b270 = begin_62_().storeAddress(
                                                                (address63 as address),
                                                            );
                                                            var b271 = storeCoinsField(
                                                                b270,
                                                                80000000,
                                                            );
                                                            selectedValue0 = storeNullableReference(
                                                                b271.storeUint(0, 106),
                                                                c46,
                                                            ).endCell();
                                                        } else {
                                                            selectedValue0 = constValue;
                                                        }
                                                    } else {
                                                        if ((protocolKind == 13)) {
                                                            val result70 = ((sourceAssetKind ==
                                                            1) as int);
                                                            var selectedValue32: int;
                                                            if (result70 != 0) {
                                                                val result71 = ((targetAssetKind ==
                                                                0) as int);
                                                                selectedValue32 = ((result71 !=
                                                                0) as int);
                                                            } else {
                                                                selectedValue32 = 0;
                                                            }
                                                            if (selectedValue32 != 0) {
                                                                var (
                                                                    cursor222,
                                                                    x24,
                                                                ) = loadCoinsField(instruction);
                                                                var tail46 = cursor222
                                                                    .preloadRef()
                                                                    .beginParse();
                                                                val address64 = (tail46.loadAddress() as slice);
                                                                val address65 = (tail46.loadAddress() as slice);
                                                                var b16 = storeCoinsField(
                                                                    beginCell(),
                                                                    x24,
                                                                ).store_2_();
                                                                val c47 = storeNullableReference(
                                                                    b16,
                                                                    (null as unknown as cell),
                                                                ).endCell();
                                                                var b17 = begin_595F07BC();
                                                                val c48 = storeNullableReference(
                                                                    storeCoinsField(
                                                                        b17.storeUint(queryId, 64),
                                                                        amount,
                                                                    ).storeAddress(
                                                                        (address64 as address),
                                                                    ),
                                                                    c47,
                                                                ).endCell();
                                                                var b272 = begin_62_().storeAddress(
                                                                    (address65 as address),
                                                                );
                                                                var b273 = storeCoinsField(
                                                                    b272,
                                                                    80000000,
                                                                );
                                                                selectedValue0 = storeNullableReference(
                                                                    b273.storeUint(0, 106),
                                                                    c48,
                                                                ).endCell();
                                                            } else {
                                                                selectedValue0 = constValue;
                                                            }
                                                        } else {
                                                            selectedValue0 = constValue;
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
                val result72 = ((sourceAssetKind == 1) as int);
                var selectedValue33: int;
                if (result72 != 0) {
                    val result73 = ((targetAssetKind == 0) as int);
                    selectedValue33 = ((result73 != 0) as int);
                } else {
                    selectedValue33 = 0;
                }
                var selectedValue34 = constValue;
                if (selectedValue33 != 0) {
                    var (cursor223, x25) = loadCoinsField(instruction);
                    var tail47 = cursor223.preloadRef().beginParse();
                    val address66 = (tail47.loadAddress() as slice);
                    val address67 = (tail47.loadAddress() as slice);
                    var b18 = begin_25938561();
                    val c49 = storeCoinsField(
                        b18.storeAddress(
                            ("80022A16A3164C4D5AA3133F3110FF10496E00CA8AC8ABEFFC5027E024D33480C3F_".hexToSlice() as address),
                        ),
                        x25,
                    )
                        .storeAddress((address66 as address))
                        .store_4_()
                        .endCell();
                    val constslice3 = "800EF3B9902A271B2A01C8938A523CFE24E71847AAEB6A620001ED44A77AC0E709D_".hexToSlice();
                    val constValue22 = (null as unknown as int);
                    val constValue23 = (null as unknown as cell);
                    val result74 = jettonTransferBody(
                        queryId,
                        amount,
                        constslice3,
                        constValue22,
                        constValue23,
                        250000000,
                        c49,
                    );
                    var b274 = begin_62_().storeAddress((address67 as address));
                    var b275 = storeCoinsField(b274, 0x11e1a300);
                    selectedValue34 = storeNullableReference(
                        b275.storeUint(0, 106),
                        result74,
                    ).endCell();
                }
                val result75 = ((sourceAssetKind == 1) as int);
                var selectedValue35: int;
                if (result75 != 0) {
                    val result76 = ((targetAssetKind == 1) as int);
                    selectedValue35 = ((result76 != 0) as int);
                } else {
                    selectedValue35 = 0;
                }
                if (selectedValue35 != 0) {
                    var (cursor224, x26) = loadCoinsField(instruction);
                    var tail48 = cursor224;
                    val refCell19 = tail48.loadRef();
                    var dataSlice37 = refCell19.beginParse();
                    var dataSlice38 = tail48.preloadRef().beginParse();
                    var tail49 = dataSlice37;
                    val address68 = (tail49.loadAddress() as slice);
                    val address69 = (tail49.loadAddress() as slice);
                    val address70 = (dataSlice38.loadAddress() as slice);
                    val c50 = storeCoinsField(
                        begin_25938561().storeAddress((address70 as address)),
                        x26,
                    )
                        .storeAddress((address68 as address))
                        .store_4_()
                        .endCell();
                    val constslice4 = "800EF3B9902A271B2A01C8938A523CFE24E71847AAEB6A620001ED44A77AC0E709D_".hexToSlice();
                    val constValue24 = (null as unknown as int);
                    val constValue25 = (null as unknown as cell);
                    val result77 = jettonTransferBody(
                        queryId,
                        amount,
                        constslice4,
                        constValue24,
                        constValue25,
                        250000000,
                        c50,
                    );
                    var b276 = begin_62_().storeAddress((address69 as address));
                    var b277 = storeCoinsField(b276, 0x11e1a300);
                    selectedValue0 = storeNullableReference(
                        b277.storeUint(0, 106),
                        result77,
                    ).endCell();
                } else {
                    selectedValue0 = selectedValue34;
                }
            }
        }
    }
    return selectedValue0;
}
