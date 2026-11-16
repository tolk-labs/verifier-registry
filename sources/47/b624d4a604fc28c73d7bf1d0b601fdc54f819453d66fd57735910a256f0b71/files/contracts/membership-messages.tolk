tolk 1.5

import "@stdlib/gas-payments"

// What the CyberKonquest membership collection (membership-nft-collection.tolk) and its items
// (membership-nft-item.tolk) both know: the layouts both read, the message one sends the other, and the
// amounts that are the same in both.
//
// A message a standard defines carries that standard's opcode (TEP-62, TEP-66). The opcodes of the pair's
// own messages are crc32 checksums of "membership::" and the struct's name in snake_case
// (membership::init_nft_item).

// The data an item is deployed with: its index and its collection. They give the item its address; its
// owner and its content follow once the collection has initialized it.
struct ItemDeploymentData {
    index: uint64
    collectionAddress: address
}

// An item's individual content (TEP-62): the collection's get_nft_content makes the metadata link of it
struct MembershipContent {
    tier: uint8           // 0 to 3: Bronze, Silver, Gold, Cyber
    mintTimestamp: uint32 // unix time of the mint
}

// Initializes an item (collection -> item): the wallet that minted is its first owner. Should the item
// refuse it, it comes back to the collection whole, which then undoes the mint.
struct (0x87e5e38a) InitNftItem {
    index: uint64 // the item's own index: the collection reads it in a bounce, to know which mint to undo
    minter: address
    content: MembershipContent
}

// What is left of a message's value, sent back
struct (0xd53276db) Excesses {
    queryId: uint64
}

// What a transfer leaves on its item, out of the item's balance with the transfer's own value in it: the
// item's storage reserve (the value of the TEP-62 reference item) and the fixed amount the transfer's gas
// is counted as. A mint gives its item exactly that much, so that an item's first transfer keeps
// nothing more of the value it comes with than any later one.
const ITEM_STORAGE_RESERVE: int = grams("0.05")
const ITEM_TRANSFER_GAS: int = grams("0.01")
const ITEM_TRANSFER_SETS_ASIDE: int = ITEM_STORAGE_RESERVE + ITEM_TRANSFER_GAS

// The mode of an answer sent on the request's own value: the collection's to a get_royalty_params, an
// item's to a get_static_data. The answer leaves with all that is left of the request's value
// (SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE), which pays its forward fee. The handler first checks that
// the request carries what the answer costs (answerCost), so that it can leave. With that check the send
// does not fail. Should a rule of the network ever make it fail all the same, the request bounces with its
// value if it asked to, instead of leaving it on the contract (SEND_MODE_BOUNCE_ON_ACTION_FAIL).
const ON_REQUEST_VALUE: int = SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE |
    SEND_MODE_BOUNCE_ON_ACTION_FAIL

// The gas a request answered on its own value is asked to pay for (answerCost): a bound on the two
// handlers. Answering a get_static_data takes an item 3 955, and answering a get_royalty_params takes the
// collection 3 955, and up to 4 050 when its data hold a royalty that is not allowed and it reports the
// maximum: ANSWER_GAS leaves a margin of 950 above the most.
const ANSWER_GAS: int = 5000

// The GRAM a request must carry that is answered on its own value: the handler's gas at its bound
// (ANSWER_GAS), at the basechain's gas price, and the forward fee of the answer at the message prices of
// the chain it goes to. The network charges that fee on what a message holds below its root cell: an
// answer's body, which is one cell of `bits` bits. The answer goes to the asker, so the chain is the
// sender's own (`workchain`), whatever it is: an asker is never refused for its chain.
// calculateForwardFee takes the basechain's prices (ConfigParam 25) for workchain 0 and the masterchain's
// (ConfigParam 24) for any other. A request with less is refused: its answer could not leave, and its
// GRAM would stay on the contract. Refused, it bounces with what the refusal left of its value, if it
// asked to and if that pays a message's way back.
fun answerCost(bits: int, workchain: int): coins {
    return calculateGasFee(BASECHAIN, ANSWER_GAS) + calculateForwardFee(workchain, bits, 1);
}
