import "@stdlib/gas-payments"
import "@gen/JettonWalletWithFees.code"
import "creation"
import "fee-rules"
import "fee-token-fees"
import "fee-token-messages"
import "fee-token-storage"
import "fee-wallet-fees"
import "fee-wallet-messages"
import "fee-wallet-utils"
import "messages"
import "sharding"
import "storage"
import "token-errors"
import "token-fees"
import "token-messages"
import "token-sends"
import "token-storage"

type AllowedMessageToFeeToken =
    | BurnNotificationForMinter
    | RequestWalletAddress
    | SetExcluded
    | LockExclusions
    | ChangeMinterAdmin
    | ClaimMinterAdmin
    | DropMinterAdmin
    | TakeGram
    | TakeTokens
    | TopUpGrams
    | TextComment

type BounceableFromFeeToken = InternalTransferStep | AskToTransfer

fun FeeTokenStorage.rent(self): coins {
    return tokenRent(
        FEE_TOKEN_STATE_BITS + self.metadataBits,
        FEE_TOKEN_STATE_CELLS + self.metadataCells,
    );
}

fun loadFeeTokenForAdmin(senderAddress: address): FeeTokenStorage {
    val storage = loadStartedFeeToken();
    val admin = storage.roles.load().adminAddress;
    assert (admin != null && senderAddress == admin) throw TokenErrors.NotAdmin;
    return storage;
}

fun loadFeeTokenForCreator(senderAddress: address): FeeTokenStorage {
    val storage = loadStartedFeeToken();
    assert (senderAddress == storage.roles.load().creator) throw TokenErrors.NotCreator;
    return storage;
}

fun taxIsValid(rule: TaxRule?): bool {
    return rule == null || (rule.permille > 0 && rule.to.getWorkchain() == MY_WORKCHAIN);
}

fun taxRate(rule: TaxRule?): int {
    return rule == null ? 0 : rule.permille;
}

fun taxAddress(rule: TaxRule?): any_address {
    return rule == null ? createAddressNone() : rule.to as any_address;
}

fun feeWalletOf(ownerAddress: address, rules: Cell<FeeRules>): AutoDeployAddress {
    return calcDeployedFeeWallet(
        ownerAddress,
        contract.getAddress(),
        rules,
        jettonWalletWithFeesCompiledCode(),
    );
}

