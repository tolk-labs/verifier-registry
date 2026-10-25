// Role encoded in bounce queryId: USDT AskToTransfer.queryId (uint64), TON RefundBounce.queryId (uint8).
// QueryRole.None — ErrRefund: accounting was not decremented, bounce must not credit.
enum QueryRole {
    None = 0
    Client = 1
    Provider = 2
    Admin = 3
}

enum ErrModeVal {
    ClientFullRights = 1
    ProviderFullRights = 2
    ClientFullRightsAfterHalfYear = 16   // client gains full rights after half a year
    ProviderFullRightsAfterHalfYear = 26 // provider gains full rights after half a year
    BlockErrorMode = 99
}

// Lost-wallet timeout for AfterHalfYear ErrRefund (180 days).
const HALF_YEAR: uint64 = 180 * 24 * 60 * 60

// Wallet comment: opcode 0, UTF-8 tail in the same cell.
struct (0x00000000) WalletTextComment {
    text: RemainingBitsAndRefs
}

const HALF_YEAR_NOTICE_CLIENT: string = "Your contract will come under the full control of the client in six months."
const HALF_YEAR_NOTICE_PROVIDER: string = "Your contract will come under the full control of the provider in six months."
// Paid by the ErrMode sender. Forward fee is taken from this value.
const HALF_YEAR_NOTICE_VALUE: coins = grams("0.01")

// Opponent notice when AfterHalfYear is armed. Role name, not a raw address:
// a friendly address is not formatted on-chain.
fun sendHalfYearControlNotice(dest: address, aboutClient: bool) {
    val text = aboutClient ? HALF_YEAR_NOTICE_CLIENT : HALF_YEAR_NOTICE_PROVIDER;
    // 32 zero bits, then UTF-8 (storeStringTail). These notices fit in one cell.
    val body = beginCell().storeUint(0, 32).storeSlice(text.beginParse()).endCell();
    val notice = createMessage({
        bounce: BounceMode.NoBounce,
        dest,
        value: HALF_YEAR_NOTICE_VALUE,
        body,
    });
    notice.send(SEND_MODE_REGULAR);
}

struct (0x581bad4c) ErrMode {
    value: int8
}

struct (0xec77f843) ChangePercent {
    percent: int8
}

struct (0x2585b53d) AcceptPercent {
    percent: int8
}

struct (0x3b3e8b44) BurnContract {}
