// InheritanceJettonFactory + InheritanceJettonVault — shared types (Acton 1.0.0 dialect).
//
// Phase 2 / Plan 01. Parallel to inheritance_types.tolk — do NOT modify Phase 1 file.
//
// CRITICAL (SC-11): Phase 1 Heartbeat opcode 0xd53276db is identical to TEP-74 Excesses.
// JettonVault MUST use OPCODE_JETTON_HEARTBEAT (0xa8c52b77) — a distinct value — so that
// incoming Excesses messages from the jetton-wallet do not trigger heartbeat logic.
//
// Error codes start at 200 to avoid collision with Phase 1 (100-108).
// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

// JettonVaultExtra holds the jetton-specific data in a ref cell.
//
// T-02-01 (mainnet): expectedJettonWallet is no longer stored — instead
// we keep the jetton-wallet CODE next to the master address and compute
// expectedJettonWallet on every TransferNotification / Withdraw / Claim
// via `computeJettonWalletAddress(walletCode, master, vault.address)`.
// This kills the front-run vector that TOFU left open (attacker could
// race the legitimate first deposit and pin a fake wallet permanently).
//
// Циркулярная зависимость, которая в testnet'е заставила нас pin'ить
// addr_none, решается так: walletCode + master приходят в vault из
// factory.storage (factory deploy указывает их при изначальном setup),
// а вместе с vault.address (известна из contract.getAddress() в runtime
// и из stateInit-hash в FE) дают детерминированный expectedJettonWallet.
struct JettonVaultExtra {
    jettonMaster: address
    jettonWalletCode: cell
}

// TEP-74 §3.3 стандартная jetton-wallet storage. Используется только для
// вычисления адреса (`balance:0`-snapshot). Реальный wallet может хранить
// дополнительные поля — наш computeJettonWalletAddress воспроизводит то,
// что master'ы используют в get_wallet_address: для USDT-TON mainnet и
// нашего TestJettonMaster шаблон совпадает.
struct StandardJettonWalletData {
    balance: coins
    owner: address
    master: address
    walletCode: cell
}

// Computes the deterministic jetton-wallet address for `walletOwner` under
// `master` given the master's `walletCode`. Mirrors the stateInit hash
// produced by `master.get_wallet_address(walletOwner)`.
fun computeJettonWalletAddress(
    walletCode: cell,
    master: address,
    walletOwner: address,
): address {
    val data: StandardJettonWalletData = {
        balance: 0,
        owner: walletOwner,
        master,
        walletCode,
    };
    val state = ContractState {
        code: walletCode,
        data: data.toCell(),
    };
    return AutoDeployAddress { stateInit: state }.calculateAddress();
}

// JettonVaultStorage: 7 fields in main cell + JettonVaultExtra in ref.
// Main cell: 2 addr + coins + 2×uint64 + 2×bool ≈ 2×267 + 16 + 128 + 2 = 680 bits (fits 1023).
struct JettonVaultStorage {
    owner: address
    heir: address
    amount: coins        // jetton amount (6 decimals for USDT-TON)
    deadline: uint64
    heartbeatPeriod: uint64
    isActive: bool
    depositPending: bool // true until transfer_notification received (D-17)
    extra: cell          // JettonVaultExtra ref: expectedJettonWallet + jettonMaster
}

fun JettonVaultStorage.load(): JettonVaultStorage {
    return JettonVaultStorage.fromCell(contract.getData());
}

fun JettonVaultStorage.save(self) {
    contract.setData(self.toCell());
}

// Helpers to read/write JettonVaultExtra from/to the extra ref cell.
fun JettonVaultStorage.getExtra(self): JettonVaultExtra {
    return JettonVaultExtra.fromCell(self.extra);
}

