// Generated from the verified Tact contract ABI.
contract Lottery {
    storage: LotteryData
    incomingMessages: LotteryIncomingMessage
    thrownErrors: LotteryErrors
}

struct (0x946a98b6) LotteryDeploy {
    queryId: uint64
}

struct (0xb4b86e5a) LotteryBuyTicket {
}

struct LotteryData {
    tactDeploymentCompleted: bool
    owner: address
    round: uint32
    nextDrawTs: uint64
    participantsCount: uint32
    participants: map<int257, address>
    joined: map<address, bool>
    lastWinner: address
    lastReward: coins
    lastRound: uint32
    totalRounds: uint32
}

type LotteryIncomingMessage =
    | LotteryBuyTicket
    | LotteryDeploy

enum LotteryErrors {
    /// Stack underflow
    StackUnderflow = 2
    /// Stack overflow
    StackOverflow = 3
    /// Integer overflow
    IntegerOverflow = 4
    /// Integer out of expected range
    IntegerOutOfExpectedRange = 5
    /// Invalid opcode
    InvalidOpcode = 6
    /// Type check error
    TypeCheckError = 7
    /// Cell overflow
    CellOverflow = 8
    /// Cell underflow
    CellUnderflow = 9
    /// Dictionary error
    DictionaryError = 10
    /// 'Unknown' error
    UnknownError = 11
    /// Fatal error
    FatalError = 12
    /// Out of gas error
    OutOfGasError = 13
    /// Virtualization error
    VirtualizationError = 14
    /// Action list is invalid
    ActionListIsInvalid = 32
    /// Action list is too long
    ActionListIsTooLong = 33
    /// Action is invalid or not supported
    ActionIsInvalidOrNotSupported = 34
    /// Invalid source address in outbound message
    InvalidSourceAddressInOutboundMessage = 35
    /// Invalid destination address in outbound message
    InvalidDestinationAddressInOutboundMessage = 36
    /// Not enough Toncoin
    NotEnoughToncoin = 37
    /// Not enough extra currencies
    NotEnoughExtraCurrencies = 38
    /// Outbound message does not fit into a cell after rewriting
    OutboundMessageDoesNotFitIntoACellAfterRewriting = 39
    /// Cannot process a message
    CannotProcessAMessage = 40
    /// Library reference is null
    LibraryReferenceIsNull = 41
    /// Library change action error
    LibraryChangeActionError = 42
    /// Exceeded maximum number of cells in the library or the maximum depth of the Merkle tree
    ExceededMaximumNumberOfCellsInTheLibraryOrTheMaximumDepthOfTheMerkleTree = 43
    /// Account state size exceeded limits
    AccountStateSizeExceededLimits = 50
    /// Null reference exception
    NullReferenceException = 128
    /// Invalid serialization prefix
    InvalidSerializationPrefix = 129
    /// Invalid incoming message
    InvalidIncomingMessage = 130
    /// Constraints error
    ConstraintsError = 131
    /// Access denied
    AccessDenied = 132
    /// Contract stopped
    ContractStopped = 133
    /// Invalid argument
    InvalidArgument = 134
    /// Code of a contract was not found
    CodeOfAContractWasNotFound = 135
    /// Invalid standard address
    InvalidStandardAddress = 136
    /// Not a basechain address
    NotABasechainAddress = 138
    /// Insufficient balance for reward
    InsufficientBalanceForReward = 4191
    /// This wallet already has a ticket in current round
    ThisWalletAlreadyHasATicketInCurrentRound = 8646
    /// Ticket sale closed; wait for next round
    TicketSaleClosedWaitForNextRound = 28918
    /// Send at least 1 TON (ticket + gas buffer)
    SendAtLeast1TONTicketGasBuffer = 35961
    /// Draw time not reached
    DrawTimeNotReached = 62768
}

get fun owner(): address {
    throw 0;
}

get fun round(): int257 {
    throw 0;
}

get fun nextDrawTs(): int257 {
    throw 0;
}

get fun participantsCount(): int257 {
    throw 0;
}

get fun totalRounds(): int257 {
    throw 0;
}

get fun ticketPrice(): int257 {
    throw 0;
}

get fun minPayment(): int257 {
    throw 0;
}

get fun hasJoined(addr: address): bool {
    throw 0;
}

get fun participantAt(idx: int257): address {
    throw 0;
}

get fun lastWinner(): address {
    throw 0;
}

get fun lastReward(): int257 {
    throw 0;
}

get fun lastRound(): int257 {
    throw 0;
}

get fun contractBalance(): int257 {
    throw 0;
}
