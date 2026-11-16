// =====================================================================
//  GemSafe — Deal: одна сделка (условия + деньги заказчика до выполнения)
//  ---------------------------------------------------------------------
//  Роли:  заказчик  — открывает сделку и сразу платит;
//         исполнитель — принимает условия (по приглашению или ссылке с кодом), выполняет их;
//         арбитр    — решает споры (только делит сумму между сторонами).
//
//  Жизненный цикл:
//   PROPOSED  → исполнитель принимает (и платит комиссию, если она на нём) → ACTIVE
//   ACTIVE    → исполнитель отмечает «выполнено»
//   DELIVERED → заказчик подтверждает  → COMPLETED (деньги сразу исполнителю)
//             → или «не выполнено»     → CONTESTED
//   CONTESTED → исполнитель соглашается (возврат) / дорабатывает / спорит
//   DISPUTED  → арбитр делит сумму между сторонами → RESOLVED
//
//  Гарантии, зашитые в код:
//   * Деньги сделки могут получить ТОЛЬКО заказчик или исполнитель.
//   * После оплаты ни одна сторона не может отменить сделку в одиночку
//     в свою пользу. Исполнитель может только добровольно вернуть деньги.
//   * Молчание не блокирует деньги: на каждый шаг есть срок, после
//     которого вторая сторона может завершить сделку сама.
//   * Комиссия не выше 5% и фиксируется при создании сделки. Удерживается
//     только при успешной сделке или решении арбитра, при отмене — возвращается.
//   * Изменить условия можно только по согласию обеих сторон.
//   * Текст условий в блокчейн не попадает: хранится только его отпечаток (sha256).
// =====================================================================
tolk 1.5

import "messages"

// ------------------------- хранилище сделки ---------------------------
// c4:   master, id, Maybe ^Body                 (Body нет до DealInit)

struct Roles {
    arbiter: address
    feeWallet: address
    disputedBy: address? = null
}

struct Times {
    termsHash: uint256 = 0
    deliveryPeriod: uint32 = 0
    reviewPeriod: uint32 = 0
    deadline: uint32 = 0
    createdAt: uint32 = 0
    acceptedAt: uint32 = 0
    fundedAt: uint32 = 0
    deliveredAt: uint32 = 0
    contestedAt: uint32 = 0
    disputedAt: uint32 = 0
    closedAt: uint32 = 0
    customerShare: coins = 0
    customerTag: uint64 = 0
    executorTag: uint64 = 0
    version: uint16 = 0                 // сколько раз меняли условия
}

struct Money {
    feePaid: bool = false               // комиссия внесена (хранится на контракте)
    funded: bool = false                // сумма сделки внесена
    cancelRequested: bool = false       // заказчик просит отменить сделку
    customerClaim: coins = 0            // к выплате заказчику
    executorClaim: coins = 0            // к выплате исполнителю
    invite: uint256 = 0                 // хэш кода-приглашения
    change: cell? = null                // предложение изменить условия (Change)
}

struct Jettons {
    jettonMaster: address? = null
    jettonWallet: address? = null       // жетон-кошелёк ЭТОЙ сделки (узнаём у мастера жетона, TEP-89)
}

struct Body {
    customer: address
    executor: address?
    openOffer: bool
    state: uint8
    feePayer: uint8
    currency: uint8
    feeBps: uint16
    amount: coins
    fee: coins
    roles: Cell<Roles>
    times: Cell<Times>
    money: Cell<Money>
    jettons: Cell<Jettons>
}

global gMaster: address
global gId: int
global gInit: bool

global gCustomer: address
global gExecutor: address?
global gOpenOffer: bool
global gState: int
global gFeePayer: int
global gCurrency: int
global gFeeBps: int
global gAmount: int
global gFee: int
global gR: Roles
global gT: Times
global gM: Money
global gJ: Jettons

// контекст текущего сообщения
global gSender: address
global gValue: int

fun loadData() {
    var s = contract.getData().beginParse();
    gMaster = s.loadAddress();
    gId = s.loadUint(64);
    val body = s.loadMaybeRef();
    gInit = body != null;
    if (body == null) {
        // значения по умолчанию (до DealInit)
        gCustomer = gMaster; gExecutor = null; gOpenOffer = true;
        gState = ST_PROPOSED; gFeePayer = 0; gCurrency = CUR_TON; gFeeBps = 0; gAmount = 0; gFee = 0;
        gR = { arbiter: gMaster, feeWallet: gMaster };
        gT = {};
        gM = {};
        gJ = {};
        return;
    }
    val b = Body.fromCell(body!);
    gCustomer = b.customer;
    gExecutor = b.executor;
    gOpenOffer = b.openOffer;
    gState = b.state;
    gFeePayer = b.feePayer;
    gCurrency = b.currency;
    gFeeBps = b.feeBps;
    gAmount = b.amount;
    gFee = b.fee;
    gR = b.roles.load();
    gT = b.times.load();
    gM = b.money.load();
    gJ = b.jettons.load();
}

