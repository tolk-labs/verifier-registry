// TEP-74 jetton messages + jetton-specific view structs.
// Kept separate from PaymentMessages.tact so TON-only compilation units don't pull them in.

message(0xf8a7ea5) TokenTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    response_destination: Address;
    custom_payload: Cell?;
    forward_ton_amount: Int as coins;
    forward_payload: Cell?;
}

message(0x7362d09c) JettonTransferNotification {
    queryId: Int as uint64 = 0;
    amount: Int as coins;
    sender: Address;
    // TEP-74: forward_payload:(Either Cell ^Cell). Taken as a raw slice so the envelope
    // always parses; the Either bit is decoded manually INSIDE the try/catch — a malformed
    // or inline payload must end in a refund, not in an unparseable-message abort.
    forwardPayload: Slice as remaining;
}

message(0xd53276db) Excess {
    queryId: Int as uint64;
}

struct JettonConfigResponse {
    owner: Address;
    mainCommissionWallet: Address;
    nftCollection: Address;
    platformCommissionBps: Int;
    minimalPlatformCommission: Int;
    jettonMaster: Address;
    jettonWallet: Address;
    paused: Bool;
}
