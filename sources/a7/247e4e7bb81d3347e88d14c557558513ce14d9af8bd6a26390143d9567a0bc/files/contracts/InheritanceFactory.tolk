// InheritanceFactory — deploys per-inheritance vaults atomically (OWN-03).
//
// Phase 1 / Plan 02. Acton 1.0.0 dialect.
//
// Behavior:
//   - DeployVault (op 0x18af5f6e) — receives heir + heartbeat_period + initial_deadline
//     and `in.valueCoins` TON. Validates D-05 bounds + D-06 heir != owner invariant
//     on-chain (defence-in-depth — FE already validates). Deploys an
//     InheritanceVault stateInit and forwards the deposit in a SINGLE outgoing
//     message (SC-01 + OWN-03 atomicity). Emits VaultCreated external log.
//
// Architecture note: vault `code` is held in factory storage (FactoryStorage.vaultCode)
// because contract-source code cannot import `@acton/build` (E010 forbids
// host-only stdlib imports inside contracts). The factory deploy script
// (`scripts/deploy-factory.tolk`) loads the vault code cell via the host
// `build()` helper and supplies it as part of factory's initial storage. This
// is the canonical Acton 1.0.0 factory pattern.
//
// The factory is immutable: no admin opcode, no setCode mechanism. Migration
// strategy (v2) is to deploy a new factory; existing vaults continue to work
// under v1.

import "inheritance_types"

contract InheritanceFactory {
    author: "ton-inheritance"
    version: "1.0.0"
    description: "Factory contract that deploys per-inheritance vaults (Phase 1 / Plan 02)."
    storage: FactoryStorage
    incomingMessages: FactoryMessage
}

type FactoryMessage = DeployVault

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        // Plain TON deposits to the factory are dropped (no top-up flow).
        return;
    }

    val msg = lazy FactoryMessage.fromSlice(in.body);

    match (msg) {
        DeployVault => {
            // D-06: heir != owner anti-footgun (defence-in-depth on-chain).
            assert (msg.heir != in.senderAddress) throw Errors.HeirEqOwner;

            // D-05: bounds enforcement on-chain (raw factory-call defence).
            assert (
                msg.heartbeatPeriod >= HEARTBEAT_PERIOD_MIN
            ) throw Errors.HeartbeatPeriodOutOfBounds;
            assert (
                msg.heartbeatPeriod <= HEARTBEAT_PERIOD_MAX
            ) throw Errors.HeartbeatPeriodOutOfBounds;

            // Initial deadline must be at least one heartbeat-period from now.
            assert (
                msg.initialDeadline >= blockchain.now() + msg.heartbeatPeriod
            ) throw Errors.InitialDeadlineTooSoon;

            // Load factory storage (vault code is pinned in there at deploy time).
            var s = lazy FactoryStorage.load();

            // Calculate the deposit amount the vault will receive: `in.valueCoins`
            // minus gas reserved for the factory (this tx) and deploy-gas for
            // the outgoing factory→vault message. RESEARCH §Pitfall 8 +
            // OWN-03 atomicity: single outgoing message carries both the
            // stateInit (deploy) and the deposit.
            val deposit = in.valueCoins - GAS_RESERVE - DEPLOY_GAS_RESERVE;

            // Build the vault's initial storage cell.
            val vaultStorage: VaultStorage = {
                owner: in.senderAddress,
                heir: msg.heir,
                amount: deposit,
                deadline: msg.initialDeadline,
                heartbeatPeriod: msg.heartbeatPeriod,
                isActive: true,
            };

            // Build the vault state-init (code from factory storage + per-vault data).
            val vaultState = ContractState {
                code: s.vaultCode,
                data: vaultStorage.toCell(),
            };

            // The deterministic vault address (used in the VaultCreated event).
            val vaultAutoDeploy = AutoDeployAddress { stateInit: vaultState };
            val vaultAddress = vaultAutoDeploy.calculateAddress();

            // Deploy + initial deposit in a single outgoing message (SC-01 +
            // OWN-03). `AutoDeployAddress` makes the compiler compute the
            // vault address from the stateInit. Body is empty (Vault accepts
            // plain TON deposit as the initial transfer).
            val deployMsg = createMessage({
                bounce: BounceMode.NoBounce,
                value: deposit,
                dest: vaultAutoDeploy,
            });
            deployMsg.send(SEND_MODE_REGULAR);

            // Emit VaultCreated event (SC-09) — Plan 03 reconciler picks this up.
            val createdLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x9b1d3e72 },
                body: VaultCreated {
                    vault: vaultAddress,
                    owner: in.senderAddress,
                    heir: msg.heir,
                },
            });
            createdLog.send(SEND_MODE_REGULAR);

            // Increment deploy count.
            s.deployCount += 1;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // deploy counter is intentionally permissionless — anyone may
            // deploy a vault via the factory (05.1-TOOLCHAIN-MIGRATION.md
            // §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {}

get fun getDeployCount(): uint64 {
    val s = lazy FactoryStorage.load();
    return s.deployCount;
}

get fun owner(): address {
    val s = lazy FactoryStorage.load();
    return s.owner;
}
