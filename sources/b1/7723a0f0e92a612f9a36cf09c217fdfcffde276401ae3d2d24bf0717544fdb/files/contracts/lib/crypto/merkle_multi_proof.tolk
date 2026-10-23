// SPDX-License-Identifier: MIT
import "../utils.tolk"

const MerkleMultiProof_FACILITY_ID= 120;  // (crc32(<facility>) % 640) + 10
const MerkleMultiProof_ERROR_CODE= MerkleMultiProof_FACILITY_ID * 100;

// --- Errror Codes ---

enum MerkleMultiProof_Error {
    InvalidProofLeavesCannotBeEmpty = MerkleMultiProof_ERROR_CODE,
    InvalidProofLeavesTooLarge,
    InvalidProofProofsTooLarge,
    InvalidProofTotalHashesExceededMax,
    InvalidProofDataSizeMismatch,
}

/// @notice internal domain separator, should be used as the first 32 bytes of an internal node's preimage.
const INTERNAL_DOMAIN_SEPARATOR: int = 0x0000000000000000000000000000000000000000000000000000000000000001;

/// @notice Maximum number of hashes that can be computed in a single Merkle root calculation.
/// Capped to 255 because a TVM tuple can only hold at most 255 elements.
const MAX_NUM_HASHES: int = 255;

/// @notice Computes the Merkle root based on provided pre-hashed leaf nodes in `leaves`, internal nodes in `proofs`,
/// and using `proofFlagBits` to determine whether to use a proof element or a previously computed node during each step.
fun merkleRoot<I>(
    leaves: I, // Iterator or TupleIterator<uint256>
    proofs: Iterator<uint256>,
    proofFlagBits: uint256,
): uint256 {
    val leavesLen = leaves.size(32);
    val proofsLen = proofs.size(32);

    assert (leavesLen != 0, MerkleMultiProof_Error.InvalidProofLeavesCannotBeEmpty);
    assert (leavesLen <= MAX_NUM_HASHES, MerkleMultiProof_Error.InvalidProofLeavesTooLarge);
    assert (proofsLen <= MAX_NUM_HASHES, MerkleMultiProof_Error.InvalidProofProofsTooLarge);

    var totalHashes: int = leavesLen + proofsLen - 1;
    assert (totalHashes <= MAX_NUM_HASHES, MerkleMultiProof_Error.InvalidProofTotalHashesExceededMax);

    if (totalHashes == 0) {
        return leaves.next();
    }

    var hashes = createEmptyTuple();

    // index over the hashes tuple
    var hashPos: int = 0;
    var i: int = 0;
    while (i < totalHashes) {
        // Find the first hash needed to compute the parent.
        // Check the ith value of the bitmap that signals wether to use an element from proofs or leaves.
        var a: int = 0;
        if ((proofFlagBits & (1 << i)) == (1 << i)) {
            // Use a leaf or a previously computed hash.
            if (! leaves.empty()) {
                a = leaves.next();
            } else {
                assert(hashPos<i, MerkleMultiProof_Error.InvalidProofDataSizeMismatch);
                a = hashes.get(hashPos);
                hashPos += 1;
            }
        } else {
            // Use the next supplied proof.
            assert(! proofs.empty(), MerkleMultiProof_Error.InvalidProofDataSizeMismatch);
            a = proofs.next();
        }

        // Find the second hash needed to compute the parent. It is never a proof.
        var b: int = 0;
        if (! leaves.empty()) {
            b = leaves.next();
        } else {
            assert(hashPos<i, MerkleMultiProof_Error.InvalidProofDataSizeMismatch);
            b = hashes.get(hashPos);
            hashPos += 1;
        }
        
        // Hash the two children to get the parent
        hashes.push(hashPair(a, b));
        i += 1;
    }
    // The last hash is the root.
    return hashes.get(hashPos);
}

fun hashPair(a: uint256, b: uint256): uint256 {
    if (a < b) {
        return hashInternalNode(a, b);
    } else {
        return hashInternalNode(b, a);
    }
}

fun hashInternalNode(a: uint256, b: uint256): uint256 {
    var data = beginCell()
        .storeUint(INTERNAL_DOMAIN_SEPARATOR, 256)
        .storeUint(a, 256)
        .storeUint(b, 256);
    return keccak256(data);
}


