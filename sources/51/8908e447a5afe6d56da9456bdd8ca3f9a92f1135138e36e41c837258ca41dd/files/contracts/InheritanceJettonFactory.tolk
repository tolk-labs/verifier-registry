// InheritanceJettonFactory — deploys per-inheritance jetton vaults (Phase 2 / Plan 01).
//
// Acton 1.0.0 dialect.
//
// Behavior:
//   - DeployJettonVault (op 0x18af5f6f) — receives heir, heartbeatPeriod, initialDeadline,
//     expectedJettonWallet (pre-computed by FE), jettonMaster. Validates D-05 bounds +
//     D-06 heir != owner invariant on-chain. Deploys an InheritanceJettonVault stateInit
//     with depositPending=true, isActive=false. Emits JettonVaultCreated external log.
//
// D-16: Parallel factory — does NOT extend Phase 1 InheritanceFactory. Separate audit surface.
// D-17: Vault starts in depositPending=true state. Owner must send jetton transfer to activate.
//
// Factory pattern: vaultCode is stored in JettonFactoryStorage at deploy time (same as Phase 1).
// Contracts cannot import @acton/build (E010) — only deploy scripts can.

import "jetton_types"

contract InheritanceJettonFactory {
    author: "ton-inheritance"
    version: "1.0.0"
    description: "Factory contract that deploys per-inheritance jetton vaults (Phase 2 / Plan 01)."
    storage: JettonFactoryStorage
    incomingMessages: JettonFactoryMessage
}

type JettonFactoryMessage = DeployJettonVault

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        // Plain TON deposits to the factory are dropped.
        return;
    }

    val msg = lazy JettonFactoryMessage.fromSlice(in.body);

    match (msg) {
        DeployJettonVault => {
            // D-06: heir != owner anti-footgun (defence-in-depth on-chain).
            assert (
                msg.heir != in.senderAddress
            ) throw JettonErrors.FakeJettonSender;                                     // HeirEqOwner semantics

            // D-05: bounds enforcement on-chain.
            assert (
                msg.heartbeatPeriod >= HEARTBEAT_PERIOD_MIN
            ) throw JettonErrors.DepositAlreadyReceived;                                                    // HeartbeatPeriodOutOfBounds
            assert (
                msg.heartbeatPeriod <= HEARTBEAT_PERIOD_MAX
            ) throw JettonErrors.DepositAlreadyReceived;

            // Initial deadline must be at least one heartbeat-period from now.
            assert (
                msg.initialDeadline >= blockchain.now() + msg.heartbeatPeriod
            ) throw JettonErrors.RefundNotAllowed;                                                                      // InitialDeadlineTooSoon

            // Load factory storage (vault code + jetton master + wallet code
            // были запиннены при deploy factory'и). T-02-01: walletCode даёт
            // vault'у возможность compute'ить expectedJettonWallet inline
            // вместо TOFU.
            var s = lazy JettonFactoryStorage.load();

            // Build the vault's initial storage cell.
            // D-17: depositPending=true, isActive=false — vault activates only on TransferNotification.
            val vaultExtra: JettonVaultExtra = {
                jettonMaster: s.jettonMaster,
                jettonWalletCode: s.jettonWalletCode,
            };
            val vaultStorage: JettonVaultStorage = {
                owner: in.senderAddress,
                heir: msg.heir,
                amount: 0,
                deadline: msg.initialDeadline,
                heartbeatPeriod: msg.heartbeatPeriod,
                isActive: false,
                depositPending: true,
                extra: vaultExtra.toCell(),
            };

            // Build the vault state-init (code from factory storage + per-vault data).
            val vaultState = ContractState {
                code: s.vaultCode,
                data: vaultStorage.toCell(),
            };

            // The deterministic vault address (used in the JettonVaultCreated event).
            val vaultAutoDeploy = AutoDeployAddress { stateInit: vaultState };
            val vaultAddress = vaultAutoDeploy.calculateAddress();

            // T-02-01: пред-вычисляем expectedJettonWallet, чтобы emit'ить
            // его в JettonVaultCreated — backend reconciler пишет это поле
            // в jetton_vaults.expected_jetton_wallet и использует для
            // отображения в UI/боте.
            val expectedJettonWallet = computeJettonWalletAddress(
                s.jettonWalletCode,
                s.jettonMaster,
                vaultAddress,
            );

            // Deploy vault with gas reserve (body empty — vault does not expect initial TON deposit).
            val deployMsg = createMessage({
                bounce: BounceMode.NoBounce,
                value: DEPLOY_GAS_RESERVE,
                dest: vaultAutoDeploy,
            });
            deployMsg.send(SEND_MODE_REGULAR);

            // Emit JettonVaultCreated event for reconciler.
            // Layout: (vault, expectedJettonWallet, jettonMaster).
            val createdLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x4b8d2e91 },
                body: JettonVaultCreated {
                    vault: vaultAddress,
                    expectedJettonWallet,
                    jettonMaster: s.jettonMaster,
                },
            });
            createdLog.send(SEND_MODE_REGULAR);

            // Increment deploy count.
            s.deployCount += 1;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // deploy counter is intentionally permissionless — anyone may
            // deploy a jetton vault via the factory
            // (05.1-TOOLCHAIN-MIGRATION.md §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {}

get fun getDeployCount(): uint64 {
    val s = lazy JettonFactoryStorage.load();
    return s.deployCount;
}

get fun owner(): address {
    val s = lazy JettonFactoryStorage.load();
    return s.owner;
}

// FE pre-computes the vault's jetton-wallet address BEFORE sending the
// atomic deploy+transfer TonConnect tx (so the JettonTransfer can name
// the right destination wallet). The pre-computation must reproduce
// EXACTLY what the DeployJettonVault branch does on-chain; otherwise the
// user's TUSDT lands at the factory's jetton-wallet (or any other wrong
// address) and the vault stays deposit_pending forever.
//
// Expose the calculation as a get-method so the FE has a single source of
// truth and cannot drift. Inputs mirror DeployJettonVault payload + the
// owner address (which is in_msg.source at deploy time).
// T-02-01: jettonMaster + jettonWalletCode больше не приходят аргументами
// — фабрика пинит их в своём storage. FE передаёт только пользовательские
// параметры (sender/heir/period/deadline) и получает детерминированный
// адрес vault'а, который будет задеплоен.
get fun predictedVaultAddress(
    sender: address,
    heir: address,
    heartbeatPeriod: uint64,
    initialDeadline: uint64,
): address {
    val s = lazy JettonFactoryStorage.load();

    val vaultExtra: JettonVaultExtra = {
        jettonMaster: s.jettonMaster,
        jettonWalletCode: s.jettonWalletCode,
    };
    val vaultStorage: JettonVaultStorage = {
        owner: sender,
        heir,
        amount: 0,
        deadline: initialDeadline,
        heartbeatPeriod,
        isActive: false,
        depositPending: true,
        extra: vaultExtra.toCell(),
    };
    val vaultState = ContractState {
        code: s.vaultCode,
        data: vaultStorage.toCell(),
    };
    return AutoDeployAddress { stateInit: vaultState }.calculateAddress();
}

// Get-methods to expose the pinned jetton master + wallet code so the FE
// can show «which jetton does this factory serve» without an extra round
// trip to a config endpoint.
get fun jettonMaster(): address {
    val s = lazy JettonFactoryStorage.load();
    return s.jettonMaster;
}

get fun jettonWalletCode(): cell {
    val s = lazy JettonFactoryStorage.load();
    return s.jettonWalletCode;
}
