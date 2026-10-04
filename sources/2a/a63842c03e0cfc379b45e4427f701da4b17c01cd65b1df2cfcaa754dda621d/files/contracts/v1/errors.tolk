enum Errors {
    BalanceError = 47
    NotEnoughGas = 48
    InvalidMessage = 49
    InvalidOp = 72
    NotOwner = 73
    NotValidWallet = 74
    WrongWorkchain = 333
}

// Reference wallet error aliases.
const ERROR_NOT_OWNER = Errors.NotOwner
const ERROR_NOT_VALID_WALLET = Errors.NotValidWallet
const ERROR_WRONG_WORKCHAIN = Errors.WrongWorkchain
const ERROR_BALANCE_ERROR = Errors.BalanceError
