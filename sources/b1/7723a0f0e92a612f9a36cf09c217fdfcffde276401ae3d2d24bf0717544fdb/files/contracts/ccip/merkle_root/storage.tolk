// SPDX-License-Identifier: BUSL-1.1
import "../offramp/types";
import "./errors"

struct MerkleRoot_Storage {
    root: uint256;
    owner: address;
    timestamp: uint64;
    minMsgNr: uint64;
    maxMsgNr: uint64;
    messageStates: uint128; // seq_num offset -> state (2 bits)
    deliveredMessageCount: uint16 = 0;
}

fun MerkleRoot_Storage.load(): MerkleRoot_Storage {
    return MerkleRoot_Storage.fromCell(contract.getData());
}

fun MerkleRoot_Storage.store(self) {
    return contract.setData(self.toCell());
}

fun MerkleRoot_Storage.expectedMessages(self) {
    return self.maxMsgNr - self.minMsgNr + 1
}

fun MerkleRoot_Storage.setMessageState(mutate self, seqNum: uint64, executionState: ExecutionState) {
    assert(seqNum >= self.minMsgNr && seqNum <= self.maxMsgNr, MerkleRoot_Error.SeqNumOutOfBounds);
    val i = seqNum - self.minMsgNr;
    assert(i < 64, MerkleRoot_Error.SeqNumOutOfBounds);

    // Clear the 2 bits at position 'i'
    self.messageStates &= ~(0b11 << (i * 2));
    // Set the new value in the cleared bits
    self.messageStates |= (executionState as int as uint128) << (i * 2);
}

fun MerkleRoot_Storage.getMessageState(self, seqNum: uint64): ExecutionState {
    assert(seqNum >= self.minMsgNr && seqNum <= self.maxMsgNr, MerkleRoot_Error.SeqNumOutOfBounds);
    val i= seqNum - self.minMsgNr;
    assert(i < 64, MerkleRoot_Error.SeqNumOutOfBounds);

    val mask = 0b11 << (i * 2);
    val state = (self.messageStates & mask) >> (i * 2);
    return state as ExecutionState
}
