// SPDX-License-Identifier: MIT
import "../utils"

const Deployable_FACILITY_NAME = "link.chain.ton.lib.Deployable";
const Deployable_FACILITY_ID = 92;  // (crc32(<facility>) % 640) + 10

struct Deployable<T> {
    owner: address;
    id: T // builder on serialize, RemainingBitsAndRefs on deserialize
}

fun Deployable<T>.load() {
    return Deployable<T>.fromCell(contract.getData());
}

fun Deployable<T>.store(self) {
    return contract.setData(self.toCell());
}

type Deployable_InMessage =
    | Deployable_Initialize
    | Deployable_InitializeAndSend
    ;

// Message for Initializing the Deployable contract. It sets the code and data of the contract.
struct (0xba466447) Deployable_Initialize {
    stateInit: ContractState;
}
// This message initializes the Deployable contract and immediately sends a message to itself to execute some logic. It allows to carry the message value.
struct (0xb0ec5157) Deployable_InitializeAndSend {
    stateInit: ContractState;
    selfMessage: Deployable_Message;
}

struct Deployable_Message {
    value: coins;
    body: cell;
}

enum Deployable_Error {
    NotOwner = Deployable_FACILITY_ID * 100
}