fun saveData() {
    val body: Body = {
        customer: gCustomer,
        executor: gExecutor,
        openOffer: gOpenOffer,
        state: gState,
        feePayer: gFeePayer,
        currency: gCurrency,
        feeBps: gFeeBps,
        amount: gAmount,
        fee: gFee,
        roles: gR.toCell(),
        times: gT.toCell(),
        money: gM.toCell(),
        jettons: gJ.toCell(),
    };
    contract.setData(beginCell()
        .storeAddress(gMaster)
        .storeUint(gId, 64)
        .storeMaybeRef(body.toCell())
        .endCell());
}

// ----------------------------- проверки -------------------------------

@inline
fun requireInit() {
    assert (gInit) throw E_NOT_INIT;
}

fun isExecutor(a: address): bool {
    if (gExecutor == null || gState == ST_PROPOSED) {
        return false;
    }
    return a == gExecutor!;
}

fun isParty(a: address): bool {
    return a == gCustomer || isExecutor(a);
}

fun isFundedOpen(): bool {
    return gState == ST_ACTIVE || gState == ST_DELIVERED || gState == ST_CONTESTED || gState == ST_DISPUTED;
}

fun isChangeable(): bool {
    return gState == ST_ACTIVE || gState == ST_DELIVERED || gState == ST_CONTESTED;
}

fun inviteOk(code: int): bool {
    return gM.invite != 0 && beginCell().storeUint(code, 128).endCell().hash() == gM.invite;
}

fun minAmount(): int {
    return gCurrency == CUR_JETTON ? MIN_JETTON_AMOUNT : MIN_DEAL_AMOUNT;
}

// Сколько должна доплатить сторона при изменении суммы.
fun dueFor(isCustomer: bool, newAmount: int): int {
    val newFee = newAmount * gFeeBps / BPS;
    var due = 0;
    if (isCustomer) {
        due = max(0, newAmount - gAmount);
        if (gFeePayer == FEE_BY_CUSTOMER) {
            due += max(0, newFee - gFee);
        }
    } else if (gFeePayer == FEE_BY_EXECUTOR) {
        due = max(0, newFee - gFee);
    }
    return due;
}

// ----------------------------- деньги ---------------------------------

// Принять депозит `due` и вернуть отправителю всё лишнее (остаток газа).
fun takeDeposit(due: int) {
    assert (gValue >= due + ACTION_GAS) throw E_NOT_ENOUGH_TON;
    val before = contract.getOriginalBalance() - gValue;
    reserveToncoinsOnBalance(before + due, RESERVE_EXACT);
    createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: gSender })
        .send(MODE_ALL_BALANCE | MODE_IGNORE_ERRORS);
}

fun sendJettons(amount: int, to: address, response: address, value: int, mode: int, queryId: int) {
    createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: value,
        dest: gJ.jettonWallet!,
        body: JettonTransfer {
            queryId: queryId,
            amount: amount,
            destination: to,
            responseDestination: response,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayloadInRef: false,
        }
    }).send(mode);
}

fun sendTon(to: address, value: int, text: slice) {
    createMessage({ bounce: BounceMode.NoBounce, value: value, dest: to, body: comment(text) })
        .send(MODE_FEES_SEPARATELY);
}

fun applyChange(ch: Change) {
    val newFee = ch.amount * gFeeBps / BPS;
    // уменьшение суммы/комиссии — разница возвращается тем, кто платил
    if (ch.amount < gAmount) {
        gM.customerClaim += gAmount - ch.amount;
    }
    if (newFee < gFee) {
        if (gFeePayer == FEE_BY_CUSTOMER) {
            gM.customerClaim += gFee - newFee;
        } else {
            gM.executorClaim += gFee - newFee;
        }
    }
    gAmount = ch.amount;
    gFee = newFee;
    gT.termsHash = ch.termsHash;
    gT.deadline = ch.deadline;
    gT.version += 1;
    gM.change = null;
    // условия изменились — работа выполняется/проверяется заново
    gState = ST_ACTIVE;
    gT.deliveredAt = 0;
    gT.contestedAt = 0;
}

fun refundChange() {
    if (gM.change != null) {
        val ch = Change.fromCell(gM.change!);
        gM.customerClaim += ch.customerPaid;
        gM.executorClaim += ch.executorPaid;
        gM.change = null;
    }
}

