// decompiled by @fiscaldev
import "@stdlib/gas-payments"
import "types"

// Recovered from the frozen V3 factory. Author names/comments are not available.
// This exotic cell is a library reference, not an embedded executable contract.
fun memeLibrary(): cell
    asm
        "<b 2 8 u, 0xa63e4a802c8b982cd888a357b2c9ee5a722644c2d7e7cdaed350f24fc96eca3d 256 u, b>spec PUSHREF"

@inline_ref
fun initialCurve(
    totalSupply: coins,
    onSellSupply: coins,
    raisingFunds: coins,
    virtualFunds: coins,
): Curve {
    assert (totalSupply > onSellSupply) throw 20;
    val remaining = totalSupply - onSellSupply;
    val sum = raisingFunds + virtualFunds;
    val weighted = mulDivFloor(raisingFunds, onSellSupply * onSellSupply, remaining);
    val denominator = mulDivFloor(raisingFunds, onSellSupply, remaining) - sum;
    val alpha = weighted / denominator;
    val beta = sum * sum / denominator;
    assert (alpha > 0 && beta > 0) throw 20;
    return {
        graduated: false,
        alpha,
        beta,
        onSellSupply,
        raisedFunds: 0,
        currentSupply: 0,
    };
}

@inline
fun presetParameters(preset: int): (coins, coins, coins, coins, int) {
    return match (preset) {
        3 => (1000000000000000000, 800000000000000000, 1000000000000, 50000000000, 100),
        4 => (1000000000000000000, 800000000000000000, 1000000000000, 50000000000, 300),
        5 => (1000000000000000000, 800000000000000000, 1000000000000, 50000000000, 500),
        6 => (1000000000000000000, 750000000000000000, 1500000000000, 50000000000, 100),
        7 => (1000000000000000000, 750000000000000000, 1500000000000, 50000000000, 300),
        8 => (1000000000000000000, 750000000000000000, 2500000000000, 50000000000, 100),
        9 => (1000000000000000000, 750000000000000000, 2500000000000, 50000000000, 300),
        else => throw 22,
    };
}

@inline
fun feeFromPreset(preset: int): int {
    return match (preset) {
        0 => 10,
        1 => 25,
        2 => 50,
        3 => 100,
        4 => 200,
        5 => 300,
        6 => 500,
        7 => 1000,
        else => throw 34,
    };
}

fun incomingOriginalFee(): coins
    asm "INMSG_FWDFEE" "0 PUSHINT" "GETORIGINALFWDFEE"

@inline
fun presetDeploymentBudget(initialBuy: coins): coins {
    var required: coins;
    if (initialBuy > 0) {
        required = contract.getStoragePaidPayment() + calculateGasFee(0, 10253) + 10000000 +
        calculateGasFee(0, 22492) +
        calculateGasFee(0, 8862) +
        calculateForwardFeeWithoutLumpPrice(0, 812, 3) +
        calculateStorageFee(0, 157680000, 970, 3) +
        (incomingOriginalFee() << 1) +
        initialBuy;
    } else {
        required = contract.getStoragePaidPayment() + calculateGasFee(0, 10253) + 10000000 +
        calculateGasFee(0, 16450) +
        incomingOriginalFee();
    }
    return required;
}

@inline
fun customDeploymentBudget(initialBuy: coins): coins {
    var required: coins;
    if (initialBuy > 0) {
        required = contract.getStoragePaidPayment() + calculateGasFee(0, 12458) + 10000000 +
        calculateGasFee(0, 22492) +
        calculateGasFee(0, 8862) +
        calculateForwardFeeWithoutLumpPrice(0, 812, 3) +
        calculateStorageFee(0, 157680000, 970, 3) +
        (incomingOriginalFee() << 1) +
        initialBuy;
    } else {
        required = contract.getStoragePaidPayment() + calculateGasFee(0, 12458) + 10000000 +
        calculateGasFee(0, 16450) +
        incomingOriginalFee();
    }
    return required;
}

fun deploymentStateHash(depth: int, code: cell, data: cell): uint256
    asm(data code depth) "NEWC x{C_} STSLICECONST 5 STU x{6} STSLICECONST STREF STREF HASHBU"

fun selectAddress(condition: bool, present: address, absent: address): address
    asm "CONDSEL"

// Keep the legacy compiler's depth operand lifetime after copying the shard prefix.
fun discardShardDepth(depth: int): void
    asm "DROP"

