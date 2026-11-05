tolk 1.5

/// FlipCoin is a heads-or-tails game funded by its own balance.
/// A player bets by sending a text comment naming a side, and a win pays double the bet.
/// Each bet is settled in the transaction that receives it, so no player funds are held.
contract FlipCoin {
    author: "TON Core (maybe)"
    version: "1.0.0"
    description: "Source code reconstructed by @ai_terminal. Heads-or-tails game that pays winners double from the contract balance."
    storage: Storage
    incomingMessages: AllowedMessage
}

/// Smallest accepted bet.
const MIN_BET = grams("0.05")

/// Balance a bet must leave on the contract after paying out, before fees.
const BALANCE_RESERVE = grams("0.1")

/// Exit codes thrown by the contract.
enum Errors {
    /// A non-empty message that is not a text comment.
    UnknownMessage = 0xFFFF
}

/// Heads, numbered as `random.range(2)` draws it.
const SIDE_HEADS = 0

/// Tails, numbered as `random.range(2)` draws it.
const SIDE_TAILS = 1

/// Persistent contract data.
struct Storage {
    /// The only address that can withdraw the balance. It can't be changed.
    admin: address
    /// Bets played so far. Refunded bets don't count.
    gamesPlayed: uint32
    /// Bets won by players so far.
    playerWins: uint32
}

/// Reads storage from the contract data.
fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

/// Writes storage to the contract data.
fun Storage.save(self): void {
    contract.setData(self.toCell());
}

/// Standard text comment: op 0 followed by the text. Bets arrive as one, replies leave as one.
struct (0x00000000) TextComment {
    /// The comment text, without the opcode.
    text: RemainingBitsAndRefs
}

/// Messages with a body that the contract accepts. Empty messages are handled separately.
type AllowedMessage = TextComment

/// Reply of the `stats` getter.
struct StatsReply {
    /// Bets played so far. Refunded bets don't count.
    gamesPlayed: uint32
    /// Bets won by players so far.
    playerWins: uint32
    /// Current contract balance.
    balance: coins
    /// Largest bet the contract would accept right now.
    maxBet: coins
}

/// Largest bet that `bankroll` can pay out while keeping the reserve.
fun maxBetFor(bankroll: coins): coins {
    return bankroll > BALANCE_RESERVE ? bankroll - BALANCE_RESERVE : 0;
}

/// Maps a comment to the side it bets on, or null if it is not a bet.
fun parseSide(text: slice): int? {
    if (text.bitsEqual("heads".literalSlice())) {
        return SIDE_HEADS;
    }
    if (text.bitsEqual("tails".literalSlice())) {
        return SIDE_TAILS;
    }
    return null;
}

/// Sends a non-bounceable message carrying `text` as a comment.
fun sendComment(to: address, value: coins, text: slice, mode: int): void {
    val commentMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value,
        body: TextComment { text },
    });

    commentMessage.send(mode);
}

/// Returns the incoming bet, less fees, with the reason as a comment.
fun refundBet(player: address, reason: slice): void {
    sendComment(
        player,
        0,
        reason,
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
    );
}

/// Refunds a bet the contract can't take; otherwise flips the coin and pays out any win.
fun handleBet(mutate storage: Storage, player: address, bet: coins, betSide: int): void {
    if (bet < MIN_BET) {
        refundBet(player, "Bet refunded: the minimum bet is 0.05".literalSlice());
    } else if (maxBetFor(contract.getOriginalBalance() - bet) < bet) {
        // The balance already includes this bet, so it does not count as bankroll.
        refundBet(player, "Bet refunded: the bankroll cannot cover it".literalSlice());
    } else {
        val (_, playerAddressHash) = player.getWorkchainAndHash();

        // Validators can influence the block seed, so this draw is not manipulation-proof.
        random.initialize();
        random.initializeBy(playerAddressHash ^ storage.gamesPlayed);
        val drawnSide = random.range(2);

        storage.gamesPlayed += 1;

        if (drawnSide == betSide) {
            storage.playerWins += 1;

            val payout = bet * 2;

            val headsComment = "You won: heads".literalSlice();
            val tailsComment = "You won: tails".literalSlice();
            val winComment = (drawnSide != SIDE_HEADS) ? tailsComment : headsComment;

            sendComment(player, payout, winComment, SEND_MODE_PAY_FEES_SEPARATELY);
        }

        storage.save();
    }
}

/// Everything this contract sends is non-bounceable, so nothing is expected back.
fun onBouncedMessage(_in: InMessageBounced) {}

/// Handles admin withdrawals, bets and top-ups.
fun onInternalMessage(in: InMessage) {
    var storage = lazy Storage.load();

    // An empty message from the admin withdraws the whole balance.
    if (in.body.isEmpty() && in.senderAddress == storage.admin) {
        val withdrawalMessage = createMessage({
            bounce: BounceMode.NoBounce,
            dest: storage.admin,
            value: 0,
        });

        // SAFETY: only the admin reaches this send, and draining the contract is its purpose.
        withdrawalMessage.send(SEND_MODE_CARRY_ALL_BALANCE);

        return;
    }

    val msg = lazy AllowedMessage.fromSlice(in.body);

    match (msg) {
        TextComment => {
            val betSide = parseSide(msg.text);

            if (betSide == null) {
                // Any other comment is not a bet: the value stays on the contract.
                return;
            }

            handleBet(mutate storage, in.senderAddress, in.valueCoins, betSide);
        }

        else => {
            // Empty messages from anyone but the admin are bankroll top-ups; the rest are rejected.
            assert (in.body.isEmpty()) throw Errors.UnknownMessage;
        }
    }
}

/// Returns the game counters, the balance and the current bet limit.
get fun stats(): StatsReply {
    val storage = lazy Storage.load();
    val balance = contract.getOriginalBalance();

    return {
        gamesPlayed: storage.gamesPlayed,
        playerWins: storage.playerWins,
        balance,
        maxBet: maxBetFor(balance),
    };
}

/// Returns the admin address.
get fun admin(): address {
    val storage = lazy Storage.load();

    return storage.admin;
}
