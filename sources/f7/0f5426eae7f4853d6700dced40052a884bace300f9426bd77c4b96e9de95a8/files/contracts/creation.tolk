struct Receipt {
    creator: address
    price: coins
    referrer: address?
    referrerAmount: coins
}

struct Unstarted {
    factory: address
    kind: uint16
    index: uint64
}

struct ContractLoader {
    factory: address
    kind: uint16
    index: uint64
    private rest: RemainingBitsAndRefs
}

fun ContractLoader.start(): ContractLoader {
    return ContractLoader.fromCell(contract.getData());
}

fun ContractLoader.isUnstarted(self): bool {
    return self.rest.isEmpty();
}

struct (0x7c0d5e02) Start {
    queryId: uint64
    receipt: Receipt
    reportValue: coins
    params: cell
    settings: cell?
}

struct (0x7c0d5e04) Started {
    queryId: uint64
    kind: uint16
    index: uint64
    subject: address?
    receipt: Cell<Receipt>
}

struct (0x00000000) TextComment {
    text: RemainingBitsAndRefs
}

fun notePayload(note: slice): slice {
    return beginCell().storeBool(true).storeRef(TextComment { text: note }.toCell()).toSlice();
}

struct OriginReply {
    factory: address
    kind: int
    index: int
    creator: any_address
    queryId: int
}
