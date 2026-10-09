// decompiled by @fiscaldev
// Reconstructed from mainnet code dd82f24db614798ee7c579f8b3f07f0645d06d65cede368d80d0d74b180d2dd6.
// Names describe recovered behavior; the original author's identifiers are unknown.
import "@stdlib/gas-payments"
import "types"

// Preserve individual VM operations that the current compiler otherwise folds.
fun emptyReward(): PositionReward
    asm "0 PUSHINT 0 PUSHINT"

fun isZero(value: int): bool
    asm "0 EQINT"

fun selectFees(flag: bool, present: cell?, absent: cell?): cell?
    asm "CONDSEL"

// A wide nullable struct carries its data and variant ID in separate stack slots.
fun snapshotTag(value: OptionalRewards): int
    asm "NIP"

fun OptionalRewards.packToBuilder(self, mutate b: builder) {
    if (isZero(snapshotTag(self))) {
        b.storeBool(false);
    } else {
        b.storeBool(true).storeDict(self!.rewards.toLowLevelDict());
    }
}

@inline_ref
fun sendExcesses(recipient: any_address, queryId: uint64, mode: int) {
    val outgoing = beginCell()
        .storeUint(0x10, 6)
        .storeSlice(recipient as slice)
        .storeUint(0xd53276db, 143)
        .storeUint(queryId, 64)
        .endCell();
    sendRawMessage(outgoing, mode | SEND_MODE_IGNORE_ERRORS);
}

@inline_ref
fun accrueReward(
    pending: coins,
    oldCheckpoint: varuint32,
    liquidity: coins,
    checkpoint: varuint32,
): PositionReward {
    return PositionReward {
        pending: pending + mulDivFloor(checkpoint - oldCheckpoint, liquidity, 1 << 120),
        checkpoint,
    };
}

@inline_ref
fun synchronizeRewards(
    rewards: map<uint2, PositionReward>,
    liquidity: coins,
    poolRewards: map<uint2, PoolReward>,
): map<uint2, PositionReward> {
    var updated = rewards;
    var entry = poolRewards.findFirst();
    while (entry.isFound) {
        val poolReward = entry.loadValue();
        val previous = updated.get(entry.getKey());
        var reward = previous.isFound ? previous.loadValue() : emptyReward();
        reward = accrueReward(reward.pending, reward.checkpoint, liquidity, poolReward.checkpoint);
        updated.set(entry.getKey(), reward);
        entry = poolRewards.iterateNext(entry);
    }
    return updated;
}

@inline
fun PositionStorage.save(self) {
    contract.setData(self.toCell());
}

// Three unused variants reserve the original incoming union IDs (132 through 136).
@inline
fun registerOutgoingUnionLayout(message: Excesses | DepositNotification | PositionState): int {
    return ((message is Excesses) ? 1 : 0) + ((message is DepositNotification) ? 2 : 0) +
    ((message is PositionState) ? 4 : 0);
}

