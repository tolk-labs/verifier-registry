import "@stdlib/ownable";
import "./PaymentMessages.tact";
import "./JettonMessages.tact"; // TokenTransfer for the jetton sweep available on all variants
import "../messages.tact";
import "../Errors.tact";
import "../Constants.tact";

// Core payment-processor logic shared by all four variants (TON/Jetton x Safe/Unsafe).
// Mirrors Solidity PaymentProcessorBase: commission math, partner (referrer) split,
// admin setters, pausability, partner registry synced from the NFT collection.
trait PaymentProcessorBase with Ownable {
    owner: Address;
    platformCommissionBps: Int;               // 0..10000
    minimalPlatformCommission: Int as coins;  // minimum commission floor
    mainCommissionWallet: Address;
    partnerCollection: Address;               // partner NFT collection contract address
    partnerShareBps: map<Address, Int>;
    nonces: map<Address, Int>;                // per-buyer nonce
    incrementGas: Int as coins;               // gas for IncrementSuccessfulTx to collection
    paused: Bool;

    // ==== Internal helpers ====
    inline fun onlyCollection() {
        throwIf(ExitCodeNotCollection, sender() != self.partnerCollection);
    }

    fun calculateCommission(amount: Int): Int {
        let commission = (amount * self.platformCommissionBps) / 10000;
        if (commission < self.minimalPlatformCommission) {
            commission = self.minimalPlatformCommission;
        }
        return commission;
    }

    fun consumeNonce(buyer: Address) {
        let currentNonce = self.nonces.get(buyer);
        let nextNonce: Int = (currentNonce != null) ? (currentNonce!! + 1) : 1;
        self.nonces.set(buyer, nextNonce);
    }

    // Partner (referrer) share of the commission; 0 when no wallet passed or not registered
    fun computeOptionalPart(commission: Int, optionalCommissionWallet: Address?): Int {
        if (optionalCommissionWallet == null) {
            return 0;
        }
        let shareOpt = self.partnerShareBps.get(optionalCommissionWallet!!);
        let shareBps = shareOpt != null ? shareOpt!! : 0;
        if (shareBps > 0 && shareBps <= 10000) {
            return (commission * shareBps) / 10000;
        }
        return 0;
    }

    // Common payment validation; actualBuyer is who actually sent the funds
    fun validatePaymentRequest(req: PaymentRequest, actualBuyer: Address) {
        throwIf(Paused, self.paused);
        throwIf(InvalidAmountValidation, req.amount <= 0);
        throwIf(InvalidSellerValidation, req.seller == ZERO_ADDRESS || req.seller == req.buyer);
        throwIf(InvalidSignature, actualBuyer != req.buyer);
        throwIf(SellerNotWhitelisted, !self.isSellerAllowed(req.seller));
    }

    // Unsafe default: any seller allowed. SellerWhitelist trait overrides this.
    virtual inline fun isSellerAllowed(seller: Address): Bool {
        return true;
    }

    // Accept plain TON (gas top-ups), mirrors Solidity receive() {}
    receive() {}

    // ============ Admin ============
    receive(msg: SetOwner) {
        self.requireOwner();
        self.handleSetOwner(msg.newOwner);
    }

    // Safe variants override this with a throw: a bare owner rotation would leave the old
    // owner's ed25519 key valid for RegisterSeller — there ownership moves only atomically
    // with the key via SetOwnerWithKey.
    virtual fun handleSetOwner(newOwner: Address) {
        throwIf(ZeroAddress, newOwner == ZERO_ADDRESS);
        self.owner = newOwner;
    }

    receive(msg: SetPlatformCommissionBps) {
        self.requireOwner();
        throwIf(InvalidCommissionBps, !(msg.newBps >= 0 && msg.newBps <= 10000));
        emit(CommissionBpsUpdated{ oldBps: self.platformCommissionBps, newBps: msg.newBps }.toCell());
        self.platformCommissionBps = msg.newBps;
    }

    receive(msg: SetMinimalPlatformCommission) {
        self.requireOwner();
        emit(MinimalCommissionUpdated{ oldMinimal: self.minimalPlatformCommission, newMinimal: msg.amount }.toCell());
        self.minimalPlatformCommission = msg.amount;
    }

    receive(msg: SetPartnerCollection) {
        self.requireOwner();
        throwIf(ZeroAddress, msg.collection == ZERO_ADDRESS);
        emit(NftCollectionUpdated{ oldCollection: self.partnerCollection, newCollection: msg.collection }.toCell());
        self.partnerCollection = msg.collection;
    }

    receive(msg: SetIncrementGas) {
        self.requireOwner();
        self.incrementGas = msg.amount;
    }

    receive(msg: SetPaused) {
        self.requireOwner();
        self.paused = msg.paused;
    }

