import "./digitaltwin"

// Store a single matrix cell coordinate
struct MatrixIndex {
    row: uint8
    col: uint8
}

// Store entries above threshold for a calculation
struct MatrixEntry {
    index: MatrixIndex
    value: int32
}

struct Storage {
    id: uint32
    owner: address
    calculations: array<CalculationRecord>
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

// Define the structure for incoming staking messages with opcode 0x12345678
struct PopulateMessage {
    // The matrix to validate (4x32)
    matrix: array<array<int32>>
}

// Error codes
enum Errors {
    InvalidMatrix = 0xFFFF01
    InvalidMessage = 0xFFFF02
    InvalidIndex = 0xFFFF03
    EmptyCalculations = 0xFFFF04
    UnauthorizedSender = 0xFFFF05
}

// Message to change owner
struct (0x2ce05111) ChangeOwner {
    newOwner: address
}
