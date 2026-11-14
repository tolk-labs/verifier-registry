import "@stdlib/gas-payments"
import "messages"
import "otc-constants"
import "otc-errors"
import "otc-math"
import "otc-messages"
import "otc-storage"

contract OtcOrder {
    author: "GroypFi"
    version: "2.0.0"
    description: "GroypFi OTC sell order: one isolated escrow per order, fixed price, 0.5% + 0.5% fee, open until filled or cancelled"
    storage: OrderStorage
    incomingMessages: AllowedMessageToOrder
}

type AllowedMessageToOrder =
    | InitOrder
    | ResponseWalletAddress
    | TransferNotificationForRecipient
    | FillOrder
    | CancelOrder
    | SweepJettons

fun emptyForwardPayload(): RemainingBitsAndRefs {
    return beginCell().storeUint(0, 1).endCell().beginParse();
}

// Ask this order's own (verified) jetton wallet to send `amount` jettons to `to`.
fun sendJettons(jettonWallet: address, amount: int, to: address, queryId: int, excessesTo: address) {
    val msg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: jettonWallet,
        value: JETTON_TRANSFER_VALUE,
        body: AskToTransfer {
            queryId,
            jettonAmount: amount,
            transferRecipient: to,
            sendExcessesTo: excessesTo,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: emptyForwardPayload(),
        },
    });
    msg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// Plain GRAM payout. Non-bounceable so it always lands at the owner's address,
// even if that wallet is not deployed yet (the owner's key still controls it).
fun payGrams(to: address, amount: int) {
    if (amount <= 0) {
        return;
    }
    val msg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: amount,
    });
    msg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

// Keep the order's balance as it was before this message (never below the rent reserve),
// then send everything else that came in to `to`.
fun reserveAndRefundRest(inValue: coins, to: address) {
    val before = contract.getOriginalBalance() - inValue + contract.getStorageDuePayment();
    reserveGramsOnBalance(max(before, ORDER_STORAGE_RESERVE), RESERVE_MODE_AT_MOST);
    val msg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
    });
    msg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

