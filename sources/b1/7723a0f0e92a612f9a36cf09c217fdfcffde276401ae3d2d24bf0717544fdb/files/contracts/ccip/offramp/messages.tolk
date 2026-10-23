// SPDX-License-Identifier: BUSL-1.1
import "types"
import "../../lib/ocr/types.tolk"
import "../../lib/ocr/multi_ocr3_base.tolk"
import "../../lib/utils"
import "../../lib/funding/withdrawable"
import "../../lib/versioning/upgradeable"
import "../../lib/deployable/types"
import "../common/types.tolk"
import "../rmn_remote/lib"
import "../merkle_root/messages"
import "../receive_executor/messages"
import "../fee_quoter/messages"
import "../router/messages"

type OffRamp_InMessage =
    | OffRamp_Commit
    | OffRamp_Execute
    | OffRamp_ExecuteValidated
    | OffRamp_ManuallyExecute
    | OffRamp_DispatchValidated
    | OffRamp_UpdateSourceChainConfigs
    | OffRamp_CCIPReceiveConfirm
    | OffRamp_CCIPReceiveBounced
    | OffRamp_NotifyFailure
    | OffRamp_NotifySuccess
    | OffRamp_UpdateCursedSubjects
    | OffRamp_SetDynamicConfig
    | OCR3Base_SetOCR3Config
    | OffRamp_UpdateDeployables
    | Upgradeable_Upgrade
    | Withdrawable_Withdraw;

type OffRamp_InMessageBounced = 
    | ReceiveExecutor_InitExecute
    | Deployable_Initialize
    | Router_RouteMessage;

struct (0x9d431905) OffRamp_Commit {
    queryId: uint64;
    reportContext: ReportContext;
    report: CommitReport;
    signatures: SnakedCell<SignatureEd25519>;
}

struct (0x27bdac33) OffRamp_Execute {
    queryId: uint64;
    reportContext: ReportContext;
    report: ExecutionReport;
}

struct (0xc73d5a8a) OffRamp_ExecuteValidated {
    message: Cell<Any2TVMRampMessage>;
    root: MerkleRootId;
    metadataHash: uint256;
    gasOverride: coins?;
    executionState: ExecutionState;
}

struct (0xa00785cf) OffRamp_ManuallyExecute {
    queryId: uint64;
    report: ExecutionReport;
    gasOverride: coins; 
}

//Must be sent by owner
struct (0x22b4f05c) OffRamp_UpdateSourceChainConfigs {
    queryId: uint64;
    configs: SnakedCell<SourceChainConfigUpdate>; // Array of configs
}

struct SourceChainConfigUpdate {
    sourceChainSelector: uint64;
    config: SourceChainConfig;
}

//Must be sent from an owned ReceiveExecutor contract
struct (0x58cfcb02) OffRamp_DispatchValidated { 
    message: Cell<Any2TVMRampMessage>;
    execId: uint192;
    gasOverride: coins?;
}

struct (0x28f4166f) OffRamp_CCIPReceiveConfirm {
    execId: ReceiveExecutorId;
    receiver: address;
}

struct (0x2dcf2a43) OffRamp_CCIPReceiveBounced {
    execId: ReceiveExecutorId;
    receiver: address;
}

struct (0x59e56170) OffRamp_NotifySuccess {
    header: RampMessageHeader;
    execId: ReceiveExecutorId;
    root: address;
}

struct (0x177ebd03) OffRamp_NotifyFailure {
    header: RampMessageHeader;
    execId: ReceiveExecutorId;
    root: address;
}

struct (0x4ca1bcb3) OffRamp_UpdateCursedSubjects {
    cursedSubjects: CursedSubjects
}

struct (0x95bc5a5c) OffRamp_SetDynamicConfig {
    queryId: uint64;
    feeQuoter: address;
    permissionlessExecutionThresholdSeconds: uint32,
}

struct (0xa015e0e2) OffRamp_UpdateDeployables {
    queryId: uint64;
    receiveExecutorCode: cell?;
    merkleRootCode: cell?;
}

struct OffRamp_Costs{}

fun OffRamp_Costs.executeValidated(): int {
    val baseFee = OFFRAMP_COSTS_EXECUTE_VALIDATED_FEE;
    return baseFee + AMOUNT_FOR_RECEIVE_EXECUTOR_DEPLOYMENT + ReceiveExecutor_Costs.initExec();
}

fun OffRamp_Costs.dispatchValidated(): int {
    val baseFee = OFFRAMP_COSTS_DISPATCH_VALIDATED_FEE;
    return baseFee + Router_Costs.routeMessage();
}

fun OffRamp_Costs.receiveConfirmOrDeny(): int {
    val baseFee = OFFRAMP_COSTS_CONFIRM_OR_DENY_FEE;
    return baseFee + ReceiveExecutor_Costs.confirmedOrBounced();
}

fun OffRamp_Costs.notify(): int {
    val baseFee = OFFRAMP_COSTS_NOTIFY_FEE;
    return baseFee + MerkleRoot_Costs.markState();
}

fun OffRamp_Costs.commit(priceUpdatesOnlyReport: bool): int {
    val baseFee = OFFRAMP_COSTS_COMMIT_FEE;
    if (priceUpdatesOnlyReport) {
        return baseFee + FeeQuoter_Costs.updatePrices();
    } else {
        val totalAmountForRoot = AMOUNT_FOR_MERKLE_ROOT_DEPLOYMENT;
        return baseFee + FeeQuoter_Costs.updatePrices() + totalAmountForRoot;
    }
}

fun OffRamp_Costs.execute(): int {
    val baseFee = OFFRAMP_COSTS_EXECUTE_FEE;
    return baseFee + MerkleRoot_Costs.validate();
}

const OFFRAMP_COSTS_EXECUTE_VALIDATED_FEE = ton("0.012");
const OFFRAMP_COSTS_DISPATCH_VALIDATED_FEE = ton("0.005");
const OFFRAMP_COSTS_NOTIFY_FEE = ton("0.004");
const OFFRAMP_COSTS_CONFIRM_OR_DENY_FEE = ton("0.004");
const OFFRAMP_COSTS_COMMIT_FEE = ton("0.015");
const OFFRAMP_COSTS_EXECUTE_FEE = ton("0.0125");
