import "@stdlib/gas-payments"
import "@gen/JettonWallet.code"
import "creation"
import "jetton-utils"
import "messages"
import "sharding"
import "storage"
import "token-errors"
import "token-fees"
import "token-messages"
import "token-sends"
import "token-storage"

type BounceableFromToken = InternalTransferStep | AskToTransfer

fun TokenStorage.rent(self, stateBits: int, stateCells: int): coins {
    return tokenRent(stateBits + self.metadataBits, stateCells + self.metadataCells);
}

fun restoreSupplyOfBouncedMint(bouncedBody: slice) {
    var body = bouncedBody;
    body.skipBouncedPrefix();
    val msg = lazy BounceableFromToken.fromSlice(body);

    match (msg) {
        InternalTransferStep => {
            var storage = loadStartedToken();
            storage.totalSupply -= msg.jettonAmount;
            storage.save();
        }
        AskToTransfer => {}
        else => {}
    }
}

fun startToken(
    loading: ContractLoader,
    valueCoins: coins,
    msg: Start,
    params: TokenParams,
    withAdmin: bool,
    stateBits: int,
    stateCells: int,
) {
    assert (params.supply > 0) throw TokenErrors.InvalidSupply;
    val creator = msg.receipt.creator;
    val (sizeCells, sizeBits, _, fits) = params.metadata.calculateSize(METADATA_MAX_CELLS);
    assert (fits) throw TokenErrors.MetadataTooLarge;
    val metadataCells = sizeCells!;
    val metadataBits = sizeBits!;

    val roles: TokenRoles = {
        creator,
        adminAddress: withAdmin ? creator : null,
        nextAdminAddress: null,
    };
    val storage: TokenStorage = {
        factory: loading.factory,
        kind: loading.kind,
        index: loading.index,
        queryId: msg.queryId,
        totalSupply: params.supply,
        maxSupply: params.maxSupply,
        mintingLockedUntil: 0,
        metadataBits: metadataBits as uint32,
        metadataCells: metadataCells as uint16,
        roles: roles.toCell(),
        metadata: params.metadata,
    };
    storage.save();

    val mintMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: calcDeployedJettonWallet(creator, contract.getAddress(), jettonWalletCompiledCode()),
        value: firstMintValue(),
        body: InternalTransferStep {
            queryId: msg.queryId,
            jettonAmount: params.supply,
            transferInitiator: null,
            sendExcessesTo: creator,
            forwardTonAmount: 1,
            forwardPayload: beginCell().storeUint(0, 1).toSlice(),
        },
    });
    mintMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    keepRent(valueCoins, storage.rent(stateBits, stateCells));
    val startedMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: loading.factory,
        value: 0,
        body: Started {
            queryId: msg.queryId,
            kind: loading.kind,
            index: loading.index,
            subject: null,
            receipt: msg.receipt.toCell(),
        },
    });
    // SAFETY: the rent and the balance from before this message are reserved above; the rest of the creation's value goes on with the report
    startedMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun acceptBurnNotification(senderAddress: address, msg: BurnNotificationForMinter) {
    var storage = loadStartedToken();
    assert (
        senderAddress ==
        calcAddressOfJettonWallet(
            msg.burnInitiator,
            contract.getAddress(),
            jettonWalletCompiledCode(),
        )
    ) throw TokenErrors.NotValidWallet;
    storage.totalSupply -= msg.jettonAmount;
    storage.save();

    if (msg.sendExcessesTo == null) {
        return;
    }
    returnTheMessageRest(msg.sendExcessesTo, msg.queryId);
}

fun answerWalletAddress(senderAddress: address, msg: RequestWalletAddress) {
    val ownerAddress: Cell<address>? = msg.includeOwnerAddress ? msg.ownerAddress.toCell() : null;

    var walletAddress: address? = null;
    if (msg.ownerAddress.getWorkchain() == MY_WORKCHAIN) {
        walletAddress = calcAddressOfJettonWallet(
            msg.ownerAddress,
            contract.getAddress(),
            jettonWalletCompiledCode(),
        );
    }

    val respondMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: senderAddress,
        value: 0,
        body: ResponseWalletAddress {
            queryId: msg.queryId,
            jettonWalletAddress: walletAddress,
            ownerAddress,
        },
    });
    respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun loadTokenForCreator(senderAddress: address): TokenStorage {
    val storage = loadStartedToken();
    assert (senderAddress == storage.roles.load().creator) throw TokenErrors.NotCreator;
    return storage;
}

fun takeGram(senderAddress: address, stateBits: int, stateCells: int) {
    val storage = loadTokenForCreator(senderAddress);
    reserveGramsOnBalance(
        storage.rent(stateBits, stateCells) + contract.getStorageDuePayment(),
        RESERVE_MODE_AT_MOST,
    );
    val takenMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: senderAddress,
        value: 0,
        body: TextComment { text: NOTE_GRAM_TAKEN },
    });
    // SAFETY: the rent is reserved above; everything beyond it is what the creator takes out
    takenMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun takeTokens(senderAddress: address, msg: TakeTokens) {
    loadTokenForCreator(senderAddress);
    assert (msg.amount > 0) throw TokenErrors.NothingToTake;
    val orderMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: msg.wallet,
        value: 0,
        body: AskToTransfer {
            queryId: msg.queryId,
            jettonAmount: msg.amount,
            transferRecipient: senderAddress,
            sendExcessesTo: senderAddress,
            customPayload: null,
            forwardTonAmount: 1,
            forwardPayload: notePayload(NOTE_TOKENS_TAKEN),
        },
    });
    orderMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun tokenJettonData(): TokenDataReply {
    var loading = ContractLoader.start();
    if (loading.isUnstarted()) {
        val empty: OnchainMetadataReply = { contentDict: [] };
        return {
            totalSupply: 0,
            mintable: false,
            adminAddress: createAddressNone(),
            jettonContent: empty.toCell(),
            jettonWalletCode: jettonWalletCompiledCode(),
        };
    }
    val storage = loading.endToken();
    val admin = storage.roles.load().adminAddress;
    return {
        totalSupply: storage.totalSupply,
        mintable: admin != null,
        adminAddress: addressOrNone(admin),
        jettonContent: storage.metadata as Cell<OnchainMetadataReply>,
        jettonWalletCode: jettonWalletCompiledCode(),
    };
}

fun tokenWalletAddress(ownerAddress: address): address {
    return calcAddressOfJettonWallet(
        ownerAddress,
        contract.getAddress(),
        jettonWalletCompiledCode(),
    );
}

fun tokenOrigin(): OriginReply {
    var loading = ContractLoader.start();
    if (loading.isUnstarted()) {
        return {
            factory: loading.factory,
            kind: loading.kind,
            index: loading.index,
            creator: createAddressNone(),
            queryId: 0,
        };
    }
    val storage = loading.endToken();
    return {
        factory: storage.factory,
        kind: storage.kind,
        index: storage.index,
        creator: storage.roles.load().creator as any_address,
        queryId: storage.queryId,
    };
}
