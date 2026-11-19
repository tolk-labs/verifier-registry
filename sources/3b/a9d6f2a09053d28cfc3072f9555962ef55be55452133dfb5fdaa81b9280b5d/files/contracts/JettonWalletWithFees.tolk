// MIT License
//
// Copyright (c) 2026 TON Core
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import "@stdlib/gas-payments"
import "errors"
import "fee-rules"
import "fee-wallet-fees"
import "fee-wallet-messages"
import "fee-wallet-storage"
import "fee-wallet-utils"
import "messages"
import "sharding"
import "storage"

contract JettonWalletWithFees {
    version: "2.0"
    description: "Jetton wallet of a token with a burn and taxes: when its owner sends, it takes the token's burn and taxes off the amount and sends each on as a transfer of its own. TEP-74 and TEP-89 compliant"
    storage: FeeWalletStorage
    incomingMessages: AllowedMessageToFeeWallet
}

type AllowedMessageToFeeWallet =
    | AskToTransfer
    | AskToBurn
    | InternalTransferStep
    | MarkExcluded
    | TopUpGrams

type BounceOpToHandle = InternalTransferStep | BurnNotificationForMinter | AskToTransfer

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();

    val msg = lazy BounceOpToHandle.fromSlice(in.bouncedBody);
    val restoreAmount = match (msg) {
        InternalTransferStep => msg.jettonAmount,
        BurnNotificationForMinter => msg.jettonAmount,
        AskToTransfer => msg.jettonAmount,
    };

    var storage = lazy FeeWalletStorage.load();
    storage.jettonBalance += restoreAmount;
    storage.save();
}

fun orderFee(to: address, part: coins, queryId: uint64, value: coins, notice: coins) {
    val orderMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: contract.getAddress(),
        value,
        body: AskToTransfer {
            queryId,
            jettonAmount: part,
            transferRecipient: to,
            sendExcessesTo: null,
            customPayload: null,
            forwardTonAmount: notice,
            forwardPayload: beginCell().storeBool(false).toSlice(),
        },
    });
    orderMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun orderTax(rule: TaxRule?, part: coins, queryId: uint64, value: coins) {
    if (rule == null || part == 0) {
        return;
    }
    orderFee(rule.to, part, queryId, value, 1);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToFeeWallet.fromSlice(in.body);

    match (msg) {
        InternalTransferStep => {
            var storage = lazy FeeWalletStorage.load();
            if (in.senderAddress != storage.minterAddress) {
                assert (
                    in.senderAddress ==
                    calcAddressOfFeeWallet(
                        msg.transferInitiator!,
                        storage.minterAddress,
                        storage.rules,
                        contract.getCode(),
                    )
                ) throw Errors.NotValidWallet;
            }
            storage.jettonBalance += msg.jettonAmount;
            storage.save();

            if (storage.ownerAddress == storage.minterAddress) {
                assert (in.valueCoins > tokenWalletBurnAmount()) throw Errors.NotEnoughGas;
                reserveGramsOnBalance(
                    max(contract.getOriginalBalance() - in.valueCoins, feeWalletMinStorageFee()),
                    RESERVE_MODE_AT_MOST,
                );
                val burnMsg = createMessage({
                    bounce: BounceMode.Only256BitsOfBody,
                    dest: contract.getAddress(),
                    value: 0,
                    body: AskToBurn {
                        queryId: msg.queryId,
                        jettonAmount: msg.jettonAmount,
                        sendExcessesTo: msg.sendExcessesTo,
                        customPayload: null,
                    },
                });
                // SAFETY: the wallet's rent and its balance from before this message are reserved above
                burnMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                return;
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
                    max(toLeaveOnBalance, feeWalletMinStorageFee()),
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

            var storage = lazy FeeWalletStorage.load();
            reserveGramsOnBalance(
                0,
                RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
            );
            var arrives = msg.jettonAmount;
            if (in.senderAddress != contract.getAddress()) {
                assert (in.senderAddress == storage.ownerAddress) throw Errors.NotOwner;
                val rules = storage.rules.load();
                val fees = rules.feesOf(
                    msg.jettonAmount,
                    storage.excluded || rules.isExcludedForGood(storage.ownerAddress) ||
                        rules.isExcludedForGood(msg.transferRecipient),
                );
                checkFeeWalletTransferAmount(
                    in.valueCoins,
                    msg.forwardTonAmount,
                    in.originalForwardFee,
                    fees.burned != 0,
                    fees.taxCount(),
                );
                assert (storage.jettonBalance >= msg.jettonAmount) throw Errors.BalanceError;
                storage.jettonBalance -= msg.jettonAmount;
                storage.save();

                if (fees.burned != 0) {
                    orderFee(storage.minterAddress, fees.burned, msg.queryId, burnOrderValue(), 0);
                }
                val orderValue = taxOrderValue();
                orderTax(rules.tax1, fees.tax1, msg.queryId, orderValue);
                orderTax(rules.tax2, fees.tax2, msg.queryId, orderValue);
                orderTax(rules.tax3, fees.tax3, msg.queryId, orderValue);
                arrives -= fees.total();
            }

            val deployMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: calcDeployedFeeWallet(
                    msg.transferRecipient,
                    storage.minterAddress,
                    storage.rules,
                    contract.getCode(),
                ),
                value: 0,
                body: InternalTransferStep {
                    queryId: msg.queryId,
                    jettonAmount: arrives,
                    transferInitiator: storage.ownerAddress,
                    sendExcessesTo: msg.sendExcessesTo,
                    forwardTonAmount: msg.forwardTonAmount,
                    forwardPayload: msg.forwardPayload,
                },
            });
            // SAFETY: the balance from before this message is reserved at the top of this branch, and the fee orders are paid before this send
            deployMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        AskToBurn => {
            checkFeeWalletBurnAmount(in.valueCoins);

            var storage = lazy FeeWalletStorage.load();
            assert (
                in.senderAddress == storage.ownerAddress ||
                in.senderAddress == contract.getAddress()
            ) throw Errors.NotOwner;
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

        MarkExcluded => {
            var storage = lazy FeeWalletStorage.load();
            assert (in.senderAddress == storage.minterAddress) throw Errors.NotValidWallet;
            storage.excluded = msg.excluded;
            storage.save();
        }

        TopUpGrams => {}

        else => throw 0xFFFF,
    }
}

get fun get_wallet_data(): JettonWalletDataReply {
    val storage = lazy FeeWalletStorage.load();

    return {
        jettonBalance: storage.jettonBalance,
        ownerAddress: storage.ownerAddress,
        minterAddress: storage.minterAddress,
        jettonWalletCode: contract.getCode(),
    };
}

get fun isExcluded(): bool {
    val storage = lazy FeeWalletStorage.load();
    return storage.excluded || storage.rules.load().isExcludedForGood(storage.ownerAddress);
}
