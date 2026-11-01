// PassportItem — NFT-паспорт одной копии пластинки (TEP-62). Адрес зависит только от коллекции
// и номера копии, поэтому второй паспорт той же копии выпустить нельзя.
// Передача — стандартная (MyWallet, Getgems, передача на сайте vinyl.market — задача №11).
import "passport-types"

type AllowedPassportItemMessage = InitPassport | PassportTransfer | PassportGetStaticData

contract PassportItem {
    storage: PassportItemStorage
    incomingMessages: AllowedPassportItemMessage
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedPassportItemMessage.fromSlice(in.body);

    match (msg) {
        InitPassport => {
            var storage = lazy PassportItemStorage.load();
            assert (in.senderAddress == storage.collection) throw PassportErrors.NotFromCollection;
            assert (storage.owner == null) throw PassportErrors.AlreadyInitialized;
            storage.owner = msg.owner;
            storage.content = msg.content;
            storage.save();

            // Резерв на хранение остаётся на паспорте, остальное — тому, кто запросил выпуск.
            reserveGramsOnBalance(PASSPORT_RESERVE, RESERVE_MODE_AT_MOST);
            val refund = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: msg.excessesTo,
                body: PassportExcesses { queryId: 0 },
            });
            // SAFETY: при выпуске весь баланс паспорта — деньги выпускающего; резерв остаётся.
            refund.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        PassportTransfer => {
            var storage = lazy PassportItemStorage.load();
            assert (storage.owner != null) throw PassportErrors.NotInitialized;
            assert (in.senderAddress == storage.owner) throw PassportErrors.NotItemOwner;
            assert (msg.newOwner.getWorkchain() == BASECHAIN) throw PassportErrors.WrongWorkchain;

            // Как в стандартном nft-item.fc: на паспорте остаётся резерв, хватает на уведомление
            // новому владельцу (forwardAmount + пересылка) и на возврат излишка.
            val needResponse = !msg.responseDestination.isNone();
            var rest = contract.getOriginalBalance() - PASSPORT_RESERVE;
            if (msg.forwardAmount > 0) {
                rest -= msg.forwardAmount + PASSPORT_TRANSFER_FEE;
            }
            if (needResponse) {
                rest -= PASSPORT_TRANSFER_FEE;
            }
            assert (rest >= 0) throw PassportErrors.NotEnoughForTransfer;

            val prevOwner = storage.owner;
            storage.owner = msg.newOwner;
            storage.save();

            if (msg.forwardAmount > 0) {
                val notice = createMessage({
                    bounce: BounceMode.NoBounce,
                    value: msg.forwardAmount,
                    dest: msg.newOwner,
                    body: OwnershipAssigned {
                        queryId: msg.queryId,
                        prevOwner,
                        forwardPayload: msg.forwardPayload,
                    },
                });
                // SAFETY: forwardAmount оплачен отправителем (проверено выше).
                notice.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            if (needResponse) {
                reserveGramsOnBalance(PASSPORT_RESERVE, RESERVE_MODE_AT_MOST);
                val reply = createMessage({
                    bounce: BounceMode.NoBounce,
                    value: 0,
                    dest: msg.responseDestination.castToInternal(),
                    body: PassportExcesses { queryId: msg.queryId },
                });
                // SAFETY: излишек сверх резерва на хранение — тому, кого указал отправитель.
                reply.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
            }
        }
        PassportGetStaticData => {
            val storage = lazy PassportItemStorage.load();
            assert (storage.owner != null) throw PassportErrors.NotInitialized;
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: in.senderAddress,
                body: PassportReportStaticData {
                    queryId: msg.queryId,
                    index: storage.index as uint256,
                    collection: storage.collection,
                },
            });
            // SAFETY: только остаток входящего сообщения.
            reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        else => {
            // пустое сообщение — пополнение баланса
            assert (in.body.isEmpty()) throw PassportErrors.InvalidMessage;
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {}

// ───────────── Геттеры TEP-62 ─────────────

// (выпущен, номер, коллекция, владелец, личное содержимое)
get fun get_nft_data(): (bool, int, address, any_address, cell) {
    val storage = lazy PassportItemStorage.load();
    if (storage.owner == null) {
        return (false, storage.index, storage.collection, createAddressNone(), createEmptyCell());
    }
    return (
        true,
        storage.index,
        storage.collection,
        storage.owner as any_address,
        storage.content!,
    );
}
