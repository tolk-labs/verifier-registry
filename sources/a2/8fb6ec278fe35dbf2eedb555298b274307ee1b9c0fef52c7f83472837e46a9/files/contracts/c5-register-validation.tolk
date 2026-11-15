import "errors"
import "messages"

/// Puts a raw OutActionList into c5.
/// SAFETY: no validation. Callers must run `verifyC5Actions` on the whole list first.
fun setTvmRegisterC5(actionList: cell): void
    asm "c5 POP"

/// Parses an ordinary or exotic cell as a slice.
/// SAFETY: accepts exotic cells. Callers must validate the structure of the parsed action list.
fun OutActionsCell.beginParseAllowExotic(self): slice
    asm "XCTOS" "DROP"

/// Checks that an OutActionList has 1–255 send-message actions, none with destroy mode (+32)
/// and, for an external request, all with ignore-errors mode (+2).
fun OutActionsCell.verifyC5Actions(self, isExternal: bool): self {
    var count = 0;

    var cs = self.beginParseAllowExotic();
    // do-while: rejects an empty list and is cheaper than while
    do {
        // explicit size checks throw InvalidC5 instead of cell underflow (9), at a small gas cost
        val (nBits, nRefs) = cs.remainingBitsAndRefsCount();
        assert (nRefs == 2) throw Errors.InvalidC5;
        assert (nBits == 32 + 8) throw Errors.InvalidC5;

        val outAction = lazy OutActionWithSendMessageOnly.fromSlice(
            cs,
            { throwIfOpcodeDoesNotMatch: Errors.InvalidC5 },
        );

        // the wallet is an NFT: a wallet action must never destroy its account
        assert ((outAction.sendMode & SEND_MODE_DESTROY) == 0) throw Errors.DestroyNotAllowed;

        if (isExternal) {
            assert (
                (outAction.sendMode & SEND_MODE_IGNORE_ERRORS) != 0
            ) throw Errors.ExternalSendMessageMustHaveIgnoreErrorsSendMode;
        }

        cs = (outAction.prev as OutActionsCell).beginParseAllowExotic();
        count += 1;
    } while (!cs.isEmpty());

    // the TVM action phase accepts at most 255 actions: reject them earlier with a clear code
    assert (count <= 255) throw Errors.InvalidC5;
    return self;
}
