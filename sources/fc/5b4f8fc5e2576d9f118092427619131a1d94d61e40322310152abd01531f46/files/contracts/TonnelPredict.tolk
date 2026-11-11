import "errors"
import "messages"
import "storage"

/// TonnelPredict: price prediction rounds with oracle prices.
/// Bettors send a text bet "Long" or "Short" (op 0) to the next round. At the start of each
/// round, the oracle sends a signed price. This price opens the round and closes the previous
/// round. Then the contract pays the bettors of the closed round in batches.
/// This source is a reconstruction of the deployed bytecode.
contract TonnelPredict {
    author: "Mr FreeMan / Tonnel Network"
    version: "1.0.0"
    description: "Price prediction rounds with oracle-signed prices. Source code reconstructed by @ai_terminal."
    storage: Storage
    incomingMessages: AllowedMessage
}

/// The admin address. It is hardcoded in the deployed bytecode.
const ADMIN_ADDRESS = address("EQD8ltklZKBzj0gRIFj4f1Nh8DqRQXzMLYZmsDaOqFDnSs__")

/// The send mode of all outgoing messages: pay the fees separately, and bounce the transaction
/// if a send fails.
const SEND_MODE = SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL

/// The bet side "Long".
const SIDE_LONG = 1

/// The bet side "Short".
const SIDE_SHORT = 2

/// 100% in basis points.
const BPS_BASE = 10000

// limits for a new configuration (`UpdateOracleAndConfig`)

/// The minimum round length, in seconds.
const MIN_ROUND_DURATION = 60
/// The round length must be a multiple of this value, in seconds.
const ROUND_DURATION_STEP = 60
/// The maximum round length and the maximum refund delay, in seconds.
const ONE_DAY = 86400
/// The maximum protocol fee, in basis points.
const MAX_FEE_BPS = 10000
/// The maximum bet fee.
const MAX_BET_FEE = 1000000000
/// The minimum value of `minOpValue`.
const MIN_OP_VALUE_LIMIT = 1000000
/// The maximum value of `minOpValue`.
const MAX_OP_VALUE_LIMIT = 1000000000
/// The minimum value of `reserveExtra`.
const MIN_RESERVE_EXTRA = 100000000
/// The minimum price window, in seconds.
const MIN_PRICE_WINDOW = 15
/// The maximum value of `maxActiveRounds`.
const MAX_ACTIVE_ROUNDS_LIMIT = 32
/// The maximum value of `payoutBatchSize`.
const MAX_PAYOUT_BATCH = 32
/// The maximum bet size.
const MAX_BET_SIZE = 1000000000000000

/// Sends `amount` to `dest` with a text comment. The message does not bounce.
fun sendPayment(dest: address, amount: coins, text: string) {
    val payment = createMessage({
        bounce: false,
        value: amount,
        dest,
        // the original body is a cell ref: keep the explicit toCell() for TL-B parity
        // check-disable-next-line create-message-body-to-cell
        body: TextComment { text }.toCell(),
    });
    payment.send(SEND_MODE);
}

