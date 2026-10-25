tolk 1.5

// PassGramRegistry, compiled with Tolk 1.5.0 so verifier.ton.org can recompile it.
// Incoming and outgoing message layouts match the Mini App and the indexer.

struct CommunityConfig {
    creator: address
    payout: address
    price: coins
    durationSeconds: uint32
    platformReferrer: address?
    communityReferralBps: uint16
    accessMode: uint8
    paused: bool
}

struct SubscriberReferralLock {
    bps: uint16
    marketer: address?
}

struct ReferralLockMap {
    locks: map<address, SubscriberReferralLock>
}

struct OutgoingPayout {
    destination: address
    amount: coins
    queued: bool
    nextRetry: uint64
}

struct StorageHead {
    owner: address
    treasury: address
    platformFeeBps: uint16
    affiliateShareOfPlatformBps: uint16
    maxCommunityReferralBps: uint16
    usdtJettonMaster: address
}

struct StorageTail {
    ownerPublicKey: uint256
    usdtJettonWallet: address?
    nextPayoutId: uint64
    retryHead: uint64
    retryTail: uint64
}

struct CommunityBook {
    items: map<uint64, CommunityConfig>
}

struct ReferralBook {
    items: map<uint64, ReferralLockMap>
}

struct PayoutBook {
    items: map<uint64, OutgoingPayout>
}

struct PersistedBooks {
    communities: cell
    referralLocks: cell
    payouts: cell
}

struct Persisted {
    head: cell
    tail: cell
    books: cell
}

struct Storage {
    owner: address
    treasury: address
    platformFeeBps: uint16
    affiliateShareOfPlatformBps: uint16
    maxCommunityReferralBps: uint16
    usdtJettonMaster: address
    ownerPublicKey: uint256
    usdtJettonWallet: address?
    communities: map<uint64, CommunityConfig>
    referralLocks: map<uint64, ReferralLockMap>
    nextPayoutId: uint64
    retryHead: uint64
    retryTail: uint64
    payouts: map<uint64, OutgoingPayout>
}

struct SplitResult {
    creatorAmount: coins
    treasuryAmount: coins
    platformAffiliateAmount: coins
    communityAffiliateAmount: coins
    hasPlatformReferrer: bool
    hasCommunityReferrer: bool
}

struct ResolvedCommunityReferral {
    payout: address?
    bps: uint16
    writeLock: bool
}

struct ParsedSubscribe {
    communityId: uint64
    payout: address?
    validUntil: uint32
    authorization: slice
}

struct (0x7362d09c) JettonTransferNotification {
    queryId: uint64
    amount: coins
    sender: address
    forwardPayload: RemainingBitsAndRefs
}

struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    amount: coins
    destination: address
    responseDestination: address
    customPayload: cell?
    forwardTonAmount: coins
    // TEP-74 forward_payload is Either Cell ^Cell. This slice must already contain that tag.
    forwardPayload: RemainingBitsAndRefs
}

struct SubscriptionPaidRest {
    creatorAmount: coins
    treasuryAmount: coins
    platformAffiliateAmount: coins
}

struct (0x4afca88b) SubscriptionPaid {
    subscriber: address
    creator: address
    communityId: uint64
    amount: coins
    paidAt: uint32
    expiresAt: uint32
    hasPlatformReferrer: bool
    hasCommunityReferrer: bool
    communityAffiliateAmount: coins
    rest: cell
}

struct (0x52464e44) PaymentRefunded {
    payer: address
    amount: coins
    communityId: uint64
    reason: uint8
}

struct (0x55534457) DiscoverUsdtJettonWallet {
    queryId: uint64
}

struct (0x2c76b973) ProvideWalletAddress {
    queryId: uint64
    ownerAddress: address
    includeAddress: bool
}

struct (0xd1735400) TakeWalletAddress {
    queryId: uint64
    walletAddress: address
    ownerAddress: cell?
}

struct (0x57534554) UsdtJettonWalletSet {
    wallet: address
}

struct (0x524f574b) RotateOwnerKey {
    newKey: uint256
    validUntil: uint32
    authorization: RemainingBitsAndRefs
}

struct (0x4f4b5254) OwnerKeyRotated {
    newKey: uint256
}

struct (0x45584353) ExcessReturned {
    payer: address
    communityId: uint64
    amount: coins
}

struct (0xd53276db) JettonExcesses {
    queryId: uint64
}

