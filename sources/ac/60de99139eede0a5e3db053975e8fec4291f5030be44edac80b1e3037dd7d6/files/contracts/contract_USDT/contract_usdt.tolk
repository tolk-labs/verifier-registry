import "@contracts/common-messages"
import "@contracts/errors"
import "@contracts/contract_USDT/usdt-utils"
import "fees-management"
import "messages"
import "storage"

contract ContractUSDT {
    author: "Alexandr_K"
    version: "0.0.4"
    description: "Escrow contract USDT"
    storage: StorageUsdt
    incomingMessages: AllowedMessage
}

type AllowedMessage =
    | TransferNotificationForRecipient
    | ChangePercent
    | AcceptPercent
    | RefundUsdt
    | ErrRefund
    | ErrMode
    | BurnContract

type BounceOpToHandle = TransferBounce

// The contract is active when both parties have deposited the init amounts and the deal is not completed
fun StorageUsdt.isActive(self, extra: ExtraFieldsUsdt): bool {
    if (extra.completed) {
        return false;
    }
    return self.clientAmount >= extra.clientAmountInit &&
        self.providerDeposit >= extra.providerDepositInit;
}

fun ExtraFieldsUsdt.allowsErrRefund(
    self,
    sender: address,
    client: address,
    provider: address,
): bool {
    if (sender == client) {
        if (self.errMode == ErrModeVal.ClientFullRights as int8) {
            return true;
        }
        return self.errMode == ErrModeVal.ClientFullRightsAfterHalfYear as int8 &&
            (blockchain.now() as uint64) >= self.errModeAt + HALF_YEAR;
    }
    if (sender == provider) {
        if (self.errMode == ErrModeVal.ProviderFullRights as int8) {
            return true;
        }
        return self.errMode == ErrModeVal.ProviderFullRightsAfterHalfYear as int8 &&
            (blockchain.now() as uint64) >= self.errModeAt + HALF_YEAR;
    }
    return false;
}

fun ExtraFieldsUsdt.deployerAddress(self, client: address, provider: address): address {
    if (self.mode == QueryRole.Client as int8) {
        return client;
    }
    assert (self.mode == QueryRole.Provider as int8) throw Errors.UnauthorizedSender;
    return provider;
}

fun sendExcessesTon(to: address, amount: coins) {
    if (amount > MIN_MESSAGE_VALUE_BOUND) {
        val excessesMsg = createMessage({
            bounce: BounceMode.NoBounce,
            dest: to,
            value: amount,
        });
        excessesMsg.send(SEND_MODE_IGNORE_ERRORS);
    }
}

fun contractUsdtWallet(): address {
    return calcAddressOfJettonWallet(contract.getAddress());
}

