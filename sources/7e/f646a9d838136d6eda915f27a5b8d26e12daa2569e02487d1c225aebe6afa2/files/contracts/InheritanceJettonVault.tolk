// InheritanceJettonVault — per-inheritance immutable USDT-TON jetton vault contract.
//
// Phase 2 / Plan 01. Acton 1.0.0 dialect.
//
// Behavior:
//   - TransferNotification (0x7362d09c) — TEP-74 inbound from vault's jetton-wallet.
//     Validates sender == expectedJettonWallet (fake-jetton mitigation, T-02-01).
//     Marks vault active: depositPending=false, isActive=true.
//   - Excesses (0xd53276db) — TEP-74; MUST be silently ignored (SC-11).
//     CRITICAL: 0xd53276db is Phase 1 Heartbeat opcode. In JettonVault this is a
//     no-op to avoid resetting the deadline on every jetton excess message.
//   - JettonHeartbeat (0xa8c52b77) — owner-only; resets deadline (SC-11).
//     Uses a distinct opcode different from 0xd53276db.
//   - Withdraw (0xb5de5f9e) — owner-only; sends JettonTransfer to owner's jetton-wallet, destroys vault.
//   - Claim (0x4dcbb5a8) — heir-only, only if now > deadline; sends JettonTransfer to heir, destroys vault.
//   - Refund (0x1c4a3e9d) — owner-only; only if depositPending=true; sweeps the vault's
//     ACTUAL jetton-wallet balance (sweepAmount from the message body) back to the owner
//     as a real JettonTransfer, returns leftover gas TON, and destroys the vault (D-17).
//
// SC-10 CEI: isActive=false; s.save() executed BEFORE any outgoing message for Withdraw/Claim/Refund.
//
// D-16: Separate from Phase 1 InheritanceVault — parallel contract pair for USDT.
// D-17: Refund mechanism protects against stuck deposits (the create+deposit ordering
//       race — a transfer_notification that reaches the vault before the factory's deploy
//       is dropped during compute_skipped, leaving jettons stranded on the vault's
//       jetton-wallet with depositPending=true. Refund recovers those stranded jettons.).

import "jetton_types"

contract InheritanceJettonVault {
    author: "ton-inheritance"
    version: "1.0.0"
    description: "Per-inheritance immutable jetton vault (Phase 2 / Plan 01)."
    storage: JettonVaultStorage
    incomingMessages: JettonVaultMessage
}

