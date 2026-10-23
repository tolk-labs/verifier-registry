// SPDX-License-Identifier: BUSL-1.1
import "types"

enum FeeQuoter_Error {
    UnsupportedChainFamilySelector = FeeQuoter_FACILITY_ID * 100
    GasLimitTooHigh
    ExtraArgOutOfOrderExecutionMustBeTrue
    InvalidExtraArgsData
    UnsupportedNumberOfTokens
    InvalidEVMReceiverAddress
    Invalid32ByteReceiverAddress
    InvalidSuiReceiverAddress
    InvalidSVMReceiverAddress
    InvalidTokenReceiver
    TooManySuiExtraArgsReceiverObjectIds
    MsgDataTooLarge
    StaleGasPrice
    DestChainNotEnabled
    FeeTokenNotSupported
    InvalidMsgData
    TokenNotSupported
    UnknownDestChainSelector
    InsufficientFee
    TokenTransfersNotSupported
    UnauthorizedPriceUpdater
    ExecutionCostOverflow // Unreachable
    PremiumFeeOverflow // Unreachable
    DataAvailabilityCostOverflow // Unreachable
    FeeCalculationOverflow // Unreachable
    TokenPriceTooLow
    FeeOverflow
    MessageFeeTooHigh
    TooManySVMExtraArgsAccounts
    InvalidSVMExtraArgsWritableBitmap
}
