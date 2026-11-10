import "@gen/BondingCurve.code"

import "@gen/JettonMinter.code"
import "bonding-config"
import "bonding-messages"
import "bonding-storage"
import "errors"
import "messages"
import "sharding"
import "storage"

contract BondingCurveMaster {
    author: "bonding-curve-contracts"
    version: "1.0.0"
    description: "Factory for bonding-curve launchpads on TON"
    storage: MasterStorage
    incomingMessages: AllowedMessageToMaster
}

type AllowedMessageToMaster =
    | CreateLaunch
    | ChangeMasterAdmin
    | ClaimMasterAdmin
    | ChangeTreasury
    | WithdrawProtocolFees
    | DepositProtocolFees
    | ReinitializeCurve
    | TopUpTons

type BounceableMasterOps = TreasuryPayout | InitializeCurve

const MASTER_STORAGE_RESERVE: coins = ton("0.05")

fun assertSenderIsAdmin(senderAddress: address, adminAddress: address) {
    assert (senderAddress == adminAddress) throw Errors.NotOwner;
}

fun calcDeployedBondingCurve(
    master: address,
    creator: address,
    salt: uint64,
): AutoDeployAddress {
    val config: LaunchConfig = {
        master,
        creator,
        salt,
        curveSupply: CURVE_SUPPLY,
        dexReserveSupply: DEX_RESERVE_SUPPLY,
        graduationThreshold: GRADUATION_THRESHOLD_TON,
    };
    val initStorage: BondingCurveStorage = {
        state: CURVE_STATE_INITIALIZING,
        jettonMinter: null,
        virtualTonReserve: VIRTUAL_TON_RESERVE_INIT,
        realTonReserve: 0,
        curveJettonBalance: 0,
        feeAccrued: 0,
        migrationReserve: 0,
        config: config.toCell(),
        dropAdminPending: false,
        pendingBuyTonInNet: 0,
    };
    return {
        workchain: MY_WORKCHAIN,
        stateInit: { code: bondingCurveCompiledCode(), data: initStorage.toCell() },
    };
}