// Закрыть сделку. customerPart — часть суммы, которая возвращается заказчику.
// Деньги сразу уходят сторонам на кошельки, комиссия — сервису, остаток газа возвращается.
// Если перевод жетонов не пройдёт, сумма вернётся «к выводу» (onBouncedMessage).
fun closeDeal(newState: int, customerPart: int) {
    refundChange();
    if (gM.funded) {
        gM.customerClaim += customerPart;
        gM.executorClaim += gAmount - customerPart;
        gT.customerShare = customerPart;
    }
    var feeToService = 0;
    if (gM.feePaid) {
        if (newState == ST_COMPLETED || newState == ST_RESOLVED) {
            feeToService = gFee;
        } else if (gFeePayer == FEE_BY_CUSTOMER) {
            gM.customerClaim += gFee;
        } else {
            gM.executorClaim += gFee;
        }
    }
    gState = newState;
    gT.closedAt = blockchain.now();
    gM.cancelRequested = false;

    val c = gM.customerClaim;
    var e = 0;
    if (gExecutor != null) {
        e = gM.executorClaim;
    }
    gM.customerClaim = 0;
    gM.executorClaim -= e;

    if (gCurrency == CUR_JETTON) {
        var n = 0;
        if (feeToService > 0) { n += 1; }
        if (c > 0) { n += 1; }
        if (e > 0) { n += 1; }
        assert (gValue >= JETTON_TX * n + ACTION_GAS) throw E_ATTACH_MORE;
        if (feeToService > 0) { sendJettons(feeToService, gR.feeWallet, gR.feeWallet, JETTON_TX, MODE_FEES_SEPARATELY, Q_FEE); }
        if (c > 0) { sendJettons(c, gCustomer, gCustomer, JETTON_TX, MODE_FEES_SEPARATELY, Q_CUSTOMER); }
        if (e > 0) { sendJettons(e, gExecutor!, gExecutor!, JETTON_TX, MODE_FEES_SEPARATELY, Q_EXECUTOR); }
        reserveToncoinsOnBalance(KEEP_BALANCE, RESERVE_AT_MOST);
        createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: gSender })
            .send(MODE_ALL_BALANCE | MODE_IGNORE_ERRORS);
        return;
    }

    if (feeToService > 0) { sendTon(gR.feeWallet, feeToService, "GemSafe fee".literalSlice()); }
    if (c > 0) { sendTon(gCustomer, c, "GemSafe: refund".literalSlice()); }
    if (e > 0) { sendTon(gExecutor!, e, "GemSafe: payout".literalSlice()); }
    // приложенные TON — обратно тому, кто закрыл сделку; остаток газа сделки — заказчику (он его вносил)
    if (gSender != gCustomer) {
        cashback(gSender);
    }
    reserveToncoinsOnBalance(KEEP_BALANCE, RESERVE_AT_MOST);
    createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: gCustomer })
        .send(MODE_ALL_BALANCE | MODE_IGNORE_ERRORS);
}

// ======================== создание сделки =============================

fun onDealInit(msg: DealInit) {
    assert (gSender == gMaster) throw E_ONLY_MASTER;
    assert (!gInit) throw E_ALREADY_INIT;
    val x = msg.extra.load();
    val h = x.hashes.load();
    val now = blockchain.now();
    gInit = true;
    gCustomer = msg.customer;
    gExecutor = msg.executor;
    gOpenOffer = msg.executor == null;
    gR.arbiter = msg.arbiter;
    gR.feeWallet = x.feeWallet;
    gAmount = x.amount;
    gFeeBps = x.feeBps;
    gFee = gAmount * gFeeBps / BPS;
    gFeePayer = x.feePayer;
    gT.deliveryPeriod = x.deliveryPeriod;
    gT.reviewPeriod = x.reviewPeriod;
    gT.customerTag = x.customerTag;
    gT.termsHash = h.termsHash;
    gState = ST_PROPOSED;
    gT.createdAt = now;
    gCurrency = x.currency;
    gM.invite = h.invite;
    if (x.prepaid) {
        // деньги пришли вместе с созданием (мастер проверил сумму) — сделка сразу оплачена
        gM.funded = true;
        gT.fundedAt = now;
        if (gFeePayer == FEE_BY_CUSTOMER) {
            gM.feePaid = true;
        }
    }
    if (gCurrency == CUR_JETTON) {
        gJ.jettonMaster = x.jettonMaster;
        // спрашиваем у мастера жетона адрес нашего жетон-кошелька: так фальшивый токен не пройдёт
        createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: DISCOVERY_GAS,
            dest: x.jettonMaster!,
            body: ProvideWalletAddress { queryId: gId, ownerAddress: contract.getAddress(), includeAddress: false }
        }).send(MODE_REGULAR);
    }
    // Лишний газ сразу возвращаем заказчику: на сделке остаются только её деньги и небольшой запас.
    var keep = KEEP_OPEN;
    if (x.prepaid) {
        keep += gAmount;
        if (gM.feePaid) {
            keep += gFee;
        }
    }
    reserveToncoinsOnBalance(keep, RESERVE_AT_MOST);
    createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: gCustomer, body: comment("GemSafe gas refund".literalSlice()) })
        .send(MODE_ALL_BALANCE | MODE_IGNORE_ERRORS);
}

