// Общие TEP-62 сообщения для приёма и передачи NFT.

// Rich bounce сохраняет полный исходный body, обычный — только первые 256 bits. Обработчику NFT-
// сбоя нужен только opcode; автоматического повтора нет, потому что он зацикливает постоянную ошибку.
fun bouncedOriginalBody(bouncedBody: slice): slice? {
    if (bouncedBody.remainingBitsCount() < 32) {
        return null;
    }
    val prefix = bouncedBody.preloadUint(32);
    if (prefix == 0xFFFFFFFE) {
        return RichBounceBody.fromSlice(bouncedBody).originalBody.beginParse();
    }
    if (prefix == 0xFFFFFFFF) {
        var original = bouncedBody;
        original.skipBouncedPrefix();
        return original;
    }
    return null;
}

// NFT-контракт уведомляет escrow о состоявшейся передаче владения.
struct (0x05138d91) NftOwnershipAssigned {
    queryId: uint64
    previousOwner: address
    forwardPayload: RemainingBitsAndRefs
}

// Команда NFT-контракту передать владение получателю или вернуть отправителю.
struct (0x5fcc3d14) NftTransfer {
    queryId: uint64
    newOwner: address
    responseDestination: address
    customPayload: cell? = null
    forwardAmount: coins = grams("0")
    forwardPayload: RemainingBitsAndRefs
}

// TEP-62 отвечает только отправителю запроса: response_destination здесь нет.
struct (0x2fcb26a2) NftGetStaticData {
    queryId: uint64
}

struct (0x8b771735) NftReportStaticData {
    queryId: uint64
    index: uint256
    collection: address?
}
