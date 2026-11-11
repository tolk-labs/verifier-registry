import "storage"

/// The opcode of `AdminWithdraw`. The contract checks it before it loads the storage.
const OP_ADMIN_WITHDRAW = 0x544D5006

/// Admin → contract: sends `amount` from the contract balance to the admin.
struct (0x544D5006) AdminWithdraw {
    amount: coins
}

/// Anyone → contract: the signed oracle price at the start of a round.
/// The price opens this round and closes the previous round.
struct (0x544D5001) SubmitPrice {
    /// The round start time. It must be a multiple of `roundDuration`.
    roundTs: uint32
    /// The oracle price. It must not be 0.
    price: uint64
    /// The 512-bit Ed25519 signature of `PricePayload`, with no refs.
    signature: cell
}

/// Contract → contract: pays the next batch of bettors of a closed round.
/// Any sender can send it.
struct (0x544D5002) ProcessPayouts {
    roundTs: uint32
}

/// Anyone → contract: refunds a round that has no result after the refund delay.
struct (0x544D5003) ForceRefund {
    roundTs: uint32
}

/// Treasury → contract: withdraws all protocol fees.
struct (0x544D5004) WithdrawFees {}

/// Admin → contract: sets a new oracle key and a new configuration.
/// The contract must have no active rounds, no locked funds and no bettors.
struct (0x544D5005) UpdateOracleAndConfig {
    oraclePublicKey: uint256
    config: Cell<Config>
}

/// The operation messages. The opcodes are the same as in the deployed contract.
/// An unknown opcode causes exit code 63.
type AllowedMessage =
    | SubmitPrice
    | ProcessPayouts
    | ForceRefund
    | WithdrawFees
    | UpdateOracleAndConfig

/// The data that the oracle signs. The contract checks the signature of its cell hash.
struct (0x544D5031) PricePayload {
    networkId: int32
    contractAddress: address
    roundTs: uint32
    price: uint64
}

/// The body of an outgoing payment: op 0 and a ref to the comment text.
struct (0x00000000) TextComment {
    text: string
}

/// The text of a "Long" bet (op 0, then this text).
const BET_TEXT_LONG = "Long"

/// The text of a "Short" bet (op 0, then this text).
const BET_TEXT_SHORT = "Short"