fun onTakeWalletAddress(msg: TakeWalletAddress) {
    assert (gJ.jettonMaster != null && gSender == gJ.jettonMaster!) throw E_ONLY_JETTON_MASTER;
    assert (gJ.jettonWallet == null) throw E_WALLET_KNOWN;
    gJ.jettonWallet = msg.walletAddress;
}

// ============================ до оплаты ===============================

// Исполнитель принимает условия. Если комиссия на нём — прикладывает её.
fun onAccept(msg: Accept) {
    requireInit();
    assert (gState == ST_PROPOSED) throw E_WRONG_STATE;
    val s = gSender;
    assert (s != gCustomer) throw E_CUSTOMER_CANNOT_ACCEPT;
    assert (s != gR.arbiter) throw E_ARBITER_PARTY;
    if (!gOpenOffer) {
        assert (s == gExecutor!) throw E_ONLY_INVITED;
    } else {
        assert (inviteOk(msg.code)) throw E_BAD_INVITE_CODE;
    }
    assert (gM.funded) throw E_NOT_PAID;
    val now = blockchain.now();
    gExecutor = s;
    gT.executorTag = msg.tag;
    gState = ST_ACTIVE;              // деньги уже в контракте — сразу «в работе»
    gT.acceptedAt = now;
    gT.deadline = now + gT.deliveryPeriod;
    if (gFeePayer == FEE_BY_EXECUTOR) {
        assert (gCurrency == CUR_TON) throw E_PAY_FEE_IN_JETTONS;
        gM.feePaid = true;
        takeDeposit(gFee);
    } else {
        cashback(s);
    }
}

// Заказчик выпускает новую ссылку-приглашение (старая перестаёт работать).
fun onSetInvite(msg: SetInvite) {
    requireInit();
    assert (gSender == gCustomer) throw E_ONLY_CUSTOMER;
    assert (gState == ST_PROPOSED && gOpenOffer) throw E_WRONG_STATE;
    assert (msg.invite != 0) throw E_BAD_INVITE;
    gM.invite = msg.invite;
    cashback(gSender);
}

// Приглашённый исполнитель отклоняет условия.
fun onReject() {
    requireInit();
    assert (gState == ST_PROPOSED) throw E_WRONG_STATE;
    assert (!gOpenOffer && gSender == gExecutor!) throw E_ONLY_INVITED;
    closeDeal(ST_CANCELLED, gAmount);
}

// Отмена до начала работы: всё возвращается заказчику.
fun onCancel() {
    requireInit();
    val s = gSender;
    if (s == gCustomer) {
        assert (gState == ST_PROPOSED || gState == ST_ACCEPTED) throw E_ALREADY_FUNDED;
    } else {
        assert (isExecutor(s)) throw E_ONLY_PARTIES;
        assert (gState == ST_ACCEPTED) throw E_WRONG_STATE;
    }
    closeDeal(ST_CANCELLED, gAmount);
}

// Заказчик оплачивает сделку (+ комиссию, если она на нём).
fun onFund() {
    requireInit();
    assert (gCurrency == CUR_TON) throw E_PAY_IN_JETTONS;
    assert (gSender == gCustomer) throw E_ONLY_CUSTOMER;
    assert (!gM.funded) throw E_ALREADY_FUNDED;
    assert (gState == ST_PROPOSED || gState == ST_ACCEPTED) throw E_WRONG_STATE;
    var due = gAmount;
    if (gFeePayer == FEE_BY_CUSTOMER) {
        due += gFee;
        gM.feePaid = true;
    }
    gM.funded = true;
    gT.fundedAt = blockchain.now();
    if (gState == ST_ACCEPTED) {
        gState = ST_ACTIVE;
        gT.deadline = blockchain.now() + gT.deliveryPeriod;
    }
    takeDeposit(due);
}

// =========================== выполнение ===============================

// Исполнитель отмечает, что выполнил условия.
fun onDone() {
    requireInit();
    assert (isExecutor(gSender)) throw E_ONLY_EXECUTOR;
    assert (gState == ST_ACTIVE) throw E_WRONG_STATE;
    gState = ST_DELIVERED;
    gT.deliveredAt = blockchain.now();
    cashback(gSender);
}

