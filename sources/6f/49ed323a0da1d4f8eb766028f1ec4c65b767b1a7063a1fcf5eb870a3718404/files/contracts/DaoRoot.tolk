// DaoRoot — главный контракт DAO: администратор, список предлагающих, параметры,
// создание предложений. Этап Б1.2: создание предложений и управление предлагающими.
// Б1.3: отмена предложений. Б1.4: параметры (в жёстких границах) и права администратора.

import "@bounds/bounds"
import "@gen/Proposal.code"
import "types"

type AllowedDaoMessage =
    | CreateProposal
    | SetProposer
    | RemoveProposer
    | CancelProposal
    | SetParams
    | TransferAdmin
    | AcceptAdmin
    | RenounceAdmin

contract DaoRoot {
    storage: DaoStorage
    incomingMessages: AllowedDaoMessage
}

fun proposalInitFor(id: uint64): ContractState {
    return {
        code: proposalCompiledCode(),
        data: ProposalStorage {
            dao: contract.getAddress(),
            id,
            details: null,
            votesYes: 0,
            votesNo: 0,
            status: Status.Open,
        }.toCell(),
    };
}

// Какие типы предложений может создавать роль (DAO.md, раздел 4).
fun isKindAllowed(role: Role, kind: ProposalType): bool {
    return match (kind) {
        ProposalType.Pressing => true,
        ProposalType.Repress => role == Role.Label,
        ProposalType.Treasury => false,
        ProposalType.Governance => true,
        ProposalType.Community => true,
    };
}

fun assertAdmin(storage: DaoStorage, sender: address) {
    assert (storage.admin != null && sender == storage.admin) throw Errors.NotAdmin;
}

// Параметры должны лежать внутри жёстких границ, зашитых в код (DAO.md, раздел 5).
fun isValidParams(p: Params): bool {
    return p.votingDelay >= VOTING_DELAY_MIN && p.votingDelay <= VOTING_DELAY_MAX &&
        p.minDuration >= DURATION_BOUND_MIN &&
        p.minDuration <= p.maxDuration &&
        p.maxDuration <= DURATION_BOUND_MAX &&
        p.minVotesFloor >= MIN_VOTES_BOUND_MIN &&
        p.minVotesFloor <= p.minVotesCeil &&
        p.minVotesCeil <= MIN_VOTES_BOUND_MAX;
}

