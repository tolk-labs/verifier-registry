// SPDX-License-Identifier: BUSL-1.1
import "types"
import "../common/types.tolk"
import "../../lib/utils"
import "../../lib/funding/withdrawable.tolk";
import "../../lib/versioning/upgradeable"
import "../../lib/receiver/types"
import "../../lib/receiver/messages"
import "../offramp/types"
import "../offramp/messages"
import "../onramp/messages"

type Router_InMsg =
    | Router_CCIPSend
    | Router_ApplyRampUpdates
    | Router_GetValidatedFee<RemainingBitsAndRefs>
    | OnRamp_MessageValidated<Router_GetValidatedFeeContext>
    | OnRamp_MessageValidationFailed<Router_GetValidatedFeeContext>
    | Router_RouteMessage
    | Router_CCIPReceiveConfirm
    | Upgradeable_Upgrade
    | Withdrawable_Withdraw
    | Router_RMNRemoteCurse
    | Router_RMNRemoteUncurse
    | Router_RMNRemoteVerifyNotCursed
    | Router_MessageSent
    | Router_MessageRejected
    | Router_RMNOwnableMessage
    ;

type Router_BouncedMessage = 
    | Receiver_CCIPReceive
    | OffRamp_CCIPReceiveConfirm
    | OffRamp_CCIPReceiveBounced;

// update multiple chain selectors in batch to the same onramp/offramp address
struct (0x7db6745d) Router_ApplyRampUpdates {
    queryId: uint64;
    onRampUpdates: OnRamps?;
    offRampAdds: OffRamps?;
    offRampRemoves: OffRamps?;
}

// Answers with Router_CCIPReceive
struct (0x31768d95) Router_CCIPSend {
    queryID: uint64;
    destChainSelector: uint64;
    receiver: CrossChainAddress;
    data: cell;
    tokenAmounts: SnakedCell<TokenAmount>;
    feeToken: address?;
    extraArgs: cell;
}

struct (0xfc69c50b) Router_RouteMessage {
    message: Cell<Any2TVMMessage>;
    execId: ReceiveExecutorId;
    receiver: address;
    gasLimit: coins;
}

struct (0x1e55bbf6) Router_CCIPReceiveConfirm {
    execId: ReceiveExecutorId;
}

// curse/uncurse/verify uncursed (also as getter)
struct (0xf3388046) Router_RMNRemoteCurse {
    queryId: uint64
    subjects: SnakedCell<uint128>
}

struct (0x3f153a31) Router_RMNRemoteUncurse {
    queryId: uint64
    subjects: SnakedCell<uint128>
}

// Internal contracts can have their own cache, but external contracts will need to fetch the curse status via this method.
struct (0x0b95aa4e) Router_RMNRemoteVerifyNotCursed {
    queryId: uint64
    subject: uint128
}

struct (0x22ba83b3) Router_RMNRemoteVerifyNotCursedResponse {
    queryId: uint64
    result: bool
}

struct (0x6513f8e1) Router_MessageSent {
    queryID: uint64;
    messageId: uint256;
    destChainSelector: uint64;
    sender: address;
}

struct (0x8ae25114) Router_MessageRejected {
    queryID: uint64;
    destChainSelector: uint64;
    sender: address;
    error: uint256;
}

struct (0xaf7a9ac6) Router_RMNOwnableMessage {
    content: RemainingBitsAndRefs; // Ownable2Step_Messages
}

struct (0x78d0f21e) Router_CCIPSendACK {
    queryID: uint64;
    messageId: uint256;
}

struct (0x5a45d434) Router_CCIPSendNACK {
    queryID: uint64;
    error: uint256;
}

struct (0x4dd6aa82) Router_GetValidatedFee<T> {
    ccipSend: Cell<Router_CCIPSend>;
    context: T;
}

struct Router_GetValidatedFeeContext {
    routerContext: address; // sender
    userContext: RemainingBitsOrRef<RemainingBitsAndRefs>,
}

// --- Outgoing messages ---

// crc32('Router_MessageValidated')
struct (0x9e2155ec) Router_MessageValidated<T> {
    fee: coins
    msg: Cell<Router_CCIPSend>
    context: T
}

// crc32('Router_MessageValidationFailed')
struct (0xec23c562) Router_MessageValidationFailed<T> {
    error: uint256,
    msg: Cell<Router_CCIPSend>,
    context: T
}

// Costs associated with Router operations
struct Router_Costs {}

// Minimum value for calling Router_CCIPSend
fun Router_Costs.CCIPSend(): int {
    return
        + ton("0.001") // computeFee
        + ton("0.019") // CCIPSend fwdFee
        + OnRamp_Costs.Send()
        ;
}

// Minimum value for calling Router_MessageSent
fun Router_Costs.MessageSent(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // CCIPSendACK fwdFee
        ;

}

// Minimum value for calling Router_MessageRejected
fun Router_Costs.MessageRejected(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // CCIPSendNACK fwdFee
        ;
}

// Minimum value for calling Router_GetValidatedFee
fun Router_Costs.GetValidatedFee(): int {
    return
        ton("0.002") // computeFee
        + ton("0.019") // GetValidatedFee fwdFee
        + OnRamp_Costs.GetValidatedFee()
        + max(
            Router_Costs.MessageValidated(),
            Router_Costs.MessageValidationFailed()
        )
        ;
}

fun Router_Costs.MessageValidated(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // MessageValidated fwdFee
        ;
}

fun Router_Costs.MessageValidationFailed(): int {
    return
        + ton("0.002") // computeFee
        + ton("0.019") // MessageValidationFailed fwdFee
        ;
}

// Minimum value for calling Router_RouteMessage
fun Router_Costs.routeMessage(): int {
    val baseFee = ton("0.004");
    return baseFee + Router_Costs.receiveConfirm();
}

// Minimum value for calling Router_CCIPReceiveConfirm
fun Router_Costs.receiveConfirm(): int {
    val baseFee = ROUTER_RECEIVE_CONFIRM_FEE;
    return baseFee + OffRamp_Costs.receiveConfirmOrDeny();
}

const ROUTER_RECEIVE_CONFIRM_FEE = ton("0.002");
