// =====================================================================
//  GemSafe — общие константы, коды ошибок и сообщения (Tolk)
//  Формат сообщений совпадает с первой версией контракта, поэтому сайт
//  и бот работают с обеими версиями одинаково.
// =====================================================================
tolk 1.5

// ----------------------------- параметры ------------------------------
const MAX_FEE_BPS = 500;                    // потолок комиссии: 5.00%
const BPS = 10000;
const MIN_DEAL_AMOUNT: int = ton("0.1");
const CREATE_GAS: int = ton("0.1");              // запас на газ при создании сделки
const ACTION_GAS: int = ton("0.03");             // минимум к сообщениям с депозитом
const MIN_PERIOD = 3600;                    // 1 час
const MAX_DELIVERY_PERIOD = 15552000;       // 180 дней
const MAX_REVIEW_PERIOD = 2592000;          // 30 дней

const CUR_TON = 0;                          // расчёты в TON
const CUR_JETTON = 1;                       // расчёты в жетоне (USDT в сети TON)
const MIN_JETTON_AMOUNT = 1000000;          // минимум 1 USDT (6 знаков)
const JETTON_GAS: int = ton("0.1");              // TON к выводу жетонов
const JETTON_TX: int = ton("0.05");              // TON на исходящий перевод жетонов
const DISCOVERY_GAS: int = ton("0.03");
const KEEP_BALANCE: int = ton("0.01");
const KEEP_OPEN: int = ton("0.02");

const OP_ACCEPT = 0x50a4c703;
const OP_FUND = 0x50a4c704;
const OP_PROPOSE = 0x50a4c705;
const OP_CHANGE_ACCEPT = 0x50a4c709;
const OP_JETTON_TRANSFER = 0x0f8a7ea5;
const Q_CUSTOMER = 1;
const Q_EXECUTOR = 2;
const Q_FEE = 3;

const FEE_BY_CUSTOMER = 0;
const FEE_BY_EXECUTOR = 1;

const ST_PROPOSED = 0;
const ST_ACCEPTED = 1;
const ST_ACTIVE = 2;
const ST_DELIVERED = 3;
const ST_CONTESTED = 4;
const ST_DISPUTED = 5;
const ST_COMPLETED = 6;   // сумма — исполнителю, комиссия — сервису
const ST_CANCELLED = 7;   // отменена до оплаты / отклонена
const ST_REFUNDED = 8;    // сумма возвращена заказчику
const ST_RESOLVED = 9;    // решение арбитра

// режимы отправки и резерва
const MODE_REGULAR = 0;
const MODE_FEES_SEPARATELY = 1;
const MODE_IGNORE_ERRORS = 2;
const MODE_REMAINING_VALUE = 64;
const MODE_ALL_BALANCE = 128;
const RESERVE_EXACT = 0;
const RESERVE_AT_MOST = 2;

// ------------------------------ ошибки --------------------------------
// Те же коды, что в первой версии: сайт и бот показывают понятный текст.
const E_INVALID_MESSAGE = 130;
const E_BAD_FEE_PAYER = 1860;
const E_ALREADY_INIT = 2977;
const E_CANNOT_CONTEST = 4587;
const E_BAD_SHARE = 4730;
const E_PAY_IN_JETTONS = 5094;
const E_BAD_INVITE_CODE = 5933;
const E_NOT_INIT = 7657;
const E_INVITE_REQUIRED = 12193;
const E_CUSTOMER_CANNOT_ACCEPT = 13534;
const E_PAY_FEE_IN_JETTONS = 16247;
const E_ONLY_MASTER = 16588;
const E_WRONG_STATE = 17346;
const E_ONLY_CUSTOMER = 18550;
const E_ALREADY_FUNDED = 27392;
const E_BAD_DELIVERY = 29268;
const E_BAD_CURRENCY = 29500;
const E_NOT_ENOUGH_TON = 29562;
const E_BAD_INVITE = 30109;
const E_ONLY_OWNER = 35499;
const E_PROPOSER_CANNOT_ACCEPT = 36449;
const E_ATTACH_DEAL_AMOUNT = 36871;
const E_REVIEW_NOT_OVER = 37061;
const E_ATTACH_01 = 38983;
const E_ONLY_PARTIES = 39355;
const E_WALLET_KNOWN = 40564;
const E_NOTHING_TO_WITHDRAW = 40636;
const E_EXECUTOR_IS_CUSTOMER = 42449;
const E_JETTON_NOT_CONFIGURED = 43660;
const E_FEE_TOO_HIGH = 46136;
const E_NO_CHANGE = 46156;
const E_ONLY_INVITED = 46179;
const E_CHANGE_PROPOSED = 46247;
const E_ATTACH_MORE = 46549;
const E_NOT_PAID = 46695;
const E_AMOUNT_TOO_SMALL = 46710;
const E_BAD_DEADLINE = 48718;
const E_ONLY_JETTON_MASTER = 51072;
const E_BAD_REVIEW = 51602;
const E_ARBITER_PARTY = 54556;
const E_ONLY_EXECUTOR = 56628;
const E_ONLY_ARBITER = 57914;
const E_EXECUTOR_HAS_TIME = 57929;
const E_CANNOT_DISPUTE = 58639;
const E_PAUSED = 59457;