    receive(msg: WithdrawAll) {
        self.requireOwner();
        throwIf(ZeroAddress, msg.to == ZERO_ADDRESS);
        let balance = myBalance();
        throwIf(BelowReserve, !(balance > MIN_KEEP));
        emit(Withdrawn{ jettonWallet: null, to: msg.to, amount: balance - MIN_KEEP }.toCell());
        nativeReserve(MIN_KEEP, 0);
        send(SendParameters{ to: msg.to, value: 0, mode: SendRemainingBalance });
    }

    // Withdraw stuck jettons from any variant (Solidity: withdrawAllTokens lives in the base).
    // msg.jettonWallet = null falls back to the processor's own jetton wallet on jetton
    // variants; TON variants have none, so there the field is effectively required.
    receive(msg: WithdrawAllJettons) {
        self.requireOwner();
        throwIf(ZeroAddress, msg.to == ZERO_ADDRESS);
        let walletOpt: Address? = msg.jettonWallet != null ? msg.jettonWallet : self.defaultJettonWallet();
        throwIf(ZeroAddress, walletOpt == null);
        let wallet = walletOpt!!;
        send(SendParameters{
            to: wallet,
            value: GAS_PER_JETTON_TRANSFER,
            bounce: true,
            mode: SendPayGasSeparately,
            body: TokenTransfer{
                queryId: SWEEP_QUERY_ID,
                amount: msg.amount,
                destination: msg.to,
                response_destination: myAddress(),
                custom_payload: null,
                forward_ton_amount: 0,
                forward_payload: null
            }.toCell()
        });
        emit(Withdrawn{ jettonWallet: wallet, to: msg.to, amount: msg.amount }.toCell());
    }

    // Jetton variants override this with their own jetton wallet
    virtual inline fun defaultJettonWallet(): Address? {
        return null;
    }

    // Silently accept excess gas returns from jetton wallets. Lives in the base because
    // WithdrawAllJettons does too: the sweep's response_destination is this contract, and
    // without this receiver the excesses message would bounce off the TON variants.
    receive(_: Excess) {}

    // The successful-tx counter notification bounced (collection missing / out of gas).
    // Mirrors Solidity's PartnerCounterFailed — the payment itself is unaffected.
    // The wallet can't be recovered from a truncated bounce body, hence null.
    bounced(msg: bounced<IncrementSuccessfulTx>) {
        emit(PartnerCounterFailed{ wallet: null }.toCell());
    }

    // An outgoing TokenTransfer bounced on the jetton wallet (refund, payout or sweep failed —
    // e.g. not enough gas attached or wrong wallet address). The jettons stay on our jetton
    // wallet and are recoverable via WithdrawAllJettons; this makes the failure visible
    // off-chain instead of a silently swallowed bounce. Guarded: anyone can bounce a fake
    // TokenTransfer at the contract to fabricate the event, so jetton variants only emit
    // when the bounce comes from their own jetton wallet (see isJettonBounceTrusted).
    bounced(msg: bounced<TokenTransfer>) {
        if (self.isJettonBounceTrusted()) {
            emit(JettonTransferFailed{ queryId: msg.queryId }.toCell());
        }
    }

    // TON variants have no protected jetton wallet (sweeps go to arbitrary wallets), so
    // they keep emitting for any bounce; jetton variants override with a sender() check.
    virtual inline fun isJettonBounceTrusted(): Bool {
        return true;
    }

    // ============ Partners (only from collection) ============
    receive(msg: RegisterPartnerShare) {
        self.onlyCollection();
        if (msg.shareBps == null || msg.shareBps!! <= 0) {
            self.partnerShareBps.set(msg.wallet, null);
            return;
        }
        self.partnerShareBps.set(msg.wallet, msg.shareBps);
    }

    receive(msg: UnregisterPartnerShare) {
        self.onlyCollection();
        self.partnerShareBps.set(msg.wallet, null);
    }

    // ============ Views ============
    get fun previewPayment(amount: Int, buyerPaysCommission: Bool): Preview {
        let commission = self.calculateCommission(amount);
        let totalPay = buyerPaysCommission ? (amount + commission) : amount;
        return Preview{ commission: commission, totalPay: totalPay };
    }

    get fun nonceOf(account: Address): Int {
        let nonce = self.nonces.get(account);
        return (nonce != null) ? nonce!! : 0;
    }

    // On-chain view of the partner registry (synced from the collection) — without it the
    // actual share a processor pays is only reconstructable by replaying events
    get fun partnerShareOf(wallet: Address): Int {
        let share = self.partnerShareBps.get(wallet);
        return (share != null) ? share!! : 0;
    }

    get fun isPaused(): Bool {
        return self.paused;
    }
}