fun onInternalMessage(in: InMessage) {
    val message = PositionMessage.fromSlice(in.body, { throwIfOpcodeDoesNotMatch: 65535 });
    var storage = PositionStorage.fromCell(contract.getData());
    match (message) {
        CreditLiquidity => {
            assert ((in.senderAddress as slice).bitsEqual(storage.pool as slice)) throw 23;
            var fees = storage.fees.load();
            if (storage.liquidity > 0) {
                fees.xPending += mulDivFloor(
                    message.xCheckpoint - fees.xCheckpoint,
                    storage.liquidity,
                    1 << 120,
                );
                fees.yPending += mulDivFloor(
                    message.yCheckpoint - fees.yCheckpoint,
                    storage.liquidity,
                    1 << 120,
                );
            }
            fees.xCheckpoint = message.xCheckpoint;
            fees.yCheckpoint = message.yCheckpoint;
            storage.fees = fees.toCell();
            storage.rewards = synchronizeRewards(
                storage.rewards,
                storage.liquidity,
                message.rewards,
            );
            storage.liquidity += message.liquidity;
            val locked = mulDivFloor(message.liquidity, min(message.lockedShare, 10000), 10000);
            storage.lockedLiquidity += locked;
            storage.save();
            reserveToncoinsOnBalance(contract.getStoragePaidPayment(), 4);
            if (message.notifyGas > 0) {
                val outgoing = beginCell()
                    .storeUint(0x10, 6)
                    .storeSlice(storage.owner as slice)
                    .storeCoins(message.notifyGas)
                    .storeUint(0x63554160, 139)
                    .storeUint(message.queryId, 64)
                    .storeCoins(message.liquidity)
                    .storeCoins(locked)
                    .storeMaybeRef(message.payload)
                    .endCell();
                sendRawMessage(outgoing, SEND_MODE_PAY_FEES_SEPARATELY);
            }
            // The receiver field is decoded but ignored by the original code.
            sendExcesses(storage.owner, message.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }
        ClaimAvailableFees => {
            assert ((in.senderAddress as slice).bitsEqual(storage.pool as slice)) throw 23;
            var fees = storage.fees.load();
            val x = fees.xPending +
            mulDivFloor(message.xCheckpoint - fees.xCheckpoint, storage.liquidity, 1 << 120);
            val y = fees.yPending +
            mulDivFloor(message.yCheckpoint - fees.yCheckpoint, storage.liquidity, 1 << 120);
            fees.xCheckpoint = message.xCheckpoint;
            fees.xPending = 0;
            fees.yCheckpoint = message.yCheckpoint;
            fees.yPending = 0;
            storage.fees = fees.toCell();
            storage.save();
            val body = beginCell()
                .storeUint(0x29ff1bcf, 32)
                .storeUint(message.queryId, 64)
                .storeCoins(x)
                .storeCoins(y)
                .storeSlice(storage.owner as slice)
                .storeSlice(message.payout as slice)
                .endCell();
            sendRawMessage(
                beginCell()
                    .storeUint(0x18, 6)
                    .storeSlice(storage.pool as slice)
                    .storeUint(1, 111)
                    .storeRef(body)
                    .endCell(),
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
            );
        }
        WithdrawLiquidity => {
            assert ((in.senderAddress as slice).bitsEqual(storage.pool as slice)) throw 23;
            try {
                assert (storage.liquidity - storage.lockedLiquidity >= message.liquidity) throw 36;
                storage.rewards = synchronizeRewards(
                    storage.rewards,
                    storage.liquidity,
                    message.rewards,
                );
                var fees = storage.fees.load();
                if (storage.liquidity > 0) {
                    fees.xPending += mulDivFloor(
                        message.xCheckpoint - fees.xCheckpoint,
                        storage.liquidity,
                        1 << 120,
                    );
                    fees.yPending += mulDivFloor(
                        message.yCheckpoint - fees.yCheckpoint,
                        storage.liquidity,
                        1 << 120,
                    );
                }
                var x = 0;
                var y = 0;
                if (message.claimFees) {
                    x = fees.xPending;
                    y = fees.yPending;
                    fees.xPending = 0;
                    fees.yPending = 0;
                }
                fees.xCheckpoint = message.xCheckpoint;
                fees.yCheckpoint = message.yCheckpoint;
                storage.fees = fees.toCell();
                storage.liquidity -= message.liquidity;
                storage.save();
                val body = beginCell()
                    .storeUint(0xf6f6a3aa, 32)
                    .storeUint(message.queryId, 64)
                    .storeCoins(message.liquidity)
                    .storeCoins(x)
                    .storeCoins(y)
                    .storeSlice(storage.owner as slice)
                    .storeCoins(message.minX)
                    .storeCoins(message.minY)
                    .storeRef(message.config)
                    .endCell();
                sendRawMessage(
                    beginCell()
                        .storeUint(0x18, 6)
                        .storeSlice(storage.pool as slice)
                        .storeUint(1, 111)
                        .storeRef(body)
                        .endCell(),
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
                );
            } catch (code, _) {
                sendExcesses(
                    storage.owner,
                    message.queryId,
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
                );
                commitContractDataAndActions();
                throw code;
            }
        }
        ProvidePositionState => {
            reserveToncoinsOnBalance(
                contract.getOriginalBalance() + contract.getStoragePaidPayment() - in.valueCoins,
                2,
            );
            val recipient = in.senderAddress;
            val pool = message.includePool ? storage.pool : null;
            val owner = message.includeOwner ? storage.owner : null;
            val fees = selectFees(message.includeFees, storage.fees as cell, null);
            val rewards: RewardSnapshot? = message.includeRewards
                ? RewardSnapshot { rewards: storage.rewards }
                : null;
            val body = PositionState {
                queryId: message.queryId,
                liquidity: storage.liquidity,
                lockedLiquidity: storage.lockedLiquidity,
                pool,
                owner,
                fees,
                rewards,
            }.toCell();
            sendRawMessage(
                beginCell()
                    .storeUint(0x10, 6)
                    .storeSlice(recipient as slice)
                    .storeUint(1, 111)
                    .storeRef(body)
                    .endCell(),
                SEND_MODE_CARRY_ALL_BALANCE,
            );
        }
        ClaimPositionReward => {
            assert ((in.senderAddress as slice).bitsEqual(storage.pool as slice)) throw 23;
            reserveToncoinsOnBalance(contract.getStoragePaidPayment(), 4);
            val previous = storage.rewards.get(message.rewardId);
            var reward = previous.isFound ? previous.loadValue() : emptyReward();
            reward = accrueReward(
                reward.pending,
                reward.checkpoint,
                storage.liquidity,
                message.checkpoint,
            );
            storage
                .rewards
                .set(
                    message.rewardId,
                    PositionReward {
                        pending: 0,
                        checkpoint: reward.checkpoint,
                    },
                );
            storage.save();
            if (isZero(reward.pending)) {
                sendExcesses(message.payout, message.queryId, SEND_MODE_CARRY_ALL_BALANCE);
                return;
            }
            val body = beginCell()
                .storeUint(0x9e17fbbe, 32)
                .storeUint(message.queryId, 64)
                .storeCoins(reward.pending)
                .storeUint(message.rewardId, 2)
                .storeSlice(storage.owner as slice)
                .storeSlice(message.payout as slice)
                .endCell();
            sendRawMessage(
                beginCell()
                    .storeUint(0x18, 6)
                    .storeSlice(storage.pool as slice)
                    .storeUint(1, 111)
                    .storeRef(body)
                    .endCell(),
                SEND_MODE_CARRY_ALL_BALANCE,
            );
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var body = in.bouncedBody;
    body.loadUint(32); // Consume, but do not validate, the conventional bounce prefix.
    var storage = PositionStorage.fromCell(contract.getData());
    val message = lazy BouncedPositionMessage.fromSlice(body);
    match (message) {
        BouncedFeeClaim => {
            var fees = storage.fees.load();
            // Decode after fees: malformed fees take precedence over malformed body.
            val queryId = message.queryId;
            fees.xPending += message.x;
            fees.yPending += message.y;
            storage.fees = fees.toCell();
            storage.save();
            sendExcesses(storage.owner, queryId, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        BouncedWithdrawal => {
            var fees = storage.fees.load();
            val queryId = message.queryId;
            val liquidity = message.liquidity;
            fees.xPending += message.x;
            fees.yPending += message.y;
            storage.fees = fees.toCell();
            storage.liquidity += liquidity;
            storage.save();
            sendExcesses(storage.owner, queryId, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        BouncedRewardClaim => {
            val queryId = message.queryId;
            val amount = message.amount;
            val rewardId = message.tail.preloadUint(2) as uint2;
            val previous = storage.rewards.get(rewardId);
            var reward = previous.isFound ? previous.loadValue() : emptyReward();
            reward.pending += amount;
            storage.rewards.set(rewardId, reward);
            storage.save();
            sendExcesses(storage.owner, queryId, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        else => {
            throw 63;
        }
    }
}

get fun get_available_fees(xCheckpoint: int, yCheckpoint: int): (int, int) {
    var data = contract.getData().beginParse();
    data.loadAddressAny();
    data.loadAddressAny();
    val liquidity = data.loadCoins();
    var fees = data.preloadRef().beginParse();
    val xOld = fees.loadAny<varuint32>();
    val xPending = fees.loadCoins();
    fees.loadCoins();
    val yOld = fees.loadAny<varuint32>();
    val yPending = fees.loadCoins();
    return (
        xPending + mulDivFloor(xCheckpoint - xOld, liquidity, 1 << 120),
        yPending + mulDivFloor(yCheckpoint - yOld, liquidity, 1 << 120),
    );
}

get fun get_position_data(): (
    any_address,
    any_address,
    int,
    int,
    dict,
    int,
    int,
    int,
    int,
) {
    var data = contract.getData().beginParse();
    val pool = data.loadAddressAny();
    val owner = data.loadAddressAny();
    val liquidity = data.loadCoins();
    val locked = data.loadCoins();
    val feeCell = data.loadRef();
    val rewards = data.preloadDict();
    var fees = feeCell.beginParse();
    val xOld = fees.loadAny<varuint32>();
    val xPending = fees.loadCoins();
    fees.loadCoins();
    val yOld = fees.loadAny<varuint32>();
    val yPending = fees.loadCoins();
    return (
        pool,
        owner,
        liquidity,
        locked,
        rewards,
        xPending,
        yPending,
        xOld,
        yOld,
    );
}
