// decompiled by @fiscaldev
// Wire codecs and bounded stack-lifetime primitives. No trade branch or whole method is assembly.
fun releaseNoHook(
    fields: (
        cell,
        cell,
        cell,
        int,
        int,
        cell,
        int,
        cell,
        int,
        int,
        int,
        int,
        int,
        int,
        slice,
        int,
        int,
        cell,
        int,
    ),
): (
    cell,
    cell,
    cell,
    int,
    int,
    cell,
    int,
    int,
    int,
    int,
    int,
    cell,
    int,
    int,
    slice,
)
    asm "DROP s2 s10 XCHG s6 POP s7 POP DROP"

fun hookState(
    fields: (
        cell,
        cell,
        cell,
        int,
        int,
        cell,
        int,
        int,
        int,
        int,
        int,
        cell,
        int,
        int,
        slice,
    ),
): (
    cell,
    cell,
    cell,
    int,
    int,
    cell,
    int,
    int,
    int,
    int,
    int,
    cell,
    int,
    int,
    slice,
)
    asm "nop"

fun ackValue(key: int): (int, int, builder)
    asm "64 PUSHINT OVER NEWC 64 STU"

fun setWithWidth(dict: cell, key: int, width: int, value: builder): cell
    asm(value key dict width) "DICTUSETB"

fun ackState(
    fields: (
        cell,
        cell,
        cell,
        int,
        int,
        cell,
        int,
        cell,
        int,
        int,
        int,
        int,
        int,
        int,
        slice,
        int,
        int,
        cell,
        cell,
        int,
    ),
): (
    cell,
    cell,
    cell,
    int,
    int,
    cell,
    int,
    cell,
    int,
    int,
    int,
    int,
    int,
    int,
    slice,
    int,
    int,
    cell,
    cell,
    int,
)
    asm "nop"

fun feeState(
    fields: (
        cell,
        cell,
        cell,
        int,
        int,
        int,
        int,
        cell,
        int,
        int,
        int,
        int,
        int,
        int,
        slice,
        int,
        cell,
        cell,
        cell,
        int,
    ),
): (
    cell,
    cell,
    cell,
    int,
    int,
    int,
    int,
    cell,
    int,
    int,
    int,
    int,
    int,
    int,
    slice,
    int,
    cell,
    cell,
    cell,
    int,
)
    asm "nop"

fun releaseNoProgram(
    fields: (
        cell,
        cell,
        cell,
        int,
        int,
        cell,
        int,
        cell,
        int,
        int,
        int,
        int,
        int,
        int,
        slice,
        int,
        int,
        cell,
        cell,
        int,
        cell,
        int,
    ),
): (
    cell,
    cell,
    cell,
    int,
    int,
    cell,
    int,
    cell,
    int,
    int,
    int,
    int,
    int,
    int,
    slice,
    int,
    int,
    cell,
    cell,
    int,
)
    asm "s5 POP DROP"

fun stage8<
    T0,
    T1,
    T2,
    T3,
    T4,
    T5,
    T6,
    T7,
>(
    f0: T0,
    f1: T1,
    f2: T2,
    f3: T3,
    f4: T4,
    f5: T5,
    f6: T6,
    f7: T7,
): (
    T0,
    T1,
    T2,
    T3,
    T4,
    T5,
    T6,
    T7,
)
    asm "nop"

fun stage22(
    fields: (
        cell,
        cell,
        cell,
        int,
        int,
        cell,
        int,
        cell,
        int,
        int,
        int,
        int,
        int,
        int,
        slice,
        int,
        int,
        cell,
        cell,
        int,
        cell,
        int,
    ),
): (
    cell,
    cell,
    cell,
    int,
    int,
    cell,
    int,
    cell,
    int,
    int,
    int,
    int,
    int,
    int,
    slice,
    int,
    int,
    cell,
    cell,
    int,
    cell,
    int,
)
    asm "nop"

fun completeBounce(): void
    asm "nop"

fun fallbackDispatch(
    ack: cell,
    value: int,
    opcode: int,
    query: int,
    body: slice,
    walletId: int,
    seqno: int,
    key: int,
    parameters: cell,
    fees: cell,
    messages: cell,
    recipe: slice,
): (
    cell,
    cell,
    cell,
    int,
    cell,
    int,
    int,
    int,
)
    asm "DROP s2 s9 XCHG s6 POP s7 POP DROP"

fun discardBounceState(
    messages: cell,
    walletId: int,
    seqno: int,
    key: int,
    parameters: cell,
    fees: cell,
    ack: cell,
): void
    asm "7 BLKDROP"

fun loadRequestFlag(s: slice): (int, slice, int)
    asm( -> 0 2 1) "0 PUSHINT SWAP 1 LDU"

