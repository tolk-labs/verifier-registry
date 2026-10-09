// decompiled by @fiscaldev
@pure
fun archivedStateHash(code: cell, data: cell): uint256
    asm(data code) "NEWC x{34_} STSLICECONST STREF STREF HASHBU"

@pure
fun archivedStateHashPrefix(fixedPrefixLength: uint5, code: cell, data: cell): uint256
    asm(data code fixedPrefixLength)
        "NEWC x{C_} STSLICECONST 5 STU x{6} STSLICECONST STREF STREF HASHBU"
