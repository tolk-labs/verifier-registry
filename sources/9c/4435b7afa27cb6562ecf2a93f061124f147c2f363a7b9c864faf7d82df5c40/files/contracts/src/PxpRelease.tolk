import "@stdlib/gas-payments"
import "@gen/PxpBurnVault.code"
import "@gen/ReleaseJettonWallet.code"
import "messages"
import "release-fees"
import "release-network"
import "release-types"
import "release-wallet-utils"
import "storage"

contract PxpRelease {
    author: "PenaltyXP"
    version: "2.0.0"
    description: "Fixed-cap issuance with one-time delayed snapshot registration"
    storage: ReleaseStorage
    incomingMessages: ReleaseMessage
}

type ReleaseMessage =
    | PushAllocation
    | RegisterSnapshot
    | MintBurnReserve
    | MintReceipt
    | BurnNotificationForMinter
    | RepeatBurnReceipt
    | RequestWalletAddress
    | ReturnExcessesBack
    | TopUpGrams

fun burnVaultAddress(releaseAt: int): address {
    val data: BurnVaultStorage = { minterAddress: contract.getAddress(), releaseAt };
    return AutoDeployAddress {
        workchain: 0,
        stateInit: { code: pxpBurnVaultCompiledCode(), data: data.toCell() },
    }.calculateAddress();
}

fun verifyAllocation(c: ReleaseConfig, msg: PushAllocation) {
    assert (c.recipientCount > 0 && c.recipientCount <= 1000000 && c.proofDepth <= 20) throw 906;
    assert (
        msg.index < c.recipientCount && msg.amount > 0 && msg.amount <= PXP_USERS &&
        msg.recipient.getWorkchain() == 0
    ) throw 907;
    var h = AllocationLeaf {
        snapshotHash: c.snapshotHash,
        index: msg.index,
        recipient: msg.recipient,
        amount: msg.amount as uint120,
    }
    .toCell()
    .hash();
    var sum = msg.amount;
    var path = msg.index;
    var step = msg.proof;
    repeat (c.proofDepth) {
        assert (step != null) throw 908;
        val p = step.load();
        val branch = (path & 1) == 0
            ? AllocationBranch {
                leftHash: h,
                leftSum: sum as uint120,
                rightHash: p.siblingHash,
                rightSum: p.siblingSum,
            }
            : AllocationBranch {
                leftHash: p.siblingHash,
                leftSum: p.siblingSum,
                rightHash: h,
                rightSum: sum as uint120,
            };
        h = branch.toCell().hash();
        sum += p.siblingSum;
        assert (sum <= PXP_USERS) throw 908;
        path >>= 1;
        step = p.next;
    }
    assert (step == null && path == 0 && h == c.rootHash && sum == PXP_USERS) throw 908;
}

fun wasSettled(s: ReleaseStorage, index: int): bool {
    val r = s.settled.get(index >> 8);
    return r.isFound && (r.loadValue() & (1 << (index & 255))) != 0;
}

