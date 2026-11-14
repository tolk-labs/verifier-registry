// JettonMinter.tolk — minimal TEP-74 jetton master used for every meme token.
//
// Storage layout MUST match `minterData()` in BondingCurve.tolk:
//   total_supply:Coins admin:MsgAddress ^content ^wallet_code
//
// The admin is always the bonding curve that deployed it.

import "@stdlib/gas-payments";

const OP_MINT = 21;
const OP_INTERNAL_TRANSFER = 0x178d4519;
const OP_BURN_NOTIFICATION = 0x7bdd97de;
const OP_PROVIDE_WALLET_ADDRESS = 0x2c76b973;
const OP_TAKE_WALLET_ADDRESS = 0xd1735400;
const OP_EXCESSES = 0xd53276db;

const ERR_NOT_ADMIN = 73;
const ERR_NOT_VALID_SENDER = 74;
const ERR_NOT_ENOUGH_GAS = 76;
const ERR_WRONG_WORKCHAIN = 333;
const ERR_SUPPLY = 77;

/// Storage cushion, mirroring JettonWallet.tolk: the minter lives forever and
/// must never be able to refund itself into storage debt (freeze / deletion of
/// the master would break wallet discovery for the whole token).
const MY_WORKCHAIN = 0;
const MIN_STORAGE_DURATION = 5 * 365 * 24 * 3600;
const STORAGE_SIZE_MINTER_BITS = 1000;
const STORAGE_SIZE_MINTER_CELLS = 3;

fun minStorageFee(): coins {
    return calculateStorageFee(MY_WORKCHAIN, MIN_STORAGE_DURATION,
        STORAGE_SIZE_MINTER_BITS, STORAGE_SIZE_MINTER_CELLS);
}

struct Minter {
    supply: coins;
    admin: address;
    content: cell;
    walletCode: cell;
}

fun loadMinter(): Minter {
    var cs = contract.getData().beginParse();
    return {
        supply: cs.loadCoins(),
        admin: cs.loadAddress(),
        content: cs.loadRef(),
        walletCode: cs.loadRef(),
    };
}

