import "@contracts/common-messages"
import "@contracts/errors"
import "fees_management"
import "messages"
import "storage"

contract ContractTON {
    author: "Alexandr_K"
    version: "0.0.4"
    description: "Escrow contract TON"
    storage: StorageTon
    incomingMessages: AllowedMessage
}

type AllowedMessage =
    | Transfer
    | ChangePercent
    | AcceptPercent
    | RefundTon
    | ErrMode
    | ErrRefund
    | BurnContract

type BounceOpToHandle = RefundBounce

// The contract is active when both parties have deposited the init amounts 
// and the deal is not completed.
fun StorageTon.isActive(self, extra: ExtraFieldsTon): bool {
    if (extra.completed) {
        return false;
    }
    return self.clientAmount >= extra.clientAmountInit &&
        self.providerDeposit >= extra.providerDepositInit;
}

// AfterHalfYear: ErrRefund may drain all booked TON. The counterparty
// wallet may be lost; RefundTon stays the ordinary own-balance path.
fun ExtraFieldsTon.allowsErrRefund(
    self,
    sender: address,
    client: address,
    provider: address,
): bool {
    if (sender == client) {
        return self.errMode == ErrModeVal.ClientFullRightsAfterHalfYear as int8 &&
            (blockchain.now() as uint64) >= self.errModeAt + HALF_YEAR;
    }
    if (sender == provider) {
        return self.errMode == ErrModeVal.ProviderFullRightsAfterHalfYear as int8 &&
            (blockchain.now() as uint64) >= self.errModeAt + HALF_YEAR;
    }
    return false;
}

fun ExtraFieldsTon.deployerAddress(self, client: address, provider: address): address {
    if (self.mode == QueryRole.Client as int8) {
        return client;
    }
    assert (self.mode == QueryRole.Provider as int8) throw Errors.UnauthorizedSender;
    return provider;
}

fun sendRefundTonBounce(
    dest: address,
    queryId: uint8,
    tonToSend: uint75,
    value: coins,
) {
    val refundMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest,
        value,
        body: RefundBounce {
            queryId,
            tonAmount: tonToSend,
        },
    });
    refundMsg.send(SEND_MODE_REGULAR);
}

