import "@stdlib/gas-payments"
import "creation"
import "messages"

const NOTE_RETURNED: slice = "Returned: this address is a token contract".literalSlice()
const NOTE_MINTED: slice = "Tokens minted".literalSlice()
const NOTE_MINTING_LOCKED: slice = "Minting locked".literalSlice()
const NOTE_ADMIN_OFFERED: slice = "Token ownership transfer offered".literalSlice()
const NOTE_ADMIN_TAKEN: slice = "Token ownership accepted".literalSlice()
const NOTE_ADMIN_GIVEN_UP: slice = "Token ownership renounced".literalSlice()
const NOTE_MINTING_CLOSED: slice = "Minting closed permanently".literalSlice()
const NOTE_WHITELIST_ADDED: slice = "Added to the whitelist".literalSlice()
const NOTE_WHITELIST_REMOVED: slice = "Removed from the whitelist".literalSlice()
const NOTE_WHITELIST_LOCKED: slice = "Whitelist locked".literalSlice()
const NOTE_GRAM_TAKEN: slice = "GRAM withdrawn".literalSlice()
const NOTE_TOKENS_TAKEN: slice = "Tokens recovered".literalSlice()

fun keepRent(valueCoins: coins, rent: coins) {
    reserveGramsOnBalance(
        max(contract.getOriginalBalance() - valueCoins + contract.getStorageDuePayment(), rent),
        RESERVE_MODE_AT_MOST,
    );
}

fun returnTheRest(to: address, note: slice) {
    val restMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: TextComment { text: note },
    });
    // SAFETY: every caller reserves the rent and the balance from before the message with keepRent() right before this send
    restMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun answerWithNote(to: address, note: slice) {
    val answerMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: TextComment { text: note },
    });
    answerMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun returnTheMessageRest(to: address, queryId: uint64) {
    val excessesMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: ReturnExcessesBack { queryId },
    });
    excessesMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun returnPlainSend(to: address) {
    val backMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: TextComment { text: NOTE_RETURNED },
    });
    backMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun addressOrNone(value: address?): any_address {
    return value == null ? createAddressNone() : value as any_address;
}