fun saveMinter(m: Minter) {
    contract.setData(beginCell()
        .storeCoins(m.supply)
        .storeAddress(m.admin)
        .storeRef(m.content)
        .storeRef(m.walletCode)
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

/// addr_std 0:00..00 — nobody holds this key, so assigning it as admin
/// permanently revokes minting and admin transfer.
fun zeroAddress(): address {
    return beginCell().storeUint(4, 3).storeInt(0, 8).storeUint(0, 256)
        .endCell().beginParse().loadAddress();
}

fun walletAddressFor(code: cell, owner: address, minter: address): address {
    val cs: ContractState = { code: code, data: walletDataFor(code, owner, minter) };
    return AutoDeployAddress { stateInit: cs }.calculateAddress();
}

/// Real bounces only (routed by the runtime, unforgeable). Supply is credited
/// before internal_transfer is delivered, so a bounced mint must be reversed.
fun onBouncedMessage(in: InMessageBounced) {
    var bb = in.bouncedBody;
    bb.skipBouncedPrefix();
    if (bb.remainingBitsCount() < 32 + 64 + 4) { return; }
    val origOp = bb.loadUint(32);
    bb.loadUint(64);
    if (origOp == OP_INTERNAL_TRANSFER) {
        val amt = bb.loadCoins();
        var mb = loadMinter();
        if (mb.supply >= amt) {
            mb.supply -= amt;
            saveMinter(mb);
        }
    }
}

// curve mints the whole supply to itself right after deployment
fun doMint(mIn: Minter, sender: address, value: coins, bodyIn: slice) {
        var m = mIn;
        var body = bodyIn;
        assert(sender == m.admin, ERR_NOT_ADMIN);
        val to = body.loadAddress();
        val tonAmount = body.loadCoins();
        val masterMsg = body.loadRef();
        // AUDIT (critical, fixed): admin is revoked in this same transaction, so
        // a BOUNCED mint would leave the jetton with zero supply and no admin —
        // permanently bricked. Refuse the mint up front unless the caller
        // attached enough to pay the whole deploy+internal_transfer chain, which
        // is the only realistic way that leg can fail. Bouncing HERE is safe:
        // nothing has been written yet and the curve can retry.
        assert(value >= tonAmount
            + calculateForwardFeeWithoutLumpPrice(MY_WORKCHAIN, 812, 3)
            + calculateGasFee(MY_WORKCHAIN, 20000), ERR_NOT_ENOUGH_GAS);
        // basechain only: the wallet code and every fee assumption are workchain 0
        assert(to.getWorkchain() == MY_WORKCHAIN, ERR_WRONG_WORKCHAIN);

        // read the minted amount out of the internal_transfer body
        var ms = masterMsg.beginParse();
        ms.loadUint(32);
        ms.loadUint(64);
        m.supply += ms.loadCoins();
        // one-shot mint: revoke admin immediately so the jetton can never be
        // minted again and no authority can be transferred.
        m.admin = zeroAddress();
        saveMinter(m);

        val destData = walletDataFor(m.walletCode, to, contract.getAddress());
        val cs: ContractState = { code: m.walletCode, data: destData };
        val destWallet = AutoDeployAddress { stateInit: cs }.calculateAddress();

        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(destWallet)
            .storeCoins(tonAmount)
            .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
            .storeRef(packStateInit(m.walletCode, destData))
            .storeRef(masterMsg)
            .endCell(), 1);
}

fun onInternalMessage(in: InMessage) {
    var body = in.body;
    if (body.isEmpty()) { return; }
    val op = body.loadUint(32);
    // Forged "bounce" bodies must never touch supply.
    if (op == 0xffffffff) { return; }

    val queryId = body.loadUint(64);
    var m = loadMinter();


    if (op == OP_MINT) {
        doMint(m, in.senderAddress, in.valueCoins, body);
        return;
    }

    if (op == OP_BURN_NOTIFICATION) {
        val amount = body.loadCoins();
        val from = body.loadAddress();
        val responseTo = body.loadAny<any_address>();   // AUDIT 2026-10-24: addr_none burns no longer bounce
        assert(in.senderAddress == walletAddressFor(m.walletCode, from, contract.getAddress()),
               ERR_NOT_VALID_SENDER);
        // defence in depth: a wallet can never notify a burn larger than the
        // supply it was minted from, but never let the counter underflow blindly
        assert(m.supply >= amount, ERR_SUPPLY);
        m.supply -= amount;
        saveMinter(m);
        if (!responseTo.isNone()) {
            // Never carry away the minter's own balance: reserve everything it
            // held before this message so it can keep paying storage rent.
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
                .endCell(), 128 + 2);
        }
        return;
    }

    // TEP-89 wallet address discovery
    if (op == OP_PROVIDE_WALLET_ADDRESS) {
        // ROUND 31 (audit 2026-10-29): TEP-89 says a wallet address is returned
        // only for owners this jetton can serve; every other owner (another
        // workchain, addr_none, an external address) gets addr_none back.
        val owner = body.loadAny<any_address>();
        val includeOwner = body.loadUint(1);
        var b = beginCell()
            .storeUint(OP_TAKE_WALLET_ADDRESS, 32)
            .storeUint(queryId, 64);
        if (owner.isInternal() && owner.getWorkchain() == MY_WORKCHAIN) {
            b = b.storeAddress(walletAddressFor(m.walletCode, owner.castToInternal(), contract.getAddress()));
        } else {
            b = b.storeUint(0, 2);                  // addr_none
        }
        if (includeOwner != 0) {
            b = b.storeUint(1, 1).storeRef(beginCell().storeAny<any_address>(owner).endCell());
        } else {
            b = b.storeUint(0, 1);
        }
        sendRawMessage(beginCell()
            .storeUint(0x18, 6)
            .storeAddress(in.senderAddress)
            .storeCoins(0)
            .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeRef(b.endCell())
            .endCell(), 64);
        return;
    }

    if (op == OP_EXCESSES) { return; }
    assert(false, 0xffff);
}

get fun get_jetton_data(): (coins, int, address, cell, cell) {
    val m = loadMinter();
    val mintable = m.admin == zeroAddress() ? 0 : -1;
    return (m.supply, mintable, m.admin, m.content, m.walletCode);
}

get fun get_wallet_address(owner: address): address {
    val m = loadMinter();
    return walletAddressFor(m.walletCode, owner, contract.getAddress());
}