struct (0x52545259) RetryPayouts {
    queryId: uint64
}

struct (0xd11b4fd2) PayoutRetried {
    destination: address
    amount: coins
}

struct (0x52454743) RegisterCommunity {
    communityId: uint64
    creator: address
    payout: address
    price: coins
    durationSeconds: uint32
    tail: cell
}

struct (0x43524547) CommunityRegistered {
    communityId: uint64
    creator: address
    price: coins
    durationSeconds: uint32
    platformMarketer: address?
    communityReferralBps: uint16
    accessMode: uint8
}

struct (0x43555044) CommunityUpdated {
    communityId: uint64
    price: coins
    durationSeconds: uint32
}

struct (0x55504443) UpdateCommunity {
    queryId: uint64
    communityId: uint64
    price: coins
    durationSeconds: uint32
}

struct (0x53435246) SetCommunityReferral {
    queryId: uint64
    communityId: uint64
    communityReferralBps: uint16
}

struct (0x3ae67dca) CommunityReferralActivated {
    communityId: uint64
    communityReferralBps: uint16
}

struct (0xd06e0b93) CommunityReferralStopped {
    communityId: uint64
}

struct (0x53435053) SetCommunityPaused {
    queryId: uint64
    communityId: uint64
    paused: bool
}

struct (0x09a00421) CommunityDeactivated {
    communityId: uint64
}

struct (0x63881308) CommunityReactivated {
    communityId: uint64
}

type AllowedMessage = DiscoverUsdtJettonWallet | TakeWalletAddress | RotateOwnerKey | JettonExcesses | RetryPayouts | RegisterCommunity | UpdateCommunity | SetCommunityReferral | SetCommunityPaused | JettonTransferNotification

contract PassGramRegistry {
    storage: Persisted
    incomingMessages: AllowedMessage
}

fun Storage.load(): Storage {
    val persisted = Persisted.fromCell(contract.getData());
    val head = StorageHead.fromCell(persisted.head);
    val tail = StorageTail.fromCell(persisted.tail);
    val books = PersistedBooks.fromCell(persisted.books);
    return Storage {
        owner: head.owner,
        treasury: head.treasury,
        platformFeeBps: head.platformFeeBps,
        affiliateShareOfPlatformBps: head.affiliateShareOfPlatformBps,
        maxCommunityReferralBps: head.maxCommunityReferralBps,
        usdtJettonMaster: head.usdtJettonMaster,
        ownerPublicKey: tail.ownerPublicKey,
        usdtJettonWallet: tail.usdtJettonWallet,
        nextPayoutId: tail.nextPayoutId,
        retryHead: tail.retryHead,
        retryTail: tail.retryTail,
        communities: CommunityBook.fromCell(books.communities).items,
        referralLocks: ReferralBook.fromCell(books.referralLocks).items,
        payouts: PayoutBook.fromCell(books.payouts).items,
    };
}

fun Storage.save(self) {
    contract.setData(Persisted {
        head: StorageHead {
            owner: self.owner,
            treasury: self.treasury,
            platformFeeBps: self.platformFeeBps,
            affiliateShareOfPlatformBps: self.affiliateShareOfPlatformBps,
            maxCommunityReferralBps: self.maxCommunityReferralBps,
            usdtJettonMaster: self.usdtJettonMaster,
        }.toCell(),
        tail: StorageTail {
            ownerPublicKey: self.ownerPublicKey,
            usdtJettonWallet: self.usdtJettonWallet,
            nextPayoutId: self.nextPayoutId,
            retryHead: self.retryHead,
            retryTail: self.retryTail,
        }.toCell(),
        books: PersistedBooks {
            communities: CommunityBook { items: self.communities }.toCell(),
            referralLocks: ReferralBook { items: self.referralLocks }.toCell(),
            payouts: PayoutBook { items: self.payouts }.toCell(),
        }.toCell(),
    }.toCell());
}