// Keep only the rent reserve and send the rest of the order's balance to `to`.
fun reserveRentAndSendAll(to: address) {
    reserveGramsOnBalance(ORDER_STORAGE_RESERVE, RESERVE_MODE_AT_MOST);
    val msg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
    });
    msg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
    // Only our own jetton transfers are bounceable; anything else throws and is dropped.
    val msg = lazy AskToTransfer.fromSlice(in.bouncedBody);

    var storage = lazy OrderStorage.load();
    if (storage.live == null) {
        return;
    }
    val live0 = storage.live!.load();
    // no wallet yet means none of our transfers can be in flight
    assert (live0.jettonWallet != null) throw OtcErrors.NotOrderWallet;
    assert (in.senderAddress == live0.jettonWallet!) throw OtcErrors.NotOrderWallet;

    val kind = queryKind(msg.queryId);
    if (kind == QK_FILL || kind == QK_CANCEL) {
        // The jettons never left our wallet: put them back on the order.
        var live = live0;
        live.amountLeft += msg.jettonAmount;
        storage.live = live.toCell();
        storage.status = STATUS_ACTIVE;
        storage.save();
    }
    // QK_RETURN / QK_SWEEP bounces: jettons stay in the wallet as strays (maker can sweep later).
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToOrder.fromSlice(in.body);

    match (msg) {
        InitOrder => {
            var storage = lazy OrderStorage.load();
            assert (in.senderAddress == storage.factory) throw OtcErrors.NotFactory;

            if (storage.status != STATUS_UNINIT) {
                // Same maker + nonce sent twice: give the second payment straight back.
                reserveAndRefundRest(in.valueCoins, storage.maker);
                return;
            }

            val req = msg.request.load();
            storage.status = STATUS_WAITING_WALLET;
            storage.terms = OrderTerms {
                jettonMaster: req.jettonMaster,
                feeWallet: msg.feeWallet,
                amountTotal: req.amountTotal,
                totalPrice: req.totalPrice,
                minFill: req.minFill,
            }.toCell();
            storage.live = OrderLive {
                jettonWallet: null,
                amountLeft: req.amountTotal,
                privateTaker: req.privateTaker,
            }.toCell();
            storage.save();

            // TEP-89: ask the jetton master which wallet belongs to this order.
            reserveGramsOnBalance(ORDER_STORAGE_RESERVE, RESERVE_MODE_AT_MOST);
            val ask = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: req.jettonMaster,
                value: 0,
                body: RequestWalletAddress {
                    queryId: msg.queryId,
                    ownerAddress: contract.getAddress(),
                    includeOwnerAddress: false,
                },
            });
            ask.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        ResponseWalletAddress => {
            var storage = lazy OrderStorage.load();
            assert (storage.terms != null) throw OtcErrors.WrongStatus;
            val terms = storage.terms!.load();
            assert (in.senderAddress == terms.jettonMaster) throw OtcErrors.NotJettonMaster;

            if (storage.status == STATUS_CLOSED) {
                // Maker cancelled before the master answered: remember the wallet (so stray
                // jettons can be swept) and pass the returned GRAM on to the maker.
                var closedLive = storage.live!.load();
                if (closedLive.jettonWallet == null && msg.jettonWalletAddress != null) {
                    closedLive.jettonWallet = msg.jettonWalletAddress;
                    storage.live = closedLive.toCell();
                    storage.save();
                }
                reserveRentAndSendAll(storage.maker);
                return;
            }
            assert (storage.status == STATUS_WAITING_WALLET) throw OtcErrors.WrongStatus;

            if (msg.jettonWalletAddress == null) {
                storage.status = STATUS_CLOSED;
                storage.save();
                reserveRentAndSendAll(storage.maker);
                return;
            }
            var live = storage.live!.load();
            live.jettonWallet = msg.jettonWalletAddress;
            storage.live = live.toCell();
            storage.status = STATUS_AWAITING_DEPOSIT;
            storage.save();
            reserveRentAndSendAll(storage.maker);
        }

        TransferNotificationForRecipient => {
            var storage = lazy OrderStorage.load();
            assert (storage.live != null) throw OtcErrors.WrongStatus;
            val live = storage.live!.load();
            // The one check that stops fake-jetton deposits.
            assert (live.jettonWallet != null) throw OtcErrors.NotOrderWallet;
            assert (in.senderAddress == live.jettonWallet!) throw OtcErrors.NotOrderWallet;

            val terms = storage.terms!.load();
            val exact = storage.status == STATUS_AWAITING_DEPOSIT &&
                msg.transferInitiator != null &&
                msg.transferInitiator! == storage.maker &&
                msg.jettonAmount == terms.amountTotal;

            if (exact) {
                storage.status = STATUS_ACTIVE;
                storage.save();
                // nothing GRAM-wise is owed to anyone yet: hand the forwarded gas back to the maker
                reserveRentAndSendAll(storage.maker);
                return;
            }

            // Anything else is returned to whoever sent it, if it paid for the return.
            if (msg.transferInitiator != null && in.valueCoins >= DEPOSIT_RETURN_VALUE) {
                val before = contract.getOriginalBalance() - in.valueCoins + contract.getStorageDuePayment();
                reserveGramsOnBalance(max(before, ORDER_STORAGE_RESERVE), RESERVE_MODE_AT_MOST);
                sendJettons(
                    live.jettonWallet!,
                    msg.jettonAmount,
                    msg.transferInitiator!,
                    makeQueryId(QK_RETURN, msg.queryId),
                    msg.transferInitiator!,
                );
            }
        }

        FillOrder => {
            var storage = lazy OrderStorage.load();
            assert (storage.status == STATUS_ACTIVE) throw OtcErrors.WrongStatus;
            val terms = storage.terms!.load();
            var live = storage.live!.load();
            if (live.privateTaker != null) {
                assert (in.senderAddress == live.privateTaker!) throw OtcErrors.NotPrivateTaker;
            }
            assert (in.senderAddress.getWorkchain() == BASECHAIN) throw OtcErrors.WrongWorkchain;
            assert (msg.amount > 0 && msg.amount <= live.amountLeft) throw OtcErrors.BadAmount;
            assert (msg.amount >= terms.minFill || msg.amount == live.amountLeft) throw OtcErrors.BelowMinFill;

            val cost = fillCost(msg.amount, live.amountLeft, terms.amountTotal, terms.totalPrice);
            val takerFee = takerFeeOf(cost);
            val makerFee = makerFeeOf(cost);
            // A dust fill that rounds to 0 GRAM would hand out jettons for free and skip the fee.
            assert (cost > 0) throw OtcErrors.BadAmount;
            assert (in.valueCoins >= cost + takerFee + FILL_GAS) throw OtcErrors.NotEnoughValue;

            // State first, then sends.
            live.amountLeft -= msg.amount;
            if (live.amountLeft == 0) {
                storage.status = STATUS_CLOSED;
            }
            storage.live = live.toCell();
            storage.save();

            val before = contract.getOriginalBalance() - in.valueCoins + contract.getStorageDuePayment();
            reserveGramsOnBalance(max(before, ORDER_STORAGE_RESERVE), RESERVE_MODE_AT_MOST);

            sendJettons(
                live.jettonWallet!,
                msg.amount,
                in.senderAddress,
                makeQueryId(QK_FILL, msg.queryId),
                in.senderAddress,
            );
            payGrams(storage.maker, cost - makerFee);
            payGrams(terms.feeWallet, takerFee + makerFee);

            val rest = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
            });
            rest.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        CancelOrder => {
            var storage = lazy OrderStorage.load();
            assert (in.senderAddress == storage.maker) throw OtcErrors.NotMaker;
            closeOrder(storage, in.valueCoins);
        }

        SweepJettons => {
            var storage = lazy OrderStorage.load();
            assert (in.senderAddress == storage.maker) throw OtcErrors.NotMaker;
            assert (storage.status == STATUS_CLOSED) throw OtcErrors.WrongStatus;
            assert (in.valueCoins >= CANCEL_GAS) throw OtcErrors.NotEnoughValue;
            val live = storage.live!.load();
            assert (live.jettonWallet != null) throw OtcErrors.WrongStatus;
            assert (msg.amount > 0) throw OtcErrors.BadAmount;
            sendJettons(live.jettonWallet!, msg.amount, storage.maker, makeQueryId(QK_SWEEP, msg.queryId), storage.maker);
            reserveAndRefundRest(in.valueCoins, storage.maker);
        }

        else => {
            // plain GRAM top-ups only
            assert (in.body.isEmpty()) throw OtcErrors.UnknownOp;
        }
    }
}