fun twoStageState(
    value: int,
    opcode: int,
    query: int,
    body: slice,
    parameters: cell,
    fees: cell,
    messages: cell,
    nextQuery: int,
    program: cell,
): (
    int,
    int,
    int,
    slice,
    cell,
    cell,
    cell,
    int,
    cell,
)
    asm "nop"

fun keepTen_6_4_5(
    value: int,
    opcode: int,
    query: int,
    body: slice,
    parameters: cell,
    fees: cell,
    messages: cell,
    nextQuery: int,
    program: cell,
    otherProgram: cell,
): (cell, cell, cell)
    asm "3 BLKDROP s6 POP 3 2 BLKDROP2"

fun releaseSeven_5_1_4(
    nextQuery: int,
    parameters: cell,
    query: int,
    amount: int,
    messages: cell,
    fees: cell,
    rejected: cell,
): (cell, cell, cell)
    asm "DROP s5 POP 2 1 BLKDROP2"

fun releaseSeven_0_5_4(
    parameters: cell,
    nextQuery: int,
    query: int,
    amount: int,
    messages: cell,
    fees: cell,
    rejected: cell,
): (cell, cell, cell)
    asm "DROP s4 POP 2 1 BLKDROP2"

fun keepEight_6_4_5(
    first: int,
    second: unknown,
    query: int,
    body: slice,
    parameters: cell,
    fees: cell,
    messages: cell,
    program: unknown,
): (cell, cell, cell)
    asm "DROP s6 POP 3 2 BLKDROP2"

fun keepNine_6_4_5(
    first: int,
    second: int,
    query: int,
    body: slice,
    parameters: cell,
    fees: cell,
    messages: cell,
    program: cell,
    otherProgram: unknown,
): (cell, cell, cell)
    asm "DROP2 s6 POP 3 2 BLKDROP2"

fun keepUnmatchedProgram(
    body: slice,
    nextQuery: int,
    query: int,
    messages: cell,
    parameters: cell,
    fees: cell,
    program: cell,
): (cell, cell, cell)
    asm "DROP 3 3 BLKDROP2"

fun releaseCompletedTrade(
    parameters: cell,
    opcode: int,
    query: int,
    messages: cell,
    amount: int,
    fees: cell,
    nextQuery: int,
    rejected: cell,
): (cell, int, cell, cell)
    asm "DROP2 s3 POP DROP"

fun activeState(fees: cell, opcode: int, query: int, messages: cell, parameters: cell): (
    cell,
    int,
    int,
    cell,
    cell,
)
    asm "nop"

fun pendingState(messages: cell, parameters: cell, fees: cell): (cell, cell, cell)
    asm "nop"

fun releasePreparedTrade(
    parameters: cell,
    nextQuery: int,
    query: int,
    messages: cell,
    amount: int,
    fees: cell,
    rejected: cell,
): (cell, cell, cell)
    asm "DROP s2 s4 XCHG 3 1 BLKDROP2"

fun keepUnmatchedTrade(
    body: slice,
    program: cell,
    query: int,
    messages: cell,
    parameters: cell,
    fees: cell,
    nextQuery: int,
): (cell, cell, cell)
    asm "DROP 3 3 BLKDROP2"

fun keepOtherTrade(
    body: slice,
    opcode: int,
    query: int,
    messages: cell,
    parameters: cell,
    fees: cell,
): (cell, cell, cell)
    asm "3 3 BLKDROP2"

fun releaseRejectedTrade(
    nextQuery: int,
    parameters: cell,
    query: int,
    messages: cell,
    amount: int,
    fees: cell,
    rejected: cell,
): (cell, cell, cell)
    asm "DROP s2 s5 XCHG 3 1 BLKDROP2"

fun builder.store_2_(self): builder
    asm "x{2_} STSLICECONST"

fun builder.store_4_(self): builder
    asm "x{4_} STSLICECONST"

fun builder.store_0(self): builder
    asm "x{0} STSLICECONST"

fun builder.store_0000(self): builder
    asm "x{0000} STSLICECONST"

fun builder.store_06_(self): builder
    asm "x{06_} STSLICECONST"

fun builder.store_1_(self): builder
    asm "x{1_} STSLICECONST"

fun builder.store_6_(self): builder
    asm "x{6_} STSLICECONST"

fun loadUint4(s: slice): (slice, int)
    asm( -> 1 0) "4 LDU"

fun loadUint8(s: slice): (slice, int)
    asm( -> 1 0) "8 LDU"

fun loadUint32(s: slice): (slice, int)
    asm( -> 1 0) "32 LDU"

fun loadUint256(s: slice): (slice, int)
    asm( -> 1 0) "256 LDU"

fun loadUint1(s: slice): (slice, int)
    asm( -> 1 0) "1 LDU"

