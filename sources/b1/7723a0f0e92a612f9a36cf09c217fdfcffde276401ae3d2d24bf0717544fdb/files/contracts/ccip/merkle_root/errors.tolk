// SPDX-License-Identifier: BUSL-1.1
import "types"

enum MerkleRoot_Error {
    AlreadyExecuted = MerkleRoot_FACILITY_ID * 100
    NotOwner
    ManualExecutionNotYetEnabled
    SkippedAlreadyExecutedMessage
    InvalidState
    SeqNumOutOfBounds
}
