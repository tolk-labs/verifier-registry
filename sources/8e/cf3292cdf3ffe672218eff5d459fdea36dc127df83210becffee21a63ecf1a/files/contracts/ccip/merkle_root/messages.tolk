// SPDX-License-Identifier: BUSL-1.1
import "../offramp/types"
import "../offramp/messages"

type MerkleRoot_InMessage = 
    | MerkleRoot_Validate
    | MerkleRoot_MarkState;

struct (0x038ede91) MerkleRoot_Validate {
    message: Cell<Any2TVMRampMessage>,
    permissionlessExecutionThresholdSeconds: uint32,
    metadataHash: uint256,
    gasOverride: coins?,
}

//crc32('MerkleRoot_MarkState')
struct (0x019f4cd2) MerkleRoot_MarkState {
    seqNum: uint64,
    state: ExecutionState
}

struct MerkleRoot_Costs{}

fun MerkleRoot_Costs.validate(): int {
    val baseFee = MERKLE_ROOT_COSTS_VALIDATE_FEE; // validateFees
    return baseFee + OffRamp_Costs.executeValidated();
}

fun MerkleRoot_Costs.markState(): int {
    return MERKLE_ROOT_COSTS_MARK_STATE_FEE;
}

const MERKLE_ROOT_COSTS_MARK_STATE_FEE = ton("0.005");
const MERKLE_ROOT_COSTS_VALIDATE_FEE = ton("0.012");

