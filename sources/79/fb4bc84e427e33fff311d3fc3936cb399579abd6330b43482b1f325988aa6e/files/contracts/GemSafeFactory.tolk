// =====================================================================
//  GemSafe — DealMaster: фабрика сделок
//  Создаёт отдельный контракт Deal на каждую сделку. Код сделки хранится
//  в данных фабрики, адрес сделки = f(код сделки, адрес фабрики, номер).
// =====================================================================
tolk 1.5

import "messages"

contract GemSafeFactory {
    author: "gemsafe.ton"
    version: "2.0"
    description: "GemSafe (gemsafe.ton) — factory of escrow deals on TON"
    incomingMessages: MasterMessage
}

struct MasterExtra {
    feeBps: uint16
    nextId: uint64
    paused: bool
    jettonMaster: address?      // мастер-контракт USDT (mainnet: EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs)
}

struct MasterStorage {
    owner: address
    arbiter: address
    feeWallet: address
    extra: Cell<MasterExtra>
    dealCode: cell
}

// Начальные данные сделки: только фабрика и номер (остальное придёт в DealInit)
fun dealState(code: cell, id: int): AutoDeployAddress {
    return {
        stateInit: {
            code: code,
            data: beginCell().storeAddress(contract.getAddress()).storeUint(id, 64).storeBool(false).endCell(),
        }
    };
}

// Заказчик открывает сделку и сразу платит: в TON — этим же сообщением,
// в USDT — следующим переводом жетонов на адрес сделки (до оплаты принять сделку нельзя).
fun onCreateDeal(st: MasterStorage, x: MasterExtra, msg: CreateDeal, customer: address, value: int): MasterExtra {
    assert (!x.paused) throw E_PAUSED;
    assert (value >= CREATE_GAS) throw E_NOT_ENOUGH_TON;
    assert (msg.currency == CUR_TON || msg.currency == CUR_JETTON) throw E_BAD_CURRENCY;
    assert (msg.currency == CUR_TON || x.jettonMaster != null) throw E_JETTON_NOT_CONFIGURED;
    assert (msg.amount >= (msg.currency == CUR_JETTON ? MIN_JETTON_AMOUNT : MIN_DEAL_AMOUNT)) throw E_AMOUNT_TOO_SMALL;
    assert (customer != st.arbiter) throw E_ARBITER_PARTY;
    if (msg.executor != null) {
        assert (msg.executor! != customer) throw E_EXECUTOR_IS_CUSTOMER;
        assert (msg.executor! != st.arbiter) throw E_ARBITER_PARTY;
    }
    assert (msg.feePayer == FEE_BY_CUSTOMER || msg.feePayer == FEE_BY_EXECUTOR) throw E_BAD_FEE_PAYER;
    assert (msg.deliveryPeriod >= MIN_PERIOD && msg.deliveryPeriod <= MAX_DELIVERY_PERIOD) throw E_BAD_DELIVERY;
    assert (msg.reviewPeriod >= MIN_PERIOD && msg.reviewPeriod <= MAX_REVIEW_PERIOD) throw E_BAD_REVIEW;
    assert (msg.executor != null || msg.invite != 0) throw E_INVITE_REQUIRED;   // открытая сделка — только по ссылке с кодом

    val prepaid = msg.currency == CUR_TON;
    if (prepaid) {
        var due = msg.amount;
        if (msg.feePayer == FEE_BY_CUSTOMER) {
            due += msg.amount * x.feeBps / BPS;
        }
        assert (value >= CREATE_GAS + due) throw E_ATTACH_DEAL_AMOUNT;
    }

    val id = x.nextId;
    val terms = msg.terms.load();
    createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: 0,
        dest: dealState(st.dealCode, id),
        body: DealInit {
            customer: customer,
            executor: msg.executor,
            arbiter: st.arbiter,
            extra: DealInitExtra {
                feeWallet: st.feeWallet,
                amount: msg.amount,
                feeBps: x.feeBps,
                deliveryPeriod: msg.deliveryPeriod,
                reviewPeriod: msg.reviewPeriod,
                feePayer: msg.feePayer,
                customerTag: msg.tag,
                currency: msg.currency,
                jettonMaster: msg.currency == CUR_JETTON ? x.jettonMaster : null,
                prepaid: prepaid,
                hashes: DealInitHashes { invite: msg.invite, termsHash: terms.termsHash }.toCell(),
            }.toCell(),
        }
    }).send(MODE_REMAINING_VALUE);

    return {
        feeBps: x.feeBps,
        nextId: id + 1,
        paused: x.paused,
        jettonMaster: x.jettonMaster,
    };
}

type MasterMessage = CreateDeal | SetConfig | TransferOwnership | SetJetton | SetPaused

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;                     // просто пополнение баланса
    }
    var st = MasterStorage.fromCell(contract.getData());
    var x = st.extra.load();
    val sender = in.senderAddress;
    val msg = lazy MasterMessage.fromSlice(in.body);
    match (msg) {
        CreateDeal => {
            x = onCreateDeal(st, x, msg, sender, in.valueCoins);
        }
        SetConfig => {
            assert (sender == st.owner) throw E_ONLY_OWNER;
            assert (msg.feeBps <= MAX_FEE_BPS) throw E_FEE_TOO_HIGH;
            st.arbiter = msg.arbiter;
            st.feeWallet = msg.feeWallet;
            x.feeBps = msg.feeBps;
            cashback(sender);
        }
        TransferOwnership => {
            assert (sender == st.owner) throw E_ONLY_OWNER;
            st.owner = msg.newOwner;
            cashback(sender);
        }
        // Указать мастер-контракт жетона (USDT) для новых сделок
        SetJetton => {
            assert (sender == st.owner) throw E_ONLY_OWNER;
            x.jettonMaster = msg.jettonMaster;
            cashback(sender);
        }
        SetPaused => {
            assert (sender == st.owner) throw E_ONLY_OWNER;
            x.paused = msg.paused;
            cashback(sender);
        }
        else => throw E_INVALID_MESSAGE,
    }
    st.extra = x.toCell();
    contract.setData(st.toCell());
}

// Сделка не создалась (не должно происходить) — средства остаются на фабрике.
fun onBouncedMessage(in: InMessageBounced) {
}

// ============================= геттеры ================================

// Настройки фабрики одной ячейкой (формат MasterConfig первой версии)
get fun configCell(): cell {
    val st = MasterStorage.fromCell(contract.getData());
    val x = st.extra.load();
    return beginCell()
        .storeAddress(st.owner)
        .storeAddress(st.arbiter)
        .storeAddress(st.feeWallet)
        .storeRef(beginCell()
            .storeInt(x.feeBps, 257)
            .storeInt(x.nextId, 257)
            .storeBool(x.paused)
            .storeAddressOpt(x.jettonMaster)
            .endCell())
        .endCell();
}

get fun dealAddress(id: int): address {
    val st = MasterStorage.fromCell(contract.getData());
    return dealState(st.dealCode, id).calculateAddress();
}

get fun nextId(): int {
    val st = MasterStorage.fromCell(contract.getData());
    return st.extra.load().nextId;
}

// Сервис, которому принадлежит контракт
get fun service(): string {
    return "gemsafe.ton";
}

// Хэш кода сделок — чтобы любой мог сверить его с проверенным исходником
get fun dealCodeHash(): int {
    val st = MasterStorage.fromCell(contract.getData());
    return st.dealCode.hash();
}