// Заказчик подтверждает выполнение — сумма уходит исполнителю (в любой момент после оплаты).
fun onConfirm() {
    requireInit();
    assert (gSender == gCustomer) throw E_ONLY_CUSTOMER;
    assert (isFundedOpen()) throw E_WRONG_STATE;
    closeDeal(ST_COMPLETED, 0);
}

// Заказчик молчит дольше срока проверки — исполнитель забирает сумму сам.
fun onClaim() {
    requireInit();
    assert (isExecutor(gSender)) throw E_ONLY_EXECUTOR;
    assert (gState == ST_DELIVERED) throw E_WRONG_STATE;
    assert (blockchain.now() > gT.deliveredAt + gT.reviewPeriod) throw E_REVIEW_NOT_OVER;
    closeDeal(ST_COMPLETED, 0);
}

// Заказчик: «условия не выполнены».
fun onContest() {
    requireInit();
    assert (gSender == gCustomer) throw E_ONLY_CUSTOMER;
    val now = blockchain.now();
    assert (gState == ST_ACTIVE || (gState == ST_DELIVERED && now <= gT.deliveredAt + gT.reviewPeriod)) throw E_CANNOT_CONTEST;
    gState = ST_CONTESTED;
    gT.contestedAt = now;
    cashback(gSender);
}

// Исполнитель берёт на доработку после претензии.
fun onRework() {
    requireInit();
    assert (isExecutor(gSender)) throw E_ONLY_EXECUTOR;
    assert (gState == ST_CONTESTED) throw E_WRONG_STATE;
    gState = ST_ACTIVE;
    gT.deliveredAt = 0;
    cashback(gSender);
}

// Исполнитель добровольно возвращает деньги заказчику (в любой момент после оплаты).
fun onRefund() {
    requireInit();
    assert (isExecutor(gSender)) throw E_ONLY_EXECUTOR;
    assert (isFundedOpen()) throw E_WRONG_STATE;
    closeDeal(ST_REFUNDED, gAmount);
}

// Исполнитель не ответил на претензию в срок — заказчик возвращает деньги сам.
fun onRefundTimeout() {
    requireInit();
    assert (gSender == gCustomer) throw E_ONLY_CUSTOMER;
    assert (gState == ST_CONTESTED) throw E_WRONG_STATE;
    assert (blockchain.now() > gT.contestedAt + gT.reviewPeriod) throw E_EXECUTOR_HAS_TIME;
    closeDeal(ST_REFUNDED, gAmount);
}

// Открыть спор. Исполнитель — в работе, после «выполнено» или после претензии;
// заказчик — после своей претензии.
fun onDispute() {
    requireInit();
    val s = gSender;
    if (s == gCustomer) {
        assert (gState == ST_CONTESTED) throw E_CANNOT_DISPUTE;
    } else {
        assert (isExecutor(s)) throw E_ONLY_PARTIES;
        assert (isChangeable()) throw E_CANNOT_DISPUTE;
    }
    gState = ST_DISPUTED;
    gT.disputedAt = blockchain.now();
    gR.disputedBy = s;
    cashback(s);
}

// Заказчик просит отменить сделку (исполнитель соглашается кнопкой «вернуть деньги»).
fun onCancelRequest() {
    requireInit();
    assert (gSender == gCustomer) throw E_ONLY_CUSTOMER;
    assert (isFundedOpen()) throw E_WRONG_STATE;
    gM.cancelRequested = true;
    cashback(gSender);
}

fun onCancelWithdraw() {
    requireInit();
    assert (gSender == gCustomer) throw E_ONLY_CUSTOMER;
    gM.cancelRequested = false;
    cashback(gSender);
}

// ======================== изменение условий ===========================

fun onProposeChange(msg: ProposeChange) {
    requireInit();
    val s = gSender;
    assert (isParty(s)) throw E_ONLY_PARTIES;
    assert (isChangeable()) throw E_WRONG_STATE;
    assert (gM.change == null) throw E_CHANGE_PROPOSED;
    assert (msg.amount >= minAmount()) throw E_AMOUNT_TOO_SMALL;
    val now = blockchain.now();
    assert (msg.deadline > now && msg.deadline <= now + MAX_DELIVERY_PERIOD) throw E_BAD_DEADLINE;
    val isC = s == gCustomer;
    val due = dueFor(isC, msg.amount);
    assert (gCurrency == CUR_TON || due == 0) throw E_PAY_IN_JETTONS;
    gM.change = Change {
        proposer: s,
        amount: msg.amount,
        deadline: msg.deadline,
        termsHash: msg.termsHash,
        customerPaid: isC ? due : 0,
        executorPaid: isC ? 0 : due,
    }.toCell();
    takeDeposit(due);
}

