import "@stdlib/gas-payments"
import "@contracts/types"

contract RuWallet {
    author: "None"
    version: "1.0.0"
    description: "ECDSA secp256k1 owner verification for RuToken"
    storage: Storage
    incomingMessages: AllowedMessage
}

type AllowedMessage = WalletMessage

const SECP256K1_HALF_N: uint256 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
const OP_SIGNED_INTERNAL: uint32 = 0x7369676e

// SAFETY
fun ecRecover(
    hash: uint256,
    v: uint8,
    r: uint256,
    s: uint256
): (uint8, uint256, uint256, int)
    asm "ECRECOVER";

// SAFETY
fun builderHash(b: builder): uint256
    asm "HASHBU"

// SAFETY
fun sendRawMsg(msg: cell, mode: int): void
    asm "SENDRAWMSG"

@inline
fun verifyAndExecute(inSlice: slice, isExternal: bool) {
    val r = inSlice.loadUint(256);
    val s = inSlice.loadUint(256);
    val v = inSlice.loadUint(8);

    val payloadSlice = inSlice;

    val subwalletId = inSlice.loadUint(32);
    val validUntil = inSlice.loadUint(32);
    val msgSeqno = inSlice.loadUint(32);

    var st = Storage.load();

    assert(validUntil > blockchain.now(), 30);
    assert(msgSeqno == st.seqno, 31);
    assert(subwalletId == st.subwalletId, 32);
    assert(r != 0 && s != 0 && s < SECP256K1_HALF_N, 33);

    val msgHash = builderHash(
        beginCell().storeAddress(contract.getAddress()).storeSlice(payloadSlice),
    );

    val (_, recX, recY, success) = ecRecover(msgHash, v, r, s);

    assert(success != 0, 34);
    assert(recX == st.pubKeyX && recY == st.pubKeyY, 34);

    if (isExternal) {
        acceptExternalMessage();
    }

    st.seqno += 1;
    st.save();

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
    if (in.body.remainingBitsCount() < 32) {
        return;
    }

    val op = in.body.preloadUint(32);
    if (op == OP_SIGNED_INTERNAL) {
        in.body.skipBits(32);
        verifyAndExecute(in.body, false);
    }
}

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
