// SPDX-License-Identifier: MIT
const RECEIVER_FACILITY_NAME = "link.chain.ton.ccip.lib.Receiver";
const RECEIVER_FACILITY_ID = 54; // (crc32(<facility>) % 640) + 10
const RECEIVER_ERROR_CODE = RECEIVER_FACILITY_ID * 100;

enum Receiver_Error {
    Unauthorized = 5400 //FACILITY_ID * 100,
    LowValue,
}
