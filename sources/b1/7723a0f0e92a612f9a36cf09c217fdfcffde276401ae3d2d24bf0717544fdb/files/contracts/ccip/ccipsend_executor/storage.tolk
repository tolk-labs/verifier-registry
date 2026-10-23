// SPDX-License-Identifier: BUSL-1.1
import "errors"
import "types"
import "../onramp/messages"

struct CCIPSendExecutor<T> {
    id: CCIPSendExecutor_ID,
    onrampSend: OnRamp_Send,
    addresses: Cell<CCIPSendExecutor_Addresses>,
    state: Cell<T>,
}

fun CCIPSendExecutor<T>.load(): CCIPSendExecutor<T> {
    val st = lazy CCIPSendExecutor_Data.fromCell(contract.getData());
    assert (st.state is Cell<T>) throw CCIPSendExecutor_Error.StateNotExpected; // invalid state
    return CCIPSendExecutor<T> {
        id: st.id,
        onrampSend: st.onrampSend,
        addresses: st.addresses,
        state: st.state,
    };
}

fun CCIPSendExecutor<T>.store(self) {
    contract.setData(CCIPSendExecutor_Data {
        id: self.id,
        onrampSend: self.onrampSend,
        addresses: self.addresses,
        state: self.state,
    }.toCell());
}
