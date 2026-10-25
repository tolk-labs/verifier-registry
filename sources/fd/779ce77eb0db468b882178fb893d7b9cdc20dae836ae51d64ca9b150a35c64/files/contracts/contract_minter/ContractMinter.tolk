import "@contracts/common-messages"
import "@contracts/errors"
import "@contracts/contract_minter/fees_management"
import "@contracts/contract_minter/messages"
import "@contracts/contract_minter/minter-utils"
import "@contracts/contract_minter/storage"

contract ContractMinter {
    author: "Alexandr_K"
    version: "0.0.5"
    description: "Escrow contract minter"
    storage: StorageMinter
    incomingMessages: AllowedMessageToMinter
}

type AllowedMessageToMinter =
    | CreateTonContract
    | CreateUsdtContract
    | WithdrawTon
    | UpdateCode

fun royaltyInitTon(clientAmountInit: uint75): uint75 {
    val royalty = clientAmountInit / 250;
    if (royalty > MAX_ROYALTY_INIT_TON) {
        return MAX_ROYALTY_INIT_TON;
    }
    return royalty;
}

fun royaltyInitUsdt(clientAmountInit: uint72): uint72 {
    val royalty = clientAmountInit / 250;
    if (royalty > MAX_ROYALTY_INIT_USDT) {
        return MAX_ROYALTY_INIT_USDT;
    }
    return royalty;
}

fun assertCreateData(clientAmountInit: int, providerDepositInit: int, minClientAmount: int) {
    assert (clientAmountInit >= minClientAmount) throw Errors.BelowMinimum;
    val providerPercent = providerDepositInit * 100 / clientAmountInit;
    assert (providerPercent >= 10 && providerPercent <= 90) throw Errors.WrongPercent;
}

fun onBouncedMessage(in: InMessageBounced) {
    val rich = lazy RichBounceBody.fromSlice(in.bouncedBody);
    val msg = lazy TransferRefund.fromCell(rich.originalBody);

    reserveGramsOnBalance(
        MIN_TONS_FOR_STORAGE_THIS_CONTRACT,
        RESERVE_MODE_EXACT_AMOUNT,
    );
    val refundMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: msg.sender,
        value: 0,
    });
    refundMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    val msg = lazy AllowedMessageToMinter.fromSlice(in.body);

    val tonBalanceBeforeMsg = contract.getOriginalBalance() - in.valueCoins;
    val storageFee = MIN_TONS_FOR_STORAGE_THIS_CONTRACT -
        min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE_THIS_CONTRACT);

    val msgValueRefaund = in.valueCoins - storageFee - CONTRACT_GAS_CONSUMPTION;
    assert (msgValueRefaund > 0) throw Errors.NotEnoughGas;

    val storage = lazy StorageMinter.load();

    val now = blockchain.now();

    match (msg) {
        CreateUsdtContract => {
            assert (
                in.senderAddress == msg.clientAddress || in.senderAddress == msg.providerAddress
            ) throw Errors.UnauthorizedSender;
            assert (msg.clientAddress != msg.providerAddress) throw Errors.PartiesAreEqual;
            assert (msgValueRefaund >= MIN_USDT_DEPLOY_VALUE) throw Errors.ValueTooSmall;
            assertCreateData(msg.clientAmountInit, msg.providerDepositInit, MIN_CLIENT_AMOUNT_USDT);

            val mode: int8 = in.senderAddress == msg.clientAddress
                ? QueryRole.Client as int8
                : QueryRole.Provider as int8;

            val deployUsdtAddress = calcDeployedUsdtContract(
                storage.contractUsdtCode,
                msg.clientAddress,
                msg.providerAddress,
                storage.adminAddress,
                msg.clientAmountInit,
                msg.providerDepositInit,
                royaltyInitUsdt(msg.clientAmountInit),
                now,
                mode,
            );

            val deployMsg = createMessage(
                {
                    bounce: BounceMode.NoBounce,
                    dest: deployUsdtAddress,
                    value: MIN_USDT_DEPLOY_VALUE,
                },
            );
            deployMsg.send(SEND_MODE_REGULAR);

            val excess = msgValueRefaund - MIN_USDT_DEPLOY_VALUE;
            if (excess > 0) {
                val excessesMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: in.senderAddress,
                    value: excess,
                });
                excessesMsg.send(SEND_MODE_IGNORE_ERRORS);
            }
        }

        CreateTonContract => {
            assert (
                in.senderAddress == msg.clientAddress || in.senderAddress == msg.providerAddress
            ) throw Errors.UnauthorizedSender;
            assert (msg.clientAddress != msg.providerAddress) throw Errors.PartiesAreEqual;
            assert (msgValueRefaund >= MIN_TON_DEPLOY_VALUE) throw Errors.ValueTooSmall;
            assertCreateData(msg.clientAmountInit, msg.providerDepositInit, MIN_CLIENT_AMOUNT_TON);

            val mode: int8 = in.senderAddress == msg.clientAddress
                ? QueryRole.Client as int8
                : QueryRole.Provider as int8;

            val deployMsg = createMessage(
                {
                    bounce: BounceMode.RichBounce,
                    dest: calcDeployedTonContract(
                        storage.contractTonCode,
                        msg.clientAddress,
                        msg.providerAddress,
                        storage.adminAddress,
                        msg.clientAmountInit,
                        msg.providerDepositInit,
                        royaltyInitTon(msg.clientAmountInit),
                        now,
                        mode,
                    ),
                    value: msgValueRefaund,
                    body: TransferRefund { sender: in.senderAddress },
                },
            );
            deployMsg.send(SEND_MODE_REGULAR);
        }

        WithdrawTon => {
            assert (in.senderAddress == storage.adminAddress) throw Errors.UnauthorizedSender;
            assert (msg.amount > 0) throw Errors.ZeroAmount;

            // We don't allow withdrawing the storage reserve.
            // Otherwise the contract will "freeze" on fees.
            reserveGramsOnBalance(
                MIN_TONS_FOR_STORAGE_THIS_CONTRACT,
                RESERVE_MODE_EXACT_AMOUNT,
            );

            val withdrawMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: msg.dest,
                value: msg.amount,
            });
            withdrawMsg.send(SEND_MODE_REGULAR);
        }

        UpdateCode => {
            assert (in.senderAddress == storage.adminAddress) throw Errors.UnauthorizedSender;
            assert (msg.newCode != null || msg.newData != null) throw Errors.EmptyCodeUpdate;
            if (msg.newData != null) {
                contract.setData(msg.newData);
            }
            if (msg.newCode != null) {
                contract.setCodePostponed(msg.newCode);
            }
        }
    }
}

/// Reads minter admin and the child escrow code cells used for deploys.
get fun getContractData(): StorageMinter {
    return StorageMinter.load();
}