// Возвращает отправителю остаток его сообщения: DaoRoot не копит чужие GRAM (инвариант 8).
fun replyExcess(to: address) {
    val replyMsg = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: to,
    });
    // SAFETY: только остаток входящего сообщения; баланс DaoRoot не расходуется.
    replyMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun emitAdminAction(action: AdminAction, subject: address?) {
    val log = createExternalLogMessage({
        dest: createAddressNone(),
        body: AdminActionEvent { action, subject },
    });
    log.send(SEND_MODE_REGULAR);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedDaoMessage.fromSlice(in.body);

    match (msg) {
        CreateProposal => {
            var storage = lazy DaoStorage.load();
            val found = storage.proposers.get(in.senderAddress);
            assert (found.isFound) throw Errors.NotProposer;
            val role = found.loadValue();

            assert (msg.kind != ProposalType.Treasury) throw Errors.TypeDisabled;
            assert (isKindAllowed(role, msg.kind)) throw Errors.TypeNotAllowed;

            val params = storage.params.load();
            assert (
                msg.duration >= params.minDuration && msg.duration <= params.maxDuration
            ) throw Errors.BadDuration;
            assert (
                msg.minVotes >= params.minVotesFloor && msg.minVotes <= params.minVotesCeil
            ) throw Errors.BadMinVotes;
            assert (in.valueCoins >= MIN_CREATE_VALUE) throw Errors.NotEnoughValue;

            val id = storage.nextProposalId;
            storage.nextProposalId = id + 1;
            storage.save();

            val now = blockchain.now();
            val startAt = now + params.votingDelay;
            val details = ProposalDetails {
                author: in.senderAddress,
                kind: msg.kind,
                createdAt: now,
                startAt,
                endAt: startAt + msg.duration,
                minVotes: msg.minVotes,
                textHash: msg.textHash,
                forumUrl: msg.forumUrl,
            };

            val deployMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                value: 0,
                dest: { stateInit: proposalInitFor(id) },
                body: InitProposal { details: details.toCell() },
            });
            // SAFETY: пересылаем в новый Proposal только то, что приложил автор
            // (не меньше MIN_CREATE_VALUE); Proposal вернёт ему излишек.
            deployMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);

            val log = createExternalLogMessage({
                dest: createAddressNone(),
                body: ProposalCreatedEvent {
                    id,
                    author: in.senderAddress,
                    kind: msg.kind,
                },
            });
            log.send(SEND_MODE_REGULAR);
        }
        SetProposer => {
            var storage = lazy DaoStorage.load();
            assertAdmin(storage, in.senderAddress);
            storage.proposers.set(msg.wallet, msg.role);
            storage.save();
            emitAdminAction(AdminAction.SetProposer, msg.wallet);
            replyExcess(in.senderAddress);
        }
        RemoveProposer => {
            var storage = lazy DaoStorage.load();
            assertAdmin(storage, in.senderAddress);
            storage.proposers.delete(msg.wallet);
            storage.save();
            emitAdminAction(AdminAction.RemoveProposer, msg.wallet);
            replyExcess(in.senderAddress);
        }
        CancelProposal => {
            val storage = lazy DaoStorage.load();
            assertAdmin(storage, in.senderAddress);
            assert (msg.id < storage.nextProposalId) throw Errors.UnknownProposal;

            val proposal = AutoDeployAddress {
                stateInit: proposalInitFor(msg.id),
            }.calculateAddress();
            val cancelMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                value: 0,
                dest: proposal,
                body: CancelByDao { replyTo: in.senderAddress },
            });
            // SAFETY: пересылаем только то, что приложил администратор;
            // Proposal вернёт сдачу ему же (replyTo).
            cancelMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            // Журнал фиксирует запрос администратора; результат (Cancelled)
            // пишет сам Proposal событием ProposalClosedEvent.
            emitAdminAction(AdminAction.CancelProposal, proposal);
        }
        SetParams => {
            var storage = lazy DaoStorage.load();
            assertAdmin(storage, in.senderAddress);
            assert (isValidParams(msg.params.load())) throw Errors.BadParams;
            storage.params = msg.params;
            storage.save();
            emitAdminAction(AdminAction.SetParams, null);
            replyExcess(in.senderAddress);
        }
        TransferAdmin => {
            var storage = lazy DaoStorage.load();
            assertAdmin(storage, in.senderAddress);
            storage.pendingAdmin = msg.newAdmin;
            storage.save();
            emitAdminAction(AdminAction.TransferAdmin, msg.newAdmin);
            replyExcess(in.senderAddress);
        }
        AcceptAdmin => {
            var storage = lazy DaoStorage.load();
            assert (
                storage.pendingAdmin != null && in.senderAddress == storage.pendingAdmin
            ) throw Errors.NotPendingAdmin;
            storage.admin = in.senderAddress;
            storage.pendingAdmin = null;
            storage.save();
            emitAdminAction(AdminAction.AcceptAdmin, in.senderAddress);
            replyExcess(in.senderAddress);
        }
        RenounceAdmin => {
            var storage = lazy DaoStorage.load();
            assertAdmin(storage, in.senderAddress);
            storage.admin = null;
            storage.pendingAdmin = null;
            storage.save();
            emitAdminAction(AdminAction.RenounceAdmin, null);
            replyExcess(in.senderAddress);
        }
        else => {
            assert (in.body.isEmpty()) throw Errors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {}

get fun admin(): address? {
    val storage = lazy DaoStorage.load();
    return storage.admin;
}

get fun pendingAdmin(): address? {
    val storage = lazy DaoStorage.load();
    return storage.pendingAdmin;
}

// (пауза до старта, мин. срок, макс. срок, нижняя и верхняя граница минимума голосов)
get fun params(): (uint32, uint32, uint32, uint32, uint32) {
    val storage = lazy DaoStorage.load();
    val p = storage.params.load();
    return (p.votingDelay, p.minDuration, p.maxDuration, p.minVotesFloor, p.minVotesCeil);
}

get fun nextProposalId(): uint64 {
    val storage = lazy DaoStorage.load();
    return storage.nextProposalId;
}

// 0 — не предлагающий, 1 — лейбл, 2 — команда
get fun proposerRole(wallet: address): uint8 {
    val storage = lazy DaoStorage.load();
    val found = storage.proposers.get(wallet);
    if (!found.isFound) {
        return 0;
    }
    return found.loadValue() as uint8;
}

get fun proposalAddress(id: uint64): address {
    return AutoDeployAddress { stateInit: proposalInitFor(id) }.calculateAddress();
}