fun loadUint16(s: slice): (slice, int)
    asm( -> 1 0) "16 LDU"

fun loadUint64(s: slice): (slice, int)
    asm( -> 1 0) "64 LDU"

fun begin_62_(): builder
    asm "NEWC x{62_} STSLICECONST"

fun store_62_(b: builder): builder
    asm "x{62_} STSLICECONST"

fun begin_10937847(): builder
    asm "NEWC x{10937847} STSLICECONST"

fun store_10937847(b: builder): builder
    asm "x{10937847} STSLICECONST"

fun begin_C(): builder
    asm "NEWC x{C} STSLICECONST"

fun store_C(b: builder): builder
    asm "x{C} STSLICECONST"

fun begin_01(): builder
    asm "NEWC x{01} STSLICECONST"

fun store_01(b: builder): builder
    asm "x{01} STSLICECONST"

fun begin_0F8A7EA5(): builder
    asm "NEWC x{0F8A7EA5} STSLICECONST"

fun store_0F8A7EA5(b: builder): builder
    asm "x{0F8A7EA5} STSLICECONST"

fun begin_BEAF9617(): builder
    asm "NEWC x{BEAF9617} STSLICECONST"

fun store_BEAF9617(b: builder): builder
    asm "x{BEAF9617} STSLICECONST"

fun begin_00000000(): builder
    asm "NEWC x{00000000} STSLICECONST"

fun store_00000000(b: builder): builder
    asm "x{00000000} STSLICECONST"

fun begin_E3A0D482(): builder
    asm "NEWC x{E3A0D482} STSLICECONST"

fun store_E3A0D482(b: builder): builder
    asm "x{E3A0D482} STSLICECONST"

fun begin_6664DE2A(): builder
    asm "NEWC x{6664DE2A} STSLICECONST"

fun store_6664DE2A(b: builder): builder
    asm "x{6664DE2A} STSLICECONST"

fun begin_A7FB58F8(): builder
    asm "NEWC x{A7FB58F8} STSLICECONST"

fun store_A7FB58F8(b: builder): builder
    asm "x{A7FB58F8} STSLICECONST"

fun begin_C442500F(): builder
    asm "NEWC x{C442500F} STSLICECONST"

fun store_C442500F(b: builder): builder
    asm "x{C442500F} STSLICECONST"

fun begin_CBC33949(): builder
    asm "NEWC x{CBC33949} STSLICECONST"

fun store_CBC33949(b: builder): builder
    asm "x{CBC33949} STSLICECONST"

fun begin_DD79732C(): builder
    asm "NEWC x{DD79732C} STSLICECONST"

fun store_DD79732C(b: builder): builder
    asm "x{DD79732C} STSLICECONST"

fun begin_C09DA84E(): builder
    asm "NEWC x{C09DA84E} STSLICECONST"

fun store_C09DA84E(b: builder): builder
    asm "x{C09DA84E} STSLICECONST"

fun begin_C0FFEE10(): builder
    asm "NEWC x{C0FFEE10} STSLICECONST"

fun store_C0FFEE10(b: builder): builder
    asm "x{C0FFEE10} STSLICECONST"

fun begin_00003039(): builder
    asm "NEWC x{00003039} STSLICECONST"

fun store_00003039(b: builder): builder
    asm "x{00003039} STSLICECONST"

fun begin_CB7F38D6(): builder
    asm "NEWC x{CB7F38D6} STSLICECONST"

fun store_CB7F38D6(b: builder): builder
    asm "x{CB7F38D6} STSLICECONST"

fun begin_C47C1F57(): builder
    asm "NEWC x{C47C1F57} STSLICECONST"

fun store_C47C1F57(b: builder): builder
    asm "x{C47C1F57} STSLICECONST"

fun begin_B37A900B(): builder
    asm "NEWC x{B37A900B} STSLICECONST"

fun store_B37A900B(b: builder): builder
    asm "x{B37A900B} STSLICECONST"

fun begin_FA45056B(): builder
    asm "NEWC x{FA45056B} STSLICECONST"

fun store_FA45056B(b: builder): builder
    asm "x{FA45056B} STSLICECONST"

fun begin_D151210F(): builder
    asm "NEWC x{D151210F} STSLICECONST"

fun store_D151210F(b: builder): builder
    asm "x{D151210F} STSLICECONST"

fun begin_CC1A97AF(): builder
    asm "NEWC x{CC1A97AF} STSLICECONST"

fun store_CC1A97AF(b: builder): builder
    asm "x{CC1A97AF} STSLICECONST"

fun begin_B7459E2C(): builder
    asm "NEWC x{B7459E2C} STSLICECONST"

fun store_B7459E2C(b: builder): builder
    asm "x{B7459E2C} STSLICECONST"

