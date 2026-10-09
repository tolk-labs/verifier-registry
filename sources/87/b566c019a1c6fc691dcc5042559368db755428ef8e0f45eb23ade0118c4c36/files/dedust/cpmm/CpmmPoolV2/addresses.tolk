// decompiled by @fiscaldev
// Shared Pool deployment/address logic. This module is not a complete Pool.
struct ReservedAddressVariantA {}
struct ReservedAddressVariantB {}

// Keep the original ContractState/AddressShardingOptions union IDs 130/131.
@inline
fun registerAddressUnionLayout(value: ReservedAddressVariantA | ReservedAddressVariantB): int {
    return (value is ReservedAddressVariantA) ? 1 : 0;
}

fun positionLibrary(): cell
    asm "<b 2 8 u, 0xdd82f24db614798ee7c579f8b3f07f0645d06d65cede368d80d0d74b180d2dd6 256 u, b>spec PUSHREF"

fun depositLibrary(): cell
    asm "<b 2 8 u, 0x2cac3fddd30969d08df036067108c6e7d69780a9459d931d2eb63d95d5ff6825 256 u, b>spec PUSHREF"

fun initialFeeCheckpoints(): (varuint32, varuint32)
    asm "0 PUSHINT 0 PUSHINT"

struct InitialPositionFees {
    xCheckpoint: varuint32
    xPending: coins
    xReserved: coins
    yCheckpoint: varuint32
    yPending: coins
    yReserved: coins
}

@overflow1023_policy("suppress")
struct InitialPositionStorage {
    pool: any_address
    owner: any_address
    liquidity: coins
    lockedLiquidity: coins
    fees: cell
    rewards: dict
}

struct InitialDepositConfig {
    targetX: coins
    targetY: coins
    minimalLiquidity: coins
    lockedShare: uint16
    payout: cell
}

@overflow1023_policy("suppress")
struct InitialDepositStorage {
    config: cell
    pool: any_address
    initiator: any_address
    amountX: coins
    amountY: coins
}

@inline
fun initialPositionData(owner: any_address): cell {
    val pool = contract.getAddress();
    val (xCheckpoint, yCheckpoint) = initialFeeCheckpoints();
    val fees = InitialPositionFees {
        xCheckpoint, xPending: 0, xReserved: 0,
        yCheckpoint, yPending: 0, yReserved: 0,
    }.toCell();
    return InitialPositionStorage {
        pool: pool as any_address, owner, liquidity: 0, lockedLiquidity: 0, fees, rewards: null,
    }.toCell();
}

@inline_ref
fun positionDeployment(owner: any_address): AutoDeployAddress {
    return { workchain: 0, stateInit: { code: positionLibrary(), data: initialPositionData(owner) },
        toShard: { fixedPrefixLength: 8, closeTo: contract.getAddress() } };
}

@inline
fun initialDepositData(
    initiator: any_address,
    targetX: coins,
    targetY: coins,
    minimalLiquidity: coins,
    lockedShare: uint16,
    payout: cell,
): cell {
    val config = InitialDepositConfig { targetX, targetY, minimalLiquidity, lockedShare, payout }.toCell();
    val pool = contract.getAddress();
    return InitialDepositStorage {
        config, pool: pool as any_address, initiator, amountX: 0, amountY: 0,
    }.toCell();
}

@inline_ref
fun depositDeployment(
    initiator: any_address,
    targetX: coins,
    targetY: coins,
    minimalLiquidity: coins,
    lockedShare: uint16,
    payout: cell,
): AutoDeployAddress {
    return { workchain: 0, stateInit: { code: depositLibrary(),
        data: initialDepositData(initiator, targetX, targetY, minimalLiquidity, lockedShare, payout) },
        toShard: { fixedPrefixLength: 8, closeTo: contract.getAddress() } };
}
