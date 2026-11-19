import "@gen/JettonWallet.code"
import "creation"
import "fees-management"
import "jetton-utils"
import "messages"
import "sharding"
import "token-core"
import "token-errors"
import "token-fees"
import "token-messages"
import "token-sends"
import "token-storage"

type AllowedMessageToMintableToken =
    | MintNewJettons
    | BurnNotificationForMinter
    | RequestWalletAddress
    | ChangeMinterAdmin
    | ClaimMinterAdmin
    | DropMinterAdmin
    | LockMinting
    | TakeGram
    | TakeTokens
    | TopUpGrams
    | TextComment

fun loadTokenForAdmin(senderAddress: address): TokenStorage {
    val storage = loadStartedToken();
    val admin = storage.roles.load().adminAddress;
    assert (admin != null && senderAddress == admin) throw TokenErrors.NotAdmin;
    return storage;
}

fun mintTokens(
    senderAddress: address,
    valueCoins: coins,
    originalForwardFee: coins,
    msg: MintNewJettons,
) {
    var storage = loadTokenForAdmin(senderAddress);
    assert (blockchain.now() >= storage.mintingLockedUntil) throw TokenErrors.MintingLocked;
    assert (msg.mintRecipient.getWorkchain() == MY_WORKCHAIN) throw TokenErrors.WrongWorkchain;

    val internalTransferMsg = lazy msg
        .internalTransferMsg
        .load({ throwIfOpcodeDoesNotMatch: TokenErrors.InvalidPayload });
    val forwardTonAmount = internalTransferMsg.forwardTonAmount;
    var payload = internalTransferMsg.forwardPayload;
    if (payload.loadMaybeRef() != null) {
        assert (payload.isEmpty()) throw TokenErrors.InvalidPayload;
    }
    assert (
        msg.tonAmount > calcMinimalTransferAmount(forwardTonAmount, originalForwardFee)
    ) throw TokenErrors.NotEnoughGas;

    storage.totalSupply += internalTransferMsg.jettonAmount;
    if (storage.maxSupply != 0) {
        assert (storage.totalSupply <= storage.maxSupply) throw TokenErrors.CapExceeded;
    }
    storage.save();

    keepRent(valueCoins, storage.rent(TOKEN_MINTABLE_STATE_BITS, TOKEN_MINTABLE_STATE_CELLS));

    val deployMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: calcDeployedJettonWallet(
            msg.mintRecipient,
            contract.getAddress(),
            jettonWalletCompiledCode(),
        ),
        value: msg.tonAmount,
        body: msg.internalTransferMsg,
    });
    deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    returnTheRest(senderAddress, NOTE_MINTED);
}

fun proposeAdmin(senderAddress: address, msg: ChangeMinterAdmin) {
    var storage = loadTokenForAdmin(senderAddress);
    var roles = storage.roles.load();
    roles.nextAdminAddress = msg.newAdminAddress;
    storage.roles = roles.toCell();
    storage.save();
    answerWithNote(senderAddress, NOTE_ADMIN_OFFERED);
}

fun claimAdmin(senderAddress: address) {
    var storage = loadStartedToken();
    var roles = storage.roles.load();
    assert (
        roles.nextAdminAddress != null && senderAddress == roles.nextAdminAddress
    ) throw TokenErrors.NotAdmin;
    roles.adminAddress = roles.nextAdminAddress;
    roles.nextAdminAddress = null;
    storage.roles = roles.toCell();
    storage.save();
    answerWithNote(senderAddress, NOTE_ADMIN_TAKEN);
}

fun dropAdmin(senderAddress: address) {
    var storage = loadTokenForAdmin(senderAddress);
    var roles = storage.roles.load();
    roles.adminAddress = null;
    roles.nextAdminAddress = null;
    storage.roles = roles.toCell();
    storage.save();
    answerWithNote(senderAddress, NOTE_MINTING_CLOSED);
}

fun lockMinting(senderAddress: address, msg: LockMinting) {
    var storage = loadTokenForAdmin(senderAddress);
    assert (
        msg.until > max(blockchain.now(), storage.mintingLockedUntil)
    ) throw TokenErrors.InvalidLock;
    storage.mintingLockedUntil = msg.until;
    storage.save();
    answerWithNote(senderAddress, NOTE_MINTING_LOCKED);
}

fun handleMintableTokenMessage(
    senderAddress: address,
    valueCoins: coins,
    originalForwardFee: coins,
    body: slice,
) {
    val loading = ContractLoader.start();
    if (loading.isUnstarted()) {
        assert (senderAddress == loading.factory) throw TokenErrors.NotFactory;
        val start = Start.fromSlice(body);
        val params = TokenParams.fromCell(start.params);
        assert (
            (loading.kind == TOKEN_KIND_CAPPED) == (params.maxSupply != 0)
        ) throw TokenErrors.InvalidCap;
        assert (
            params.maxSupply == 0 || params.maxSupply >= params.supply
        ) throw TokenErrors.InvalidCap;
        return startToken(
            loading,
            valueCoins,
            start,
            params,
            true,
            TOKEN_MINTABLE_STATE_BITS,
            TOKEN_MINTABLE_STATE_CELLS,
        );
    }

    val msg = lazy AllowedMessageToMintableToken.fromSlice(body);

    match (msg) {
        MintNewJettons => mintTokens(senderAddress, valueCoins, originalForwardFee, msg),
        BurnNotificationForMinter => acceptBurnNotification(senderAddress, msg),
        RequestWalletAddress => answerWalletAddress(senderAddress, msg),
        ChangeMinterAdmin => proposeAdmin(senderAddress, msg),
        ClaimMinterAdmin => claimAdmin(senderAddress),
        DropMinterAdmin => dropAdmin(senderAddress),
        LockMinting => lockMinting(senderAddress, msg),
        TakeGram => takeGram(
            senderAddress,
            TOKEN_MINTABLE_STATE_BITS,
            TOKEN_MINTABLE_STATE_CELLS,
        ),
        TakeTokens => takeTokens(senderAddress, msg),
        TopUpGrams => {}
        TextComment => returnPlainSend(senderAddress),
        else => {
            assert (body.isEmpty()) throw 0xFFFF;
            returnPlainSend(senderAddress);
        }
    }
}