fun onChangeAccept() {
    requireInit();
    assert (gM.change != null) throw E_NO_CHANGE;
    var ch = Change.fromCell(gM.change!);
    val s = gSender;
    assert (s != ch.proposer) throw E_PROPOSER_CANNOT_ACCEPT;
    assert (isParty(s)) throw E_ONLY_PARTIES;
    assert (isChangeable()) throw E_WRONG_STATE;
    val isC = s == gCustomer;
    val due = dueFor(isC, ch.amount);
    assert (gCurrency == CUR_TON || due == 0) throw E_PAY_IN_JETTONS;
    if (isC) { ch.customerPaid = due; } else { ch.executorPaid = due; }
    applyChange(ch);
    takeDeposit(due);
}

// Отклонить (вторая сторона) или отозвать (автор) предложение — доплаты возвращаются.
fun onChangeDecline() {
    requireInit();
    assert (gM.change != null) throw E_NO_CHANGE;
    assert (isParty(gSender)) throw E_ONLY_PARTIES;
    refundChange();
    cashback(gSender);
}

// ============================ арбитраж ================================

fun onResolve(msg: Resolve) {
    requireInit();
    assert (gSender == gR.arbiter) throw E_ONLY_ARBITER;
    assert (gState == ST_DISPUTED) throw E_WRONG_STATE;
    assert (msg.customerAmount <= gAmount) throw E_BAD_SHARE;
    closeDeal(ST_RESOLVED, msg.customerAmount);
}

// ========================== вывод средств =============================

// Каждый выводит СВОИ средства на указанный им кошелёк (если автоматическая выплата не прошла).
fun onWithdraw(msg: Withdraw) {
    requireInit();
    val s = gSender;
    var value = 0;
    val isC = s == gCustomer;
    if (isC) {
        value = gM.customerClaim;
        gM.customerClaim = 0;
    } else {
        assert (isExecutor(s)) throw E_ONLY_PARTIES;
        value = gM.executorClaim;
        gM.executorClaim = 0;
    }
    assert (value > 0) throw E_NOTHING_TO_WITHDRAW;
    if (gCurrency == CUR_JETTON) {
        assert (gValue >= JETTON_GAS) throw E_ATTACH_01;
        sendJettons(value, msg.to, s, 0, MODE_REMAINING_VALUE, isC ? Q_CUSTOMER : Q_EXECUTOR);
        return;
    }
    createMessage({ bounce: BounceMode.NoBounce, value: value, dest: msg.to, body: comment("GemSafe payout".literalSlice()) })
        .send(MODE_REMAINING_VALUE);
}

fun onSetTag(msg: SetTag) {
    requireInit();
    val s = gSender;
    if (s == gCustomer) {
        gT.customerTag = msg.tag;
    } else {
        assert (isExecutor(s)) throw E_ONLY_PARTIES;
        gT.executorTag = msg.tag;
    }
    cashback(s);
}

// ===================== оплата жетонами (USDT) =========================

fun jFund(from: address, amt: int): bool {
    if (from != gCustomer || gM.funded) { return false; }
    if (gState != ST_PROPOSED && gState != ST_ACCEPTED) { return false; }
    var due = gAmount;
    if (gFeePayer == FEE_BY_CUSTOMER) { due += gFee; }
    if (amt < due) { return false; }
    if (gFeePayer == FEE_BY_CUSTOMER) { gM.feePaid = true; }
    gM.funded = true;
    gT.fundedAt = blockchain.now();
    if (gState == ST_ACCEPTED) {
        gState = ST_ACTIVE;
        gT.deadline = blockchain.now() + gT.deliveryPeriod;
    }
    gM.customerClaim += amt - due;
    return true;
}

fun jAccept(from: address, tag: int, code: int, amt: int): bool {
    if (gState != ST_PROPOSED || gFeePayer != FEE_BY_EXECUTOR) { return false; }
    if (from == gCustomer || from == gR.arbiter) { return false; }
    if (!gOpenOffer && from != gExecutor!) { return false; }
    if (gOpenOffer && !inviteOk(code)) { return false; }
    if (!gM.funded || amt < gFee) { return false; }
    val now = blockchain.now();
    gExecutor = from;
    gT.executorTag = tag;
    gState = ST_ACTIVE;
    gT.acceptedAt = now;
    gT.deadline = now + gT.deliveryPeriod;
    gM.feePaid = true;
    gM.executorClaim += amt - gFee;
    return true;
}