fun emitLog<TBody>(body: TBody) {
    createExternalLogMessage({
        dest: createAddressNone(),
        body: body,
    }).send(SEND_MODE_REGULAR);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessage.fromSlice(in.body);
    var st = Storage.load();
    match (msg) {
        DiscoverUsdtJettonWallet => { st = onDiscover(st, in.senderAddress, msg); }
        TakeWalletAddress => { st = onTakeWallet(st, in.senderAddress, msg); }
        RotateOwnerKey => { st = onRotate(st, in.senderAddress, msg); }
        JettonExcesses => { st = onExcesses(st, in.senderAddress, msg); }
        RetryPayouts => { st = retryBouncedPayouts(st, 0); }
        RegisterCommunity => { st = onRegister(st, in.senderAddress, msg); }
        UpdateCommunity => { st = onUpdate(st, in.senderAddress, msg); }
        SetCommunityReferral => { st = onSetReferral(st, in.senderAddress, msg); }
        SetCommunityPaused => { st = onSetPaused(st, in.senderAddress, msg); }
        JettonTransferNotification => { st = onJetton(st, in.senderAddress, msg); }
        else => {
            assert (in.body.isEmpty()) throw 0xFFFF;
            st = retryBouncedPayouts(st, 0);
        }
    }
    st.save();
}

fun onBouncedMessage(in: InMessageBounced) {
    var st = Storage.load();
    val wallet = st.usdtJettonWallet;
    if (wallet == null) { return; }
    if (in.senderAddress != wallet!) { return; }
    in.bouncedBody.skipBouncedPrefix();
    if (in.bouncedBody.remainingBitsCount() < 96) { return; }
    if (in.bouncedBody.loadUint(32) != 0x0f8a7ea5) { return; }
    st = queueBouncedPayout(st, in.bouncedBody.loadUint(64));
    st.save();
}

fun onDiscover(st: Storage, sender: address, msg: DiscoverUsdtJettonWallet): Storage {
    assert (sender == st.owner) throw 100;
    assert (st.usdtJettonWallet == null) throw 101;
    createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: ton("0.05"),
        dest: st.usdtJettonMaster,
        body: ProvideWalletAddress {
            queryId: msg.queryId,
            ownerAddress: contract.getAddress(),
            includeAddress: true,
        },
    }).send(SEND_MODE_REGULAR);
    return st;
}

fun onTakeWallet(st: Storage, sender: address, msg: TakeWalletAddress): Storage {
    assert (sender == st.usdtJettonMaster) throw 102;
    assert (st.usdtJettonWallet == null) throw 101;
    val packed = msg.ownerAddress;
    assert (packed != null) throw 103;
    val owner = packed!.beginParse().loadAddress();
    assert (owner == contract.getAddress()) throw 103;
    st.usdtJettonWallet = msg.walletAddress;
    emitLog(UsdtJettonWalletSet { wallet: msg.walletAddress });
    return st;
}

fun onRotate(st: Storage, sender: address, msg: RotateOwnerKey): Storage {
    assert (sender == st.owner) throw 100;
    assert (msg.newKey != 0 && msg.newKey != st.ownerPublicKey) throw 104;
    val now = blockchain.now();
    assert (now <= msg.validUntil && msg.validUntil <= now + 86400) throw 105;
    var approved = beginCell();
    approved.storeUint(0x524f574b, 32);
    approved.storeAddress(contract.getAddress());
    approved.storeUint(msg.newKey, 256);
    approved.storeUint(msg.validUntil, 32);
    assert (isSignatureValid(approved.endCell().hash(), msg.authorization, st.ownerPublicKey)) throw 105;
    st.ownerPublicKey = msg.newKey;
    emitLog(OwnerKeyRotated { newKey: msg.newKey });
    return st;
}

fun onExcesses(st: Storage, sender: address, msg: JettonExcesses): Storage {
    val wallet = st.usdtJettonWallet;
    assert (wallet != null) throw 106;
    assert (sender == wallet!) throw 107;
    var payouts = st.payouts;
    payouts.delete(msg.queryId);
    st.payouts = payouts;
    return retryBouncedPayouts(st, 0);
}