/// Pays a maximum of `payoutBatchSize` bettors of a closed round. If bettors remain, the contract
/// sends `ProcessPayouts` to itself. After the last payout, the amount that remains goes to the
/// protocol fees, and the contract deletes the round.
fun Storage.processPayouts(mutate self, roundTs: uint32) {
    val config = self.config.load();
    var round = self.rounds.mustGet(roundTs, Errors.RoundNotFound).load();
    assert (round.result != RESULT_OPEN) throw Errors.InvalidRoundState;

    var processed = 0;
    var entry = round.bets.findFirst();
    while (entry.isFound && processed < config.payoutBatchSize) {
        val bettor = entry.getKey();
        val bet = entry.loadValue().load();

        // a refund returns the full bet; a winner gets the bet and a part of the losing pool
        // minus the protocol fee; a loser gets 0
        var amount = bet.long + bet.short;
        var text = "Refund";
        if (round.result == RESULT_LONG) {
            amount = bet.long +
                // the original formula: do not change the order of the integer divisions
                // check-disable-next-line divide-before-multiply
                (round.shortPool - round.shortPool * config.feeBps / BPS_BASE) * bet.long /
                    round.longPool;
            text = "Long Win";
        } else if (round.result == RESULT_SHORT) {
            amount = bet.short +
                // the original formula: do not change the order of the integer divisions
                // check-disable-next-line divide-before-multiply
                (round.longPool - round.longPool * config.feeBps / BPS_BASE) * bet.short /
                    round.shortPool;
            text = "Short Win";
        }

        if (amount > 0) {
            // bytecode parity: build the comment cell first, then copy the amount and the address
            val comment = TextComment { text }.toCell();
            val payAmount = amount;
            val payTo = bettor;

            val payment = createMessage({
                bounce: false,
                value: payAmount,
                dest: payTo,
                body: comment,
            });
            payment.send(SEND_MODE);

            round.unpaidPool -= amount;
            self.lockedFunds -= amount;
        }

        round.bets.delete(bettor);
        val openBets = self.openBetCounts.mustGet(bettor, Errors.BettorNotFound);
        if (openBets == 1) {
            self.openBetCounts.delete(bettor);
        } else {
            self.openBetCounts.set(bettor, openBets - 1);
        }
        round.unpaidBettorCount -= 1;
        processed += 1;
        entry = round.bets.findFirst();
    }

    if (round.bets.isEmpty()) {
        // the rest of the round is the protocol fee and the rounding remainder
        self.lockedFunds -= round.unpaidPool;
        self.protocolFees += round.unpaidPool;
        self.rounds.delete(roundTs);
        self.activeRoundCount -= 1;
    } else {
        self.rounds.set(roundTs, round.toCell());

        // continue in a new transaction; the contract pays `minOpValue` for it
        val continuation = createMessage({
            bounce: false,
            value: config.minOpValue as coins,
            dest: contract.getAddress(),
            // the original body is a cell ref: keep the explicit toCell() for TL-B parity
            // check-disable-next-line create-message-body-to-cell
            body: ProcessPayouts { roundTs }.toCell(),
        });
        continuation.send(SEND_MODE);
    }
}