type JettonVaultMessage =
    | TransferNotification // 0x7362d09c — TEP-74 inbound from jetton-wallet
    | Excesses // 0xd53276db — TEP-74; MUST be silently ignored (SC-11)
    | JettonHeartbeat // 0xa8c52b77 — MUST NOT be 0xd53276db (SC-11)
    | Withdraw // 0xb5de5f9e — owner withdraw (sends JettonTransfer to owner)
    | Claim // 0x4dcbb5a8 — heir claim after deadline
    | Refund // 0x1c4a3e9d — D-17: owner sweeps stranded jettons if depositPending

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        // Plain TON deposits accepted (empty body).
        return;
    }

    val msg = lazy JettonVaultMessage.fromSlice(in.body);

    match (msg) {
        TransferNotification => {
            var s = lazy JettonVaultStorage.load();

            // T-02-01 (mainnet, FIRST check): strict sender check runs BEFORE any state
            // inspection — eliminates the state-oracle: a fake jetton-wallet can no longer
            // distinguish "depositPending=true" from "depositPending=false" by comparing
            // error codes (200 vs 201). expectedJettonWallet вычисляется детерминированно
            // из (walletCode, master, self), которые пинятся в storage фабрикой. TOFU
            // убран — больше нет окна для front-run'а fake-jetton'ом.
            val extra = s.getExtra();
            val expectedJettonWallet = computeJettonWalletAddress(
                extra.jettonWalletCode,
                extra.jettonMaster,
                contract.getAddress(),
            );
            assert (in.senderAddress == expectedJettonWallet) throw JettonErrors.FakeJettonSender;

            // Reject duplicate deposits (only reachable by the legitimate jetton-wallet).
            assert (s.depositPending) throw JettonErrors.DepositAlreadyReceived;

            // Effects first (CEI).
            s.amount = msg.amount;
            s.depositPending = false;
            s.isActive = true;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // branch is guarded above by `in.senderAddress ==
            // expectedJettonWallet` (05.1-TOOLCHAIN-MIGRATION.md §3,
            // false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();

            // Emit event for reconciler (BE-07).
            val depositLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x5c9f3a02 },
                body: JettonDepositReceived {
                    vault: contract.getAddress(),
                    amount: s.amount,
                    ts: blockchain.now(),
                },
            });
            depositLog.send(SEND_MODE_REGULAR);
        }

        Excesses => {
            // SC-11: TEP-74 excesses are silently accepted with no state mutation.
            // This is the critical separation point — if Heartbeat used 0xd53276db, every
            // jetton-wallet excess would reset the deadline. JettonHeartbeat uses 0xa8c52b77.
            return;
        }

        JettonHeartbeat => {
            var s = lazy JettonVaultStorage.load();
            assert (
                in.senderAddress == s.owner
            ) throw JettonErrors.FakeJettonSender;                                       // NotOwner semantics
            assert (
                s.isActive
            ) throw JettonErrors.DepositAlreadyReceived;                                 // AlreadyInactive semantics
            assert (
                blockchain.now() <= s.deadline
            ) throw JettonErrors.RefundNotAllowed;                                       // DeadlinePassed semantics

            // Effects first (CEI).
            s.deadline = blockchain.now() + s.heartbeatPeriod;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // branch is guarded above by `in.senderAddress == s.owner`
            // (05.1-TOOLCHAIN-MIGRATION.md §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();

            // Emit event for reconciler.
            val heartbeatLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x6da14b13 },
                body: JettonHeartbeatReceived {
                    vault: contract.getAddress(),
                    ts: blockchain.now(),
                    newDeadline: s.deadline,
                },
            });
            heartbeatLog.send(SEND_MODE_REGULAR);
        }

        Withdraw => {
            var s = lazy JettonVaultStorage.load();
            assert (
                in.senderAddress == s.owner
            ) throw JettonErrors.FakeJettonSender;                                    // NotOwner semantics
            assert (
                s.isActive
            ) throw JettonErrors.DepositAlreadyReceived;                              // AlreadyInactive semantics

            // Effects first (SC-10 CEI gate — isActive=false BEFORE any send).
            s.isActive = false;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // branch is guarded above by `in.senderAddress == s.owner`
            // (05.1-TOOLCHAIN-MIGRATION.md §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();

            // Emit Withdrawn event for reconciler.
            // CR-02 (Phase 4 / Plan 01 — Variant C): `depositedAmount` carries
            // JettonVaultStorage.amount (the activation-time jetton deposit), not
            // the current jetton-wallet balance. Actual transfer uses s.amount
            // in JettonTransfer body (correct). See jetton_types.tolk for rationale.
            val withdrawnLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x7eb25c24 },
                body: JettonWithdrawn {
                    vault: contract.getAddress(),
                    owner: s.owner,
                    depositedAmount: s.amount,
                },
            });
            withdrawnLog.send(SEND_MODE_REGULAR);

            // Send JettonTransfer to vault's own jetton-wallet. Computed
            // inline from pinned (walletCode, master, self) — see T-02-01.
            val wExtra = s.getExtra();
            val vaultJettonWallet = computeJettonWalletAddress(
                wExtra.jettonWalletCode,
                wExtra.jettonMaster,
                contract.getAddress(),
            );
            val jettonBody = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: vaultJettonWallet,
                body: JettonTransfer {
                    queryId: 0,
                    amount: s.amount,
                    destination: s.owner,
                    responseDestination: s.owner,
                    customPayload: false,
                    forwardTonAmount: 1,
                    forwardPayload: false,
                },
            });
            // SAFETY: SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY is safe here —
            // `s.isActive = false; s.save()` (SC-10 CEI) already ran above, so a
            // bounce or any later message cannot re-enter an active vault; the
            // vault self-destructs after forwarding its jettons to `s.owner`.
            jettonBody.send(SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY);
        }

        Claim => {
            var s = lazy JettonVaultStorage.load();
            assert (
                in.senderAddress == s.heir
            ) throw JettonErrors.FakeJettonSender;                                      // NotHeir semantics
            assert (
                s.isActive
            ) throw JettonErrors.DepositAlreadyReceived;                                // AlreadyInactive semantics
            assert (
                blockchain.now() > s.deadline
            ) throw JettonErrors.RefundNotAllowed;                                      // DeadlineNotReached semantics

            // Effects first (SC-10 CEI gate).
            s.isActive = false;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // branch is guarded above by `in.senderAddress == s.heir`
            // (05.1-TOOLCHAIN-MIGRATION.md §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();

            // Emit Claimed event for reconciler.
            // CR-02 (Phase 4 / Plan 01 — Variant C): `depositedAmount` carries
            // JettonVaultStorage.amount (the activation-time jetton deposit), not
            // the current jetton-wallet balance. Actual transfer uses s.amount
            // in JettonTransfer body (correct). See jetton_types.tolk for rationale.
            val claimedLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x8fc36d35 },
                body: JettonClaimed {
                    vault: contract.getAddress(),
                    heir: s.heir,
                    depositedAmount: s.amount,
                },
            });
            claimedLog.send(SEND_MODE_REGULAR);

            // Send JettonTransfer to vault's own jetton-wallet, routing USDT
            // to the heir. Computed inline (T-02-01).
            val cExtra = s.getExtra();
            val vaultJettonWallet = computeJettonWalletAddress(
                cExtra.jettonWalletCode,
                cExtra.jettonMaster,
                contract.getAddress(),
            );
            val jettonBody = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: vaultJettonWallet,
                body: JettonTransfer {
                    queryId: 0,
                    amount: s.amount,
                    destination: s.heir,
                    responseDestination: s.heir,
                    customPayload: false,
                    forwardTonAmount: 1,
                    forwardPayload: false,
                },
            });
            // SAFETY: SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY is safe here —
            // `s.isActive = false; s.save()` (SC-10 CEI) already ran above, so a
            // bounce or any later message cannot re-enter an active vault; the
            // vault self-destructs after forwarding its jettons to `s.heir`.
            jettonBody.send(SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY);
        }

        Refund => {
            var s = lazy JettonVaultStorage.load();
            // T-02-05: owner-only (use NotOwner semantics via JettonErrors code)
            assert (in.senderAddress == s.owner) throw JettonErrors.FakeJettonSender;
            // T-02-03: refund only while depositPending=true (vault not yet active).
            // Inverse polarity from TransferNotification check.
            assert (s.depositPending) throw JettonErrors.RefundNotAllowed;

            // Effects first (CEI).
            s.isActive = false;
            // D-06 (05.3): E013 pattern-matches only `*.adminAddress`; this
            // branch is guarded above by `in.senderAddress == s.owner`
            // (05.1-TOOLCHAIN-MIGRATION.md §3, false-positive class).
            // check-disable-next-line unauthorized-access
            s.save();

            // Emit JettonRefunded event so the reconciler can mark this vault
            // as `refunded` in the DB. Without this the vault is destroyed
            // on-chain (SEND_MODE_DESTROY below) but the poller can't tell
            // the destroyed state from "no new activity" and the row stays
            // stuck on deposit_pending=true forever.
            val refundedLog = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: 0x9ad47e16 },
                body: JettonRefunded {
                    vault: contract.getAddress(),
                    owner: s.owner,
                },
            });
            refundedLog.send(SEND_MODE_REGULAR);

            // D-17 ordering-race recovery: sweep the vault's ACTUAL stranded
            // jetton-wallet balance back to the owner as a real JettonTransfer,
            // then self-destruct (returning leftover gas TON too).
            //
            // Why an explicit sweepAmount from the message body: the deposit
            // that lost the create+deposit race was never credited, so
            // s.amount is 0 here — using it (as the old Refund effectively did
            // by sending only a plain TON message) would leave the real jettons
            // stranded on the vault's jetton-wallet forever. A contract cannot
            // read its own jetton-wallet balance synchronously during compute,
            // so the owner/backend reads it off-chain via get_wallet_data and
            // passes it in. Owner-authenticated above, so no third party can
            // inject a hostile amount; an owner over-stating it only over-asks
            // from their OWN jetton-wallet (which caps/bounces at its real
            // balance) — no theft vector, no impact on any other vault.
            val rExtra = s.getExtra();
            val vaultJettonWallet = computeJettonWalletAddress(
                rExtra.jettonWalletCode,
                rExtra.jettonMaster,
                contract.getAddress(),
            );
            val refundJettonBody = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: vaultJettonWallet,
                body: JettonTransfer {
                    queryId: 0,
                    amount: msg.sweepAmount,
                    destination: s.owner,
                    responseDestination: s.owner,
                    customPayload: false,
                    forwardTonAmount: 1,
                    forwardPayload: false,
                },
            });
            // SAFETY: SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY is safe here —
            // `s.isActive = false; s.save()` (SC-10 CEI) already ran above, and the
            // sender was already verified as `s.owner` above, so an over-stated
            // `msg.sweepAmount` can only over-ask from the owner's own jetton-wallet
            // (which caps at its real balance) before the vault self-destructs.
            // SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY: forwards the
            // swept jettons + all remaining gas TON to the owner, vault destroyed.
            refundJettonBody.send(SEND_MODE_CARRY_ALL_BALANCE + SEND_MODE_DESTROY);
        }
    }
}

fun onBouncedMessage(_in: InMessageBounced) {
    // Bounces silently ignored — SC-10 CEI ensures vault marked inactive before any send.
}

get fun getVaultData(): JettonVaultStorage {
    val s = lazy JettonVaultStorage.load();
    return s;
}

get fun owner(): address {
    val s = lazy JettonVaultStorage.load();
    return s.owner;
}

get fun heir(): address {
    val s = lazy JettonVaultStorage.load();
    return s.heir;
}

get fun isActive(): bool {
    val s = lazy JettonVaultStorage.load();
    return s.isActive;
}

get fun depositPending(): bool {
    val s = lazy JettonVaultStorage.load();
    return s.depositPending;
}

// T-02-01: computed inline from pinned (walletCode, master, self) — нет
// больше TOFU-поля в storage, поэтому get-method тоже считает на лету.
get fun expectedJettonWallet(): address {
    val s = lazy JettonVaultStorage.load();
    val e = s.getExtra();
    return computeJettonWalletAddress(e.jettonWalletCode, e.jettonMaster, contract.getAddress());
}

get fun jettonMaster(): address {
    val s = lazy JettonVaultStorage.load();
    return s.getExtra().jettonMaster;
}
