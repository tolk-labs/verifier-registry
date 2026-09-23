import "./PaymentProcessorBase.tact";

// Native-TON payment flow. Buyer attaches TON to a Transfer message; the contract
// splits it between seller, platform and optional partner, then refunds the excess
// back to the buyer (mirrors Solidity's exact msg.value == totalPay requirement).
trait TonPaymentBase with PaymentProcessorBase {
    owner: Address;
    platformCommissionBps: Int;
    minimalPlatformCommission: Int as coins;
    mainCommissionWallet: Address;
    partnerCollection: Address;
    partnerShareBps: map<Address, Int>;
    nonces: map<Address, Int>;
    incrementGas: Int as coins;
    paused: Bool;

    receive(msg: Transfer) {
        let req = msg.req;
        self.validatePaymentRequest(req, sender());

        let incoming: Int = context().value;
        let commission = self.calculateCommission(req.amount);

        // When seller pays commission, it must not exceed the amount
        throwIf(CommissionExceedsAmount, !req.buyerPaysCommission && commission >= req.amount);

        let sellerValue = req.buyerPaysCommission ? req.amount : (req.amount - commission);
        let totalRequired = req.buyerPaysCommission ? (req.amount + commission) : req.amount;

        let optionalPart = self.computeOptionalPart(commission, req.optionalCommissionWallet);
        let platformPart = commission - optionalPart;

        // Incoming value must also cover message forwarding fees and the collection
        // notification, otherwise the action phase would fail after the nonce is consumed
        let gasNeeded = TON_PROCESS_GAS_BUFFER + (optionalPart > 0 ? self.incrementGas : 0);
        throwIf(InvalidTotalAmountValidation, incoming < totalRequired + gasNeeded);

        self.consumeNonce(req.buyer);

        // Protect the pre-existing contract balance: only the incoming value is distributed
        let balanceBefore: Int = myBalance() - incoming;
        nativeReserve(balanceBefore > 0 ? balanceBefore : 0, 0);

        // bounce: false — like ordinary wallets: the payout credits even a not-yet-deployed
        // wallet. With bounce: true an uninitialized seller address would bounce the payout
        // back and it would silently pile up on the processor while the payment looks успешным.
        send(SendParameters{
            to: req.seller,
            value: sellerValue,
            bounce: false,
            mode: SendPayGasSeparately
        });

        if (platformPart > 0) {
            send(SendParameters{
                to: self.mainCommissionWallet,
                value: platformPart,
                bounce: false,
                mode: SendPayGasSeparately
            });
        }

        if (optionalPart > 0) {
            // Tagged body so the bounced handler can redirect a failed partner payout
            send(SendParameters{
                to: req.optionalCommissionWallet!!,
                value: optionalPart,
                bounce: true,
                mode: SendPayGasSeparately,
                body: OptionalWalletTransfer{}.toCell()
            });
            emit(OptionalWalletPaid{ wallet: req.optionalCommissionWallet!!, amount: optionalPart }.toCell());

            send(SendParameters{
                to: self.partnerCollection,
                value: self.incrementGas,
                bounce: true,
                mode: SendPayGasSeparately,
                body: IncrementSuccessfulTx{ wallet: req.optionalCommissionWallet!! }.toCell()
            });
        }

        emit(PaymentProcessed{
            buyer: req.buyer,
            seller: req.seller,
            amount: req.amount,
            commission: commission,
            partnerWallet: req.optionalCommissionWallet,
            partnerShare: optionalPart
        }.toCell());

        // Refund the excess to the buyer — must be the last registered action.
        // SendIgnoreErrors: skip the refund when the remainder can't cover the fwd fee
        send(SendParameters{
            to: req.buyer,
            value: 0,
            bounce: false,
            mode: SendRemainingBalance | SendIgnoreErrors
        });
    }

    // If the optional wallet rejects the transfer, redirect funds to mainCommissionWallet
    // (Solidity: _tryTransferTo fallback + OptionalWalletTransferFailed).
    // A bounce comes from the original destination, so sender() is the partner wallet.
    bounced(msg: bounced<OptionalWalletTransfer>) {
        emit(OptionalWalletTransferFailed{ wallet: sender(), amount: context().value }.toCell());
        send(SendParameters{
            to: self.mainCommissionWallet,
            value: 0,
            bounce: false,
            mode: SendRemainingValue
        });
    }

    get fun getConfig(): ConfigResponse {
        return ConfigResponse{
            owner: self.owner,
            mainCommissionWallet: self.mainCommissionWallet,
            nftCollection: self.partnerCollection,
            platformCommissionBps: self.platformCommissionBps,
            minimalPlatformCommission: self.minimalPlatformCommission,
            paused: self.paused
        };
    }
}
