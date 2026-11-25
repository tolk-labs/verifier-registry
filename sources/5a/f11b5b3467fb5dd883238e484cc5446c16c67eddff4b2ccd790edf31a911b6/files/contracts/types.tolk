struct Storage {
    seqno: uint32;
    subwalletId: uint32;
    pubKeyX: uint256;
    pubKeyY: uint256;
}

@inline
fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

@inline
fun Storage.save(self) {
    contract.setData(self.toCell());
}

struct (0x7369676e) WalletMessage {
    r: uint256;
    s: uint256;
    v: uint8;
    subwalletId: uint32;
    validUntil: uint32;
    seqno: uint32;
    payload: cell;
}