fun jPropose(from: address, amount: int, deadline: int, termsHash: int, amt: int): bool {
    val isC = from == gCustomer;
    if (!isC && !isExecutor(from)) { return false; }
    if (!isChangeable()) { return false; }
    if (gM.change != null || amount < minAmount()) { return false; }
    val now = blockchain.now();
    if (deadline <= now || deadline > now + MAX_DELIVERY_PERIOD) { return false; }
    val due = dueFor(isC, amount);
    if (amt < due) { return false; }
    gM.change = Change {
        proposer: from,
        amount: amount,
        deadline: deadline,
        termsHash: termsHash,
        customerPaid: isC ? due : 0,
        executorPaid: isC ? 0 : due,
    }.toCell();
    if (isC) { gM.customerClaim += amt - due; } else { gM.executorClaim += amt - due; }
    return true;
}

fun jChangeAccept(from: address, amt: int): bool {
    if (gM.change == null) { return false; }
    var ch = Change.fromCell(gM.change!);
    val isC = from == gCustomer;
    if (from == ch.proposer || (!isC && !isExecutor(from))) { return false; }
    if (!isChangeable()) { return false; }
    val due = dueFor(isC, ch.amount);
    if (amt < due) { return false; }
    if (isC) {
        ch.customerPaid = due;
        gM.customerClaim += amt - due;
    } else {
        ch.executorPaid = due;
        gM.executorClaim += amt - due;
    }
    applyChange(ch);
    return true;
}

// Деньги приходят переводом жетонов на адрес сделки; в forward_payload — что это за платёж.
fun onJettonNotify(msg: JettonNotify) {
    // принимаем уведомления ТОЛЬКО от собственного жетон-кошелька сделки
    if (gCurrency != CUR_JETTON || gJ.jettonWallet == null || gSender != gJ.jettonWallet!) {
        return;
    }
    val from = msg.sender;
    val amt = msg.amount;
    var op = 0;
    var tag = 0;
    var code = 0;
    var chAmount = 0;
    var chDeadline = 0;
    var chTerms = 0;
    var parsed = false;
    try {
        var p: slice = msg.forwardPayload;
        if (p.remainingBitsCount() >= 1 && p.loadBool()) {
            p = p.loadRef().beginParse();
        }
        op = p.preloadUint(32);
        if (op == OP_ACCEPT) {
            val ac = Accept.fromSlice(p, { assertEndAfterReading: false });
            tag = ac.tag;
            code = ac.code;
        }
        if (op == OP_PROPOSE) {
            val pc = ProposeChange.fromSlice(p, { assertEndAfterReading: false });
            chAmount = pc.amount;
            chDeadline = pc.deadline;
            chTerms = pc.termsHash;
        }
        parsed = true;
    } catch {
        parsed = false;
    }
    var ok = false;
    if (parsed) {
        if (op == OP_FUND) { ok = jFund(from, amt); }
        else if (op == OP_ACCEPT) { ok = jAccept(from, tag, code, amt); }
        else if (op == OP_PROPOSE) { ok = jPropose(from, chAmount, chDeadline, chTerms, amt); }
        else if (op == OP_CHANGE_ACCEPT) { ok = jChangeAccept(from, amt); }
    }
    if (!ok) {
        // платёж не подошёл (не тот статус, не та сумма, чужой адрес) — возвращаем жетоны отправителю
        sendJettons(amt, from, from, 0, MODE_REMAINING_VALUE | MODE_IGNORE_ERRORS, 0);
        return;
    }
    // остаток TON из уведомления — обратно отправителю
    cashback(from);
}

// ============================ входящие ================================

type DealMessage = DealInit | TakeWalletAddress | Accept | SetInvite | Fund | ProposeChange
    | Resolve | Withdraw | JettonNotify | SetTag

fun handle(inBody: slice) {
    var body = inBody;
    if (body.isEmpty()) {
        return;                     // просто пополнение баланса
    }
    if (body.preloadUint(32) == 0) {
        body.skipBits(32);
        if (body.bitsEqual("done".literalSlice())) { return onDone(); }
        if (body.bitsEqual("confirm".literalSlice())) { return onConfirm(); }
        if (body.bitsEqual("contest".literalSlice())) { return onContest(); }
        if (body.bitsEqual("rework".literalSlice())) { return onRework(); }
        if (body.bitsEqual("refund".literalSlice())) { return onRefund(); }
        if (body.bitsEqual("dispute".literalSlice())) { return onDispute(); }
        if (body.bitsEqual("claim".literalSlice())) { return onClaim(); }
        if (body.bitsEqual("refund_timeout".literalSlice())) { return onRefundTimeout(); }
        if (body.bitsEqual("reject".literalSlice())) { return onReject(); }
        if (body.bitsEqual("cancel".literalSlice())) { return onCancel(); }
        if (body.bitsEqual("cancel_request".literalSlice())) { return onCancelRequest(); }
        if (body.bitsEqual("cancel_withdraw".literalSlice())) { return onCancelWithdraw(); }
        if (body.bitsEqual("change_accept".literalSlice())) { return onChangeAccept(); }
        if (body.bitsEqual("change_decline".literalSlice())) { return onChangeDecline(); }
        throw E_INVALID_MESSAGE;
    }
    val msg = lazy DealMessage.fromSlice(inBody);
    match (msg) {
        DealInit => onDealInit(msg),
        TakeWalletAddress => onTakeWalletAddress(msg),
        Accept => onAccept(msg),
        SetInvite => onSetInvite(msg),
        Fund => onFund(),
        ProposeChange => onProposeChange(msg),
        Resolve => onResolve(msg),
        Withdraw => onWithdraw(msg),
        JettonNotify => onJettonNotify(msg),
        SetTag => onSetTag(msg),
        else => throw E_INVALID_MESSAGE,
    }
}