fun startFeeToken(loading: ContractLoader, valueCoins: coins, msg: Start) {
    val params = FeeTokenParams.fromCell(msg.params);
    assert (params.supply > 0) throw TokenErrors.InvalidSupply;
    assert (
        loading.kind == TOKEN_KIND_TAXABLE ||
        (params.tax1 == null && params.tax2 == null && params.tax3 == null)
    ) throw TokenErrors.InvalidRules;
    assert (
        taxIsValid(params.tax1) && taxIsValid(params.tax2) && taxIsValid(params.tax3)
    ) throw TokenErrors.InvalidRules;
    assert (
        params.burnPermille + taxRate(params.tax1) + taxRate(params.tax2) + taxRate(params.tax3) <=
        1000
    ) throw TokenErrors.InvalidRules;
    val (sizeCells, sizeBits, _, fits) = params.metadata.calculateSize(METADATA_MAX_CELLS);
    assert (fits) throw TokenErrors.MetadataTooLarge;

    val creator = msg.receipt.creator;
    var named: NamedAddresses = { first: null, second: null };
    if (params.named != null) {
        named = params.named.load();
    }
    val forGood: ExcludedForGood = {
        creator,
        named1: named.first,
        named2: named.second,
    };
    val rules: FeeRules = {
        burnPermille: params.burnPermille,
        tax1: params.tax1,
        tax2: params.tax2,
        tax3: params.tax3,
        forGood: forGood.toCell(),
    };
    val rulesCell = rules.toCell();
    val roles: TokenRoles = {
        creator,
        adminAddress: creator,
        nextAdminAddress: null,
    };
    val storage: FeeTokenStorage = {
        factory: loading.factory,
        kind: loading.kind,
        index: loading.index,
        queryId: msg.queryId,
        totalSupply: params.supply,
        firstSupply: params.supply,
        exclusionsLockedUntil: 0,
        metadataBits: sizeBits! as uint32,
        metadataCells: sizeCells! as uint16,
        roles: roles.toCell(),
        rules: rulesCell,
        metadata: params.metadata,
    };
    storage.save();

    val mintMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: feeWalletOf(creator, rulesCell),
        value: firstFeeMintValue(),
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

    keepRent(valueCoins, storage.rent());
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

fun restoreSupplyOfBouncedFeeMint(bouncedBody: slice) {
    var body = bouncedBody;
    body.skipBouncedPrefix();
    val msg = lazy BounceableFromFeeToken.fromSlice(body);

    match (msg) {
        InternalTransferStep => {
            var storage = loadStartedFeeToken();
            storage.totalSupply -= msg.jettonAmount;
            storage.save();
        }
        AskToTransfer => {}
        else => {}
    }
}

fun acceptFeeBurnNotification(senderAddress: address, msg: BurnNotificationForMinter) {
    var storage = loadStartedFeeToken();
    assert (
        senderAddress == feeWalletOf(msg.burnInitiator, storage.rules).calculateAddress()
    ) throw TokenErrors.NotValidWallet;
    storage.totalSupply -= msg.jettonAmount;
    storage.save();

    if (msg.sendExcessesTo == null) {
        return;
    }
    returnTheMessageRest(msg.sendExcessesTo, msg.queryId);
}

fun answerFeeWalletAddress(senderAddress: address, msg: RequestWalletAddress) {
    val storage = loadStartedFeeToken();
    val ownerAddress: Cell<address>? = msg.includeOwnerAddress ? msg.ownerAddress.toCell() : null;

    var walletAddress: address? = null;
    if (msg.ownerAddress.getWorkchain() == MY_WORKCHAIN) {
        walletAddress = feeWalletOf(msg.ownerAddress, storage.rules).calculateAddress();
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

fun setExcluded(senderAddress: address, valueCoins: coins, msg: SetExcluded) {
    val storage = loadFeeTokenForAdmin(senderAddress);
    assert (blockchain.now() >= storage.exclusionsLockedUntil) throw TokenErrors.ExclusionsLocked;
    assert (msg.account.getWorkchain() == MY_WORKCHAIN) throw TokenErrors.WrongWorkchain;

    keepRent(valueCoins, storage.rent());

    val markMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: feeWalletOf(msg.account, storage.rules),
        value: feeWalletMarkAmount(),
        body: MarkExcluded {
            queryId: msg.queryId,
            excluded: msg.excluded,
        },
    });
    markMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    returnTheRest(senderAddress, msg.excluded ? NOTE_WHITELIST_ADDED : NOTE_WHITELIST_REMOVED);
}

fun lockExclusions(senderAddress: address, msg: LockExclusions) {
    var storage = loadFeeTokenForAdmin(senderAddress);
    assert (
        msg.until > max(blockchain.now(), storage.exclusionsLockedUntil)
    ) throw TokenErrors.InvalidLock;
    storage.exclusionsLockedUntil = msg.until;
    storage.save();
    answerWithNote(senderAddress, NOTE_WHITELIST_LOCKED);
}

fun proposeFeeTokenAdmin(senderAddress: address, msg: ChangeMinterAdmin) {
    var storage = loadFeeTokenForAdmin(senderAddress);
    var roles = storage.roles.load();
    roles.nextAdminAddress = msg.newAdminAddress;
    storage.roles = roles.toCell();
    storage.save();
    answerWithNote(senderAddress, NOTE_ADMIN_OFFERED);
}

fun claimFeeTokenAdmin(senderAddress: address) {
    var storage = loadStartedFeeToken();
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

fun dropFeeTokenAdmin(senderAddress: address) {
    var storage = loadFeeTokenForAdmin(senderAddress);
    var roles = storage.roles.load();
    roles.adminAddress = null;
    roles.nextAdminAddress = null;
    storage.roles = roles.toCell();
    storage.save();
    answerWithNote(senderAddress, NOTE_ADMIN_GIVEN_UP);
}

fun takeFeeTokenGram(senderAddress: address) {
    val storage = loadFeeTokenForCreator(senderAddress);
    reserveGramsOnBalance(
        storage.rent() + contract.getStorageDuePayment(),
        RESERVE_MODE_AT_MOST,
    );
    val takenMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: senderAddress,
        value: 0,
        body: TextComment { text: NOTE_GRAM_TAKEN },
    });
    // SAFETY: the rent and what the token owes for it are reserved above; everything beyond is what the creator takes out
    takenMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun takeFeeTokenTokens(senderAddress: address, msg: TakeTokens) {
    loadFeeTokenForCreator(senderAddress);
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

fun handleFeeTokenMessage(senderAddress: address, valueCoins: coins, body: slice) {
    val loading = ContractLoader.start();
    if (loading.isUnstarted()) {
        assert (senderAddress == loading.factory) throw TokenErrors.NotFactory;
        return startFeeToken(loading, valueCoins, Start.fromSlice(body));
    }

    val msg = lazy AllowedMessageToFeeToken.fromSlice(body);

    match (msg) {
        BurnNotificationForMinter => acceptFeeBurnNotification(senderAddress, msg),
        RequestWalletAddress => answerFeeWalletAddress(senderAddress, msg),
        SetExcluded => setExcluded(senderAddress, valueCoins, msg),
        LockExclusions => lockExclusions(senderAddress, msg),
        ChangeMinterAdmin => proposeFeeTokenAdmin(senderAddress, msg),
        ClaimMinterAdmin => claimFeeTokenAdmin(senderAddress),
        DropMinterAdmin => dropFeeTokenAdmin(senderAddress),
        TakeGram => takeFeeTokenGram(senderAddress),
        TakeTokens => takeFeeTokenTokens(senderAddress, msg),
        TopUpGrams => {}
        TextComment => returnPlainSend(senderAddress),
        else => {
            assert (body.isEmpty()) throw 0xFFFF;
            returnPlainSend(senderAddress);
        }
    }
}

fun feeTokenJettonData(): TokenDataReply {
    val storage = loadFeeTokenIfStarted();
    if (storage == null) {
        val empty: OnchainMetadataReply = { contentDict: [] };
        return {
            totalSupply: 0,
            mintable: false,
            adminAddress: createAddressNone(),
            jettonContent: empty.toCell(),
            jettonWalletCode: jettonWalletWithFeesCompiledCode(),
        };
    }
    return {
        totalSupply: storage.totalSupply,
        mintable: false,
        adminAddress: addressOrNone(storage.roles.load().adminAddress),
        jettonContent: storage.metadata as Cell<OnchainMetadataReply>,
        jettonWalletCode: jettonWalletWithFeesCompiledCode(),
    };
}

fun feeRulesReply(): FeeRulesReply {
    val storage = loadFeeTokenIfStarted();
    if (storage == null) {
        return {
            burnPermille: 0,
            tax1Permille: 0,
            tax1Address: createAddressNone(),
            tax2Permille: 0,
            tax2Address: createAddressNone(),
            tax3Permille: 0,
            tax3Address: createAddressNone(),
            creator: createAddressNone(),
            named1: createAddressNone(),
            named2: createAddressNone(),
        };
    }
    val rules = storage.rules.load();
    val forGood = rules.forGood.load();
    return {
        burnPermille: rules.burnPermille,
        tax1Permille: taxRate(rules.tax1),
        tax1Address: taxAddress(rules.tax1),
        tax2Permille: taxRate(rules.tax2),
        tax2Address: taxAddress(rules.tax2),
        tax3Permille: taxRate(rules.tax3),
        tax3Address: taxAddress(rules.tax3),
        creator: forGood.creator as any_address,
        named1: addressOrNone(forGood.named1),
        named2: addressOrNone(forGood.named2),
    };
}

fun feeTokenOrigin(): OriginReply {
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
    val storage = loading.endFeeToken();
    return {
        factory: storage.factory,
        kind: storage.kind,
        index: storage.index,
        creator: storage.roles.load().creator as any_address,
        queryId: storage.queryId,
    };
}
