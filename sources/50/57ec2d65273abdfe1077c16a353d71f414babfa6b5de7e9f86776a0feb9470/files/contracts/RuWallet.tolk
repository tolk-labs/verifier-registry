import "@contracts/types"
import "@stdlib/gas-payments"

contract RuWallet {
    author: "None"
    version: "1.0.0"
    description: "ECDSA secp256k1 owner verification for RuToken"
    storage: Storage
    incomingMessages: AllowedMessage
}

type AllowedMessage = WalletMessage;

const SECP256K1_HALF_N: uint256 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
const OP_SIGNED_INTERNAL: uint32 = 0x7369676e; // "sign" — внутренний вызов подписанного пакета (например, через релеера)

// SAFETY: Восстановление координат открытого ключа secp256k1 в TVM
fun ecRecover(hash: uint256, v: uint8, r: uint256, s: uint256): (int, uint256, uint256)
    asm "ECRECOVER"

// SAFETY: Хэширование builder напрямую без создания ячейки
fun builderHash(b: builder): uint256
    asm "HASHBU"

// SAFETY: Отправка исходящего сообщения с заданным sendMode
fun sendRawMsg(msg: cell, mode: int): void
    asm "SENDRAWMSG"

@inline
fun verifyAndExecute(inSlice: slice, isExternal: bool) {
    // Ожидаемый формат inSlice:
    // r: uint256 | s: uint256 | v: uint8 | subwalletId: uint32 | validUntil: uint32 | seqno: uint32
    // и далее 0..4 пары (mode: uint8, outMsg: ^cell)
    val r = inSlice.loadUint(256);
    val s = inSlice.loadUint(256);
    val v = inSlice.loadUint(8);

    // Слайс с подписываемыми данными (копируем/сохраняем указатель на начало подписываемой части)
    val payloadSlice = inSlice;

    val subwalletId = inSlice.loadUint(32);
    val validUntil = inSlice.loadUint(32);
    val msgSeqno = inSlice.loadUint(32);

    var st = Storage.load();

    // 1. Валидация срока действия, seqno, subwalletId и параметров ECDSA secp256k1
    assert(validUntil > blockchain.now(), 30);
    assert(msgSeqno == st.seqno, 31);
    assert(subwalletId == st.subwalletId, 32);
    assert(r != 0 && s != 0 && s < SECP256K1_HALF_N, 33);

    // 2. Вычисляем хэш с привязкой к адресу контракта
    val msgHash = builderHash(
        beginCell()
            .storeAddress(contract.getAddress())
            .storeSlice(payloadSlice)
    );

    // 3. Восстанавливаем ключ и сверяем с открытым ключом владельца
    val (ok, recX, recY) = ecRecover(msgHash, v, r, s);
    assert(ok && (recX == st.pubKeyX) && (recY == st.pubKeyY), 34);

    // 4. Принимаем внешнее сообщение и обновляем seqno до отправки исходящих сообщений
    if (isExternal) {
        acceptExternalMessage();
    }

    st.seqno += 1;
    st.save();

    // 5. Отправляем исходящие сообщения (до 4 ссылок в одной ячейке)
    while (inSlice.remainingRefsCount() > 0) {
        val mode = inSlice.loadUint(8);
        val outMsg = inSlice.loadRef();
        sendRawMsg(outMsg, mode);
    }
}

fun onExternalMessage(inMsg: slice) {
    verifyAndExecute(inMsg, true);
}

fun onInternalMessage(in: InMessage) {
    // Обычные переводы TON и уведомления с коротким телом принимаем без ошибок
    if (in.body.remainingBitsCount() < 32) {
        return;
    }

    val op = in.body.preloadUint(32);
    if (op == OP_SIGNED_INTERNAL) {
        in.body.skipBits(32);
        verifyAndExecute(in.body, false);
    }
}

// --- Get-методы ---

get fun seqno(): uint32 {
    return Storage.load().seqno;
}

get fun getSubwalletId(): uint32 {
    return Storage.load().subwalletId;
}

get fun getPublicKey(): (uint256, uint256) {
    val st = Storage.load();
    return (st.pubKeyX, st.pubKeyY);
}