fun onRegister(st: Storage, sender: address, msg: RegisterCommunity): Storage {
    var tail = msg.tail.beginParse();
    val platform = tail.loadAddressOpt();
    val bps = tail.loadUint(16);
    val accessMode = tail.loadUint(8);
    val authorization = tail.loadBits(512);
    var terms = beginCell();
    terms.storeAddress(msg.payout);
    terms.storeCoins(msg.price);
    terms.storeUint(msg.durationSeconds, 32);
    if (platform != null) {
        terms.storeBool(true);
        terms.storeAddress(platform!);
    } else {
        terms.storeBool(false);
    }
    terms.storeUint(bps, 16);
    terms.storeUint(accessMode, 8);
    var approved = beginCell();
    approved.storeUint(0x41555448, 32);
    approved.storeAddress(contract.getAddress());
    approved.storeUint(msg.communityId, 64);
    approved.storeAddress(msg.creator);
    approved.storeRef(terms.endCell());
    assert (isSignatureValid(approved.endCell().hash(), authorization, st.ownerPublicKey)) throw 105;
    assert (sender == msg.creator) throw 108;
    assert (msg.payout == msg.creator) throw 109;
    assert (!st.communities.get(msg.communityId).isFound) throw 110;
    assert (accessMode == 0) throw 111;
    assert (bps <= st.maxCommunityReferralBps) throw 112;
    assert (msg.price > 0) throw 113;
    assert (msg.durationSeconds >= 86400 && msg.durationSeconds <= 31622400) throw 114;
    if (platform != null) {
        assert (platform! != sender) throw 115;
    }
    var communities = st.communities;
    communities.set(msg.communityId, CommunityConfig {
        creator: sender,
        payout: msg.payout,
        price: msg.price,
        durationSeconds: msg.durationSeconds,
        platformReferrer: platform,
        communityReferralBps: bps,
        accessMode: accessMode,
        paused: false,
    });
    st.communities = communities;
    emitLog(CommunityRegistered {
        communityId: msg.communityId,
        creator: sender,
        price: msg.price,
        durationSeconds: msg.durationSeconds,
        platformMarketer: platform,
        communityReferralBps: bps,
        accessMode: accessMode,
    });
    return st;
}

fun onUpdate(st: Storage, sender: address, msg: UpdateCommunity): Storage {
    val found = st.communities.get(msg.communityId);
    assert (found.isFound) throw 116;
    var community = found.loadValue();
    assert (sender == community.creator) throw 118;
    assert (!community.paused) throw 117;
    assert (msg.price > 0) throw 113;
    assert (msg.durationSeconds >= 86400 && msg.durationSeconds <= 31622400) throw 114;
    community.price = msg.price;
    community.durationSeconds = msg.durationSeconds;
    var communities = st.communities;
    communities.set(msg.communityId, community);
    st.communities = communities;
    emitLog(CommunityUpdated {
        communityId: msg.communityId,
        price: msg.price,
        durationSeconds: msg.durationSeconds,
    });
    return st;
}

fun onSetReferral(st: Storage, sender: address, msg: SetCommunityReferral): Storage {
    val found = st.communities.get(msg.communityId);
    assert (found.isFound) throw 116;
    var community = found.loadValue();
    assert (sender == community.creator) throw 118;
    assert (!community.paused) throw 117;
    assert (msg.communityReferralBps <= st.maxCommunityReferralBps) throw 112;
    community.communityReferralBps = msg.communityReferralBps;
    var communities = st.communities;
    communities.set(msg.communityId, community);
    st.communities = communities;
    if (msg.communityReferralBps == 0) {
        emitLog(CommunityReferralStopped { communityId: msg.communityId });
    } else {
        emitLog(CommunityReferralActivated {
            communityId: msg.communityId,
            communityReferralBps: msg.communityReferralBps,
        });
    }
    return st;
}

fun onSetPaused(st: Storage, sender: address, msg: SetCommunityPaused): Storage {
    val found = st.communities.get(msg.communityId);
    assert (found.isFound) throw 116;
    var community = found.loadValue();
    assert (sender == community.creator) throw 118;
    community.paused = msg.paused;
    var communities = st.communities;
    communities.set(msg.communityId, community);
    st.communities = communities;
    if (msg.paused) {
        emitLog(CommunityDeactivated { communityId: msg.communityId });
    } else {
        emitLog(CommunityReactivated { communityId: msg.communityId });
    }
    return st;
}

