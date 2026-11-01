// NFT-паспорта пластинок vinyl.market — общие типы, сообщения и ошибки (задача №15, решения 29.10.2026).
// Совместимость: TEP-62 (NFT), TEP-64 (метаданные по ссылке, off-chain), TEP-66 (роялти).
// Одна коллекция на релиз; номер паспорта = номер копии (1…тираж). Паспорт выпускается при получении
// («бланк печатается, когда пришёл покупатель с кодом»), поэтому номера идут не по порядку.
// Владелец коллекции — мультиподпись; у сайта ключ выпуска с дневным лимитом. Больше тиража
// выпустить нельзя никому: тираж записан в коллекции и не меняется.

// ───────────── Суммы ─────────────
// Сколько GRAM приложить к выпуску (излишек вернётся отправителю)
const PASSPORT_MIN_MINT_VALUE = grams("0.05")
// Сколько остаётся на паспорте для оплаты хранения
const PASSPORT_RESERVE = grams("0.02")
// Сколько оставляет коллекция себе при выводе излишка
const PASSPORT_COLLECTION_RESERVE = grams("0.05")
// Запас на пересылку каждого исходящего сообщения при передаче паспорта (уведомление новому
// владельцу, возврат излишка). Реальная комиссия — около 0,0005 GRAM; фиксированный запас делает
// проверку суммы предсказуемой: кошельки прикладывают к передаче NFT 0,05 GRAM — этого хватает.
const PASSPORT_TRANSFER_FEE = grams("0.01")

const PASSPORT_SECONDS_PER_DAY = 86400

enum PassportErrors {
    NotCollectionOwner = 300
    NotMinter = 301
    DailyLimit = 302
    IndexOutOfRange = 303      // номер вне 1…тираж
    NotEnoughValue = 304
    NotFromCollection = 305
    AlreadyInitialized = 306   // паспорт с этим номером уже выпущен
    NotInitialized = 307
    NotItemOwner = 308
    NotEnoughForTransfer = 309 // не хватает GRAM на пересылку уведомлений
    InvalidRoyalty = 310
    WrongWorkchain = 311
    InvalidMessage = 0xFFFF
}

// ───────────── Хранилища ─────────────

// Метаданные по ссылке (TEP-64 off-chain), как у коллекций getgems:
//   collection — 0x01 + адрес описания коллекции (…/collection.json);
//   common — начало адреса описаний паспортов (…/nft/<релиз>/), без 0x01.
// Полное описание паспорта = 0x01 + common + личное содержимое паспорта («20.json»).
struct PassportContent {
    collection: cell
    common: cell
}

// TEP-66: доля numerator / denominator с перепродаж на маркетплейсах — на кошелёк destination
struct RoyaltyParams {
    numerator: uint16
    denominator: uint16
    destination: address
}

struct PassportCollectionStorage {
    owner: address      // мультиподпись: выпуск без лимита, настройки, адрес описаний
    minter: address?    // ключ выпуска сайта: с дневным лимитом
    dailyLimit: uint16  // сколько паспортов ключ выпуска может выпустить за сутки (UTC)
    day: uint32         // номер текущих суток (now / 86400)
    mintedToday: uint16 // сколько ключ выпуска выпустил за эти сутки
    mintedTotal: uint32 // сколько паспортов выпущено (без повторных попыток)
    maxSupply: uint32   // тираж: номера паспортов 1…maxSupply, не меняется
    content: Cell<PassportContent>
    royalty: Cell<RoyaltyParams>
}

struct PassportItemStorage {
    collection: address
    index: uint64
    owner: address? // null до выпуска
    content: cell?  // личное содержимое (TEP-64), null до выпуска
}

// ───────────── Сообщения vinyl.market ─────────────

// владелец коллекции или ключ выпуска → коллекция
struct (0x56500001) MintPassport {
    queryId: uint64
    index: uint64  // номер копии, 1…тираж
    owner: address // кошелёк покупателя
    content: cell  // личное содержимое: «<номер>.json»
}

// коллекция → паспорт (с развёртыванием)
struct (0x56500002) InitPassport {
    owner: address
    content: cell
    excessesTo: address // кому вернуть излишек (тот, кто запросил выпуск)
}

// владелец коллекции → коллекция
struct (0x56500003) SetMinter {
    queryId: uint64
    minter: address?
    dailyLimit: uint16
}

// Сменить адрес описаний и роялти (например, при переезде сайта) — только владелец коллекции
struct (0x56500004) ChangeContent {
    queryId: uint64
    content: Cell<PassportContent>
    royalty: Cell<RoyaltyParams>
}

struct (0x56500005) ChangeOwner {
    queryId: uint64
    newOwner: address
}

struct (0x56500006) WithdrawExcess {
    queryId: uint64
}

// событие для журнала (внешнее сообщение)
struct (0x56508001) PassportMintedEvent {
    index: uint64
    owner: address
    byMinter: bool
}

// ───────────── Стандартные сообщения NFT ─────────────

// TEP-62: передача паспорта
struct (0x5fcc3d14) PassportTransfer {
    queryId: uint64
    newOwner: address
    responseDestination: any_address     // addr_none — излишек не возвращать
    customPayload: cell?
    forwardAmount: coins
    forwardPayload: RemainingBitsAndRefs // Either Cell ^Cell — пересылается как есть
}

// TEP-62: уведомление новому владельцу
struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    prevOwner: address
    forwardPayload: RemainingBitsAndRefs
}

struct (0x2fcb26a2) PassportGetStaticData {
    queryId: uint64
}

struct (0x8b771735) PassportReportStaticData {
    queryId: uint64
    index: uint256
    collection: address
}

// TEP-66
struct (0x693d3950) GetRoyaltyParams {
    queryId: uint64
}

struct (0xa8cb00ad) ReportRoyaltyParams {
    queryId: uint64
    numerator: uint16
    denominator: uint16
    destination: address
}

struct (0xd53276db) PassportExcesses {
    queryId: uint64
}

// ───────────── Общие функции ─────────────

fun PassportCollectionStorage.load(): PassportCollectionStorage {
    return PassportCollectionStorage.fromCell(contract.getData());
}

fun PassportCollectionStorage.save(self) {
    contract.setData(self.toCell());
}

fun PassportItemStorage.load(): PassportItemStorage {
    return PassportItemStorage.fromCell(contract.getData());
}

fun PassportItemStorage.save(self) {
    contract.setData(self.toCell());
}

// address? → any_address: null становится addr_none (так ждут кошельки и обозреватели)
fun passportOrNone(a: address?): any_address {
    if (a == null) {
        return createAddressNone();
    }
    return a as any_address;
}

fun RoyaltyParams.isValid(self): bool {
    return self.denominator > 0 && self.numerator <= self.denominator;
}
