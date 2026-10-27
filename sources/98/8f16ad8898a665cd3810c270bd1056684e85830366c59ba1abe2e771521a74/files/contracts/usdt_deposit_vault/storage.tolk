import "@contracts/common/comments/messages"
import "@contracts/common/offer/enums"
import "enums"

struct UsdtDepositTerms {
    escrow: address
    contributor: address
    offerExecutionNumber: uint32
    side: OfferSide
    purpose: UsdtDepositPurpose
    nonce: uint64
    amount: coins
    // Для taker-вклада immutable vault address коммитит execution binding. Escrow применяет его
    // только после фактического USDT deposit receipt; одна подготовка vault Offer не блокирует.
    execution: cell? = null
}

struct UsdtDepositVaultStorage {
    terms: Cell<UsdtDepositTerms>
    status: UsdtDepositStatus = UsdtDepositStatus.Collecting
    beneficiary: address? = null
    refundComment: Cell<TextComment>? = null
    // A holding has the same runtime, but a distinct immutable StateInit. The parent is derived
    // from the default main-vault StateInit and these same terms.
    holdingAttempt: uint64? = null
    allocation: Cell<UsdtPrincipalAllocation>? = null
    selectedAttempt: uint64? = null
}

struct UsdtPrincipalAllocation {
    attempt: uint64
    dispatched: bool = false
}

fun UsdtDepositVaultStorage.load(): UsdtDepositVaultStorage {
    return UsdtDepositVaultStorage.fromCell(contract.getData());
}

fun UsdtDepositVaultStorage.save(self) {
    contract.setData(self.toCell());
}
