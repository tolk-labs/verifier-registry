//import "types"
import "./types"
//===============================================================
// Contract
// ============================================================================

contract DigitalTwin {
    author: "Prgnstctr"
    version: "1.0.0"
    description: "DIGITAL TWIN DNA SETUP"
    storage: Storage
    incomingMessages: AllowedMessage
}

// ========================================================================
// Constants
// ========================================================================

const REQUIRED_ROWS: int = 4
const REQUIRED_COLS: int = 32
const REQUIRED_COL_SUM: int = 100
const THRESHOLD: int = 50

// ============================================================================
// Type Aliases
// ============================================================================

type AllowedMessage = PopulateMessage

// ============================================================================
// Record of a single calculation/validation
// ============================================================================

struct CalculationRecord {
    // Unix timestamp when this calculation was performed
    timestamp: uint64
    // Hash of the original matrix for reference
    matrixHash: uint256
    // Indices of entries above threshold
    entriesAbove: array<MatrixEntry>
    // Whether validation passed
    isValid: bool
    // Reference to the previous calculation record in the linked list
    // (for history tracking)
    prevHead: cell
}

// ============================================================================
// Core Validation Logic
// ============================================================================

// Validate matrix dimensions and column sums
fun validateMatrixStructure(matrix: array<array<int32>>): bool {
    // Check row count
    if (matrix.size() != REQUIRED_ROWS) {
        return false;
    }

    // Check column count
    val cols = matrix.get(0).size();
    if (cols != REQUIRED_COLS) {
        return false;
    }

    // Validate each column sums to REQUIRED_COL_SUM
    var j: int = 0;
    while (j < cols) {
        var sum: int = 0;
        var i: int = 0;
        while (i < REQUIRED_ROWS) {
            sum = sum + matrix.get(i).get(j);
            i = i + 1;
        }

        if (sum != REQUIRED_COL_SUM) {
            return false;
        }
        j = j + 1;
    }

    return true;
}

// Extract matrix entries where value > THRESHOLD
fun extractEntriesAboveThreshold(matrix: array<array<int32>>): array<MatrixEntry> {
    var result: array<MatrixEntry> = [];

    var i: int = 0;
    while (i < REQUIRED_ROWS) {
        var j: int = 0;
        while (j < REQUIRED_COLS) {
            val value = matrix.get(i).get(j);

            // Only record entries where value > THRESHOLD
            if (value > THRESHOLD) {
                val entry = MatrixEntry {
                    index: MatrixIndex {
                        row: i,
                        col: j,
                    },
                    value,
                };
                result.push(entry);
            }
            j = j + 1;
        }
        i = i + 1;
    }

    return result;
}

// Compute hash of matrix for reference
fun hashMatrix(matrix: array<array<int32>>): uint256 {
    return matrix.toCell().hash();
}

fun storeCalculation(
    matrix: array<array<int32>>,
    _sender: address,
): CalculationRecord {
    // Step 1: Validate matrix structure
    val isValid = validateMatrixStructure(matrix);

    if (!isValid) {
        throw Errors.InvalidMatrix;
    }

    // Step 2: Extract entries above threshold
    val entriesAbove = extractEntriesAboveThreshold(matrix);

    // Step 3: Compute matrix hash
    val matrixHash = hashMatrix(matrix);

    // Construct and return a new CalculationRecord with all computed values
    return CalculationRecord {
        timestamp: blockchain.now(),
        matrixHash,
        entriesAbove,
        isValid,
        // Set prevHead to an empty cell (no linked list chain yet)
        prevHead: beginCell().endCell(),
    };
}