/// Adds a bet of `sender` on `side` (`SIDE_LONG` or `SIDE_SHORT`) to the next round.
/// If the sender has a bet in that round already, the contract sends the amount back.
fun Storage.placeBet(mutate self, side: int, sender: address, messageValue: coins) {
    val config = self.config.load();

    assert (
        sender.getWorkchain() == BASECHAIN && sender != contract.getAddress()
    ) throw Errors.SenderNotAllowed;

    val amount = messageValue - config.betFee;
    assert (
        amount == config.betSize1 || config.betSize2 == amount || amount == config.betSize3 ||
        amount == config.betSize4
    ) throw Errors.InvalidBetAmount;

    // the start time of the next round
    // check-disable-next-line divide-before-multiply
    val roundTs = (blockchain.now() / config.roundDuration + 1) * config.roundDuration;

    val roundLookup = self.rounds.get(roundTs);
    var round: Round = roundLookup.isFound
        ? roundLookup.loadValue().load()
        : {
            openPrice: 0,
            closePrice: 0,
            longPool: 0,
            shortPool: 0,
            unpaidPool: 0,
            unpaidBettorCount: 0,
            result: RESULT_OPEN,
            bets: [],
        };

    if (round.bets.exists(sender)) {
        sendPayment(sender, amount, "Refund");
        return;
    }

    if (!roundLookup.isFound) {
        assert (self.activeRoundCount < config.maxActiveRounds) throw Errors.LimitReached;
        self.activeRoundCount += 1;
    }
    assert (round.result == RESULT_OPEN) throw Errors.InvalidRoundState;

    // bytecode parity: the sender has no bet in this round here, but the original code
    // still looks it up
    val betLookup = round.bets.get(sender);
    var bet: Bet = betLookup.isFound ? betLookup.loadValue().load() : { long: 0, short: 0 };
    if (!betLookup.isFound) {
        assert (round.unpaidBettorCount < config.maxBettorsPerRound) throw Errors.LimitReached;
        round.unpaidBettorCount += 1;
    }

    if (side == SIDE_LONG) {
        bet.long += amount;
        round.longPool += amount;
    } else {
        bet.short += amount;
        round.shortPool += amount;
    }
    round.unpaidPool += amount;

    round.bets.set(sender, bet.toCell());
    val countLookup = self.openBetCounts.get(sender);
    val openBets = countLookup.isFound ? countLookup.loadValue() + 1 : 1;
    self.openBetCounts.set(sender, openBets);
    self.rounds.set(roundTs, round.toCell());
    self.lockedFunds += amount;
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    var bodyReader = in.body;
    val op = bodyReader.loadUint(32);

    // bytecode parity: the original code checks this opcode before it loads the storage,
    // and it parses the body again from the start
    if (op == OP_ADMIN_WITHDRAW) {
        assert (in.senderAddress == ADMIN_ADDRESS) throw Errors.SenderNotAllowed;
        val msg = AdminWithdraw.fromSlice(in.body);
        sendPayment(ADMIN_ADDRESS, msg.amount, "Admin Withdraw");
        return;
    }

    var storage = Storage.load();
    val config = storage.config.load();

    if (op != 0) {
        assert (in.valueCoins >= config.minOpValue) throw Errors.NotEnoughValue;

        val msg = lazy AllowedMessage.fromSlice(in.body);
        match (msg) {
            SubmitPrice => {
                val now = blockchain.now();
                val roundTs = msg.roundTs;
                val price = msg.price;
                val signature = msg.signature;

                assert (
                    roundTs % config.roundDuration == 0 && roundTs > storage.lastRoundTs &&
                    roundTs <= now &&
                    now <= roundTs + config.priceWindow
                ) throw Errors.InvalidRoundTime;
                assert (price > 0) throw Errors.InvalidPriceProof;

                val payload = PricePayload {
                    networkId: storage.networkId,
                    contractAddress: contract.getAddress(),
                    roundTs,
                    price,
                }.toCell();
                val signatureSlice = signature.beginParse();
                assert (
                    signatureSlice.remainingBitsCount() == 512 &&
                    signatureSlice.remainingRefsCount() == 0 &&
                    isSignatureValid(payload.hash(), signatureSlice, storage.oraclePublicKey)
                ) throw Errors.InvalidPriceProof;

                storage.lastRoundTs = roundTs;
                storage.lastPrice = price;

                // open the round that starts now, if it has bets
                val currentLookup = storage.rounds.get(roundTs);
                if (currentLookup.isFound) {
                    var round = currentLookup.loadValue().load();
                    assert (
                        round.openPrice == 0 && round.result == RESULT_OPEN
                    ) throw Errors.InvalidRoundState;
                    round.openPrice = price;
                    storage.rounds.set(roundTs, round.toCell());
                }

                // close the previous round and pay the first batch;
                // a refund if a price is missing, the price did not change or a pool is empty
                val prevTs = roundTs - config.roundDuration;
                val previousLookup = storage.rounds.get(prevTs);
                if (previousLookup.isFound) {
                    var round = previousLookup.loadValue().load();
                    if (round.result == RESULT_OPEN) {
                        round.closePrice = price;
                        round.result = (price == 0 || round.openPrice == 0 ||
                            price == round.openPrice ||
                            round.longPool == 0 ||
                            round.shortPool == 0)
                            ? RESULT_REFUND
                            : (price > round.openPrice ? RESULT_LONG : RESULT_SHORT);
                        storage.rounds.set(prevTs, round.toCell());
                        storage.processPayouts(prevTs);
                    }
                }
            }

            ProcessPayouts => {
                storage.processPayouts(msg.roundTs);
            }

            ForceRefund => {
                val roundTs = msg.roundTs;
                assert (
                    blockchain.now() >= roundTs + config.roundDuration + config.refundDelay
                ) throw Errors.RefundTooEarly;

                // only a round without a result; a closed round does not change
                val roundLookup = storage.rounds.get(roundTs);
                if (roundLookup.isFound) {
                    var round = roundLookup.loadValue().load();
                    if (round.result == RESULT_OPEN) {
                        round.closePrice = 0;
                        round.result = RESULT_REFUND;
                        storage.rounds.set(roundTs, round.toCell());
                        storage.processPayouts(roundTs);
                    }
                }
            }

            WithdrawFees => {
                assert (in.senderAddress == config.treasury) throw Errors.SenderNotAllowed;
                assert (storage.protocolFees > 0) throw Errors.NoFees;

                val fees = storage.protocolFees;
                storage.protocolFees = 0;
                sendPayment(config.treasury, fees, "Protocol Fee");
            }

            UpdateOracleAndConfig => {
                assert (in.senderAddress == ADMIN_ADDRESS) throw Errors.SenderNotAllowed;
                assert (
                    storage.activeRoundCount == 0 && storage.lockedFunds == 0 &&
                    storage.openBetCounts.isEmpty()
                ) throw Errors.ContractNotIdle;

                val newKey = msg.oraclePublicKey;
                val newConfigCell = msg.config;
                val newConfig = newConfigCell.load();

                assert (
                    newConfig.roundDuration >= MIN_ROUND_DURATION &&
                    newConfig.roundDuration <= ONE_DAY &&
                    newConfig.roundDuration % ROUND_DURATION_STEP == 0
                ) throw Errors.InvalidConfig;
                assert (
                    newConfig.feeBps <= MAX_FEE_BPS && newConfig.betFee <= MAX_BET_FEE
                ) throw Errors.InvalidConfig;
                assert (
                    newConfig.minOpValue >= MIN_OP_VALUE_LIMIT &&
                    newConfig.minOpValue <= MAX_OP_VALUE_LIMIT &&
                    newConfig.reserveExtra >= MIN_RESERVE_EXTRA
                ) throw Errors.InvalidConfig;
                assert (
                    newConfig.priceWindow >= MIN_PRICE_WINDOW &&
                    newConfig.priceWindow <= newConfig.roundDuration &&
                    newConfig.refundDelay >= newConfig.priceWindow &&
                    newConfig.refundDelay <= ONE_DAY
                ) throw Errors.InvalidConfig;
                assert (
                    newConfig.maxBettorsPerRound > 0 && newConfig.maxActiveRounds > 0 &&
                    newConfig.maxActiveRounds <= MAX_ACTIVE_ROUNDS_LIMIT &&
                    newConfig.payoutBatchSize > 0 &&
                    newConfig.payoutBatchSize <= MAX_PAYOUT_BATCH &&
                    newConfig.payoutBatchSize <= newConfig.maxBettorsPerRound
                ) throw Errors.InvalidConfig;
                assert (
                    newConfig.betSize1 > 0 && newConfig.betSize1 < newConfig.betSize2 &&
                    newConfig.betSize2 <
                    newConfig.betSize3 &&
                    newConfig.betSize3 <
                    newConfig.betSize4 &&
                    newConfig.betSize4 <= MAX_BET_SIZE
                ) throw Errors.InvalidConfig;
                assert (newConfig.treasury.getWorkchain() == BASECHAIN) throw Errors.InvalidConfig;
                assert (newKey > 0) throw Errors.InvalidConfig;
                assert (
                    newConfig.treasury == config.treasury || storage.protocolFees == 0
                ) throw Errors.TreasuryChangeWithFees;

                storage.oraclePublicKey = newKey;
                storage.config = newConfigCell;
            }
        }
    } else {
        // a text bet: op 0, then exactly "Long" or "Short", with no refs
        assert (bodyReader.remainingRefsCount() == 0) throw Errors.InvalidBetText;

        var side = 0;
        if (
            bodyReader.remainingBitsCount() == 32 &&
            bodyReader.loadUint(32) == BET_TEXT_LONG.toBase256()
        ) {
            side = SIDE_LONG;
        } else if (
            bodyReader.remainingBitsCount() == 40 &&
            bodyReader.preloadUint(40) == BET_TEXT_SHORT.toBase256()
        ) {
            side = SIDE_SHORT;
        }
        assert (side != 0) throw Errors.InvalidBetText;

        storage.placeBet(side, in.senderAddress, in.valueCoins);
    }

    storage.save();

    // keep the locked funds, the protocol fees and `reserveExtra`; if the balance is too small,
    // the transaction fails
    reserveGramsOnBalance(
        storage.lockedFunds + storage.protocolFees + storage.config.load().reserveExtra,
        RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
    );
}

/// Returns the full contract data cell.
get fun get_state(): cell {
    return contract.getData();
}

/// Returns the admin address, the oracle public key and the configuration cell.
get fun get_config(): (address, uint256, Cell<Config>) {
    val storage = Storage.load();
    return (ADMIN_ADDRESS, storage.oraclePublicKey, storage.config);
}

/// Returns the round cell for a round start time. Returns null if the round is not found.
get fun get_round(roundTs: uint32): Cell<Round>? {
    val storage = Storage.load();
    val roundLookup = storage.rounds.get(roundTs);
    if (roundLookup.isFound) {
        return roundLookup.loadValue();
    }
    return null;
}
