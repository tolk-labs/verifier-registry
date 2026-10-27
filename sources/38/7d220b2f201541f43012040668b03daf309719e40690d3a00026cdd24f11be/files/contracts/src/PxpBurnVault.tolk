import "@gen/ReleaseJettonWallet.code"
import "messages"
import "release-fees"
import "release-network"
import "release-types"
import "release-wallet-utils"

contract PxpBurnVault {
    author: "PenaltyXP"
    version: "1.0.0"
    storage: BurnVaultStorage
    incomingMessages: BurnVaultMessage
}

type BurnVaultMessage = TickBurn | BurnReceipt | BurnFailure | TopUpGrams

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
    val msg = lazy AskToBurn.fromSlice(in.bouncedBody);
    var s = BurnVaultStorage.load();
    val wallet = calcAddressOfJettonWallet(
        contract.getAddress(),
        s.minterAddress,
        releaseJettonWalletCompiledCode(),
    );
    assert (in.senderAddress == wallet) throw 902;
    if (s.pending != 0 && s.pendingQuery == msg.queryId && s.pending == msg.jettonAmount) {
        s.pending = 0;
        s.save();
    }
}

fun onInternalMessage(in: InMessage) {
    requireMainnet();
    val msg = lazy BurnVaultMessage.fromSlice(in.body);
    var s = BurnVaultStorage.load();
    match (msg) {
        TickBurn => {
            assert (in.valueCoins >= releaseBurnExecutionBudget()) throw 901;
            assert (blockchain.now() >= s.releaseAt + PXP_PERIOD) throw 903;
            assert (s.pending == 0) throw 904;
            val due = completedBurnStages(s.releaseAt) * PXP_BURN_STEP;
            assert (due > s.burned) throw 905;
            s.pending = due - s.burned;
            s.pendingQuery = s.nextQuery;
            s.nextQuery += 1;
            s.save();
            val wallet = calcAddressOfJettonWallet(
                contract.getAddress(),
                s.minterAddress,
                releaseJettonWalletCompiledCode(),
            );
            val outgoing0 = createMessage({ dest: wallet, value: releaseBurnWalletBudget(), bounce: BounceMode.Only256BitsOfBody, body: AskToBurn {
                    queryId: s.pendingQuery,
                    jettonAmount: s.pending,
                    sendExcessesTo: contract.getAddress(),
                    customPayload: null,
                } });
            outgoing0.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }
        BurnReceipt => {
            assert (in.senderAddress == s.minterAddress) throw 902;
            if (s.pending == 0 || msg.queryId != s.pendingQuery || msg.jettonAmount != s.pending) {
                return;
            }
            s.burned += s.pending;
            s.pending = 0;
            s.save();
        }
        BurnFailure => {
            val wallet = calcAddressOfJettonWallet(
                contract.getAddress(),
                s.minterAddress,
                releaseJettonWalletCompiledCode(),
            );
            assert (in.senderAddress == wallet) throw 902;
            if (s.pending != 0 && msg.queryId == s.pendingQuery && msg.jettonAmount == s.pending) {
                s.pending = 0;
                s.save();
            }
        }
        TopUpGrams => {}
    }
}

get fun get_burn_status(): BurnVaultStorage {
    return BurnVaultStorage.load();
}

get fun get_execution_budget(): coins {
    return releaseBurnExecutionBudget();
}
