// SPDX-License-Identifier: BUSL-1.1

const ReceiveExecutor_FACILITY_NAME = "link.chain.ton.ccip.ReceiveExecutor";
const ReceiveExecutor_FACILITY_ID = 376;  // (crc32(<facility>) % 640) + 10

// State stores the general state machine indicating which phase we're in
enum ReceiveExecutor_MessageState {
    Untouched = 0
    Execute
    ExecuteFailed
    Success
}