fun onInternalMessage(in: InMessage) {
    loadData();
    gSender = in.senderAddress;
    gValue = in.valueCoins;
    handle(in.body);
    if (gInit) {
        saveData();
    }
}

// Перевод жетонов не прошёл (например, кошелёк заблокирован эмитентом) — сумма остаётся к выводу.
fun onBouncedMessage(in: InMessageBounced) {
    loadData();
    // принимаем отскоки только от собственного жетон-кошелька сделки
    if (!gInit || gJ.jettonWallet == null || in.senderAddress != gJ.jettonWallet!) {
        return;
    }
    var b = in.bouncedBody;
    b.skipBouncedPrefix();
    if (b.loadUint(32) != OP_JETTON_TRANSFER) {
        return;
    }
    val queryId = b.loadUint(64);
    val amount = b.loadCoins();
    if (queryId == Q_CUSTOMER) { gM.customerClaim += amount; }
    if (queryId == Q_EXECUTOR) { gM.executorClaim += amount; }
    saveData();
}

// ============================= геттеры ================================

// Все данные сделки одной ячейкой (формат DealData первой версии) — надёжно читается через toncenter
get fun dealCell(): cell {
    loadData();
    val c12 = beginCell().storeAddressOpt(gJ.jettonWallet).endCell();
    val c11 = beginCell()
        .storeInt(contract.getOriginalBalance(), 257)
        .storeInt(gCurrency, 257)
        .storeAddressOpt(gJ.jettonMaster)
        .storeRef(c12)
        .endCell();
    var b10 = beginCell();
    if (gM.change == null) {
        b10.storeBool(false);
    } else {
        val ch = Change.fromCell(gM.change!);
        b10.storeBool(true)
            .storeAddress(ch.proposer)
            .storeCoins(ch.amount)
            .storeUint(ch.deadline, 32)
            .storeUint(ch.termsHash, 256)
            .storeCoins(ch.customerPaid)
            .storeCoins(ch.executorPaid);
    }
    val c10 = b10.storeRef(c11).endCell();
    val c9 = beginCell().storeInt(gT.version, 257).storeRef(c10).endCell();
    val c8 = beginCell()
        .storeInt(gT.executorTag, 257)
        .storeBool(gM.feePaid)
        .storeBool(gM.funded)
        .storeInt(gM.customerClaim, 257)
        .storeInt(gM.executorClaim, 257)
        .storeBool(gM.cancelRequested)
        .storeRef(c9)
        .endCell();
    val c7 = beginCell().storeInt(gT.customerShare, 257).storeInt(gT.customerTag, 257).storeInt(gM.invite, 257).storeRef(c8).endCell();
    val c6 = beginCell().storeInt(gT.disputedAt, 257).storeAddressOpt(gR.disputedBy).storeInt(gT.closedAt, 257).storeRef(c7).endCell();
    val c5 = beginCell().storeInt(gT.fundedAt, 257).storeInt(gT.deliveredAt, 257).storeInt(gT.contestedAt, 257).storeRef(c6).endCell();
    val c4 = beginCell().storeInt(gT.deadline, 257).storeInt(gT.createdAt, 257).storeInt(gT.acceptedAt, 257).storeRef(c5).endCell();
    val c3 = beginCell().storeUint(gT.termsHash, 256).storeInt(gT.deliveryPeriod, 257).storeInt(gT.reviewPeriod, 257).storeRef(c4).endCell();
    val c2 = beginCell().storeInt(gFeeBps, 257).storeInt(gFeePayer, 257).storeInt(gState, 257).storeRef(c3).endCell();
    val c1 = beginCell().storeAddress(gR.arbiter).storeInt(gAmount, 257).storeInt(gFee, 257).storeRef(c2).endCell();
    return beginCell()
        .storeInt(gId, 257)
        .storeAddress(gCustomer)
        .storeAddressOpt(gExecutor)
        .storeBool(gOpenOffer)
        .storeRef(c1)
        .endCell();
}

get fun state(): int {
    loadData();
    return gState;
}
