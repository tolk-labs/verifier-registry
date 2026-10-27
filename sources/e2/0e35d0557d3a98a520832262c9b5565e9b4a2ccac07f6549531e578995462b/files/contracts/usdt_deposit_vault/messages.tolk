import "@contracts/common/comments/messages"
import "storage"

struct (0x55445052) ProbeUsdtDeposit {}

struct (0x55445250) ReportUsdtDeposit {}

struct (0x5544434d) AssignUsdtDeposit {
    beneficiary: address
}

// Escrow uses its retained deposit record to restore a deleted owner account.
struct (0x55445241) RestoreUsdtDepositAssignment {
    beneficiary: address
    holdingAttempt: uint64? = null
}

struct (0x55445246) RefundUsdtDeposit {
    comment: Cell<TextComment>
}

struct (0x55445744) WithdrawUsdtDeposit {
    amount: coins
}

struct (0x55444644) UsdtDepositReceived {
    terms: Cell<UsdtDepositTerms>
}

struct (0x55444143) UsdtDepositAssigned {
    terms: Cell<UsdtDepositTerms>
    beneficiary: address
    holdingAttempt: uint64
}

struct (0x55485052) PrepareUsdtHolding {}

struct (0x55485244) UsdtHoldingReady {
    attempt: uint64
}

struct (0x5548554e) UsdtHoldingUnavailable {
    attempt: uint64
}

struct (0x55484644) UsdtHoldingFunded {
    terms: Cell<UsdtDepositTerms>
    attempt: uint64
}