// Bounce: the outgoing refund did not reach — return the amount to the role's balance.
fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
    val msg = lazy BounceOpToHandle.fromSlice(in.bouncedBody);
    var storage = lazy StorageTon.load();

    match (msg) {
        RefundBounce => {
            if (msg.queryId == QueryRole.Client as uint8) {
                storage.clientAmount += msg.tonAmount;
            } else if (msg.queryId == QueryRole.Provider as uint8) {
                storage.providerDeposit += msg.tonAmount;
            } else if (msg.queryId == QueryRole.Admin as uint8) {
                var extra: ExtraFieldsTon = lazy storage.extra.load();
                extra.royaltyInit += msg.tonAmount;
                storage.extra = extra.toCell();
            } else {
                return;
            }
        }
    }

    storage.save();
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    val msg = lazy AllowedMessage.fromSlice(in.body);
    var storage = lazy StorageTon.load();

    val tonBalanceBeforeMsg = contract.getOriginalBalance() - in.valueCoins;
    val storageFee = MIN_TONS_FOR_STORAGE_THIS_CONTRACT -
        min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE_THIS_CONTRACT);

    var msgValue = in.valueCoins - storageFee - CONTRACT_GAS_CONSUMPTION;

    match (msg) {
        Transfer => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            // msg.sender is only for the minter's deploy Transfer: the contract
            // does not exist yet, so in.senderAddress is the minter, not the client.
            // After anyone is credited, always trust the real sender.
            val sender = tonBalanceBeforeMsg == 0 && storage.clientAmount == 0 &&
                storage.providerDeposit == 0 &&
                msg.sender != null
                ? msg.sender
                : in.senderAddress;

            if (sender == storage.clientAddress) {
                storage.clientAmount += msgValue;
                storage.save();
            } else if (sender == storage.providerAddress) {
                storage.providerDeposit += msgValue;
                storage.save();
            } else {
                throw Errors.UnauthorizedSender;
            }
        }

        ChangePercent => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            assert (in.senderAddress == storage.clientAddress) throw Errors.UnauthorizedSender;
            assert (msg.percent >= 0 && msg.percent <= 100) throw Errors.WrongPercent;
            var extra: ExtraFieldsTon = lazy storage.extra.load();
            assert (extra.completed == false) throw Errors.ContractIsCompleted;
            assert (storage.isActive(extra)) throw Errors.ContractIsNotActive;

            extra.percent = msg.percent;
            // The remainder value remains on the client's account (then it will be taken through RefundTon)
            storage.clientAmount += msgValue;
            // 100% = the client immediately closes the deal in favor of the provider
            if (msg.percent == 100) {
                extra.completed = true;
                storage.providerDeposit += extra.clientAmountInit - extra.royaltyInit;
                storage.clientAmount -= extra.clientAmountInit;
            }
            storage.extra = extra.toCell();
            storage.save();
        }

        AcceptPercent => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            assert (in.senderAddress == storage.providerAddress) throw Errors.UnauthorizedSender;
            var extra: ExtraFieldsTon = lazy storage.extra.load();
            // Repeated accept after completion is prohibited
            assert (extra.completed == false) throw Errors.ContractIsCompleted;
            // percent == 100 in init means "the client has not yet offered a percentage"
            assert (extra.percent != 100) throw Errors.PercentNotOffered;
            assert (msg.percent == extra.percent) throw Errors.PercentMismatch;

            extra.completed = true;
            val percentValue = extra.clientAmountInit / 100 * msg.percent;

            // When royalty is 0%, it is reset (termination without platform commission)
            if (msg.percent == 0) {
                extra.royaltyInit = 0;
            }

            storage.providerDeposit += percentValue - extra.royaltyInit + msgValue;
            storage.clientAmount -= percentValue;
            storage.extra = extra.toCell();
            storage.save();
        }

        RefundTon => {
            msgValue -= MIN_MESSAGE_VALUE_BOUND;
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            assert (msg.tonAmount > 0) throw Errors.ZeroAmount;
            var extra: ExtraFieldsTon = lazy storage.extra.load();

            val transferRecipient: address = msg.addressRefund != null
                ? msg.addressRefund
                : in.senderAddress;

            val isActive = storage.isActive(extra);

            var queryId: uint8;
            var tonToSend: uint75;
            var maxTon: uint75;

            if (in.senderAddress == storage.clientAddress) {
                queryId = QueryRole.Client;
                if (isActive) {
                    // While the deal is active: you cannot touch clientAmountInit + deposit 30%
                    val deposit: uint75 = (extra.clientAmountInit / 100) * 30;
                    val locked = extra.clientAmountInit + deposit;
                    assert (storage.clientAmount > locked) throw Errors.NotEnoughTons;
                    maxTon = storage.clientAmount - locked;
                } else {
                    maxTon = storage.clientAmount;
                }
                tonToSend = min(maxTon, msg.tonAmount);
                storage.clientAmount -= tonToSend;
            } else if (in.senderAddress == storage.providerAddress) {
                queryId = QueryRole.Provider;
                if (isActive) {
                    // While active: you cannot take providerDepositInit
                    assert (
                        storage.providerDeposit > extra.providerDepositInit
                    ) throw Errors.NotEnoughTons;
                    maxTon = storage.providerDeposit - extra.providerDepositInit;
                } else {
                    maxTon = storage.providerDeposit;
                }
                tonToSend = min(maxTon, msg.tonAmount);
                storage.providerDeposit -= tonToSend;
            } else if (in.senderAddress == extra.adminAddress) {
                queryId = QueryRole.Admin;
                if (extra.completed) {
                    maxTon = extra.royaltyInit;
                } else {
                    maxTon = 0;
                }
                tonToSend = min(maxTon, msg.tonAmount);
                extra.royaltyInit -= tonToSend;
                storage.extra = extra.toCell();
            } else {
                throw Errors.UnauthorizedSender;
            }

            assert (tonToSend > 0) throw Errors.NotEnoughTons;

            // First save the state — when bounce onBouncedMessage returns the amount
            storage.save();

            sendRefundTonBounce(
                transferRecipient,
                queryId,
                tonToSend,
                tonToSend + MIN_MESSAGE_VALUE_BOUND + msgValue,
            );
        }

        ErrRefund => {
            msgValue -= MIN_MESSAGE_VALUE_BOUND;
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            val extra: ExtraFieldsTon = lazy storage.extra.load();
            if (
                !extra.allowsErrRefund(
                    in.senderAddress,
                    storage.clientAddress,
                    storage.providerAddress,
                )
            ) {
                throw Errors.UnauthorizedSender;
            }

            val tonToSend = storage.clientAmount + storage.providerDeposit;
            assert (tonToSend > 0) throw Errors.NotEnoughTons;

            val queryId: uint8 = in.senderAddress == storage.clientAddress
                ? QueryRole.Client
                : QueryRole.Provider;
            storage.clientAmount = 0;
            storage.providerDeposit = 0;
            storage.save();

            val transferRecipient: address = msg.addressRefund != null
                ? msg.addressRefund
                : in.senderAddress;
            sendRefundTonBounce(
                transferRecipient,
                queryId,
                tonToSend,
                tonToSend + MIN_MESSAGE_VALUE_BOUND + msgValue,
            );
        }

        ErrMode => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            var extra: ExtraFieldsTon = lazy storage.extra.load();
            // Set only when AfterHalfYear is actually armed; BlockErrorMode stays silent.
            var noticeTo: address? = null;
            var noticeAboutClient: bool = false;
            if (in.senderAddress == storage.clientAddress) {
                if (msg.value == ErrModeVal.BlockErrorMode as int8) {
                    extra.errMode = ErrModeVal.BlockErrorMode;
                } else if (
                    msg.value == ErrModeVal.ClientFullRightsAfterHalfYear as int8 &&
                    extra.errMode != ErrModeVal.BlockErrorMode as int8
                ) {
                    extra.errMode = ErrModeVal.ClientFullRightsAfterHalfYear;
                    extra.errModeAt = blockchain.now() as uint64;
                    noticeTo = storage.providerAddress;
                    noticeAboutClient = true;
                }
                if (noticeTo != null) {
                    assert (msgValue > HALF_YEAR_NOTICE_VALUE) throw Errors.ValueTooSmall;
                    msgValue -= HALF_YEAR_NOTICE_VALUE;
                }
                storage.clientAmount += msgValue;
            } else if (in.senderAddress == storage.providerAddress) {
                if (msg.value == ErrModeVal.BlockErrorMode as int8) {
                    extra.errMode = ErrModeVal.BlockErrorMode;
                } else if (
                    msg.value == ErrModeVal.ProviderFullRightsAfterHalfYear as int8 &&
                    extra.errMode != ErrModeVal.BlockErrorMode as int8
                ) {
                    extra.errMode = ErrModeVal.ProviderFullRightsAfterHalfYear;
                    extra.errModeAt = blockchain.now() as uint64;
                    noticeTo = storage.clientAddress;
                    noticeAboutClient = false;
                }
                if (noticeTo != null) {
                    assert (msgValue > HALF_YEAR_NOTICE_VALUE) throw Errors.ValueTooSmall;
                    msgValue -= HALF_YEAR_NOTICE_VALUE;
                }
                storage.providerDeposit += msgValue;
            } else {
                throw Errors.UnauthorizedSender;
            }
            storage.extra = extra.toCell();
            storage.save();
            if (noticeTo != null) {
                sendHalfYearControlNotice(noticeTo, noticeAboutClient);
            }
        }

        BurnContract => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            val extra: ExtraFieldsTon = lazy storage.extra.load();
            val deployer = extra.deployerAddress(storage.clientAddress, storage.providerAddress);
            assert (
                in.senderAddress == deployer || in.senderAddress == extra.adminAddress
            ) throw Errors.UnauthorizedSender;
            assert (
                storage.clientAmount == 0 && storage.providerDeposit == 0
            ) throw Errors.BalancesNotEmpty;

            if (extra.completed && extra.royaltyInit > 0) {
                val royaltyMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: extra.adminAddress,
                    value: extra.royaltyInit as coins,
                });
                royaltyMsg.send(SEND_MODE_REGULAR);
            }

            val burn = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
            });
            // SAFETY: destroy; leftover TON goes to whoever burned (deployer or admin)
            burn.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_DESTROY);
        }
    }
}

struct ContractDataReply {
    clientAddress: address
    providerAddress: address
    clientAmount: uint75
    providerDeposit: uint75
    timestamp: uint64
    clientAmountInit: uint75
    providerDepositInit: uint75
    royaltyInit: uint75
    adminAddress: address
    completed: bool
    percent: int8
    errMode: int8
    errModeAt: uint64
    mode: int8
    isActive: bool
}

get fun getContractData(): ContractDataReply {
    val storage = lazy StorageTon.load();
    val extra: ExtraFieldsTon = lazy storage.extra.load();
    val isActive = storage.isActive(extra);

    return {
        clientAddress: storage.clientAddress,
        providerAddress: storage.providerAddress,
        clientAmount: storage.clientAmount,
        providerDeposit: storage.providerDeposit,
        timestamp: extra.timestamp,
        clientAmountInit: extra.clientAmountInit,
        providerDepositInit: extra.providerDepositInit,
        royaltyInit: extra.royaltyInit,
        adminAddress: extra.adminAddress,
        completed: extra.completed,
        percent: extra.percent,
        errMode: extra.errMode,
        errModeAt: extra.errModeAt,
        mode: extra.mode,
        isActive,
    };
}
