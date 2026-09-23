const MIN_KEEP: Int = 10_000_000;       // ~0.01 TON — minimum balance to keep after withdrawals
const DEFAULT_INCREMENT_GAS: Int = 5_000_000; // ~0.005 TON — gas for IncrementSuccessfulTx
const GAS_PER_JETTON_TRANSFER: Int = 50_000_000;  // 0.05 TON attached to each outgoing TokenTransfer
const JETTON_PROCESS_OVERHEAD: Int = 20_000_000;  // ~0.02 TON — compute + emit buffer for jetton payments
const TON_PROCESS_GAS_BUFFER: Int = 20_000_000;   // ~0.02 TON — fwd fees buffer for TON payments

// queryId map for outgoing TokenTransfer — the only field surviving bounce-body truncation,
// so JettonTransferFailed{queryId} identifies WHICH transfer failed:
// 0 = seller payout, 1 = platform commission, 2 = partner share, 3 = excess to buyer
const REFUND_QUERY_ID: Int = 4;  // refund of an invalid jetton payment
const SWEEP_QUERY_ID: Int = 5;   // WithdrawAllJettons sweep