// ----------------------------- сообщения ------------------------------

struct TermsRef {
    termsHash: uint256             // отпечаток (sha256) условий: сам текст хранится только в GemSafe
}

struct (0x50a4c701) CreateDeal {
    queryId: uint64
    executor: address?             // null — принять может любой, у кого есть ссылка с кодом
    amount: coins
    deliveryPeriod: uint32         // срок выполнения, отсчитывается от принятия
    reviewPeriod: uint32           // срок на проверку / ответ
    feePayer: uint8                // 0 — заказчик, 1 — исполнитель
    tag: uint64                    // ссылка на Telegram-аккаунт (случайный код из бота), 0 — нет
    currency: uint8                // 0 — TON, 1 — USDT
    invite: uint256                // хэш секретного кода из ссылки-приглашения
    terms: Cell<TermsRef>
}

struct DealInitHashes {
    invite: uint256
    termsHash: uint256
}

struct DealInitExtra {
    feeWallet: address
    amount: coins
    feeBps: uint16
    deliveryPeriod: uint32
    reviewPeriod: uint32
    feePayer: uint8
    customerTag: uint64
    currency: uint8
    jettonMaster: address?
    prepaid: bool                  // TON-сделка: сумма (и комиссия заказчика) приложены к созданию
    hashes: Cell<DealInitHashes>
}

struct (0x50a4c702) DealInit {
    customer: address
    executor: address?
    arbiter: address
    extra: Cell<DealInitExtra>
}

struct (0x50a4c703) Accept { tag: uint64; code: uint128 }        // code — из ссылки-приглашения
struct (0x50a4c704) Fund { queryId: uint64 }
struct (0x50a4c705) ProposeChange {
    amount: coins
    deadline: uint32               // новый срок выполнения (unix time)
    termsHash: uint256
}
struct (0x50a4c706) Resolve { customerAmount: coins }            // сколько из суммы вернуть заказчику
struct (0x50a4c707) Withdraw { to: address }                     // вывести свои средства на кошелёк
struct (0x50a4c708) SetTag { tag: uint64 }
struct (0x50a4c709) ChangeAcceptJ { queryId: uint64 }            // «принять изменения» с доплатой жетонами
struct (0x50a4c70a) SetInvite { invite: uint256 }                // новая ссылка-приглашение

struct (0x50a4c711) SetConfig { arbiter: address; feeWallet: address; feeBps: uint16 }
struct (0x50a4c712) TransferOwnership { newOwner: address }
struct (0x50a4c713) SetPaused { paused: bool }
struct (0x50a4c714) SetJetton { jettonMaster: address? }

// ----- стандарт жетонов TEP-74 / TEP-89
struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    amount: coins
    destination: address
    responseDestination: address
    customPayload: cell?
    forwardTonAmount: coins
    forwardPayloadInRef: bool      // false — пустой forward_payload
}
struct (0x7362d09c) JettonNotify {
    queryId: uint64
    amount: coins
    sender: address
    forwardPayload: RemainingBitsAndRefs
}
struct (0x2c76b973) ProvideWalletAddress { queryId: uint64; ownerAddress: address; includeAddress: bool }
struct (0xd1735400) TakeWalletAddress { queryId: uint64; walletAddress: address; ownerAddress: cell? }

// Предложение изменить условия (хранится в сделке отдельной ячейкой)
struct Change {
    proposer: address
    amount: coins
    deadline: uint32
    termsHash: uint256
    customerPaid: coins            // уже внесённая доплата заказчика
    executorPaid: coins            // уже внесённая доплата исполнителя
}

// Текстовый комментарий для переводов (видно в кошельке)
@inline
fun comment(text: slice): builder {
    return beginCell().storeUint(0, 32).storeSlice(text);
}

// Вернуть остаток приложенных TON отправителю
@inline
fun cashback(to: address) {
    createMessage({ bounce: BounceMode.NoBounce, value: 0, dest: to })
        .send(MODE_REMAINING_VALUE | MODE_IGNORE_ERRORS);
}
