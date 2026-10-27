import "storage"

// The same code serves both roles; only the immutable attempt distinguishes a holding.
fun usdtVaultInitWithCode(
    code: cell,
    terms: Cell<UsdtDepositTerms>,
    holdingAttempt: uint64? = null,
): AutoDeployAddress {
    return {
        stateInit: { code, data: UsdtDepositVaultStorage { terms, holdingAttempt }.toCell() },
    };
}
