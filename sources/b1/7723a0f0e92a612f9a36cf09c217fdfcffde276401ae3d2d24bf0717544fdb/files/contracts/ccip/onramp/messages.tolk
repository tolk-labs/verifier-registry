// SPDX-License-Identifier: BUSL-1.1
import "types"
import "../router/messages"
import "../../lib/utils"
import "../../lib/funding/withdrawable"
import "../../lib/versioning/upgradeable"
import "../ccipsend_executor/messages"
import "../fee_quoter/messages"
import "../ccipsend_executor/types"
import "../fee_quoter/types"

type OnRamp_InMessage =
    | OnRamp_Send
    | OnRamp_GetValidatedFee<RemainingBitsAndRefs>
    | FeeQuoter_MessageValidated<OnRamp_GetValidatedFeeContext>
    | FeeQuoter_MessageValidationFailed<OnRamp_GetValidatedFeeContext>
    | OnRamp_ExecutorFinishedSuccessfully
    | OnRamp_ExecutorFinishedWithError
    | OnRamp_SetDynamicConfig
    | OnRamp_UpdateDestChainConfigs
    | OnRamp_UpdateSendExecutor
    | OnRamp_UpdateAllowlists
    | OnRamp_WithdrawFeeTokens
    | Upgradeable_Upgrade
    ;

type OnRamp_NotificationInMessage =
    | OnRamp_Send
    ;

struct (0xdcf993c2) OnRamp_Send {
    // queryId is embedded in the first element of CCIPSend
    msg: Cell<Router_CCIPSend>;
    metadata: Metadata
}

struct (0x9c2ccc7e) OnRamp_GetValidatedFee<T> {
    ccipSend: Cell<Router_CCIPSend>;
    context: T;
}

struct OnRamp_GetValidatedFeeContext {
    onrampContext: address; // router address
    userContext: RemainingBitsOrRef<RemainingBitsAndRefs>,
}

struct (0xa178c62e) OnRamp_SetDynamicConfig {
    config: OnRamp_DynamicConfig
}

struct (0xCFA6B336) OnRamp_ExecutorFinishedSuccessfully {
    executorID: CCIPSendExecutor_ID,
    fee: Fee
    msg: Cell<Router_CCIPSend>
    metadata: Metadata
}

struct (0xC4068E21) OnRamp_ExecutorFinishedWithError {
    executorID: CCIPSendExecutor_ID,
    error: uint256,
    msg: Cell<Router_CCIPSend>,
    metadata: Metadata,
}

struct (0x1a246b6c) OnRamp_UpdateDestChainConfigs {
    updates: SnakedCell<OnRampUpdateDestChainConfig>;
}

struct (0x82901c45) OnRamp_UpdateSendExecutor {
    code: cell;
}

struct (0x9dc06185) OnRamp_UpdateAllowlists {
    updates: SnakedCell<UpdateAllowlist>;
}

// --- Outgoing messages ---

// crc32('OnRamp_MessageValidated')
struct (0x2afb11bd) OnRamp_MessageValidated<T> {
    fee: coins
    msg: Cell<Router_CCIPSend>
    context: T
}

// crc32('OnRamp_MessageValidationFailed')
struct (0xac1dd12e) OnRamp_MessageValidationFailed<T> {
    error: uint256,
    msg: Cell<Router_CCIPSend>,
    context: T
}

struct (0x7052dc75) OnRamp_WithdrawFeeTokens {
    feeTokens: SnakedCell<address>;
}

// Costs associated with OnRamp operations
struct OnRamp_Costs {}

// Minimum value for calling OnRamp_GetValidatedFee
@inline
fun OnRamp_Costs.GetValidatedFee(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // GetValidatedFee fwdFee
        + FeeQuoter_Costs.GetValidatedFee()
        + max(
            OnRamp_Costs.FeeQuoter_MessageValidated(),
            OnRamp_Costs.FeeQuoter_MessageValidationFailed()
        )
        ;
}

// Minimum value for calling FeeQuoter_MessageValidated on OnRamp
@inline
fun OnRamp_Costs.FeeQuoter_MessageValidated(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // MessageValidated fwdFee
        ;
}

// Minimum value for calling FeeQuoter_MessageValidationFailed on OnRamp
@inline
fun OnRamp_Costs.FeeQuoter_MessageValidationFailed(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // MessageValidationFailed fwdFee
        ;
}

// Minimum value for calling OnRamp_Send
@inline
fun OnRamp_Costs.Send(): int {
    return
        + ton("0.002") // computeFee
        + SendExecutor_Costs.Deploy()
        + ton("0.019") // Execute fwdFee
        + SendExecutor_Costs.Execute()
        ;
}

// Minimum value for calling OnRamp_ExecutorFinishedSuccessfully
@inline
fun OnRamp_Costs.ExecutorFinishedSuccessfully(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // emit CCIPMessageSent event
        + ton("0.019") // MessageSent fwdFee
        + Router_Costs.MessageSent() 
        ;
}

// Minimum value for calling OnRamp_ExecutorFinishedWithError
@inline
fun OnRamp_Costs.ExecutorFinishedWithError(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // MessageRejected fwdFee
        + Router_Costs.MessageRejected()
        ;
}

// Minimum value for calling OnRamp_WithdrawFeeTokens
@inline
fun OnRamp_Costs.WithdrawFeeTokens(): int {
    return
        + ton("0.02") // computeFee
        + ton("0.019") // feeTokens fwdFee
        + ton("0.05") // feeCollector computeFee
        ;
}