fun sendAskToTransferUsdt(
    queryId: uint64,
    jettonAmount: coins,
    transferRecipient: address,
    attachedTon: coins,
) {
    val transferMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: contractUsdtWallet(),
        value: attachedTon,
        body: AskToTransfer {
            queryId,
            jettonAmount,
            transferRecipient,
            sendExcessesTo: transferRecipient,
            customPayload: null,
            forwardTonAmount: MIN_FORWARD_TON_AMOUNT,
            forwardPayload: beginCell().storeUint(0, 1).endCell().beginParse(),
        },
    });
    transferMsg.send(SEND_MODE_REGULAR);
}

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();

    val msg = lazy BounceOpToHandle.fromSlice(in.bouncedBody);
    var storage = lazy StorageUsdt.load();

    match (msg) {
        TransferBounce => {
            if (msg.queryId == QueryRole.Client as uint64) {
                storage.clientAmount += msg.jettonAmount;
            } else if (msg.queryId == QueryRole.Provider as uint64) {
                storage.providerDeposit += msg.jettonAmount;
            } else if (msg.queryId == QueryRole.Admin as uint64) {
                var extra: ExtraFieldsUsdt = lazy storage.extra.load();
                extra.royaltyInit += msg.jettonAmount;
                storage.extra = extra.toCell();
            } else {
                // ErrRefund (QueryRole.None) and unknown ids: accounting was not decremented
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
    var storage: StorageUsdt = lazy StorageUsdt.load();

    val tonBalanceBeforeMsg = contract.getOriginalBalance() - in.valueCoins;
    val storageFee = MIN_TONS_FOR_STORAGE_THIS_CONTRACT -
        min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE_THIS_CONTRACT);
    var msgValue = in.valueCoins - storageFee - CONTRACT_GAS_CONSUMPTION;

    match (msg) {
        TransferNotificationForRecipient => {
            assert (in.senderAddress == contractUsdtWallet()) throw Errors.InvalidWallet;
            assert (msg.transferInitiator != null) throw Errors.MissingInitiator;

            if (msg.transferInitiator == storage.clientAddress) {
                storage.clientAmount += msg.jettonAmount;
                storage.save();
            } else if (msg.transferInitiator == storage.providerAddress) {
                storage.providerDeposit += msg.jettonAmount;
                storage.save();
            }

            sendExcessesTon(msg.transferInitiator, msgValue);
        }

        // Also: client approval (100%) / termination (0%) via ChangePercent

        ChangePercent => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            assert (in.senderAddress == storage.clientAddress) throw Errors.UnauthorizedSender;
            assert (msg.percent >= 0 && msg.percent <= 100) throw Errors.WrongPercent;
            var extra: ExtraFieldsUsdt = lazy storage.extra.load();
            assert (extra.completed == false) throw Errors.ContractIsCompleted;
            assert (storage.isActive(extra)) throw Errors.ContractIsNotActive;

            extra.percent = msg.percent;
            // 100% = client immediately closes the deal in favor of the provider
            if (msg.percent == 100) {
                extra.completed = true;
                storage.providerDeposit += extra.clientAmountInit - extra.royaltyInit;
                storage.clientAmount -= extra.clientAmountInit;
            }
            storage.extra = extra.toCell();
            storage.save();

            sendExcessesTon(in.senderAddress, msgValue);
        }

        AcceptPercent => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            assert (in.senderAddress == storage.providerAddress) throw Errors.UnauthorizedSender;
            var extra: ExtraFieldsUsdt = lazy storage.extra.load();
            assert (extra.completed == false) throw Errors.ContractIsCompleted;
            // percent == 100 in init / after ChangePercent(100) = already completed or not offered
            assert (extra.percent != 100) throw Errors.PercentNotOffered;
            assert (msg.percent == extra.percent) throw Errors.PercentMismatch;

            extra.completed = true;
            val percentValue = extra.clientAmountInit / 100 * msg.percent;

            // When royalty is 0%, it is reset (termination without platform commission)
            if (msg.percent == 0) {
                extra.royaltyInit = 0;
            }

            storage.providerDeposit += percentValue - extra.royaltyInit;
            storage.clientAmount -= percentValue;
            storage.extra = extra.toCell();
            storage.save();

            sendExcessesTon(in.senderAddress, msgValue);
        }

        RefundUsdt => {
            msgValue -= (MIN_MESSAGE_VALUE_BOUND + MIN_FORWARD_TON_AMOUNT);
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            assert (msg.jettonAmount > 0) throw Errors.ZeroAmount;
            var extra: ExtraFieldsUsdt = lazy storage.extra.load();

            val transferRecipient: address = msg.addressRefund != null
                ? msg.addressRefund
                : in.senderAddress;

            val isActive = storage.isActive(extra);
            var queryId: uint64;
            var jettonAmount: coins;

            if (in.senderAddress == storage.clientAddress) {
                queryId = QueryRole.Client;
                if (isActive) {
                    // While the deal is active, the client cannot withdraw the initial amount plus 30% of the deposit
                    val deposit: uint72 = (extra.clientAmountInit / 100) * 30;
                    val locked = extra.clientAmountInit + deposit;
                    assert (storage.clientAmount > locked) throw Errors.NotEnoughJettons;
                    jettonAmount = min(storage.clientAmount - locked, msg.jettonAmount);
                } else {
                    jettonAmount = min(storage.clientAmount, msg.jettonAmount);
                }
                storage.clientAmount -= jettonAmount;
            } else if (in.senderAddress == storage.providerAddress) {
                queryId = QueryRole.Provider;
                if (isActive) {
                    assert (
                        storage.providerDeposit > extra.providerDepositInit
                    ) throw Errors.NotEnoughJettons;
                    jettonAmount = min(
                        storage.providerDeposit - extra.providerDepositInit,
                        msg.jettonAmount,
                    );
                } else {
                    jettonAmount = min(storage.providerDeposit, msg.jettonAmount);
                }
                storage.providerDeposit -= jettonAmount;
            } else if (in.senderAddress == extra.adminAddress) {
                queryId = QueryRole.Admin;
                val maxRefundUsdt: uint72 = extra.completed ? extra.royaltyInit : 0;
                jettonAmount = min(maxRefundUsdt, msg.jettonAmount);
                extra.royaltyInit -= jettonAmount;
                storage.extra = extra.toCell();
            } else {
                throw Errors.UnauthorizedSender;
            }

            assert (jettonAmount > 0) throw Errors.NotEnoughJettons;

            // First, save the state — bounce onBouncedMessage will credit the same QueryRole
            storage.save();

            sendAskToTransferUsdt(
                queryId,
                jettonAmount,
                transferRecipient,
                msgValue + MIN_MESSAGE_VALUE_BOUND + MIN_FORWARD_TON_AMOUNT,
            );
        }

        ErrMode => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            var extra: ExtraFieldsUsdt = lazy storage.extra.load();
            // Notice only when AfterHalfYear is actually armed. FullRights and Block stay silent.
            var noticeTo: address? = null;
            var noticeAboutClient: bool = false;
            if (in.senderAddress == storage.clientAddress) {
                if (msg.value == ErrModeVal.ProviderFullRights as int8) {
                    extra.errMode = ErrModeVal.ProviderFullRights;
                } else if (msg.value == ErrModeVal.BlockErrorMode as int8) {
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
            } else if (in.senderAddress == storage.providerAddress) {
                if (msg.value == ErrModeVal.ClientFullRights as int8) {
                    extra.errMode = ErrModeVal.ClientFullRights;
                } else if (msg.value == ErrModeVal.BlockErrorMode as int8) {
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
            } else {
                throw Errors.UnauthorizedSender;
            }
            if (noticeTo != null) {
                assert (msgValue > HALF_YEAR_NOTICE_VALUE) throw Errors.ValueTooSmall;
                msgValue -= HALF_YEAR_NOTICE_VALUE;
            }
            storage.extra = extra.toCell();
            storage.save();
            if (noticeTo != null) {
                sendHalfYearControlNotice(noticeTo, noticeAboutClient);
            }

            sendExcessesTon(in.senderAddress, msgValue);
        }

        ErrRefund => {
            msgValue -= (MIN_MESSAGE_VALUE_BOUND + MIN_FORWARD_TON_AMOUNT);
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            assert (msg.jettonAmount > 0) throw Errors.ZeroAmount;
            val extra: ExtraFieldsUsdt = lazy storage.extra.load();

            if (
                !extra.allowsErrRefund(
                    in.senderAddress,
                    storage.clientAddress,
                    storage.providerAddress,
                )
            ) {
                throw Errors.UnauthorizedSender;
            }

            val transferRecipient: address = msg.addressRefund != null
                ? msg.addressRefund
                : in.senderAddress;

            // No storage.save(): booked balances stay as they are.
            // Outgoing AskToTransfer uses QueryRole.None so bounce does not credit.
            sendAskToTransferUsdt(
                QueryRole.None,
                msg.jettonAmount as coins,
                transferRecipient,
                msgValue + MIN_MESSAGE_VALUE_BOUND + MIN_FORWARD_TON_AMOUNT,
            );
        }

        BurnContract => {
            assert (msgValue > 0) throw Errors.NotEnoughGas;
            val extra: ExtraFieldsUsdt = lazy storage.extra.load();
            val deployer = extra.deployerAddress(storage.clientAddress, storage.providerAddress);
            assert (
                in.senderAddress == deployer || in.senderAddress == extra.adminAddress
            ) throw Errors.UnauthorizedSender;
            assert (
                storage.clientAmount == 0 && storage.providerDeposit == 0
            ) throw Errors.BalancesNotEmpty;

            if (extra.completed && extra.royaltyInit > 0) {
                val jettonTon = MIN_MESSAGE_VALUE_BOUND + MIN_FORWARD_TON_AMOUNT;
                msgValue -= jettonTon;
                assert (msgValue > 0) throw Errors.NotEnoughGas;
                sendAskToTransferUsdt(
                    QueryRole.Admin,
                    extra.royaltyInit as coins,
                    extra.adminAddress,
                    msgValue + jettonTon,
                );
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
    clientAmount: uint72
    providerDeposit: uint72
    timestamp: uint64
    clientAmountInit: uint72
    providerDepositInit: uint72
    royaltyInit: uint72
    adminAddress: address
    completed: bool
    percent: int8
    errMode: int8
    errModeAt: uint64
    mode: int8
    isActive: bool
}

get fun getContractData(): ContractDataReply {
    val storage = lazy StorageUsdt.load();
    val extra: ExtraFieldsUsdt = lazy storage.extra.load();
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
