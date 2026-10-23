// SPDX-License-Identifier: BUSL-1.1
import "types"
import "../fee_quoter/types"

const EXECUTION_STATE_CHANGED_TOPIC: int = stringCrc32("ExecutionStateChanged");
struct ExecutionStateChanged {
    sourceChainSelector: uint64,
    sequenceNumber: uint64,
    messageId: uint256,
    state: ExecutionState,
}

const TOPIC_COMMIT_REPORT_ACCEPTED: int = stringCrc32("CommitReportAccepted");
struct CommitReportAccepted {
    merkleRoot: MerkleRoot? // vec<MerkleRoots>
    priceUpdates: Cell<PriceUpdates>?;
}

const SOURCE_CHAIN_SELECTOR_ADDED_TOPIC: int = stringCrc32("SourceChainSelectorAdded");
struct SourceChainSelectorAdded {
    sourceChainSelector: uint64;
}

const SOURCE_CHAIN_CONFIG_UPDATED_TOPIC: int = stringCrc32("SourceChainConfigUpdated");
struct SourceChainConfigUpdated {
    sourceChainSelector: uint64;
    sourceChainConfig: SourceChainConfig;
}

const DYNAMIC_CONFIG_SET_TOPIC: int = stringCrc32("DynamicConfigSet");
struct OffRamp_DynamicConfigSet {
    feeQuoter: address;
    permissionlessExecutionThresholdSeconds: uint32,
}

const RECEIVE_EXECUTOR_INIT_EXECUTE_BOUNCED: int = stringCrc32("ReceiveExecutorInitExecuteBounced");
struct OffRamp_ReceiveExecutorInitExecuteBounced {
    receiveExecutor: address;
    root: address;
    sequenceNumber: uint64;
}

const DEPLOYABLE_INITIALIZE_BOUNCED_TOPIC: int = stringCrc32("DeployableInitializeBounced");
struct OffRamp_DeployableInitializeBounced {
    deployableAddress: address;
}

const ROUTE_MESSAGE_BOUNCED_TOPIC: int = stringCrc32("RouteMessageBounced");
struct OffRamp_RouteMessageBounced {
    router: address;
    execId: uint192;
}