fun begin_595F07BC(): builder
    asm "NEWC x{595F07BC} STSLICECONST"

fun store_595F07BC(b: builder): builder
    asm "x{595F07BC} STSLICECONST"

fun begin_25938561(): builder
    asm "NEWC x{25938561} STSLICECONST"

fun store_25938561(b: builder): builder
    asm "x{25938561} STSLICECONST"

fun begin_01010201(): builder
    asm "NEWC x{01010201} STSLICECONST"

fun store_01010201(b: builder): builder
    asm "x{01010201} STSLICECONST"

fun begin_2_(): builder
    asm "NEWC x{2_} STSLICECONST"

fun store_2_(b: builder): builder
    asm "x{2_} STSLICECONST"

// TVM compatibility primitives used by this decompilation.
fun getExecutionContinuation(): unknown
    asm "c3 PUSH"

fun blessCode(s: slice): unknown
    asm "BLESS"

fun setExecutionContinuation(c: unknown): void
    asm "c3 POP"

fun tvmLoadUint(s: slice, len: int): (slice, int)
    asm(s len -> 1 0) "LDUX"

fun loadMaybeDictionary(s: slice): (slice, cell)
    asm( -> 1 0) "LDDICT"

fun preloadMaybeDictionary(s: slice): cell
    asm "PLDDICT"

fun isVmNull(x: unknown): int
    asm "ISNULL"

fun deleteUnsignedEntry(dict: cell, key_len: int, index: int): (cell, int)
    asm(index dict key_len) "DICTUDEL"

fun loadCoinsField(s: slice): (slice, int)
    asm( -> 1 0) "LDGRAMS"

fun setUnsignedSlice(dict: cell, key_len: int, index: int, value: slice): cell
    asm(value index dict key_len) "DICTUSET"

fun storeCoinsField(b: builder, x: int): builder
    asm "STGRAMS"

fun setUnsignedBuilder(dict: cell, key_len: int, index: int, value: builder): cell
    asm(value index dict key_len) "DICTUSETB"

fun findUnsignedEntry(dict: cell, key_len: int, index: int): (slice, int)
    asm(index dict key_len) "DICTUGET" "NULLSWAPIFNOT"

fun skipBitsField(s: slice, len: int): slice
    asm "SDSKIPFIRST"

fun requireEndOfSlice(s: slice): void
    asm "ENDS"

fun skipMaybeDictionary(s: slice): slice
    asm "SKIPDICT"

fun hashArchivedBuilder(b: builder): int
    asm "HASHBU"

fun verifyArchivedSignature(hash: int, signature: slice, public_key: int): int
    asm "CHKSIGNU"

fun acceptExternalMessage(): void
    asm "ACCEPT"

fun sendArchivedMessage(msg: cell, mode: int): void
    asm "SENDRAWMSG"

fun storeNullableReference(b: builder, c: cell): builder
    asm(c b) "STOPTREF"

fun tvmNull(): unknown
    asm "PUSHNULL"

fun tvmThrow(excno: int): never
    asm "THROWANY"

fun removeUnsignedEntry(dict: cell, key_len: int, index: int): (cell, slice, int)
    asm(index dict key_len) "DICTUDELGET" "NULLSWAPIFNOT"

fun tvmStoreSlice(b: builder, s: slice): builder
    asm "STSLICER"

fun storeStandardAddress(b: builder, a: slice): builder
    asm(a b) "STSTDADDR"

fun firstUnsignedEntry(dict: cell, key_len: int): (int, slice, int)
    asm( -> 1 0 2) "DICTUMIN" "NULLSWAPIFNOT2"

fun nextUnsignedEntry(dict: cell, key_len: int, pivot: int): (int, slice, int)
    asm(pivot dict key_len -> 1 0 2) "DICTUGETNEXT" "NULLSWAPIFNOT2"

fun replaceUnsignedBuilder(dict: cell, key_len: int, index: int, value: builder): (cell, int)
    asm(value index dict key_len) "DICTUREPLACEB"

fun callAmountHookAbi(
    a: unknown,
    b: unknown,
    c: unknown,
    d: unknown,
    e: unknown,
    f: unknown,
    g: int,
    h: unknown,
): unknown
    asm "7 1 CALLXARGS"

fun ownAddressSlice(): slice
    asm "8 GETPARAM"

fun previousBlockContext(): tuple
    asm "13 GETPARAM"

fun transactionLogicalTime(): int
    asm "5 GETPARAM"

fun currentUnixTime(): int
    asm "3 GETPARAM"

fun balanceTuple(): [int, cell]
    asm "7 GETPARAM"

fun unpackBalanceTuple(value: tuple): (unknown, unknown)
    asm "2 UNTUPLE"