// JettonFactoryStorage — vault deployment + T-02-01 pinning.
//
// jettonMaster + jettonWalletCode пинятся при deploy factory'и (одна
// фабрика обслуживает один jetton — для USDT-TON отдельная, для каждого
// другого jetton'а отдельная). Это даёт vault'у source-of-truth для
// strict sender check без необходимости передавать walletCode в
// DeployJettonVault payload каждый раз (и без зависимости от чужого
// master.get_jetton_data в runtime).
struct JettonFactoryStorage {
    owner: address
    deployCount: uint64
    vaultCode: cell
    jettonMaster: address
    jettonWalletCode: cell
}

fun JettonFactoryStorage.load(): JettonFactoryStorage {
    return JettonFactoryStorage.fromCell(contract.getData());
}

fun JettonFactoryStorage.save(self) {
    contract.setData(self.toCell());
}

// ---------------------------------------------------------------------------
// Error codes — start at 200 to avoid Phase 1 collision (100-108)
// ---------------------------------------------------------------------------

enum JettonErrors {
    FakeJettonSender = 200       // T-02-01: sender != expectedJettonWallet
    DepositAlreadyReceived = 201 // transfer_notification when depositPending=false
    RefundNotAllowed = 202       // T-02-03: refund called after vault is active
}

// ---------------------------------------------------------------------------
// TEP-74 inbound opcodes (RECEIVED by vault from jetton-wallet)
// ---------------------------------------------------------------------------

struct (0x7362d09c) TransferNotification {
    queryId: uint64
    amount: coins   // VarUInteger 16 — jetton amount
    sender: address // original sender (owner's wallet address)
}

// TEP-74 Excesses — MUST be handled as a no-op in JettonVault.
// This opcode (0xd53276db) collides with Phase 1 Heartbeat.
// In JettonVault the Heartbeat role is served by JettonHeartbeat (0xa8c52b77).
struct (0xd53276db) Excesses {}

// ---------------------------------------------------------------------------
// TEP-74 outbound opcode (SENT by vault to heir/owner's jetton-wallet on claim/withdraw)
// ---------------------------------------------------------------------------

// JettonTransfer body layout per TEP-74 §4.1 (op=0x0f8a7ea5):
//   query_id: uint64
//   amount: VarUInteger 16 (coins)
//   destination: MsgAddress        — final recipient
//   response_destination: MsgAddress — where to send excesses (gas)
//   custom_payload: Maybe ^Cell     — bit 0 = false (no payload)
//   forward_ton_amount: VarUInteger 16  — TON forwarded with transfer_notification
//   forward_payload: Either Cell ^Cell  — bit 0 = false (no payload)
struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    amount: coins
    destination: address
    responseDestination: address
    customPayload: bool
    forwardTonAmount: coins
    forwardPayload: bool
}

// ---------------------------------------------------------------------------
// Jetton vault action opcodes
// ---------------------------------------------------------------------------

// CRITICAL (SC-11): opcode MUST NOT be 0xd53276db (TEP-74 Excesses collision).
// Candidate 0xa8c52b77 verified: no TEP-62/74/64/85 collision (Task 0 pre-approved).
struct (0xa8c52b77) JettonHeartbeat {}

// D-17: refund opcode — owner calls while depositPending to recover a STUCK deposit.
//
// sweepAmount (added after the D-17 ordering-race UAT finding): the ACTUAL jetton
// balance currently sitting on the vault's own jetton-wallet, read off-chain by the
// owner/backend via the jetton-wallet's get_wallet_data. The vault cannot read its
// own jetton-wallet balance synchronously during compute, so the recovery amount
// MUST be supplied in the message body. The vault forwards exactly this amount as a
// real JettonTransfer to the owner before self-destructing. Owner-authenticated
// (in.senderAddress == s.owner) so a hostile sweepAmount cannot be injected by a
// third party; an owner over-stating sweepAmount only over-requests from their own
// jetton-wallet (the jetton-wallet caps at its real balance / bounces), so there is
// no theft vector and no risk to other vaults.
struct (0x1c4a3e9d) Refund {
    sweepAmount: coins
}

