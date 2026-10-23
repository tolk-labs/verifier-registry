// SPDX-License-Identifier: BUSL-1.1
import "../onramp/messages.tolk";

const CCIPSendExecutor_FACILITY_NAME = "link.chain.ton.ccip.CCIPSendExecutor";
const CCIPSendExecutor_FACILITY_ID = 178;  // (crc32(<facility>) % 640) + 10

type CCIPSendExecutor_ID = uint224

struct CCIPSendExecutor_InitialData {
    onramp: address,
    id: CCIPSendExecutor_ID,
}

struct CCIPSendExecutor_Data {
    id: CCIPSendExecutor_ID,
    onrampSend: OnRamp_Send,
    addresses: Cell<CCIPSendExecutor_Addresses>,
    state: CCIPSendExecutor_State,
}

struct CCIPSendExecutor_Addresses {
    onramp: address,
    feeQuoter: address,
}

type CCIPSendExecutor_State =
    | Cell<CCIPSendExecutor_State_Initialized>
    | Cell<CCIPSendExecutor_State_OnGoingFeeValidation>
    | Cell<CCIPSendExecutor_State_Finalized>

struct CCIPSendExecutor_State_Initialized {
}

struct CCIPSendExecutor_State_OnGoingFeeValidation {
}

struct CCIPSendExecutor_State_Finalized {
}

struct CCIPSendExecutor_Config {
    feeQuoter: address,
}


