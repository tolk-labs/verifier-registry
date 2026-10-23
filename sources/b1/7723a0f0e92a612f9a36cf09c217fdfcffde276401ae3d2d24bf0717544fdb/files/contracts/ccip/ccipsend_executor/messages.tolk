// SPDX-License-Identifier: BUSL-1.1
import "types"
import "storage"
import "../../lib/versioning/upgradeable"

import "../onramp/messages"
import "../router/messages"
import "../fee_quoter/messages"

type CCIPSendExecutor_InMessage =
    | CCIPSendExecutor_Execute
    | FeeQuoter_MessageValidated<RemainingBitsAndRefs>
    | FeeQuoter_MessageValidationFailed<RemainingBitsAndRefs>
    ;

// crc32('CCIPSendExecutor_Execute')
struct (0xaf3c62b3) CCIPSendExecutor_Execute {
    onrampSend: OnRamp_Send,
    config: Cell<CCIPSendExecutor_Config>,
}

// Costs associated with SendExecutor operations
struct SendExecutor_Costs {}

// Minimum value for deploying SendExecutor
@inline
fun SendExecutor_Costs.Deploy(): int {
    return ton("0.01");
}

// Minimum value for calling SendExecutor_GetValidatedFee
@inline
fun SendExecutor_Costs.Execute(): int {
    var baseFee =
        + ton("0.002") // computeFee
        + ton("0.019") // GetValidatedFee fwdFee
        + FeeQuoter_Costs.GetValidatedFee()
        + max(SendExecutor_Costs.MessageValidated(), SendExecutor_Costs.MessageValidationFailed())
        ;
    return baseFee;
}

@inline
fun SendExecutor_Costs.MessageValidated(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // ExecutorFinishedSuccessfully fwdFee
        + OnRamp_Costs.ExecutorFinishedSuccessfully();
}

@inline
fun SendExecutor_Costs.MessageValidationFailed(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // ExecutorFinishedWithError fwdFee
        + OnRamp_Costs.ExecutorFinishedWithError();
}

type CCIPSendExecutor_BouncedMessage =
    | FeeQuoter_GetValidatedFee<RemainingBitsAndRefs>
    ;