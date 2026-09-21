// InheritanceFactory + InheritanceVault — shared types (Acton 1.0.0 dialect).
//
// Source of truth for:
//   - Storage struct (per-vault immutable state + factory storage holding vault code)
//   - Internal message op-codes (Heartbeat / Withdraw / Claim / DeployVault)
//   - External log opcodes (VaultCreated / HeartbeatReceived / Withdrawn / Claimed)
//   - Error codes
//   - Gas reserves and heartbeat-period bounds
//
// External-log opcodes (struct tags) are pinned at Plan 02 Task 1 — the Plan 03
// reconciler relies on these being stable for off-chain indexing.
// ---------------------------------------------------------------------------
// Storage (per-vault, immutable except is_active flag)
// ---------------------------------------------------------------------------

struct VaultStorage {
    owner: address
    heir: address
    amount: coins
    deadline: uint64
    heartbeatPeriod: uint64
    isActive: bool
}

fun VaultStorage.load(): VaultStorage {
    return VaultStorage.fromCell(contract.getData());
}

fun VaultStorage.save(self) {
    contract.setData(self.toCell());
}

// Factory storage — holds the per-vault `InheritanceVault` code cell (pinned at
// factory deploy time via the `build()` host-helper in `deploy-factory.tolk`),
// plus a deploy count for cheap inspection. Holding vaultCode in factory
// storage is necessary because the contract source cannot import `@acton/build`
// (E010) — only scripts/tests can. This is the canonical Acton 1.0.0 factory
// pattern: vault code is supplied as `data` at factory deploy time and read
// from storage on each DeployVault dispatch.
struct FactoryStorage {
    owner: address
    deployCount: uint64
    vaultCode: cell
}

fun FactoryStorage.load(): FactoryStorage {
    return FactoryStorage.fromCell(contract.getData());
}

fun FactoryStorage.save(self) {
    contract.setData(self.toCell());
}

// ---------------------------------------------------------------------------
// Error codes — all > 100 to avoid TVM builtins
// ---------------------------------------------------------------------------

enum Errors {
    NotOwner = 101
    NotHeir = 102
    DeadlineNotPassed = 103
    AlreadyInactive = 104
    DeadlinePassed = 105
    HeartbeatPeriodOutOfBounds = 106
    HeirEqOwner = 107
    InitialDeadlineTooSoon = 108
    InvalidMessage = 0xFFFF
}

// ---------------------------------------------------------------------------
// Constants (gas reserves and heartbeat-period bounds)
// ---------------------------------------------------------------------------

const GAS_RESERVE: coins = 50_000_000 // 0.05 TON
const DEPLOY_GAS_RESERVE: coins = 100_000_000 // 0.1 TON for factory→vault deploy

const HEARTBEAT_PERIOD_MIN: uint64 = 86_400 // 1 day  (D-05)
const HEARTBEAT_PERIOD_MAX: uint64 = 31_536_000 // 365 days

// WR-04 — Boundary semantics (документировано здесь и в
// packages/shared/src/heartbeat-bounds.ts):
//   - Heartbeat valid while  now <= deadline   (inclusive)
//   - Claim    valid while   now >  deadline   (strict)
// На now == deadline валиден только heartbeat; на now == deadline+1 —
// только claim. Окна перекрытия нет.

// ---------------------------------------------------------------------------
// Internal message op-codes (struct-tagged for Acton 1.0.0 dispatch)
// ---------------------------------------------------------------------------

struct (0xd53276db) Heartbeat {}

struct (0xb5de5f9e) Withdraw {}

struct (0x4dcbb5a8) Claim {}

struct (0x18af5f6e) DeployVault {
    heir: address
    heartbeatPeriod: uint64
    initialDeadline: uint64
}

// ---------------------------------------------------------------------------
// External log message bodies (Acton 1.0.0: struct-tagged so the off-chain
// reconciler in Plan 03 can demultiplex by opcode prefix).
//
// These opcodes are pinned at Plan 02 Task 1 and immutable thereafter.
// ---------------------------------------------------------------------------

struct (0x9b1d3e72) VaultCreated {
    vault: address
    owner: address
    heir: address
}

struct (0x6e2a1f04) HeartbeatReceived {
    vault: address
    ts: uint64
    newDeadline: uint64
}

// CR-02 fix (Phase 4 / Plan 01 — Variant C):
//
// `depositedAmount` carries VaultStorage.amount — the value recorded at
// deploy time as `in.valueCoins - GAS_RESERVE - DEPLOY_GAS_RESERVE`.
// This equals the ACTUAL payout only when the vault has not received any
// direct top-up TON after deploy.
//
// For MVP this is sufficient: InheritanceFactory is the sole canonical
// entry point and direct top-ups are not a supported flow.  The invariant
// is enforced off-chain: the FE create-wizard routes through the factory.
//
// Reconciler note: `factory_indexer.rs` uses VaultCreated.value_nano
// (from the deploy message) as the ground-truth deposit; the
// `depositedAmount` here is redundant but retained for audit transparency.
// Do NOT top-up a vault directly — the log will not reflect the extra TON.
//
// Opcodes 0x7d4f3c8a and 0x2c83b59e are pinned — do NOT change.
struct (0x7d4f3c8a) Withdrawn {
    vault: address
    owner: address
    depositedAmount: coins // CR-02 Variant C: deploy-time deposit, not current balance
}

struct (0x2c83b59e) Claimed {
    vault: address
    heir: address
    depositedAmount: coins // CR-02 Variant C: deploy-time deposit, not current balance
}