fun onJetton(st: Storage, sender: address, msg: JettonTransferNotification): Storage {
    val wallet = st.usdtJettonWallet;
    assert (wallet != null) throw 106;
    assert (sender == wallet!) throw 107;
    val parsed = tryParseSubscribe(msg.forwardPayload);
    if (parsed == null) {
        return refundPayment(st, msg.sender, msg.amount, 0, 1);
    }
    val request = parsed!;
    val found = st.communities.get(request.communityId);
    if (!found.isFound) {
        return refundPayment(st, msg.sender, msg.amount, request.communityId, 2);
    }
    val community = found.loadValue();
    if (community.paused) {
        return refundPayment(st, msg.sender, msg.amount, request.communityId, 3);
    }
    if (community.accessMode != 0) {
        return refundPayment(st, msg.sender, msg.amount, request.communityId, 4);
    }
    if (msg.amount < community.price) {
        return refundPayment(st, msg.sender, msg.amount, request.communityId, 5);
    }
    if (!communityReferralApproved(request, msg.sender, st.ownerPublicKey)) {
        return refundPayment(st, msg.sender, msg.amount, request.communityId, 7);
    }
    val subscriber = msg.sender;
    val settled = community.price;
    val excess = msg.amount - settled;
    val decision = decideCommunityReferral(st, request.communityId, subscriber, community, request.payout);
    val communityPay = payableMarketer(decision.payout, community.creator, subscriber);
    val platformPay = payableMarketer(community.platformReferrer, community.creator, subscriber);
    val maybeSplit = computeSplit(st, settled, community, communityPay, decision.bps, platformPay != null);
    if (maybeSplit == null) {
        return refundPayment(st, msg.sender, msg.amount, request.communityId, 1);
    }
    val split = maybeSplit!;
    var transferCount = outgoingTransfers(split);
    if (excess > 0) { transferCount = transferCount + 1; }
    if (!canFundTransfers(transferCount)) {
        return refundPayment(st, msg.sender, msg.amount, request.communityId, 6);
    }
    var next = st;
    if (decision.writeLock) {
        next = saveReferralLock(next, request.communityId, subscriber, decision.bps, decision.payout);
    }
    val paidAt = blockchain.now();
    next = recordAndPay(next, community.payout, split.creatorAmount);
    if (split.treasuryAmount > 0) {
        next = recordAndPay(next, next.treasury, split.treasuryAmount);
    }
    if (split.platformAffiliateAmount > 0 && platformPay != null) {
        next = recordAndPay(next, platformPay!, split.platformAffiliateAmount);
    }
    if (split.communityAffiliateAmount > 0 && communityPay != null) {
        next = recordAndPay(next, communityPay!, split.communityAffiliateAmount);
    }
    if (excess > 0) {
        next = recordAndPay(next, subscriber, excess);
        emitLog(ExcessReturned { payer: subscriber, communityId: request.communityId, amount: excess });
    }
    var rest = SubscriptionPaidRest {
        creatorAmount: split.creatorAmount,
        treasuryAmount: split.treasuryAmount,
        platformAffiliateAmount: split.platformAffiliateAmount,
    };
    emitLog(SubscriptionPaid {
        subscriber: subscriber,
        creator: community.creator,
        communityId: request.communityId,
        amount: settled,
        paidAt: paidAt,
        expiresAt: paidAt + community.durationSeconds,
        hasPlatformReferrer: split.hasPlatformReferrer,
        hasCommunityReferrer: split.hasCommunityReferrer,
        communityAffiliateAmount: split.communityAffiliateAmount,
        rest: rest.toCell(),
    });
    return retryBouncedPayouts(next, transferCount);
}

fun unwrapForward(raw: slice): slice? {
    if (raw.remainingBitsCount() < 1) { return null; }
    var body = raw;
    if (body.loadBool()) {
        if (body.remainingRefsCount() < 1) { return null; }
        return body.loadRef().beginParse();
    }
    return body;
}

fun tryParseSubscribe(raw: slice): ParsedSubscribe? {
    val unwrapped = unwrapForward(raw);
    if (unwrapped == null) { return null; }
    var payload = unwrapped!;
    if (payload.remainingBitsCount() < 97) { return null; }
    if (payload.loadUint(32) != 0x53554253) { return null; }
    val communityId = payload.loadUint(64);
    val hasPayout = payload.loadBool();
    var payout: address? = null;
    if (hasPayout) {
        if (payload.remainingBitsCount() < 267) { return null; }
        payout = payload.loadAddress();
    }
    if (payload.remainingBitsCount() < 32 + 512) { return null; }
    return ParsedSubscribe {
        communityId: communityId,
        payout: payout,
        validUntil: payload.loadUint(32),
        authorization: payload.loadBits(512),
    }
}

