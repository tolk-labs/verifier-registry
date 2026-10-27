import "@stdlib/gas-payments"
import "errors"
import "messages"
import "release-fees"
import "release-types"
import "release-wallet-utils"
import "sharding"
import "storage"

contract ReleaseJettonWallet {
    author: "Acton User"
    version: "1.0.0"
    description: "Standard Jetton Wallet. TEP-74 and TEP-89 compliant"
    storage: ReleaseWalletStorage
    incomingMessages: AllowedMessageToWallet
}

type AllowedMessageToWallet =
    | AskToTransfer
    | AskToBurn
    | InternalTransferStep
    | TopUpGrams
    | RepeatMintReceipt
    | RepeatBurnFailure

type BounceOpToHandle = InternalTransferStep | BurnNotificationForMinter

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();

    val msg = lazy BounceOpToHandle.fromSlice(in.bouncedBody);
    var query = 0;
    var burned = false;
    var restoreAmount = 0;
    match (msg) {
        InternalTransferStep => {
            query = msg.queryId;
            restoreAmount = msg.jettonAmount;
        }
        BurnNotificationForMinter => {
            query = msg.queryId;
            burned = true;
            restoreAmount = msg.jettonAmount;
        }
    }
    var storage = lazy ReleaseWalletStorage.load();
    storage.jettonBalance += restoreAmount;
    if (burned) {
        storage.burnFailure = BurnFailure {
            queryId: query,
            jettonAmount: restoreAmount,
        }.toCell();
    }
    storage.save();
    if (burned) {
        reserveGramsOnBalance(calculateJettonWalletMinStorageFee(), RESERVE_MODE_AT_MOST);
        val outgoing0 = createMessage({ dest: storage.ownerAddress, value: 0, bounce: BounceMode.NoBounce, body: storage.burnFailure! });
        // SAFETY: wallet storage was reserved; only its fixed owner receives surplus TON.
        outgoing0.send(
            SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
        );
    }
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToWallet.fromSlice(in.body);

    match (msg) {
        InternalTransferStep => {
            var storage = lazy ReleaseWalletStorage.load();
            if (in.senderAddress != storage.minterAddress) {
                assert (
                    in.senderAddress ==
                    calcAddressOfJettonWallet(
                        msg.transferInitiator!,
                        storage.minterAddress,
                        contract.getCode(),
                    )
                ) throw Errors.NotValidWallet;
            }
            storage.jettonBalance += msg.jettonAmount;
            val releaseMint = in.senderAddress == storage.minterAddress &&
                msg.transferInitiator == null;
            if (releaseMint) {
                storage.mintReceipt = MintReceipt {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                }.toCell();
            }
            storage.save();
            if (releaseMint) {
                val outgoing1 = createMessage({ dest: storage.minterAddress, value: releaseReceiptValue(), bounce: BounceMode.NoBounce, body: storage.mintReceipt! });
                outgoing1.send(
                    SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
                );
            }

            if (msg.forwardTonAmount != 0) {
                val notifyOwnerMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: storage.ownerAddress,
                    value: msg.forwardTonAmount,
                    body: TransferNotificationForRecipient {
                        queryId: msg.queryId,
                        jettonAmount: msg.jettonAmount,
                        transferInitiator: msg.transferInitiator,
                        forwardPayload: msg.forwardPayload,
                    },
                });
                notifyOwnerMsg.send(
                    SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
                );
            }

            if (msg.sendExcessesTo != null) {
                val toLeaveOnBalance = contract.getOriginalBalance() - in.valueCoins +
                    contract.getStorageDuePayment();
                reserveGramsOnBalance(
                    max(toLeaveOnBalance, calculateJettonWalletMinStorageFee()),
                    RESERVE_MODE_AT_MOST,
                );

                val excessesMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.sendExcessesTo,
                    value: 0,
                    body: ReturnExcessesBack { queryId: msg.queryId },
                });
                // SAFETY: mode SEND_MODE_CARRY_ALL_BALANCE is used after reserveGramsOnBalance()
                excessesMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
            }
        }

        AskToTransfer => {
            msg.forwardPayload.checkIsCorrectTlbEither();
            assert (
                msg.transferRecipient.getWorkchain() == MY_WORKCHAIN
            ) throw Errors.WrongWorkchain;
            checkAmountIsEnoughToTransfer(
                in.valueCoins,
                msg.forwardTonAmount,
                in.originalForwardFee,
            );

            var storage = lazy ReleaseWalletStorage.load();
            assert (in.senderAddress == storage.ownerAddress) throw Errors.NotOwner;
            assert (storage.jettonBalance >= msg.jettonAmount) throw Errors.BalanceError;
            storage.jettonBalance -= msg.jettonAmount;
            storage.save();

            val deployMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: calcDeployedJettonWallet(
                    msg.transferRecipient,
                    storage.minterAddress,
                    contract.getCode(),
                ),
                value: 0,
                body: InternalTransferStep {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    transferInitiator: storage.ownerAddress,
                    sendExcessesTo: msg.sendExcessesTo,
                    forwardTonAmount: msg.forwardTonAmount,
                    forwardPayload: msg.forwardPayload,
                },
            });
            deployMsg.send(
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }

        AskToBurn => {
            checkAmountIsEnoughToBurn(in.valueCoins);

            var storage = lazy ReleaseWalletStorage.load();
            assert (in.senderAddress == storage.ownerAddress) throw Errors.NotOwner;
            assert (storage.jettonBalance >= msg.jettonAmount) throw Errors.BalanceError;
            storage.jettonBalance -= msg.jettonAmount;
            storage.save();

            val notifyMinterMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: storage.minterAddress,
                value: 0,
                body: BurnNotificationForMinter {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    burnInitiator: storage.ownerAddress,
                    sendExcessesTo: msg.sendExcessesTo,
                },
            });
            notifyMinterMsg.send(
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }

        RepeatMintReceipt => {
            val storage = ReleaseWalletStorage.load();
            assert (
                in.valueCoins >= releaseReceiptRequestBudget() && storage.mintReceipt != null
            ) throw 901;
            val outgoing2 = createMessage({ dest: storage.minterAddress, value: releaseReceiptValue(), bounce: BounceMode.NoBounce, body: storage.mintReceipt });
            outgoing2.send(
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }
        RepeatBurnFailure => {
            val storage = ReleaseWalletStorage.load();
            assert (
                in.valueCoins >= releaseReceiptRequestBudget() && storage.burnFailure != null
            ) throw 901;
            val outgoing3 = createMessage({ dest: storage.ownerAddress, value: releaseReceiptValue(), bounce: BounceMode.NoBounce, body: storage.burnFailure });
            outgoing3.send(
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }
        TopUpGrams => {
            // just accept grams
        }

        else => throw 0xFFFF,
    }
}

get fun get_wallet_data(): JettonWalletDataReply {
    val storage = lazy ReleaseWalletStorage.load();

    return {
        jettonBalance: storage.jettonBalance,
        ownerAddress: storage.ownerAddress,
        minterAddress: storage.minterAddress,
        jettonWalletCode: contract.getCode(),
    };
}

get fun get_mint_receipt(): MintReceiptReply {
    val p = ReleaseWalletStorage.load().mintReceipt;
    if (p == null) {
        return {
            found: false,
            queryId: 0,
            amount: 0,
        };
    }
    val r = p.load();
    return {
        found: true,
        queryId: r.queryId,
        amount: r.jettonAmount,
    };
}

get fun get_burn_failure(): MintReceiptReply {
    val r = ReleaseWalletStorage.load().burnFailure;
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