@inline
fun sendDeployment(code: cell, data: cell, depth: int, near: address, body: cell) {
    // Non-bouncing carry-all deployment; inline sharded StateInit, referenced body.
    var outgoing = beginCell().storeUint(0x10, 6).storeUint(4, 3).storeInt(0, 8);
    val hash = deploymentStateHash(depth, code, data);
    val suffix = hash & ((1 << 248) - 1);
    val prefix = (near as slice).getMiddleBits(11, depth);
    discardShardDepth(depth);
    outgoing
        .storeSlice(prefix)
        .storeUint(suffix, 248)
        .storeUint(5389, 122)
        .storeRef(code)
        .storeRef(data)
        .storeRef(body);
    val wire = outgoing.endCell();
    reserveToncoinsOnBalance(contract.getStoragePaidPayment(), 4);
    sendRawMessage(wire, 128);
}

fun onInternalMessage(in: InMessage) {
    // The compiler's default bounce handler returns before this entrypoint.
    if (in.body.isEmpty()) {
        return;
    }
    val message = Incoming.fromSlice(in.body, { throwIfOpcodeDoesNotMatch: 65535 });
    val storage = FactoryStorage.fromCell(contract.getData());
    match (message) {
        DeployPreset => {
            assert (presetDeploymentBudget(message.initialBuy) <= in.valueCoins) throw 23;
            val (totalSupply, onSellSupply, raisingFunds, virtualFunds, baseFee) = presetParameters(
                message.preset,
            );
            assert (message.initialBuy < raisingFunds) throw 26;
            val creator = in.senderAddress;
            val code = memeLibrary();
            val liquidityTokens = totalSupply - onSellSupply;
            random.initialize();
            val seed = random.uint256() >> 128;
            val config = MemeConfig {
                creator,
                controller: storage.controller,
                metadata: message.metadata,
                raisingFunds,
                liquidityTokens,
                seed,
            }.toCell();
            val curve = initialCurve(totalSupply, onSellSupply, raisingFunds, virtualFunds);
            val migration = MigrationConfig {
                partner: storage.controller,
                partnerShare: 0,
                baseFee,
                liquidityOwner: creator,
            }.toCell();
            val data = MemeStorage {
                initialized: false,
                migrated: false,
                config,
                baseFee,
                curve,
                totalSupply,
                creatorFee: 0,
                partnerFee: 0,
                partnerShare: 0,
                migration,
            }.toCell();
            val depth = 8;
            val near = contract.getAddress();
            val body = InitializeMeme {
                queryId: message.queryId,
                initialBuy: message.initialBuy,
                partner: message.partner,
                referrer: message.referrer,
            }.toCell();
            sendDeployment(code, data, depth, near, body);
        }
        DeployCustom => {
            assert (customDeploymentBudget(message.initialBuy) <= in.valueCoins) throw 23;
            assert (
                message.raisingFunds >= 800000000000 && message.raisingFunds <= 1000000000000000
            ) throw 36;
            assert (message.partnerFee <= 6000) throw 37;
            assert (message.poolPartnerFee <= 4000) throw 39;
            assert (message.onSellPercent > 59 && message.onSellPercent < 81) throw 38;
            assert (message.initialBuy < message.raisingFunds) throw 26;
            val totalSupply = match (message.supplyPreset) {
                0 => 100000000000000000,
                1 => 1000000000000000000,
                2 => 10000000000000000000,
                else => throw 35,
            };
            val onSellSupply = mulDivFloor(totalSupply, message.onSellPercent, 100);
            val baseFee = feeFromPreset(message.feePreset);
            val partnerShare = mulDivFloor(message.poolPartnerFee, 100, 80);
            val creator = in.senderAddress;
            val liquidityTokens = totalSupply - onSellSupply;
            random.initialize();
            val seed = random.uint256() >> 128;
            val config = MemeConfig {
                creator,
                controller: storage.controller,
                metadata: message.metadata,
                raisingFunds: message.raisingFunds,
                liquidityTokens,
                seed,
            }.toCell();
            val curve = initialCurve(totalSupply, onSellSupply, message.raisingFunds, 50000000000);
            val poolBaseFee = feeFromPreset(message.poolFeePreset);
            val poolOwner = selectAddress(
                message.liquidityOwner == null,
                creator,
                message.liquidityOwner as unknown as address,
            );
            val migration = MigrationConfig {
                partner: message.partnerAddress,
                partnerShare,
                baseFee: poolBaseFee,
                liquidityOwner: poolOwner,
            }.toCell();
            val data = MemeStorage {
                initialized: false,
                migrated: false,
                config,
                baseFee,
                curve,
                totalSupply,
                creatorFee: 0,
                partnerFee: 0,
                partnerShare: message.partnerFee,
                migration,
            }.toCell();
            val code = memeLibrary();
            val depth = 8;
            val near = contract.getAddress();
            val partner = message.partner == null ? null : message.partner!.load();
            val referrer = message.referrer == null ? null : message.referrer!.load();
            val body = InitializeMeme {
                queryId: message.queryId,
                initialBuy: message.initialBuy,
                partner,
                referrer,
            }.toCell();
            sendDeployment(code, data, depth, near, body);
        }
    }
}