fun communityReferralApproved(request: ParsedSubscribe, subscriber: address, publicKey: uint256): bool {
    if (request.validUntil < blockchain.now()) { return false; }
    var b = beginCell();
    b.storeUint(0x43524546, 32);
    b.storeAddress(contract.getAddress());
    b.storeUint(request.communityId, 64);
    b.storeAddress(subscriber);
    if (request.payout != null) {
        b.storeBool(true);
        b.storeAddress(request.payout!);
    } else {
        b.storeBool(false);
    }
    b.storeUint(request.validUntil, 32);
    return isSignatureValid(b.endCell().hash(), request.authorization, publicKey);
}

fun decideCommunityReferral(st: Storage, communityId: uint64, subscriber: address, community: CommunityConfig, namedPayout: address?): ResolvedCommunityReferral {
    val stored = st.referralLocks.get(communityId);
    if (stored.isFound) {
        val existing = stored.loadValue().locks.get(subscriber);
        if (existing.isFound) {
            return payoutForLock(existing.loadValue());
        }
    }
    if (namedPayout == null) {
        return ResolvedCommunityReferral { payout: null, bps: 0, writeLock: true };
    }
    if (namedPayout! == community.creator || namedPayout! == subscriber) {
        return ResolvedCommunityReferral { payout: null, bps: 0, writeLock: true };
    }
    val applied = community.communityReferralBps;
    if (applied <= 0 || applied > st.maxCommunityReferralBps) {
        return ResolvedCommunityReferral { payout: null, bps: 0, writeLock: true };
    }
    return ResolvedCommunityReferral { payout: namedPayout, bps: applied, writeLock: true };
}

fun payoutForLock(lock: SubscriberReferralLock): ResolvedCommunityReferral {
    if (lock.marketer == null || lock.bps == 0) {
        return ResolvedCommunityReferral { payout: null, bps: 0, writeLock: false };
    }
    return ResolvedCommunityReferral { payout: lock.marketer, bps: lock.bps, writeLock: false };
}

fun saveReferralLock(st: Storage, communityId: uint64, subscriber: address, bps: uint16, marketer: address?): Storage {
    var locks: map<address, SubscriberReferralLock> = [];
    val stored = st.referralLocks.get(communityId);
    if (stored.isFound) { locks = stored.loadValue().locks; }
    locks.set(subscriber, SubscriberReferralLock { bps: bps, marketer: marketer });
    var referralLocks = st.referralLocks;
    referralLocks.set(communityId, ReferralLockMap { locks: locks });
    st.referralLocks = referralLocks;
    return st;
}

fun payableMarketer(stored: address?, creator: address, subscriber: address): address? {
    if (stored == null) { return null; }
    if (stored! == creator || stored! == subscriber) { return null; }
    return stored;
}

fun computeSplit(st: Storage, gross: coins, community: CommunityConfig, communityReferrer: address?, communityReferralBps: uint16, payPlatform: bool): SplitResult? {
    val platformFee = (gross * st.platformFeeBps) / 10000;
    var platformAffiliateCut: coins = 0;
    val hasPlatformReferrer = payPlatform;
    if (hasPlatformReferrer) {
        platformAffiliateCut = (platformFee * st.affiliateShareOfPlatformBps) / 10000;
    }
    val treasuryCut = platformFee - platformAffiliateCut;
    val creatorBeforeReferral = gross - platformFee;
    var communityAffiliateCut: coins = 0;
    var hasCommunityReferrer = false;
    if (communityReferrer != null && communityReferralBps > 0 && communityReferralBps <= st.maxCommunityReferralBps && communityReferrer! != community.creator) {
        communityAffiliateCut = (creatorBeforeReferral * communityReferralBps) / 10000;
        hasCommunityReferrer = true;
    }
    val creatorCut = creatorBeforeReferral - communityAffiliateCut;
    if (creatorCut < 0 || creatorCut + treasuryCut + platformAffiliateCut + communityAffiliateCut != gross) {
        return null;
    }
    return SplitResult {
        creatorAmount: creatorCut,
        treasuryAmount: treasuryCut,
        platformAffiliateAmount: platformAffiliateCut,
        communityAffiliateAmount: communityAffiliateCut,
        hasPlatformReferrer: hasPlatformReferrer,
        hasCommunityReferrer: hasCommunityReferrer,
    };
}

fun outgoingTransfers(split: SplitResult): int {
    var count = 0;
    if (split.creatorAmount > 0) { count = count + 1; }
    if (split.treasuryAmount > 0) { count = count + 1; }
    if (split.platformAffiliateAmount > 0) { count = count + 1; }
    if (split.communityAffiliateAmount > 0) { count = count + 1; }
    return count;
}

