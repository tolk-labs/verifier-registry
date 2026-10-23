// SPDX-License-Identifier: MIT
import "types"
import "errors"
import "../../ccip/router/messages"

struct (0xb3126df1) Receiver_CCIPReceive {
    execId: uint192; // to calculate where to send CCIPReceiveConfirm and CCIPReceiveFailed
    message: Any2TVMMessage;
}

struct Receiver_InMessagePartial { // Tolk compiler doesn't allow passing builtin InMessage as argument of a function
    senderAddress: address;
    valueCoins: coins;
}

struct Receiver_ValidateOptions {
    // Router address
    router: address;
    // Minimum value that must be sent along with the message to cover all gas, forward and action fees
    minValue: coins;
    // Original incoming message
    inMsg: Receiver_InMessagePartial;
    // Options for sending the confirmation message
    confirmationMsg: Receiver_ConfirmOpts;
};

struct Receiver_ConfirmOpts {
    // Value to attach to the confirmation message
    value: coins = 0;
    // Send mode for the confirmation message
    sendMode: uint8 = SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE;
}

fun Receiver_CCIPReceive.validateAndConfirm(self, opts: Receiver_ValidateOptions) {
    // Standard for every receiver to implement:

    // 1. Check CCIPReceive only comes from router
    assert( opts.inMsg.senderAddress == opts.router) throw (Receiver_Error.Unauthorized as int);

    // 2. Check that enough value is sent
    assert( opts.inMsg.valueCoins >= opts.minValue) throw (Receiver_Error.LowValue as int);

    // 3. Enqueue CCIPReceiveConfirm to msg.callback
    val receiveConfirm = createMessage({
        bounce: true,
        value: opts.confirmationMsg.value,
        dest: opts.inMsg.senderAddress,
        body: Router_CCIPReceiveConfirm {
            execId: self.execId,
        }
    });
    receiveConfirm.send(opts.confirmationMsg.sendMode);
}