// ============================================================================
// Message Handler
// ============================================================================
fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);

    match (msg) {
        PopulateMessage => {
            // Step 1: Validate matrix structure
            val isValid = validateMatrixStructure(msg.matrix);

            if (!isValid) {
                throw Errors.InvalidMatrix;
            }

            // Step 2: Extract entries above threshold
            val _entriesAbove = extractEntriesAboveThreshold(msg.matrix);

            // Step 3: Compute matrix hash
            val _matrixHash = hashMatrix(msg.matrix);

            //------BOOKKEEPING_START
            // Load the current contract storage state from the blockchain
            // Using lazy evaluation to defer loading until needed
            var storage = lazy Storage.load();

            // Verify that the sender is the contract owner (authorization check)
            // If not, throw NotAuthorized error and halt execution
            assert(storage.owner == in.senderAddress, Errors.UnauthorizedSender);
            //------BOOKKEEPING_END

            // Step 4: Create calculation record
            // Create a new CalculationRecord with computed values
            val calculationRecord = storeCalculation(msg.matrix, in.senderAddress);

            // Step 5: Save to storage with bounded history
            // Add the newly created calculation record to the storage array
            // This appends it to the end of the calculations list
            storage.calculations.push(calculationRecord);

            // Persist the updated storage back to the blockchain
            // This saves the new calculation record permanently
            storage.save();
        }

        // If the message does not match PopulateMessage type, execute this block
        else => {
            // Verify that the message body is empty (reject non-empty invalid messages)
            // If not empty, throw InvalidMessage error and halt execution
            assert(in.body.isEmpty(), Errors.InvalidMessage);
        }
    }
}

// ============================================================================
// Bouncing
// ============================================================================

fun onBouncedMessage(_in: InMessageBounced) {}

// ============================================================================
// Initialization
// ============================================================================

fun init(id: uint32, owner: address) {
    val storage = Storage {
        id,
        owner,
        calculations: [],
    };
    //  storage.save();
    contract.setData(storage.toCell());
}

// ============================================================================
// Getter Functions (Read-Only, No Gas Cost)
// ============================================================================

// Diagnostics
get fun getStorageSize(): int {
    val storage = lazy Storage.load();
    return storage.calculations.size();
}

// Get all calculation records
get fun getCalculations(): array<CalculationRecord> {
    val storage = lazy Storage.load();
    return storage.calculations;
}

// Get the most recent calculation
get fun getLatestCalculation(): CalculationRecord {
    val storage = lazy Storage.load();
    val calcs = storage.calculations;
    assert (calcs.size() > 0) throw Errors.EmptyCalculations;
    return calcs.get(calcs.size() - 1);
}

// Get owner
get fun getOwner(): address {
    val storage = lazy Storage.load();
    return storage.owner;
}

// Get contract ID
get fun getId(): uint32 {
    val storage = lazy Storage.load();
    return storage.id;
}

// Get total number of calculations recorded
get fun getCalculationsCount(): int {
    val storage = lazy Storage.load();
    return storage.calculations.size();
}

// Get entries above threshold for a specific calculation
get fun getEntriesAboveThreshold(index: int): array<MatrixEntry> {
    val storage = lazy Storage.load();
    assert (index >= 0 && index < storage.calculations.size()) throw Errors.InvalidIndex;
    return storage.calculations.get(index).entriesAbove;
}

// Get the count of entries above threshold in latest calculation
get fun getLatestEntriesCount(): int {
    val storage = lazy Storage.load();
    val calcs = storage.calculations;
    assert (calcs.size() > 0) throw Errors.EmptyCalculations;
    return calcs.get(calcs.size() - 1).entriesAbove.size();
}

// Check if latest validation was successful
get fun isLatestValid(): bool {
    val storage = lazy Storage.load();
    val calcs = storage.calculations;
    assert (calcs.size() > 0) throw Errors.EmptyCalculations;
    return calcs.get(calcs.size() - 1).isValid;
}

// Get matrix hash of a specific calculation
get fun getMatrixHash(index: int): uint256 {
    val storage = lazy Storage.load();
    assert (index >= 0 && index < storage.calculations.size()) throw Errors.InvalidIndex;
    return storage.calculations.get(index).matrixHash;
}

// Get timestamp of a specific calculation
get fun getCalculationTimestamp(index: int): uint64 {
    val storage = lazy Storage.load();
    assert (index >= 0 && index < storage.calculations.size()) throw Errors.InvalidIndex;
    return storage.calculations.get(index).timestamp;
}
