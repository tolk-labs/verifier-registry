// JettonWallet.tolk — minimal TEP-74 jetton wallet.
//
// Storage layout MUST match `jettonWalletData()` in BondingCurve.tolk:
//   balance:Coins owner:MsgAddress minter:MsgAddress ^wallet_code

import "@stdlib/gas-payments";

const MY_WORKCHAIN = 0;

/// Storage cushion kept on every wallet so it can never fall into storage-rent
/// debt and get frozen/deleted (mirrors jetton v2.1 fees-management.tolk).
const STORAGE_SIZE_MAX_WALLET_BITS = 1026;
const STORAGE_SIZE_MAX_WALLET_CELLS = 3;
const STORAGE_SIZE_INIT_STATE_WALLET_BITS = 812;
const STORAGE_SIZE_INIT_STATE_WALLET_CELLS = 3;
const MIN_STORAGE_DURATION = 5 * 365 * 24 * 3600;

/// Measured gas of the standard transfer/receive/burn paths (jetton v2.1).
const GAS_CONSUMPTION_JETTON_TRANSFER = 6327;
const GAS_CONSUMPTION_JETTON_RECEIVE = 7443;
const GAS_CONSUMPTION_BURN_REQUEST = 4254;
const GAS_CONSUMPTION_BURN_NOTIFICATION = 4071;
const MESSAGE_SIZE_BURN_NOTIFICATION_BITS = 754;
const MESSAGE_SIZE_BURN_NOTIFICATION_CELLS = 1;

fun minStorageFee(): coins {
    return calculateStorageFee(MY_WORKCHAIN, MIN_STORAGE_DURATION,
        STORAGE_SIZE_MAX_WALLET_BITS, STORAGE_SIZE_MAX_WALLET_CELLS);
}

/// Minimum Gram that must ride along with a transfer so the wallet never pays
/// the chain of messages out of its own balance (gas / storage-rent drain).
/// The 5-year storage cushion is deliberately excluded here: the curve forwards
/// leftover value on reject paths, and a stricter bar would bounce refunds.
fun minTransferValue(forwardTonAmount: coins, fwdFee: coins): coins {
    val fwdCount = forwardTonAmount != 0 ? 2 : 1;
    return forwardTonAmount
        + fwdCount * fwdFee
        + calculateForwardFeeWithoutLumpPrice(MY_WORKCHAIN,
            STORAGE_SIZE_INIT_STATE_WALLET_BITS, STORAGE_SIZE_INIT_STATE_WALLET_CELLS)
        + calculateGasFee(MY_WORKCHAIN, GAS_CONSUMPTION_JETTON_TRANSFER)
        + calculateGasFee(MY_WORKCHAIN, GAS_CONSUMPTION_JETTON_RECEIVE);
}

fun minBurnValue(): coins {
    return calculateForwardFee(MY_WORKCHAIN,
            MESSAGE_SIZE_BURN_NOTIFICATION_BITS, MESSAGE_SIZE_BURN_NOTIFICATION_CELLS)
        + calculateGasFee(MY_WORKCHAIN, GAS_CONSUMPTION_BURN_REQUEST)
        + calculateGasFee(MY_WORKCHAIN, GAS_CONSUMPTION_BURN_NOTIFICATION);
}

const OP_TRANSFER = 0x0f8a7ea5;
const OP_INTERNAL_TRANSFER = 0x178d4519;
const OP_TRANSFER_NOTIFICATION = 0x7362d09c;
const OP_EXCESSES = 0xd53276db;
const OP_BURN = 0x595f07bc;
const OP_BURN_NOTIFICATION = 0x7bdd97de;

const ERR_NOT_OWNER = 705;
const ERR_NOT_VALID_SENDER = 707;
const ERR_BALANCE = 706;
const ERR_WRONG_WORKCHAIN = 333;
const ERR_NOT_ENOUGH_GAS = 48;

struct Wallet {
    balance: coins;
    owner: address;
    minter: address;
    code: cell;
}

fun loadWallet(): Wallet {
    var cs = contract.getData().beginParse();
    return {
        balance: cs.loadCoins(),
        owner: cs.loadAddress(),
        minter: cs.loadAddress(),
        code: cs.loadRef(),
    };
}

