import "constants"

// Обычное wallet-сообщение с текстовым комментарием (op 0). Комментарий `cancel` без учёта регистра позволяет
// автору вернуть обеспечение без интерфейса marketplace; исходящие подписи объясняют назначение
// перевода в кошельке получателя.
struct (0x00000000) TextComment {
    text: RemainingBitsAndRefs
}

fun isCancelComment(text: slice): bool {
    if (text.remainingBitsCount() != 48 || text.remainingRefsCount() != 0) {
        return false;
    }
    var expected = CANCEL_COMMENT;
    repeat (6) {
        if ((text.loadUint(8) | 32) != expected.loadUint(8)) {
            return false;
        }
    }
    return true;
}

// Ссылка оставляет transfer с двумя адресами в пределах одной body cell.
fun Cell<TextComment>.forwardPayload(self): slice {
    return beginCell().storeBool(true).storeRef(self).toSlice();
}
