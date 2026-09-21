// InheritanceVault — per-inheritance immutable vault contract.
//
// Phase 1 / Plan 02. Acton 1.0.0 dialect.
//
// Behavior:
//   - Heartbeat   (op 0xd53276db) — owner-only; resets `deadline = now + heartbeat_period`
//   - Withdraw    (op 0xb5de5f9e) — owner-only, while is_active; sends all to owner, destroys vault
//   - Claim       (op 0x4dcbb5a8) — heir-only, only if now > deadline and is_active; sends all to heir, destroys vault
//   - Plain TON deposit (empty body) — accepted (factory's initial deposit)
//
// SC-10 CEI: `is_active = false; s.save()` are executed BEFORE any
// `createMessage().send()` for Withdraw/Claim. Double-withdraw fails with
// `Errors.AlreadyInactive`.
//
// SC-09 events: external log messages VaultCreated (emitted by factory),
// HeartbeatReceived, Withdrawn, Claimed (all defined in inheritance_types.tolk).

import "inheritance_types"

contract InheritanceVault {
    author: "ton-inheritance"
    version: "1.0.0"
    description: "Per-inheritance immutable vault contract (Phase 1 / Plan 02)."
    storage: VaultStorage
    incomingMessages: VaultMessage
}

type VaultMessage =
    | Heartbeat
    | Withdraw
    | Claim

fun onInternalMessage(in: InMessage) {
    // Accept plain TON deposits (empty body) from the factory's initial deposit
    // or from anyone else. We don't enforce sender on plain deposits — the
    // factory's atomic deploy+forward is the only canonical entry point.
    if (in.body.isEmpty()) {
        return;
    }

    val msg = lazy VaultMessage.fromSlice(in.body);

    match (msg) {
        Heartbeat => {
            var s = lazy VaultStorage.load();
            assert (in.senderAddress == s.owner) throw Errors.NotOwner;
            assert (s.isActive) throw Errors.AlreadyInactive;
            assert (blockchain.now() <= s.deadline) throw Errors.DeadlinePassed;

            // Effects first (CEI).
            s.deadline = blockchain.now() + s.heartbeatPeriod;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // branch is guarded above by `in.senderAddress == s.owner`
            // (05.1-TOOLCHAIN-MIGRATION.md §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();

            // Interactions: emit external log so the off-chain reconciler can
            // pick up the new deadline (Plan 03 SC-05).
            val heartbeatLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x6e2a1f04 },
                body: HeartbeatReceived {
                    vault: contract.getAddress(),
                    ts: blockchain.now(),
                    newDeadline: s.deadline,
                },
            });
            heartbeatLog.send(SEND_MODE_REGULAR);
        }
        Withdraw => {
            var s = lazy VaultStorage.load();
            assert (in.senderAddress == s.owner) throw Errors.NotOwner;
            assert (s.isActive) throw Errors.AlreadyInactive;

            // Effects first (SC-10 CEI gate — `is_active = false` BEFORE send).
            s.isActive = false;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // branch is guarded above by `in.senderAddress == s.owner`
            // (05.1-TOOLCHAIN-MIGRATION.md §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();

            // Emit Withdrawn event for off-chain reconciler.
            // CR-02 (Phase 4 / Plan 01 — Variant C): `depositedAmount` carries
            // VaultStorage.amount (the deploy-time deposit), not the live balance.
            // The actual payout uses SEND_MODE_CARRY_ALL_BALANCE (correct).
            // See inheritance_types.tolk Withdrawn struct for full rationale.
            val withdrawnLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x7d4f3c8a },
                body: Withdrawn {
                    vault: contract.getAddress(),
                    owner: s.owner,
                    depositedAmount: s.amount,
                },
            });
            withdrawnLog.send(SEND_MODE_REGULAR);

            // Interactions: send all balance to owner and destroy contract.
            val payoutMsg = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: s.owner,
            });
            // SAFETY (WR-03 clarified): TVM выполняет один in-msg
            // атомарно — между `s.save()` и `payoutMsg.send(... DESTROY)`
            // никакое новое сообщение в контракт прийти не может, поэтому
            // re-entrancy внутри одного in-msg здесь невозможен.
            // `assert (s.isActive)` выше — это defence-in-depth для
            // последовательных top-level Withdraw'ов: после первого
            // успешного send'а контракт уничтожается (DESTROY), повторный
            // Withdraw попадёт в `nonexist`-аккаунт и физически не
            // выполнится; assert защищает edge-case'ы вроде undeploy/
            // re-deploy в одной партии транзакций.
            payoutMsg.send(SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY);
        }
        Claim => {
            var s = lazy VaultStorage.load();
            assert (in.senderAddress == s.heir) throw Errors.NotHeir;
            assert (s.isActive) throw Errors.AlreadyInactive;
            assert (blockchain.now() > s.deadline) throw Errors.DeadlineNotPassed;

            // Effects first (SC-10 CEI gate).
            s.isActive = false;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // branch is guarded above by `in.senderAddress == s.heir`
            // (05.1-TOOLCHAIN-MIGRATION.md §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();

            // Emit Claimed event for off-chain reconciler.
            // CR-02 (Phase 4 / Plan 01 — Variant C): `depositedAmount` carries
            // VaultStorage.amount (the deploy-time deposit), not the live balance.
            // The actual payout uses SEND_MODE_CARRY_ALL_BALANCE (correct).
            // See inheritance_types.tolk Claimed struct for full rationale.
            val claimedLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x2c83b59e },
                body: Claimed {
                    vault: contract.getAddress(),
                    heir: s.heir,
                    depositedAmount: s.amount,
                },
            });
            claimedLog.send(SEND_MODE_REGULAR);

            // Interactions: send all balance to heir and destroy contract.
            val claimMsg = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: s.heir,
            });
            // SAFETY (WR-03 clarified): см. комментарий в Withdraw-ветке —
            // re-entrancy внутри одного in-msg на TVM невозможен; assert
            // isActive выше — defence-in-depth для последовательных
            // top-level Claim'ов между разными tx, не для внутри-tx гонки.
            claimMsg.send(SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY);
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {
    // Bounces are silently ignored. SC-10 ensures the vault has already
    // marked itself inactive before any outgoing tx, so a bounce can't
    // re-activate funds.
}

get fun getVaultData(): VaultStorage {
    val s = lazy VaultStorage.load();
    return s;
}

get fun owner(): address {
    val s = lazy VaultStorage.load();
    return s.owner;
}

get fun heir(): address {
    val s = lazy VaultStorage.load();
    return s.heir;
}

get fun isActive(): bool {
    val s = lazy VaultStorage.load();
    return s.isActive;
}