fun refundMintFunds(requester: address, incoming: coins, refund: coins) {
    // Preserve all previously owned TON except the temporary storage deposit being released.
    reserveGramsOnBalance(
        max(grams("0.05"), contract.getOriginalBalance() - incoming - refund),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    val outgoing0 = createMessage({ dest: requester, value: 0, bounce: BounceMode.NoBounce, body: TopUpGrams {} });
    // SAFETY: previous TON and required storage reserves are protected before sending the surplus.
    outgoing0.send(
        SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
    );
}

fun mintFixed(
    mutate s: ReleaseStorage,
    index: int,
    recipient: address,
    amount: int,
    requester: address,
    incoming: coins,
) {
    val old = s.payments.get(index);
    assert (!wasSettled(s, index) && !old.isFound) throw 909;
    assert (s.pendingCount < 1024) throw 914;
    assert (s.committed + amount <= PXP_TOTAL && s.nextAttempt < 4294967295) throw 910;
    val query = (s.nextAttempt << 32) | index;
    val deposit = calculateStorageFee(0, 5 * 365 * 86400, 2000, 8);
    s.nextAttempt += 1;
    s
        .payments
        .set(
            index,
            Payment {
                queryId: query,
                recipient,
                amount,
                state: 1,
                requester,
                storageDeposit: deposit,
            },
        );
    s.pendingCount += 1;
    s.committed += amount;
    s.totalSupply += amount;
    s.save();
    reserveGramsOnBalance(
        max(grams("0.05"), contract.getOriginalBalance() - incoming + deposit),
        RESERVE_MODE_EXACT_AMOUNT,
    );
    val outgoing1 = createMessage({
        dest: calcDeployedJettonWallet(
            recipient,
            contract.getAddress(),
            releaseJettonWalletCompiledCode(),
        ),
        value: releaseMintWalletBudget(),
        bounce: BounceMode.Only256BitsOfBody,
        body: InternalTransferStep {
            queryId: query,
            jettonAmount: amount,
            transferInitiator: null,
            sendExcessesTo: requester,
            forwardTonAmount: 0,
            forwardPayload: beginCell().storeUint(0, 1).toSlice(),
        },
    });
    outgoing1.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
    val outgoing2 = createMessage({ dest: requester, value: 0, bounce: BounceMode.NoBounce, body: ReturnExcessesBack {
            queryId: query,
        } });
    // SAFETY: previous TON and required storage reserves are protected before sending the surplus.
    outgoing2.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
    val msg = lazy InternalTransferStep.fromSlice(in.bouncedBody);
    var s = ReleaseStorage.load();
    val index = msg.queryId & 0xffffffff;
    val old = s.payments.get(index);
    assert (old.isFound) throw 902;
    val p = old.loadValue();
    assert (
        in.senderAddress ==
        calcAddressOfJettonWallet(
            p.recipient,
            contract.getAddress(),
            releaseJettonWalletCompiledCode(),
        )
    ) throw 902;
    if (p.state == 1 && p.queryId == msg.queryId && p.amount == msg.jettonAmount) {
        s.payments.delete(index);
        s.pendingCount -= 1;
        s.committed -= p.amount;
        s.totalSupply -= p.amount;
        s.save();
    }
}

fun onInternalMessage(in: InMessage) {
    requireMainnet();
    val msg = lazy ReleaseMessage.fromSlice(in.body);
    var s = lazy ReleaseStorage.load();
    val c = s.config.load();
    match (msg) {
        RegisterSnapshot => {
            assert (s.rootRegistrar != null && in.senderAddress == s.rootRegistrar) throw 915;
            assert (blockchain.now() >= c.releaseAt) throw 903;
            assert (c.rootHash == 0 && c.snapshotHash == 0 && c.recipientCount == 0 && c.proofDepth == 0) throw 916;
            assert (s.committed == 0 && s.totalSupply == 0 && s.confirmed == 0 && s.pendingCount == 0 && s.burned == 0 && s.payments.isEmpty() && s.settled.isEmpty()) throw 916;
            assert (msg.rootHash != 0 && msg.snapshotHash != 0 && msg.recipientCount > 0 && msg.recipientCount <= 1000000) throw 917;
            var leaves = 1;
            var depth = 0;
            while (leaves < msg.recipientCount) { leaves *= 2; depth += 1; }
            assert (msg.proofDepth == depth && depth <= 20) throw 917;
            s.config = ReleaseConfig {
                rootHash: msg.rootHash,
                snapshotHash: msg.snapshotHash,
                recipientCount: msg.recipientCount,
                proofDepth: msg.proofDepth,
                releaseAt: c.releaseAt,
                metadata: c.metadata,
            }.toCell();
            s.rootRegistrar = null;
            s.save();
        }
        PushAllocation => {
            assert (blockchain.now() >= c.releaseAt) throw 903;
            assert (in.valueCoins >= releaseMintExecutionBudget()) throw 901;
            verifyAllocation(c, msg);
            mintFixed(
                mutate s,
                msg.index,
                msg.recipient,
                msg.amount,
                in.senderAddress,
                in.valueCoins,
            );
        }
        MintBurnReserve => {
            assert (s.rootRegistrar == null && c.recipientCount > 0 && c.rootHash != 0) throw 916;
            assert (blockchain.now() >= c.releaseAt) throw 903;
            assert (in.valueCoins >= releaseMintExecutionBudget()) throw 901;
            mintFixed(
                mutate s,
                BURN_INDEX,
                burnVaultAddress(c.releaseAt),
                PXP_BURN,
                in.senderAddress,
                in.valueCoins,
            );
        }
        MintReceipt => {
            val index = msg.queryId & 0xffffffff;
            val old = s.payments.get(index);
            if (!old.isFound && wasSettled(s, index)) {
                return;
            }
            assert (old.isFound) throw 902;
            val p = old.loadValue();
            assert (
                in.senderAddress ==
                calcAddressOfJettonWallet(
                    p.recipient,
                    contract.getAddress(),
                    releaseJettonWalletCompiledCode(),
                )
            ) throw 902;
            if (p.queryId == msg.queryId && p.amount == msg.jettonAmount) {
                val chunk = s.settled.get(index >> 8);
                val mask: int = chunk.isFound ? chunk.loadValue() : 0;
                s.settled.set(index >> 8, mask | (1 << (index & 255)));
                s.payments.delete(index);
                s.pendingCount -= 1;
                s.confirmed += p.amount;
                if (index != BURN_INDEX) {
                    s.confirmedCount += 1;
                }
                s.save();
                // Keep a five-year bitmap reserve only when adding a new chunk;
                // refund temporary full-record storage reserve for subsequent bits.
                refundMintFunds(p.requester, in.valueCoins, chunk.isFound ? p.storageDeposit : 0);
            }
        }
        BurnNotificationForMinter => {
            assert (
                in.senderAddress ==
                calcAddressOfJettonWallet(
                    msg.burnInitiator,
                    contract.getAddress(),
                    releaseJettonWalletCompiledCode(),
                )
            ) throw 902;
            assert (msg.jettonAmount > 0 && msg.jettonAmount <= s.totalSupply) throw 910;
            if (msg.burnInitiator == burnVaultAddress(c.releaseAt)) {
                val last = s.lastBurn;
                assert (last == null || msg.queryId > last.load().queryId) throw 911;
                assert (blockchain.now() >= c.releaseAt + PXP_PERIOD) throw 903;
                val due = completedBurnStages(c.releaseAt) * PXP_BURN_STEP;
                assert (s.burned + msg.jettonAmount <= due) throw 912;
                s.burned += msg.jettonAmount;
                s.lastBurn = BurnReceipt {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                }.toCell();
            }
            s.totalSupply -= msg.jettonAmount;
            s.save();
            if (msg.burnInitiator == burnVaultAddress(c.releaseAt)) {
                val outgoing3 = createMessage({ dest: msg.burnInitiator, value: releaseReceiptValue(), bounce: BounceMode.NoBounce, body: s.lastBurn! });
                outgoing3.send(
                    SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
                );
            } else if (msg.sendExcessesTo != null) {
                val outgoing4 = createMessage({ dest: msg.sendExcessesTo, value: 0, bounce: BounceMode.NoBounce, body: ReturnExcessesBack {
                        queryId: msg.queryId,
                    } });
                outgoing4.send(
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                );
            }
        }
        RepeatBurnReceipt => {
            assert (in.valueCoins >= releaseReceiptRequestBudget() && s.lastBurn != null) throw 901;
            val outgoing5 = createMessage({ dest: burnVaultAddress(
                    c.releaseAt,
                ), value: releaseReceiptValue(), bounce: BounceMode.NoBounce, body: s.lastBurn });
            outgoing5.send(
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }
        RequestWalletAddress => {
            val a: address? = msg.ownerAddress.getWorkchain() == 0
                ? calcAddressOfJettonWallet(
                    msg.ownerAddress,
                    contract.getAddress(),
                    releaseJettonWalletCompiledCode(),
                )
                : null;
            val outgoing6 = createMessage({ dest: in.senderAddress, value: 0, bounce: BounceMode.NoBounce, body: ResponseWalletAddress {
                    queryId: msg.queryId,
                    jettonWalletAddress: a,
                    ownerAddress: msg.includeOwnerAddress ? msg.ownerAddress.toCell() : null,
                } });
            outgoing6.send(
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }
        ReturnExcessesBack => {} // Standard refund messages never confirm a payment.
        TopUpGrams => {}
    }
}

get fun get_jetton_data(): JettonDataReply {
    val s = ReleaseStorage.load();
    return {
        totalSupply: s.totalSupply,
        mintable: s.confirmed < PXP_TOTAL,
        adminAddress: s.rootRegistrar,
        jettonContent: s.config.load().metadata as Cell<OnchainMetadataReply>,
        jettonWalletCode: releaseJettonWalletCompiledCode(),
    };
}

get fun get_wallet_address(ownerAddress: address): address {
    return calcAddressOfJettonWallet(
        ownerAddress,
        contract.getAddress(),
        releaseJettonWalletCompiledCode(),
    );
}

get fun get_release_status(): ReleaseStatus {
    val s = ReleaseStorage.load();
    val c = s.config.load();
    return {
        totalSupply: s.totalSupply,
        committed: s.committed,
        confirmed: s.confirmed,
        confirmedCount: s.confirmedCount,
        burned: s.burned,
        releaseAt: c.releaseAt,
        recipientCount: c.recipientCount,
        rootHash: c.rootHash,
        snapshotHash: c.snapshotHash,
        pendingCount: s.pendingCount,
    };
}

get fun get_release_config(): ReleaseConfig {
    return ReleaseStorage.load().config.load();
}

get fun get_payment(index: int): PaymentReply {
    assert (index >= 0 && index <= 4294967295) throw 907;
    val s = ReleaseStorage.load();
    if (wasSettled(s, index)) {
        return {
            found: true,
            queryId: 0,
            recipient: null,
            amount: 0,
            state: 2,
            requester: null,
        };
    }
    val r = s.payments.get(index);
    if (!r.isFound) {
        return {
            found: false,
            queryId: 0,
            recipient: null,
            amount: 0,
            state: 0,
            requester: null,
        };
    }
    val p = r.loadValue();
    return {
        found: true,
        queryId: p.queryId,
        recipient: p.recipient,
        amount: p.amount,
        state: 1,
        requester: p.requester,
    };
}

get fun get_burn_vault(): address {
    return burnVaultAddress(ReleaseStorage.load().config.load().releaseAt);
}

get fun get_payment_states(start: int, count: int): cell {
    assert (
        start >= 0 && start <= 4294967295 && count > 0 && count <= 128 &&
        start + count <= 4294967296
    ) throw 907;
    val s = ReleaseStorage.load();
    var b = beginCell();
    var i = start;
    repeat (count) {
        val p = s.payments.get(i);
        b.storeUint(wasSettled(s, i) ? 2 : p.isFound ? 1 : 0, 2);
        i += 1;
    }
    return b.endCell();
}

get fun get_network_id(): int {
    return releaseGlobalId();
}

get fun get_execution_budget(): coins {
    return releaseMintExecutionBudget();
}

get fun get_receipt_request_budget(): coins {
    return releaseReceiptRequestBudget();
}

get fun get_last_burn_receipt(): MintReceiptReply {
    val r = ReleaseStorage.load().lastBurn;
    if (r == null) {
        return {
            found: false,
            queryId: 0,
            amount: 0,
        };
    }
    val b = r.load();
    return {
        found: true,
        queryId: b.queryId,
        amount: b.jettonAmount,
    };
}
get fun get_chain_time(): int { return blockchain.now(); }

get fun get_root_registrar(): address? { return ReleaseStorage.load().rootRegistrar; }
