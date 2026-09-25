// Generated from the verified Tact contract ABI.
contract GameToken {
    storage: GameTokenData
    incomingMessages: GameTokenIncomingMessage
    thrownErrors: GameTokenErrors
}

struct (0x819dbe99) GameTokenChangeOwner {
    queryId: uint64
    newOwner: address
}

struct (0x946a98b6) GameTokenDeploy {
    queryId: uint64
}

struct (0xeaa7a948) GameTokenMintGenesis {
    queryId: uint64
    receiver: address
}

struct (0xe99bedd9) GameTokenRequestTokenWalletBinding {
    owner: address
}

struct (0x7bdd97de) GameTokenJettonBurnNotification {
    queryId: uint64
    amount: coins
    sender: address
    responseDestination: address
}

struct GameTokenJettonData {
    totalSupply: coins
    mintable: bool
    owner: address
    content: cell
    walletCode: cell
}

struct (0xfd6261c3) GameTokenUpdateContent {
    content: cell
}

struct GameTokenData {
    tactSystemCell: cell
    tactDeploymentCompleted: bool
    totalSupply: coins
    owner: address
    mintable: bool
    content: cell
}

type GameTokenIncomingMessage =
    | GameTokenRequestTokenWalletBinding
    | GameTokenMintGenesis
    | GameTokenJettonBurnNotification
    | GameTokenUpdateContent
    | GameTokenDeploy
    | GameTokenChangeOwner

enum GameTokenErrors {
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
    /// burn exceeds supply
    BurnExceedsSupply = 14024
    /// insufficient value for forward
    InsufficientValueForForward = 18373
    /// insufficient balance
    InsufficientBalance = 19364
    /// genesis supply already issued
    GenesisSupplyAlreadyIssued = 28227
    /// metadata is immutable after genesis
    MetadataIsImmutableAfterGenesis = 34247
    /// not owner
    NotOwner = 49280
    /// binding requester must be wallet owner
    BindingRequesterMustBeWalletOwner = 50738
    /// not a valid wallet
    NotAValidWallet = 52637
}

get fun get_wallet_address(owner: address): address {
    throw 0;
}

get fun get_jetton_data(): GameTokenJettonData {
    throw 0;
}

get fun max_supply(): int257 {
    throw 0;
}

get fun owner(): address {
    throw 0;
}
