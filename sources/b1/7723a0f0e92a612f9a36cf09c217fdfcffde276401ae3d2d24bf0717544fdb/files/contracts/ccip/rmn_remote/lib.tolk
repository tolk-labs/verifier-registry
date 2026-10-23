// SPDX-License-Identifier: BUSL-1.1

const RMNREMOTE_GLOBAL_CURSE_SUBJECT =  0x01000000000000000000000000000001

struct CursedSubjects {
    data: map<uint128, ()>;
}

fun CursedSubjects.curse(mutate self, subject: uint128) {
    self.data.addIfNotExists(subject, ());
}
fun CursedSubjects.uncurse(mutate self, subject: uint128) {
    self.data.delete(subject);
}
fun CursedSubjects.isCursed(self, subject: uint128) {
    // fastpath, majority of the time there's no curse
    if (self.data.isEmpty()) { return false; }
    val isGlobalCursed = self.data.exists(RMNREMOTE_GLOBAL_CURSE_SUBJECT);
    if (isGlobalCursed) {
        return true;
    }
    return self.data.exists(subject);
}