// CancelOrder (maker only): jettons left + the order's GRAM + unused gas all go to the maker.
fun closeOrder(storage: OrderStorage, inValue: coins) {
    val status = storage.status;
    assert (status != STATUS_UNINIT && status != STATUS_CLOSED) throw OtcErrors.WrongStatus;

    if (status == STATUS_ACTIVE) {
        assert (inValue >= CANCEL_GAS) throw OtcErrors.NotEnoughValue;
        var live = storage.live!.load();
        val left = live.amountLeft;
        live.amountLeft = 0;
        storage.live = live.toCell();
        storage.status = STATUS_CLOSED;
        storage.save();
        // ACTIVE always means amountLeft > 0 (a fill that empties the order closes it).
        sendJettons(live.jettonWallet!, left, storage.maker, makeQueryId(QK_CANCEL, 0), storage.maker);
        reserveAndRefundRest(inValue, storage.maker);
        return;
    }

    // Waiting for the wallet or the deposit: nothing is escrowed yet, so every GRAM on the
    // order (including this message's value) goes to the maker.
    storage.status = STATUS_CLOSED;
    storage.save();
    reserveRentAndSendAll(storage.maker);
}

get fun get_order_data(): OrderDataReply {
    val storage = lazy OrderStorage.load();
    if (storage.terms == null) {
        return {
            status: storage.status,
            factory: storage.factory,
            maker: storage.maker,
            nonce: storage.nonce,
            jettonMaster: null,
            feeWallet: null,
            jettonWallet: null,
            amountTotal: 0,
            amountLeft: 0,
            totalPrice: 0,
            minFill: 0,
            privateTaker: null,
        };
    }
    val terms = storage.terms!.load();
    val live = storage.live!.load();
    return {
        status: storage.status,
        factory: storage.factory,
        maker: storage.maker,
        nonce: storage.nonce,
        jettonMaster: terms.jettonMaster,
        feeWallet: terms.feeWallet,
        jettonWallet: live.jettonWallet,
        amountTotal: terms.amountTotal,
        amountLeft: live.amountLeft,
        totalPrice: terms.totalPrice,
        minFill: terms.minFill,
        privateTaker: live.privateTaker,
    };
}

get fun get_fill_quote(amount: int): FillQuoteReply {
    val storage = lazy OrderStorage.load();
    assert (storage.terms != null) throw OtcErrors.WrongStatus;
    val terms = storage.terms!.load();
    val live = storage.live!.load();
    assert (amount > 0 && amount <= live.amountLeft) throw OtcErrors.BadAmount;
    val cost = fillCost(amount, live.amountLeft, terms.amountTotal, terms.totalPrice);
    val takerFee = takerFeeOf(cost);
    val makerFee = makerFeeOf(cost);
    return {
        cost,
        takerFee,
        makerFee,
        takerPays: cost + takerFee,
        makerGets: cost - makerFee,
    };
}