fun jettonTransferValue(): coins {
    return ton("0.15");
}

fun canFundTransfers(count: int): bool {
    if (count <= 0) { return true; }
    return contract.getOriginalBalance() >= jettonTransferValue() * count + ton("0.05");
}

fun refundPayment(st: Storage, payer: address, amount: coins, communityId: uint64, reason: uint8): Storage {
    val next = recordAndPay(st, payer, amount);
    emitLog(PaymentRefunded { payer: payer, amount: amount, communityId: communityId, reason: reason });
    return retryBouncedPayouts(next, 1);
}

fun recordAndPay(st: Storage, to: address, amount: coins): Storage {
    if (amount <= 0 || st.usdtJettonWallet == null) { return st; }
    val id = st.nextPayoutId;
    st.nextPayoutId = id + 1;
    var payouts = st.payouts;
    payouts.set(id, OutgoingPayout { destination: to, amount: amount, queued: false, nextRetry: 0 });
    st.payouts = payouts;
    payJettons(st, to, amount, id);
    return st;
}

fun queueBouncedPayout(st: Storage, id: uint64): Storage {
    val found = st.payouts.get(id);
    if (!found.isFound) { return st; }
    var payout = found.loadValue();
    if (payout.queued) { return st; }
    payout.queued = true;
    payout.nextRetry = 0;
    var payouts = st.payouts;
    if (st.retryHead == 0) {
        st.retryHead = id;
        st.retryTail = id;
    } else {
        val tailFound = payouts.get(st.retryTail);
        if (tailFound.isFound) {
            var tail = tailFound.loadValue();
            tail.nextRetry = id;
            payouts.set(st.retryTail, tail);
        }
        st.retryTail = id;
    }
    payouts.set(id, payout);
    st.payouts = payouts;
    return st;
}

fun retryBouncedPayouts(st: Storage, alreadyQueued: int): Storage {
    var next = st;
    var queued = alreadyQueued;
    repeat (4) {
        if (next.retryHead != 0 && canFundTransfers(queued + 1)) {
            val id = next.retryHead;
            val found = next.payouts.get(id);
            if (!found.isFound) {
                next.retryHead = 0;
                next.retryTail = 0;
            } else {
                val payout = found.loadValue();
                next.retryHead = payout.nextRetry;
                if (next.retryHead == 0) { next.retryTail = 0; }
                var payouts = next.payouts;
                payouts.delete(id);
                next.payouts = payouts;
                next = recordAndPay(next, payout.destination, payout.amount);
                emitLog(PayoutRetried { destination: payout.destination, amount: payout.amount });
                queued = queued + 1;
            }
        }
    }
    return next;
}

fun emptyJettonForwardPayload(): slice {
    // False selects the inline branch of Either Cell ^Cell and leaves that slice empty.
    return beginCell().storeBool(false).endCell().beginParse();
}

fun payJettons(st: Storage, to: address, amount: coins, queryId: uint64) {
    val wallet = st.usdtJettonWallet;
    if (amount <= 0 || wallet == null) { return; }
    createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: jettonTransferValue(),
        dest: wallet!,
        body: JettonTransfer {
            queryId: queryId,
            amount: amount,
            destination: to,
            responseDestination: contract.getAddress(),
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: emptyJettonForwardPayload(),
        },
    }).send(SEND_MODE_REGULAR);
}

get fun ownerPublicKey(): uint256 {
    return Storage.load().ownerPublicKey;
}

get fun platformFeeBps(): int {
    return Storage.load().platformFeeBps;
}

get fun affiliateShareOfPlatformBps(): int {
    return Storage.load().affiliateShareOfPlatformBps;
}

get fun maxCommunityReferralBps(): int {
    return Storage.load().maxCommunityReferralBps;
}

get fun treasury(): address {
    return Storage.load().treasury;
}

get fun usdtJettonMaster(): address {
    return Storage.load().usdtJettonMaster;
}

get fun usdtJettonWallet(): address? {
    return Storage.load().usdtJettonWallet;
}

get fun communityReferralBps(communityId: uint64): int {
    val found = Storage.load().communities.get(communityId);
    if (!found.isFound) { return 0; }
    return found.loadValue().communityReferralBps;
}
