// vinyl.market DAO — общие типы, сообщения и ошибки (этап Б, см. DAO.md)
// ───────────── Перечисления ─────────────

enum ProposalType: uint8 {
    Pressing = 0
    Repress = 1
    Treasury = 2 // скрыт до этапа В: DaoRoot отклоняет создание (DAO.md, раздел 4)
    Governance = 3
    Community = 4
}

enum Role: uint8 {
    Label = 1 // верифицированный лейбл
    Team = 2  // кошелёк команды
}

enum Choice: uint8 {
    Yes = 0
    No = 1
}

enum Status: uint8 {
    Open = 0      // ожидание старта или идёт голосование (зависит от времени)
    Cancelled = 1 // отменено администратором до старта
    Withdrawn = 2 // отозвано автором до старта
    Passed = 3
    Failed = 4
    NoQuorum = 5  // на сайте: «No Quorum» — голосов меньше минимума
}

enum Errors {
    NotAdmin = 100
    NotProposer = 101
    TypeNotAllowed = 102
    TypeDisabled = 103
    BadDuration = 104
    BadMinVotes = 105
    NotFromDao = 106
    AlreadyInitialized = 107
    NotInitialized = 108
    VotingNotStarted = 109
    VotingEnded = 110
    AlreadyVoted = 111
    NotFromProposal = 112
    NotAuthor = 113
    AlreadyStarted = 114
    NotOpen = 115
    VotingNotEnded = 116
    BadParams = 117
    NotEnoughValue = 118
    UnknownProposal = 119
    NotPendingAdmin = 120
    InvalidMessage = 0xFFFF
}

// ───────────── Параметры и их жёсткие границы ─────────────
// Границы сроков вынесены в @bounds/bounds: боевые — contracts/bounds/prod,
// «быстрые» для разработки в тестнете — contracts/bounds/fast (Acton.fast.toml).
// Там же нижняя граница кворума MIN_VOTES_BOUND_MIN.

const MIN_VOTES_BOUND_MAX = 1000

// Сколько GRAM должен приложить голосующий (излишек возвращается)
const MIN_VOTE_VALUE = grams("0.05")
// Сколько остаётся на контракте Ballot для оплаты хранения
const BALLOT_RESERVE = grams("0.01")
// Сколько должен приложить автор при создании предложения (излишек возвращается)
const MIN_CREATE_VALUE = grams("0.1")
// Сколько остаётся на контракте Proposal для оплаты хранения
const PROPOSAL_RESERVE = grams("0.05")

// FINALIZE_GRACE (в @bounds/bounds): итог можно подвести не раньше чем через час
// после конца голосования — к этому времени гарантированно вернутся все отказы Ballot.

struct Params {
    votingDelay: uint32   // пауза до старта, сек (по умолчанию 48 ч)
    minDuration: uint32   // сек (по умолчанию 7 дней)
    maxDuration: uint32   // сек (по умолчанию 30 дней)
    minVotesFloor: uint32 // нижняя граница минимума голосов (10)
    minVotesCeil: uint32  // верхняя граница минимума голосов (1000)
}

// ───────────── Хранилища ─────────────

struct DaoStorage {
    admin: address?        // null после отказа от прав
    pendingAdmin: address? // предложенный новый администратор, ждёт подтверждения
    params: Cell<Params>
    proposers: map<address, Role>
    nextProposalId: uint64
}

struct ProposalDetails {
    author: address
    kind: ProposalType
    createdAt: uint32
    startAt: uint32
    endAt: uint32
    minVotes: uint32
    textHash: uint256 // хэш текста поста на форуме
    forumUrl: cell    // ссылка на пост (строка)
}

struct ProposalStorage {
    dao: address
    id: uint64
    details: Cell<ProposalDetails>? // null до InitProposal
    votesYes: uint32
    votesNo: uint32
    status: Status
}

struct BallotStorage {
    proposal: address
    voter: address
    hasVoted: bool
    choice: Choice
}

// ───────────── Сообщения ─────────────

// кошелёк → DaoRoot
struct (0x44410001) CreateProposal {
    kind: ProposalType
    duration: uint32
    minVotes: uint32
    textHash: uint256
    forumUrl: cell
}

// DaoRoot → Proposal
struct (0x44410002) InitProposal {
    details: Cell<ProposalDetails>
}

// кошелёк → Proposal
struct (0x44410003) Vote {
    choice: Choice
}

// Proposal → Ballot (и обратно целиком при отказе: RichBounceOnlyRootCell)
struct (0x4441000d) CastVote {
    voter: address
    choice: Choice
}

// автор → Proposal
struct (0x44410004) Withdraw {}

// администратор → DaoRoot → Proposal
struct (0x44410005) CancelProposal {
    id: uint64
}

struct (0x44410006) CancelByDao {
    replyTo: address // куда вернуть сдачу (кошелёк, запросивший отмену)
}

// любой → Proposal
struct (0x44410007) Finalize {}

// администратор → DaoRoot
struct (0x44410008) SetProposer {
    wallet: address
    role: Role
}

struct (0x44410009) RemoveProposer {
    wallet: address
}

struct (0x4441000a) SetParams {
    params: Cell<Params>
}

// Передача прав в два шага: администратор предлагает, новый кошелёк подтверждает.
struct (0x4441000b) TransferAdmin {
    newAdmin: address
}

struct (0x4441000e) AcceptAdmin {}

struct (0x4441000c) RenounceAdmin {}

// ───────────── События для журнала (внешние сообщения) ─────────────

struct (0x44418001) ProposalCreatedEvent {
    id: uint64
    author: address
    kind: ProposalType
}

struct (0x44418002) ProposalClosedEvent {
    id: uint64
    status: Status
    votesYes: uint32
    votesNo: uint32
}

enum AdminAction: uint8 {
    SetProposer = 1
    RemoveProposer = 2
    CancelProposal = 3
    SetParams = 4
    TransferAdmin = 5
    RenounceAdmin = 6
    AcceptAdmin = 7
}

struct (0x44418003) AdminActionEvent {
    action: AdminAction
    subject: address? // кого или что затронуло действие (кошелёк, предложение), если применимо
}

// ───────────── Загрузка и сохранение хранилищ ─────────────

fun DaoStorage.load(): DaoStorage {
    return DaoStorage.fromCell(contract.getData());
}

fun DaoStorage.save(self) {
    contract.setData(self.toCell());
}

fun ProposalStorage.load(): ProposalStorage {
    return ProposalStorage.fromCell(contract.getData());
}

fun ProposalStorage.save(self) {
    contract.setData(self.toCell());
}

fun BallotStorage.load(): BallotStorage {
    return BallotStorage.fromCell(contract.getData());
}

fun BallotStorage.save(self) {
    contract.setData(self.toCell());
}