fun saveWallet(w: Wallet) {
    contract.setData(beginCell()
        .storeCoins(w.balance)
        .storeAddress(w.owner)
        .storeAddress(w.minter)
        .storeRef(w.code)
        .endCell());
}

fun walletDataFor(code: cell, owner: address, minter: address): cell {
    return beginCell()
        .storeCoins(0)
        .storeAddress(owner)
        .storeAddress(minter)
        .storeRef(code)
        .endCell();
}

fun packStateInit(code: cell, data: cell): cell {
    return beginCell()
        .storeUint(0, 2)
        .storeMaybeRef(code)
        .storeMaybeRef(data)
        .storeUint(0, 1)
        .endCell();
}

fun walletAddressFor(code: cell, owner: address, minter: address): address {
    val cs: ContractState = { code: code, data: walletDataFor(code, owner, minter) };
    return AutoDeployAddress { stateInit: cs }.calculateAddress();
}

/// Real bounces only: the runtime routes messages with the bounced flag here,
/// so an attacker cannot reach this path with a hand-crafted internal message.
/// A bounced outgoing internal_transfer / burn_notification means the tokens
/// never arrived, so the debit must be reverted.
fun onBouncedMessage(in: InMessageBounced) {
    var bb = in.bouncedBody;
    bb.skipBouncedPrefix();
    if (bb.remainingBitsCount() < 32 + 64 + 4) { return; }
    val origOp = bb.loadUint(32);
    bb.loadUint(64);
    if (origOp == OP_INTERNAL_TRANSFER || origOp == OP_BURN_NOTIFICATION) {
        var w = loadWallet();
        w.balance += bb.loadCoins();
        saveWallet(w);
    }
}

/// Carries a TEP-74 forward payload through UNTOUCHED: `rest` is the remainder
/// of the incoming body starting at the Either bit, so an inline payload stays
/// inline and a referenced payload stays referenced. Only when the payload no
/// longer fits alongside the outgoing header is it re-wrapped behind
/// `Either = 1` as a reference, which is equally valid TEP-74.
fun appendForwardPayload(mb: builder, rest: slice): builder {
    var s = rest;
    val (bits, refs) = s.remainingBitsAndRefsCount();
    if (mb.bitsCount() + bits <= 1023 && mb.refsCount() + refs <= 4) {
        return mb.storeSlice(s);
    }
    val isRef = s.loadUint(1);
    if (isRef != 0) {
        return mb.storeUint(1, 1).storeRef(s.loadRef());
    }
    return mb.storeUint(1, 1).storeRef(beginCell().storeSlice(s).endCell());
}


