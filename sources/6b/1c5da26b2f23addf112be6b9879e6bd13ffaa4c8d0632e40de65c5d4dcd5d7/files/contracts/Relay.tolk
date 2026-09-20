tolk 1.4.2

// Input relay for Doom on TON. The mempool caps external messages per address, so a player sends input
// batches to many relays in turn; a relay forwards the command to whatever address the message names, as
// an internal message (deploy the relays with the Doom contract's top address bits so that they share its
// shard). The attached value buys the gas limit of the Doom transaction and stays there, so a relay needs
// a balance. Testnet toy: no signature, any destination.
//
// External body: dest:address then a Doom command (op DOOM / STRT / STOP / RSET, see Doom.tolk).

import "@stdlib/gas-payments"

contract Relay {
    author: "ton-doom"
    version: "0.2.0"
    description: "Input relay for Doom on TON: forwards a command external to the address it names"
    storage: RelayStorage
}

const RELAY_VALUE = 70000000;    // 0.07 TON attached to the forwarded command: buys Doom's 1M gas limit
const OP_WITHDRAW = 0x57445257;  // "WDRW" internal from the owner: send the whole balance back

struct RelayStorage {
    owner: address
    id: uint16         // distinct ids give distinct addresses
}

fun RelayStorage.load(): RelayStorage {
    return RelayStorage.fromCell(contract.getData());
}

fun onExternalMessage(inBody: slice) {
    var body = inBody;
    val dest = body.loadAddress();
    assert (body.remainingBitsCount() >= 64) throw 130;
    val op = body.preloadUint(32);
    assert ((op == 0x444F4F4D) | (op == 0x53545254) | (op == 0x53544F50) | (op == 0x52534554)) throw 130;
    acceptExternalMessage();
    val fwd = createMessage({
        bounce: false,
        value: RELAY_VALUE,
        dest,
        body: beginCell().storeSlice(body).endCell(),
    });
    fwd.send(SEND_MODE_REGULAR);
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;   // top-up
    }
    if (in.body.preloadUint(32) == OP_WITHDRAW) {
        val st = lazy RelayStorage.load();
        if (in.senderAddress != st.owner) {
            return;
        }
        val back = createMessage({ bounce: false, value: 0, dest: st.owner });
        back.send(SEND_MODE_CARRY_ALL_BALANCE);
    }
}
