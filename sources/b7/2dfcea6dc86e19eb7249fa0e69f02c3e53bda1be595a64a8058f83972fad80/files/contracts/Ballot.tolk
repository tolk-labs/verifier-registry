// Ballot (бюллетень) — отметка одного кошелька в одном предложении (защита от повторного голоса).
// Адрес однозначно вычисляется из (proposal, voter), поэтому у кошелька
// в каждом предложении ровно один Ballot.
import "types"

type AllowedBallotMessage = CastVote

contract Ballot {
    storage: BallotStorage
    incomingMessages: AllowedBallotMessage
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedBallotMessage.fromSlice(in.body);

    match (msg) {
        CastVote => {
            var storage = lazy BallotStorage.load();
            assert (in.senderAddress == storage.proposal) throw Errors.NotFromProposal;
            assert (!storage.hasVoted) throw Errors.AlreadyVoted;
            storage.hasVoted = true;
            storage.choice = msg.choice;
            storage.save();

            // Оставляем небольшой резерв на хранение, остальное возвращаем голосующему.
            reserveGramsOnBalance(BALLOT_RESERVE, RESERVE_MODE_AT_MOST);
            val refundMsg = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: storage.voter,
            });
            // SAFETY: весь баланс сверх резерва — сдача голосующего; Ballot хранит
            // только отметку о голосе и не держит чужих средств.
            refundMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        else => {
            assert (in.body.isEmpty()) throw Errors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {}

get fun hasVoted(): bool {
    val storage = lazy BallotStorage.load();
    return storage.hasVoted;
}

get fun choice(): Choice {
    val storage = lazy BallotStorage.load();
    return storage.choice;
}
