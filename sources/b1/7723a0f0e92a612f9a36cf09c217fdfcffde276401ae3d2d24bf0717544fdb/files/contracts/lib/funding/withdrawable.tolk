// SPDX-License-Identifier: MIT
tolk 1.2

struct Withdrawable {
    reserve: coins;
}

enum Withdrawable_Error {
    // Trying to withdraw more TON than available in balance.
    InsufficientBalance = 57100; // Facility ID * 100
    // Trying to withdraw more TON than available in balance above reserve.
    HitReserve;
    // Invalid withdrawal request: Amount is non-zero and drain is true or Amount is zero and drain is false.
    InvalidRequest;
}

// Withdraw TON from the contract balance.
struct (0xf343fc1b) Withdrawable_Withdraw {
    queryId: uint64;
    // address to send TON
    destination: address;
    // Amount to withdraw. Ignored if drain is true.
    amount: coins;
    // Overwrite reserve.
    reserve: coins?; 
    // Ignore amount. If force is true, withdraw all balance, otherwise withdraw all balance above reserve.
    drainAllAvailable: bool;
}

fun Withdrawable.withdraw(self, msg: Withdrawable_Withdraw, value: coins) {
    val originalBalance = contract.getOriginalBalance();
    var actualReserve = self.reserve;
    if (msg.reserve != null) {
        actualReserve = msg.reserve;
    }
    if (msg.drainAllAvailable) {
        assert (msg.amount == 0) throw Withdrawable_Error.InvalidRequest;    
        // Withdraw all balance above reserve
        assert (originalBalance > actualReserve) throw Withdrawable_Error.HitReserve;
        reserveToncoinsOnBalance(actualReserve, RESERVE_MODE_EXACT_AMOUNT);

        return _transfer(msg.destination, 0, SEND_MODE_CARRY_ALL_BALANCE);
    }
    // Withdraw specific amount
    assert (msg.amount > 0) throw Withdrawable_Error.InvalidRequest;
    assert (msg.amount < originalBalance) throw Withdrawable_Error.InsufficientBalance;
    assert (msg.amount < originalBalance - actualReserve) throw Withdrawable_Error.HitReserve;
    return _transfer(msg.destination, msg.amount, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

fun _transfer(destination: address, value: coins, sendMode: int ) {
    val reply = createMessage({
        bounce: false, // So refund is not returned in case requester doesn't handle empty messages
        value: value,
        dest: destination,
        body: createEmptyCell(),
    });
    reply.send(sendMode);
}