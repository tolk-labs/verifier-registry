// PassportCollection — коллекция NFT-паспортов одного релиза vinyl.market (задача №15).
// Владелец (мультиподпись) выпускает без лимита, назначает ключ выпуска сайта, меняет адрес описаний
// и роялти. Ключ выпуска сайта выпускает не больше dailyLimit в сутки. Номер паспорта = номер копии
// 1…maxSupply; тираж записан при развёртывании и не меняется — больше тиража не выпустить никому.
import "@gen/PassportItem.code"
import "passport-types"

type AllowedPassportCollectionMessage =
    | MintPassport
    | SetMinter
    | ChangeContent
    | ChangeOwner
    | WithdrawExcess
    | GetRoyaltyParams

contract PassportCollection {
    storage: PassportCollectionStorage
    incomingMessages: AllowedPassportCollectionMessage
}

fun passportInitFor(index: uint64): ContractState {
    return {
        code: passportItemCompiledCode(),
        data: PassportItemStorage {
            collection: contract.getAddress(),
            index,
            owner: null,
            content: null,
        }.toCell(),
    };
}

fun assertCollectionOwner(storage: PassportCollectionStorage, sender: address) {
    assert (sender == storage.owner) throw PassportErrors.NotCollectionOwner;
}

fun replyExcess(to: address, queryId: uint64) {
    val reply = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: to,
        body: PassportExcesses { queryId },
    });
    // SAFETY: только остаток входящего сообщения; баланс коллекции не расходуется.
    reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedPassportCollectionMessage.fromSlice(in.body);

    match (msg) {
        MintPassport => {
            var storage = lazy PassportCollectionStorage.load();
            val byOwner = in.senderAddress == storage.owner;
            if (!byOwner) {
                assert (
                    storage.minter != null && in.senderAddress == storage.minter
                ) throw PassportErrors.NotMinter;
                val day = blockchain.now() / PASSPORT_SECONDS_PER_DAY;
                if (day != storage.day) {
                    storage.day = day;
                    storage.mintedToday = 0;
                }
                assert (storage.mintedToday < storage.dailyLimit) throw PassportErrors.DailyLimit;
                storage.mintedToday += 1;
            }
            assert (
                msg.index >= 1 && msg.index <= storage.maxSupply
            ) throw PassportErrors.IndexOutOfRange;
            assert (msg.owner.getWorkchain() == BASECHAIN) throw PassportErrors.WrongWorkchain;
            assert (in.valueCoins >= PASSPORT_MIN_MINT_VALUE) throw PassportErrors.NotEnoughValue;
            storage.mintedTotal += 1;
            storage.save();

            val deploy = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                value: 0,
                dest: { stateInit: passportInitFor(msg.index) },
                body: InitPassport {
                    owner: msg.owner,
                    content: msg.content,
                    excessesTo: in.senderAddress,
                },
            });
            // SAFETY: в паспорт уходит только то, что приложил выпускающий (не меньше
            // PASSPORT_MIN_MINT_VALUE); паспорт оставит резерв и вернёт ему излишек.
            deploy.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);

            val log = createExternalLogMessage({
                dest: createAddressNone(),
                body: PassportMintedEvent {
                    index: msg.index,
                    owner: msg.owner,
                    byMinter: !byOwner,
                },
            });
            log.send(SEND_MODE_REGULAR);
        }
        SetMinter => {
            var storage = lazy PassportCollectionStorage.load();
            assertCollectionOwner(storage, in.senderAddress);
            storage.minter = msg.minter;
            storage.dailyLimit = msg.dailyLimit;
            storage.save();
            replyExcess(in.senderAddress, msg.queryId);
        }
        ChangeContent => {
            var storage = lazy PassportCollectionStorage.load();
            assertCollectionOwner(storage, in.senderAddress);
            assert (msg.royalty.load().isValid()) throw PassportErrors.InvalidRoyalty;
            storage.content = msg.content;
            storage.royalty = msg.royalty;
            storage.save();
            replyExcess(in.senderAddress, msg.queryId);
        }
        ChangeOwner => {
            var storage = lazy PassportCollectionStorage.load();
            assertCollectionOwner(storage, in.senderAddress);
            storage.owner = msg.newOwner;
            storage.save();
            replyExcess(in.senderAddress, msg.queryId);
        }
        WithdrawExcess => {
            val storage = lazy PassportCollectionStorage.load();
            assertCollectionOwner(storage, in.senderAddress);
            reserveGramsOnBalance(PASSPORT_COLLECTION_RESERVE, RESERVE_MODE_AT_MOST);
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: in.senderAddress,
                body: PassportExcesses { queryId: msg.queryId },
            });
            // SAFETY: владельцу коллекции уходит всё сверх резерва на хранение
            // (например, GRAM, вернувшиеся при повторном выпуске).
            reply.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        GetRoyaltyParams => {
            val storage = lazy PassportCollectionStorage.load();
            val r = storage.royalty.load();
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: in.senderAddress,
                body: ReportRoyaltyParams {
                    queryId: msg.queryId,
                    numerator: r.numerator,
                    denominator: r.denominator,
                    destination: r.destination,
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

// Паспорт с этим номером уже был выпущен — выпуск не состоялся: счётчик выпусков возвращаем.
// GRAM остаются в коллекции, владелец может вывести их сообщением WithdrawExcess.
fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    if (op != 0x56500002) {
        return;
    }
    // Отскочить может только выпуск, который уже был посчитан, поэтому счётчик больше нуля.
    var storage = lazy PassportCollectionStorage.load();
    storage.mintedTotal -= 1;
    storage.save();
}

// ───────────── Геттеры TEP-62 / TEP-66 ─────────────

// (следующий номер: -1 — номера не по порядку, описание коллекции, владелец)
get fun get_collection_data(): (int, cell, address) {
    val storage = lazy PassportCollectionStorage.load();
    return (-1, storage.content.load().collection, storage.owner);
}

get fun get_nft_address_by_index(index: int): address {
    return AutoDeployAddress { stateInit: passportInitFor(index as uint64) }.calculateAddress();
}

// Полное описание паспорта: 0x01 + начало адреса + личное содержимое («20.json»)
get fun get_nft_content(_index: int, individualContent: cell): cell {
    val storage = lazy PassportCollectionStorage.load();
    val common = storage.content.load().common;
    return beginCell()
        .storeUint(1, 8)
        .storeSlice(common.beginParse())
        .storeRef(individualContent)
        .endCell();
}

get fun royalty_params(): (int, int, address) {
    val storage = lazy PassportCollectionStorage.load();
    val r = storage.royalty.load();
    return (r.numerator, r.denominator, r.destination);
}

// ───────────── Геттеры vinyl.market ─────────────

// (ключ выпуска, дневной лимит, выпущено ключом за текущие сутки, номер суток, всего выпущено, тираж)
get fun minterInfo(): (
    address?,
    uint16,
    uint16,
    uint32,
    uint32,
    uint32,
) {
    val storage = lazy PassportCollectionStorage.load();
    val today = blockchain.now() / PASSPORT_SECONDS_PER_DAY;
    val mintedToday: uint16 = storage.day == today ? storage.mintedToday : 0 as uint16;
    return (
        storage.minter,
        storage.dailyLimit,
        mintedToday,
        today,
        storage.mintedTotal,
        storage.maxSupply,
    );
}
