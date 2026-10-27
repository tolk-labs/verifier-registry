const PXP_TOTAL = 1000000000000000000
const PXP_USERS = 900000000000000000
const PXP_BURN = 100000000000000000
const PXP_BURN_STEP = 10000000000000000
const PXP_PERIOD = 30 * 24 * 3600
const BURN_INDEX = 4294967295

// Hash domain separators are part of the external allocation format.
struct (0x5058504c) AllocationLeaf {
    snapshotHash: uint256
    index: uint32
    recipient: address
    amount: uint120
}

struct (0x5058504e) AllocationBranch {
    leftHash: uint256
    leftSum: uint120
    rightHash: uint256
    rightSum: uint120
}

struct ProofStep {
    siblingHash: uint256
    siblingSum: uint120
    next: Cell<ProofStep>?
}

struct (0x50585001) PushAllocation {
    index: uint32
    recipient: address
    amount: coins
    proof: Cell<ProofStep>?
}

struct (0x50585002) MintBurnReserve {}

struct (0x50585003) MintReceipt {
    queryId: uint64
    jettonAmount: coins
}

struct (0x50585004) RepeatMintReceipt {}

struct (0x50585005) BurnReceipt {
    queryId: uint64
    jettonAmount: coins
}

struct (0x50585006) BurnFailure {
    queryId: uint64
    jettonAmount: coins
}

struct (0x50585007) RepeatBurnFailure {}

struct (0x50585008) TickBurn {}

struct (0x50585009) RepeatBurnReceipt {}

struct (0x5058500a) RegisterSnapshot {
    rootHash: uint256
    snapshotHash: uint256
    recipientCount: uint32
    proofDepth: uint8
}

struct ReleaseWalletStorage {
    jettonBalance: coins
    ownerAddress: address
    minterAddress: address
    mintReceipt: Cell<MintReceipt>? = null
    burnFailure: Cell<BurnFailure>? = null
}

fun ReleaseWalletStorage.load(): ReleaseWalletStorage {
    return ReleaseWalletStorage.fromCell(contract.getData());
}

fun ReleaseWalletStorage.save(self) {
    contract.setData(self.toCell());
}

struct Payment {
    queryId: uint64
    recipient: address
    amount: coins
    state: uint2 // 1 pending, 2 confirmed, 0 bounced/retryable
    requester: address
    storageDeposit: coins
}

struct ReleaseConfig {
    rootHash: uint256
    snapshotHash: uint256
    recipientCount: uint32
    proofDepth: uint8
    releaseAt: uint32
    metadata: cell
}

struct ReleaseStorage {
    config: Cell<ReleaseConfig>
    totalSupply: coins = 0
    committed: coins = 0
    confirmed: coins = 0
    confirmedCount: uint32 = 0
    nextAttempt: uint32 = 1
    payments: map<uint32, Payment> = []
    settled: map<uint32, uint256> = []
    pendingCount: uint16 = 0
    burned: coins = 0
    lastBurn: Cell<BurnReceipt>? = null
    rootRegistrar: address? = null
}

fun ReleaseStorage.load(): ReleaseStorage {
    return ReleaseStorage.fromCell(contract.getData());
}

fun ReleaseStorage.save(self) {
    contract.setData(self.toCell());
}

struct BurnVaultStorage {
    minterAddress: address
    releaseAt: uint32
    burned: coins = 0
    pending: coins = 0
    nextQuery: uint64 = 1
    pendingQuery: uint64 = 0
}

fun BurnVaultStorage.load(): BurnVaultStorage {
    return BurnVaultStorage.fromCell(contract.getData());
}

fun BurnVaultStorage.save(self) {
    contract.setData(self.toCell());
}

struct ReleaseStatus {
    totalSupply: coins
    committed: coins
    confirmed: coins
    confirmedCount: uint32
    burned: coins
    releaseAt: uint32
    recipientCount: uint32
    rootHash: uint256
    snapshotHash: uint256
    pendingCount: uint16
}

struct PaymentReply {
    found: bool
    queryId: uint64
    recipient: address?
    amount: coins
    state: uint2
    requester: address?
}

struct MintReceiptReply {
    found: bool
    queryId: uint64
    amount: coins
}

// Deliberately floor elapsed whole periods: a partial month authorizes no partial burn.
fun completedBurnStages(releaseAt: int): int {
    return max(0, min(10, (blockchain.now() - releaseAt) / PXP_PERIOD));
}
