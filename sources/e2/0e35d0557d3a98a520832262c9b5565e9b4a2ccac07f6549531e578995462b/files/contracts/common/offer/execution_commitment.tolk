// TEP-62 передаёт forward_payload как Either inline/ref. Execution binding намеренно принимается
// только канонической ссылкой: так escrow может дешёво отличить отсутствие payload от полной cell,
// не пытаясь разобрать произвольный хвост уже состоявшейся NFT-передачи.
fun readExecutionCommitment(payload: slice): cell? {
    var envelope = payload;
    if (envelope.remainingBitsCount() < 1 || envelope.loadUint(1) == 0) {
        return null;
    }
    if (envelope.remainingBitsCount() != 0 || envelope.remainingRefsCount() != 1) {
        return null;
    }
    return envelope.loadRef();
}
