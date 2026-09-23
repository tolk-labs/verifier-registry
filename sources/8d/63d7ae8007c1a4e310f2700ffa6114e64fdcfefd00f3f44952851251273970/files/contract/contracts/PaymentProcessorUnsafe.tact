import "./payment/TonPaymentBase.tact";

// Native-TON payment processor, "Unsafe" variant: no seller whitelist —
// any seller address is accepted (mirrors Solidity PaymentProcessorEIPUnsafe).
contract PaymentProcessorUnsafe with TonPaymentBase {
    owner: Address;
    platformCommissionBps: Int;
    minimalPlatformCommission: Int as coins;
    mainCommissionWallet: Address;
    partnerCollection: Address;
    partnerShareBps: map<Address, Int>;
    nonces: map<Address, Int>;
    incrementGas: Int as coins;
    paused: Bool;

    init(
        owner: Address,
        mainCommissionWallet: Address,
        partnerCollection: Address
    ) {
        // Same zero policy (1011) as the setters; mainCommissionWallet is immutable
        throwIf(ZeroAddress, owner == ZERO_ADDRESS);
        throwIf(ZeroAddress, mainCommissionWallet == ZERO_ADDRESS);
        self.owner = owner;
        self.mainCommissionWallet = mainCommissionWallet;
        self.partnerCollection = partnerCollection;
        self.platformCommissionBps = 25; // 0.25%
        self.minimalPlatformCommission = 0;
        self.incrementGas = DEFAULT_INCREMENT_GAS;
        self.paused = false;
    }

    get fun get_version(): Int {
        return 3;
    }
}
