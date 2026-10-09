// decompiled by @fiscaldev
// Adapted from TON's LGPL-licensed Tolk standard library (Tolk 1.1).
// Original: crypto/smartcont/tolk-stdlib/common.tolk at
// https://github.com/ton-blockchain/ton/blob/90267652ad79ab1492c87864ee8096da42c4c716/crypto/smartcont/tolk-stdlib/common.tolk
// These are standard StateInit hashing primitives, not recovered protocol logic.

@pure
fun archivedStateHash(
    code: cell,
    data: cell,
): uint256 asm """
    DUP2
    HASHCU
    SWAP
    HASHCU
    SWAP2
    CDEPTH
    SWAP
    CDEPTH
    NEWC
    x{020134} STSLICECONST
    16 STU
    16 STU
    256 STU
    256 STU
    ONE HASHEXT_SHA256
"""

@pure
fun archivedStateHashPrefix(
    fixedPrefixLength: uint5,
    code: cell,
    data: cell,
): uint256 asm """
    DUP2
    HASHCU
    SWAP
    HASHCU
    SWAP2
    CDEPTH
    SWAP
    CDEPTH
    s4 PUSH
    10 LSHIFT#
    0x020381A0 PUSHINT
    ADD
    NEWC
    32 STU
    16 STU
    16 STU
    256 STU
    256 STU
    ONE HASHEXT_SHA256
    NIP
"""
