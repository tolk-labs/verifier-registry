// Proposal — одно предложение DAO: окно голосования, счётчики, статус.
// Этапы Б1.1–Б1.3: инициализация, голосование, отзыв, отмена, подведение итога.

import "@bounds/bounds"
import "@gen/Ballot.code"
import "types"

type AllowedProposalMessage = InitProposal | Vote | Withdraw | CancelByDao | Finalize

contract Proposal {
    storage: ProposalStorage
    incomingMessages: AllowedProposalMessage
}

fun ballotInitFor(voter: address): ContractState {
    return {
        code: ballotCompiledCode(),
        data: BallotStorage {
            proposal: contract.getAddress(),
            voter,
            hasVoted: false,
            choice: Choice.Yes,
        }.toCell(),
    };
}

// Типы с повышенным порогом (2/3 «за»): решения о деньгах и правилах.
fun needsTwoThirds(kind: ProposalType): bool {
    return kind == ProposalType.Treasury || kind == ProposalType.Governance;
}

fun decide(details: ProposalDetails, yes: uint32, no: uint32): Status {
    val total = yes + no;
    if (total < details.minVotes) {
        return Status.NoQuorum;
    }
    val passed = needsTwoThirds(details.kind) ? yes * 3 >= total * 2 : yes > no;
    return passed ? Status.Passed : Status.Failed;
}

// Закрывает предложение, пишет событие в журнал и возвращает сдачу.
fun close(mutate storage: ProposalStorage, status: Status, replyTo: address) {
    storage.status = status;
    storage.save();

    val log = createExternalLogMessage({
        dest: createAddressNone(),
        body: ProposalClosedEvent {
            id: storage.id,
            status,
            votesYes: storage.votesYes,
            votesNo: storage.votesNo,
        },
    });
    log.send(SEND_MODE_REGULAR);

    val replyMsg = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: replyTo,
    });
    // SAFETY: возвращаем только остаток входящего сообщения; резерв Proposal не трогаем.
    replyMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedProposalMessage.fromSlice(in.body);

    match (msg) {
        InitProposal => {
            var storage = lazy ProposalStorage.load();
            assert (in.senderAddress == storage.dao) throw Errors.NotFromDao;
            assert (storage.details == null) throw Errors.AlreadyInitialized;
            storage.details = msg.details;
            storage.save();

            // Оставляем резерв на хранение, остальное — сдача автору предложения.
            val author = msg.details.load().author;
            reserveGramsOnBalance(PROPOSAL_RESERVE, RESERVE_MODE_AT_MOST);
            val refundMsg = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: author,
            });
            // SAFETY: при инициализации баланс Proposal — это деньги автора;
            // резерв на хранение остаётся, остальное возвращается ему.
            refundMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        Vote => {
            var storage = lazy ProposalStorage.load();
            assert (storage.status == Status.Open) throw Errors.NotOpen;
            assert (storage.details != null) throw Errors.NotInitialized;
            val details = storage.details.load();
            val now = blockchain.now();
            assert (now >= details.startAt) throw Errors.VotingNotStarted;
            assert (now < details.endAt) throw Errors.VotingEnded;
            assert (in.valueCoins >= MIN_VOTE_VALUE) throw Errors.NotEnoughValue;

            // Считаем сразу; если Ballot откажет (повторный голос), откатим в onBouncedMessage.
            match (msg.choice) {
                Choice.Yes => storage.votesYes += 1,
                Choice.No => storage.votesNo += 1,
            }
            storage.save();

            val castMsg = createMessage({
                bounce: BounceMode.RichBounceOnlyRootCell,
                value: 0,
                dest: { stateInit: ballotInitFor(in.senderAddress) },
                body: CastVote {
                    voter: in.senderAddress,
                    choice: msg.choice,
                },
            });
            // SAFETY: пересылаем в Ballot только то, что приложил голосующий
            // (не меньше MIN_VOTE_VALUE); баланс Proposal не расходуется.
            castMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        Withdraw => {
            var storage = lazy ProposalStorage.load();
            assert (storage.status == Status.Open) throw Errors.NotOpen;
            assert (storage.details != null) throw Errors.NotInitialized;
            val details = storage.details.load();
            assert (in.senderAddress == details.author) throw Errors.NotAuthor;
            assert (blockchain.now() < details.startAt) throw Errors.AlreadyStarted;
            close(mutate storage, Status.Withdrawn, in.senderAddress);
        }
        CancelByDao => {
            var storage = lazy ProposalStorage.load();
            assert (in.senderAddress == storage.dao) throw Errors.NotFromDao;
            assert (storage.status == Status.Open) throw Errors.NotOpen;
            assert (storage.details != null) throw Errors.NotInitialized;
            val details = storage.details.load();
            assert (blockchain.now() < details.startAt) throw Errors.AlreadyStarted;
            close(mutate storage, Status.Cancelled, msg.replyTo);
        }
        Finalize => {
            var storage = lazy ProposalStorage.load();
            assert (storage.status == Status.Open) throw Errors.NotOpen;
            assert (storage.details != null) throw Errors.NotInitialized;
            val details = storage.details.load();
            assert (blockchain.now() >= details.endAt + FINALIZE_GRACE) throw Errors.VotingNotEnded;
            val status = decide(details, storage.votesYes, storage.votesNo);
            close(mutate storage, status, in.senderAddress);
        }
        else => {
            assert (in.body.isEmpty()) throw Errors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    // Возвращается только CastVote: откатываем голос и отдаём сдачу голосующему.
    val rich = lazy RichBounceBody.fromSlice(in.bouncedBody);
    val cast = lazy CastVote.fromCell(rich.originalBody);

    var storage = lazy ProposalStorage.load();
    match (cast.choice) {
        Choice.Yes => storage.votesYes -= 1,
        Choice.No => storage.votesNo -= 1,
    }
    storage.save();

    val refundMsg = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: cast.voter,
    });
    // SAFETY: возвращаем голосующему остаток его же вернувшегося сообщения;
    // баланс Proposal не расходуется.
    refundMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

get fun results(): (uint32, uint32) {
    val storage = lazy ProposalStorage.load();
    return (storage.votesYes, storage.votesNo);
}

get fun status(): Status {
    val storage = lazy ProposalStorage.load();
    return storage.status;
}

get fun isInitialized(): bool {
    val storage = lazy ProposalStorage.load();
    return storage.details != null;
}

get fun ballotAddress(voter: address): address {
    return AutoDeployAddress { stateInit: ballotInitFor(voter) }.calculateAddress();
}

get fun schedule(): (uint32, uint32, uint32) {
    val storage = lazy ProposalStorage.load();
    val details = storage.details!.load();
    return (details.createdAt, details.startAt, details.endAt);
}

get fun info(): (address, ProposalType, uint32) {
    val storage = lazy ProposalStorage.load();
    val details = storage.details!.load();
    return (details.author, details.kind, details.minVotes);
}