// Phase 1 opcodes reused (no TEP collision for these):
struct (0xb5de5f9e) Withdraw {}

struct (0x4dcbb5a8) Claim {}

// DeployJettonVault — factory handler payload (Phase 4 / mainnet T-02-01).
// Opcode bumped to 0x18af5f70: payload shrunk — jettonMaster and walletCode
// теперь пинятся в factory.storage и не передаются с каждым deploy'ем.
// Сменили op-код, чтобы старые FE/BE с прежним layout'ом не пытались
// взаимодействовать с новой фабрикой и не падали тихо в Cell underflow.
struct (0x18af5f70) DeployJettonVault {
    heir: address
    heartbeatPeriod: uint64
    initialDeadline: uint64
}

// ---------------------------------------------------------------------------
// External log events for reconciler (jetton variants — distinct from Phase 1)
// ---------------------------------------------------------------------------

// JettonVaultCreated — emitted by factory on successful vault deploy.
// IMPORTANT: backend reconciler `parse_jetton_vault_created_log` expects the
// payload to carry (vault, expectedJettonWallet, jettonMaster). The previous
// (vault, owner, heir) layout caused the reconciler to write the heir's
// address into the jetton_vaults.jetton_master column, breaking every
// subsequent jetton poll lookup. Owner is parsed by the reconciler from
// in_msg.source; heir from the DeployJettonVault in-msg body — neither
// needs to be in this ext log.
struct (0x4b8d2e91) JettonVaultCreated {
    vault: address
    expectedJettonWallet: address
    jettonMaster: address
}

// JettonRefunded — emitted by vault on Refund (D-17). Without this event the
// jetton_vault_poller cannot tell a destroyed vault apart from any random
// transaction, so the DB stays stuck on deposit_pending=true forever even
// though the contract is gone on-chain.
struct (0x9ad47e16) JettonRefunded {
    vault: address
    owner: address
}

struct (0x5c9f3a02) JettonDepositReceived {
    vault: address
    amount: coins
    ts: uint64
}

struct (0x6da14b13) JettonHeartbeatReceived {
    vault: address
    ts: uint64
    newDeadline: uint64
}

// CR-02 fix (Phase 4 / Plan 01 — Variant C, same as TON vault):
//
// `depositedAmount` carries JettonVaultStorage.amount — the jetton amount
// stored when TransferNotification was first received (activation event).
// This equals the ACTUAL payout only when the vault has not received any
// direct jetton top-up after activation.
//
// For MVP this is sufficient: InheritanceJettonFactory is the sole canonical
// entry point; direct jetton top-ups are not a supported flow; the strict
// FakeJettonSender check (T-02-01) prevents deposits from unexpected senders.
//
// Reconciler note: `factory_indexer.rs` uses JettonDepositReceived.amount
// (from the activation event) as the ground-truth deposit; the
// `depositedAmount` here is redundant but retained for audit transparency.
// Do NOT top-up a jetton vault directly — the log will not reflect the extra
// jettons.
//
// Opcodes 0x7eb25c24 and 0x8fc36d35 are pinned — do NOT change.
struct (0x7eb25c24) JettonWithdrawn {
    vault: address
    owner: address
    depositedAmount: coins // CR-02 Variant C: activation-time jetton amount, not current balance
}

struct (0x8fc36d35) JettonClaimed {
    vault: address
    heir: address
    depositedAmount: coins // CR-02 Variant C: activation-time jetton amount, not current balance
}

// ---------------------------------------------------------------------------
// Shared constants (inherit values from Phase 1 where applicable)
// ---------------------------------------------------------------------------

const GAS_RESERVE: coins = 50_000_000 // 0.05 TON
const DEPLOY_GAS_RESERVE: coins = 100_000_000 // 0.1 TON for factory→vault deploy

const HEARTBEAT_PERIOD_MIN: uint64 = 86_400 // 1 day  (D-05)
const HEARTBEAT_PERIOD_MAX: uint64 = 31_536_000 // 365 days
