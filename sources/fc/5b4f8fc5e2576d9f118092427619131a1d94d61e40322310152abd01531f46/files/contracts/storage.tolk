/// The bet of one bettor in one round. A bettor bets on one side only.
struct Bet {
    /// The amount on "the price goes up".
    long: coins
    /// The amount on "the price goes down".
    short: coins
}

/// The round has no result yet.
const RESULT_OPEN = 0

/// The close price is higher than the open price: the "Long" bettors win.
const RESULT_LONG = 1

/// The close price is lower than the open price: the "Short" bettors win.
const RESULT_SHORT = 2

/// All bettors get their bets back.
const RESULT_REFUND = 3

/// One prediction round. The key in the rounds map is the round start time.
struct Round {
    /// The oracle price at the round start. 0: no price.
    openPrice: uint64
    /// The oracle price at the round end. 0: no price.
    closePrice: uint64
    /// The sum of all "Long" bets.
    longPool: coins
    /// The sum of all "Short" bets.
    shortPool: coins
    /// The amount that is not paid out yet. After the last payout, it goes to the protocol fees.
    unpaidPool: coins
    /// The number of bettors that are not paid out yet.
    unpaidBettorCount: uint8
    /// One of the `RESULT_*` values.
    result: uint2
    /// The bets that are not paid out yet, by bettor address.
    bets: map<address, Cell<Bet>>
}

/// The contract settings. The admin changes them with `UpdateOracleAndConfig`.
struct Config {
    /// The round length, in seconds.
    roundDuration: uint32
    /// The protocol fee, in basis points of the losing pool.
    feeBps: uint16
    /// The amount that the contract keeps from each bet message.
    betFee: uint64
    /// The minimum value of an operation message. The contract also attaches this value
    /// to each `ProcessPayouts` message that it sends to itself.
    minOpValue: uint64
    /// The balance that the contract keeps in addition to the locked funds and the protocol fees.
    reserveExtra: uint64
    /// The time after the round start in which the oracle can send the price, in seconds.
    priceWindow: uint32
    /// The time after the round end after which any sender can refund the round, in seconds.
    refundDelay: uint32
    /// The maximum number of bettors in one round.
    maxBettorsPerRound: uint8
    /// The maximum number of rounds that are not fully paid out.
    maxActiveRounds: uint8
    /// The maximum number of payouts in one transaction.
    payoutBatchSize: uint8
    /// The permitted bet sizes, from the smallest to the largest.
    betSize1: uint64
    betSize2: uint64
    betSize3: uint64
    betSize4: uint64
    /// The address that gets the protocol fees.
    treasury: address
}

/// The contract data. The field order and the field sizes are the same as in the deployed contract.
struct Storage {
    /// The global ID of the network (-239: mainnet, -3: testnet). It is part of the signed price.
    networkId: int32
    /// The public key of the price oracle.
    oraclePublicKey: uint256
    /// The start time of the last round that got a price.
    lastRoundTs: uint32
    /// The last price from the oracle.
    lastPrice: uint64
    /// The sum of the bets that are not paid out yet.
    lockedFunds: coins
    /// The protocol fees that are not withdrawn yet.
    protocolFees: coins
    /// The number of rounds that are not fully paid out.
    activeRoundCount: uint8
    /// The rounds, by round start time.
    rounds: map<uint32, Cell<Round>>
    /// The number of open bets of each bettor, by bettor address. A bettor can have one bet
    /// in each round.
    openBetCounts: map<address, uint32>
    /// The contract settings.
    config: Cell<Config>
}

/// Loads the contract data.
fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

/// Saves the contract data.
fun Storage.save(self) {
    contract.setData(self.toCell());
}