fun calcDeployedJettonMinter(
    admin: address,
    metadata: cell,
): AutoDeployAddress {
    val initStorage: MinterStorage = {
        totalSupply: 0,
        adminAddress: admin,
        nextAdminAddress: null,
        metadata,
    };
    return {
        workchain: MY_WORKCHAIN,
        stateInit: { code: jettonMinterCompiledCode(), data: initStorage.toCell() },
    };
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToMaster.fromSlice(in.body);

    match (msg) {
        CreateLaunch => {
            assert (in.valueCoins >= MIN_CREATE_LAUNCH_VALUE) throw Errors.NotEnoughGas;

            var storage = lazy MasterStorage.load();

            val curveAuto = calcDeployedBondingCurve(
                contract.getAddress(),
                in.senderAddress,
                msg.salt,
            );
            val curveAddr = curveAuto.calculateAddress();
            val minterAuto = calcDeployedJettonMinter(curveAddr, msg.metadata);
            val minterAddr = minterAuto.calculateAddress();

            val minterDeployValue = ton("0.03");
            val deployMinterMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: minterAuto,
                value: minterDeployValue,
                body: TopUpTons {},
            });
            deployMinterMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

            val curveDeployValue = in.valueCoins - minterDeployValue - CREATE_LAUNCH_FEE;

            val initBody: InitializeCurve = {
                queryId: msg.queryId,
                jettonMinter: minterAddr,
                refundTo: in.senderAddress,
            };
            val deployCurveMsg = createMessage({
                bounce: BounceMode.RichBounceOnlyRootCell,
                dest: curveAuto,
                value: curveDeployValue,
                body: initBody,
            });
            deployCurveMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

            storage.totalLaunches += 1;
            storage.feesBalance += CREATE_LAUNCH_FEE;
            storage.save();

            val launchEventMsg = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: TOPIC_LAUNCH_CREATED },
                body: LaunchCreatedEvent {
                    creator: in.senderAddress,
                    salt: msg.salt,
                    curveAddress: curveAddr,
                    minterAddress: minterAddr,
                    virtualTonReserve: VIRTUAL_TON_RESERVE_INIT,
                },
            });
            launchEventMsg.send(SEND_MODE_REGULAR);
        }

        ChangeMasterAdmin => {
            var storage = lazy MasterStorage.load();
            assertSenderIsAdmin(in.senderAddress, storage.admin);
            storage.nextAdmin = msg.newAdmin;
            storage.save();
        }

        ClaimMasterAdmin => {
            var storage = lazy MasterStorage.load();
            assert (storage.nextAdmin != null) throw Errors.NotOwner;
            assert (in.senderAddress == storage.nextAdmin!) throw Errors.NotOwner;
            storage.admin = storage.nextAdmin!;
            storage.nextAdmin = null;
            storage.save();
        }

        ChangeTreasury => {
            var storage = lazy MasterStorage.load();
            assertSenderIsAdmin(in.senderAddress, storage.admin);
            storage.treasury = msg.newTreasury;
            storage.save();
        }

        WithdrawProtocolFees => {
            var storage = lazy MasterStorage.load();
            assertSenderIsAdmin(in.senderAddress, storage.admin);
            assert (msg.amount > 0) throw Errors.InvalidMessage;
            assert (storage.feesBalance >= msg.amount) throw Errors.BalanceError;

            assert (
                contract.getOriginalBalance() >= msg.amount + MASTER_STORAGE_RESERVE
            ) throw Errors.NotEnoughGas;

            storage.feesBalance -= msg.amount;
            storage.save();

            val payoutMsg = createMessage({
                bounce: BounceMode.RichBounceOnlyRootCell,
                dest: storage.treasury,
                value: msg.amount,
                body: TreasuryPayout {
                    queryId: msg.queryId,
                    amount: msg.amount,
                },
            });
            payoutMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        DepositProtocolFees => {
            val expectedCurve = calcDeployedBondingCurve(
                contract.getAddress(),
                msg.creator,
                msg.salt,
            ).calculateAddress();
            assert (in.senderAddress == expectedCurve) throw Errors.NotValidWallet;

            assert (in.valueCoins >= msg.amount) throw Errors.BalanceError;

            var storage = lazy MasterStorage.load();
            storage.feesBalance += msg.amount;
            storage.save();
        }

        ReinitializeCurve => {
            val storage = lazy MasterStorage.load();
            assertSenderIsAdmin(in.senderAddress, storage.admin);
            assert (in.valueCoins > ton("0.5")) throw Errors.NotEnoughGas;

            val curveAuto = calcDeployedBondingCurve(
                contract.getAddress(),
                msg.creator,
                msg.salt,
            );
            val curveAddr = curveAuto.calculateAddress();
            val minterAuto = calcDeployedJettonMinter(curveAddr, msg.metadata);
            val minterAddr = minterAuto.calculateAddress();

            val initBody: InitializeCurve = {
                queryId: msg.queryId,
                jettonMinter: minterAddr,
                refundTo: null,
            };
            val reinitMsg = createMessage({
                bounce: BounceMode.RichBounceOnlyRootCell,
                dest: curveAddr,
                value: 0,
                body: initBody,
            });
            reinitMsg.send(
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }

        TopUpTons => {}

        else => {
            return;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    val rich = lazy RichBounceBody.fromSlice(in.bouncedBody);
    val origSlice = rich.originalBody.beginParse();
    val parsed = lazy BounceableMasterOps.fromSlice(origSlice);
    match (parsed) {
        TreasuryPayout => {
            var storage = lazy MasterStorage.load();
            storage.feesBalance += parsed.amount;
            storage.save();
        }
        InitializeCurve => {
            if (parsed.refundTo != null) {
                var storage = lazy MasterStorage.load();

                val refundAmount = in.valueCoins + CREATE_LAUNCH_FEE;
                val balanceAfter = contract.getOriginalBalance() - refundAmount;
                val refundCanSend = balanceAfter > MASTER_STORAGE_RESERVE;

                if (storage.totalLaunches > 0) {
                    storage.totalLaunches -= 1;
                }
                if (refundCanSend) {
                    if (storage.feesBalance >= CREATE_LAUNCH_FEE) {
                        storage.feesBalance -= CREATE_LAUNCH_FEE;
                    }
                }

                storage.save();

                val rollbackEvent = createExternalLogMessage({
                    dest: ExtOutLogBucket { topic: TOPIC_LAUNCH_ROLLED_BACK },
                    body: LaunchRolledBackEvent {
                        refundTo: parsed.refundTo!,
                        curveAddress: in.senderAddress,
                        refundSent: refundCanSend,
                        refundAmount: refundCanSend ? refundAmount : 0 as coins,
                    },
                });
                rollbackEvent.send(SEND_MODE_REGULAR);

                if (refundCanSend) {
                    val refundMsg = createMessage({
                        bounce: BounceMode.NoBounce,
                        dest: parsed.refundTo!,
                        value: refundAmount,
                        body: ReturnExcessesBack { queryId: parsed.queryId },
                    });
                    refundMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
                }
            }
        }
        else => {}
    }
}

get fun get_master_data(): MasterDataReply {
    val storage = lazy MasterStorage.load();
    return {
        admin: storage.admin,
        nextAdmin: storage.nextAdmin,
        treasury: storage.treasury,
        totalLaunches: storage.totalLaunches,
        feesBalance: storage.feesBalance,
    };
}

get fun get_launch_address(creator: address, salt: uint64): address {
    return calcDeployedBondingCurve(contract.getAddress(), creator, salt).calculateAddress();
}

get fun get_storage_reserve(): coins {
    return MASTER_STORAGE_RESERVE;
}

get fun get_version(): int {
    return 0x010000;
}