fun onInternalMessage(in: InMessage) {
    var body = in.body;
    if (body.isEmpty()) { return; }
    val op = body.loadUint(32);
    var w = loadWallet();

    // A body starting with 0xffffffff is ONLY meaningful for real bounced
    // messages, which the runtime routes to onBouncedMessage below. Anything
    // arriving here with that prefix is a forgery attempt — ignore it, never
    // credit balance.
    if (op == 0xffffffff) { return; }


    val queryId = body.loadUint(64);


    // owner sends jettons out
    if (op == OP_TRANSFER) {
        assert(in.senderAddress == w.owner, ERR_NOT_OWNER);
        val amount = body.loadCoins();
        val to = body.loadAddress();
        val responseTo = body.loadAny<any_address>();   // AUDIT (I-1): addr_none allowed
        body.loadMaybeRef();                 // custom_payload (ignored)
        val fwdTon = body.loadCoins();
        // AUDIT (high, fixed): the forward payload used to be read as
        // `Either 0 -> nothing / 1 -> ^Cell`, so an INLINE payload (Either = 0
        // followed by the payload in the same cell, which is what @dedust/sdk,
        // wallets and aggregators emit) was silently DROPPED. The receiving
        // contract then got a payload-less transfer_notification and threw —
        // every DeDust swap of a pad token bounced. The payload is now carried
        // through verbatim, exactly as TEP-74 requires.
        val fwdPayload = body;


        // Only basechain recipients: a masterchain destination would derive a
        // wallet this code can never serve, and fees differ per workchain.
        assert(to.getWorkchain() == MY_WORKCHAIN, ERR_WRONG_WORKCHAIN);
        // The sender must fund the whole message chain, never this wallet.
        assert(in.valueCoins > minTransferValue(fwdTon, in.originalForwardFee), ERR_NOT_ENOUGH_GAS);

        assert(w.balance >= amount, ERR_BALANCE);
        w.balance -= amount;
        saveWallet(w);

        val destData = walletDataFor(w.code, to, w.minter);
        val cs: ContractState = { code: w.code, data: destData };
        val destWallet = AutoDeployAddress { stateInit: cs }.calculateAddress();

        var mb = beginCell()
            .storeUint(OP_INTERNAL_TRANSFER, 32)
            .storeUint(queryId, 64)
            .storeCoins(amount)
            .storeAddress(w.owner)
            .storeAny<any_address>(responseTo)
            .storeCoins(fwdTon);
        mb = appendForwardPayload(mb, fwdPayload);


        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(destWallet)
            .storeCoins(0)
            .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
            .storeRef(packStateInit(w.code, destData))
            .storeRef(mb.endCell())
            .endCell(), 64);                 // carry the remaining value
        return;
    }

    // incoming jettons: from the minter (mint) or a sibling wallet (transfer)
    if (op == OP_INTERNAL_TRANSFER) {
        val amount = body.loadCoins();
        val from = body.loadAddress();
        val responseTo = body.loadAny<any_address>();   // AUDIT 2026-10-24: addr_none accepted downstream too
        val fwdTon = body.loadCoins();
        val fwdPayload = body;               // Either-bit + payload, verbatim

        val expected = walletAddressFor(w.code, from, w.minter);
        assert(in.senderAddress == w.minter || in.senderAddress == expected, ERR_NOT_VALID_SENDER);

        w.balance += amount;
        saveWallet(w);

        if (fwdTon > 0) {
            var nb = beginCell()
                .storeUint(OP_TRANSFER_NOTIFICATION, 32)
                .storeUint(queryId, 64)
                .storeCoins(amount)
                .storeAddress(from);
            nb = appendForwardPayload(nb, fwdPayload);

            sendRawMessage(beginCell()
                .storeUint(0x10, 6)          // non-bounceable
                .storeAddress(w.owner)
                .storeCoins(fwdTon)
                .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeRef(nb.endCell())
                .endCell(), 1);
        }

        if (!responseTo.isNone()) {
            // Keep the pre-message balance plus a 5-year storage cushion before
            // carrying everything else back, so refunding excess can never leave
            // this wallet in storage-rent debt (freeze / deletion risk).
            val keep = contract.getOriginalBalance() - in.valueCoins
                + contract.getStorageDuePayment();
            reserveGramsOnBalance(max(keep, minStorageFee()), RESERVE_MODE_AT_MOST);
            sendRawMessage(beginCell()
                .storeUint(0x10, 6)
                .storeAddress(responseTo as address)
                .storeCoins(0)
                .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeUint(OP_EXCESSES, 32)
                .storeUint(queryId, 64)
                .endCell(), 128 + 2);        // send what is left, ignore errors
        }
        return;
    }

    // owner burns jettons
    if (op == OP_BURN) {
        assert(in.senderAddress == w.owner, ERR_NOT_OWNER);
        val amount = body.loadCoins();
        val responseTo = body.loadAny<any_address>();   // AUDIT (I-1): addr_none allowed
        assert(in.valueCoins > minBurnValue(), ERR_NOT_ENOUGH_GAS);
        assert(w.balance >= amount, ERR_BALANCE);
        w.balance -= amount;
        saveWallet(w);

        // ROUND 31 (audit 2026-10-24): the notification body rides as a ref. Inline,
        // a burn naming a full response address with a large amount overflowed
        // the message cell (exit 8), so such burns failed.
        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(w.minter)
            .storeCoins(0)
            .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeRef(beginCell()
                .storeUint(OP_BURN_NOTIFICATION, 32)
                .storeUint(queryId, 64)
                .storeCoins(amount)
                .storeAddress(w.owner)
                .storeAny<any_address>(responseTo)
                .endCell())
            .endCell(), 64);
        return;
    }

    if (op == OP_EXCESSES) { return; }
    assert(false, 0xffff);
}

get fun get_wallet_data(): (coins, address, address, cell) {
    val w = loadWallet();
    return (w.balance, w.owner, w.minter, w.code);
}
