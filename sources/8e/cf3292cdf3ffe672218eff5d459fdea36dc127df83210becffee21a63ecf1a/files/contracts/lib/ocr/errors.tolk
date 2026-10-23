// SPDX-License-Identifier: BUSL-1.1
const MultiOCR3Base_FACILITY_ID = 545; // (crc32(<facility>) % 640) + 10
const MultiOCR3Base_ERROR_CODE = MultiOCR3Base_FACILITY_ID * 100

enum MultiOCR3Base_Error {
    BigFMustBePositive = MultiOCR3Base_ERROR_CODE;
    StaticConfigCannotBeChanged
    TooManySigners
    BigFTooHigh
    TooManyTransmitters
    NoTransmitters
    RepeatedSigners
    RepeatedTransmitters
    ConfigDigestMismatch
    UnauthorizedTransmitter
    WrongNumberOfSignatures
    UnauthorizedSigner
    NonUniqueSignatures
    InvalidSignature
    NonExistentOcrPluginType
    NoSigners
}
