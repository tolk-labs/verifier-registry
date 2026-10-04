import "@gen/BondingCurveV2.code"

import "@gen/JettonMinterV2.code"
import "bonding-math"
import "bonding-messages"
import "bonding-storage"
import "../v1/bonding-config"
import "../v1/errors"
import "../v1/messages"
import "../v1/sharding"
import "../v1/storage"

contract BondingCurveMasterV2 {
    author: "bonding-curve-contracts"
    version: "2.0.0"
    description: "Factory for bonding-curve launchpads on TON"
    storage: MasterStorage
    incomingMessages: AllowedMessageToMaster
}

type AllowedMessageToMaster =
    | CreateLaunch
    | ConfirmLaunch
    | CancelLaunchFees
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
    options: Cell<LaunchOptions>,
): AutoDeployAddress {
    val config: LaunchConfig = {
        master,
        creator,
        salt,
        curveSupply: options.load().supply * 9 / 10,
        dexReserveSupply: options.load().supply / 10,
        graduationThreshold: options.load().graduationThreshold,
        options,
    };
    val initStorage: BondingCurveStorage = {
        state: CURVE_STATE_INITIALIZING,
        jettonMinter: null,
        virtualTonReserve: initialVirtualReserve(options.load()),
        realTonReserve: 0,
        curveJettonBalance: 0,
        feeAccrued: 0,
        migrationReserve: 0,
        config: config.toCell(),
        dropAdminPending: false,
        pendingBuyTonInNet: 0,
        progress: LaunchProgress {
            protocolTreasury: null,
            curveReceived: false,
            devReceived: false,
            devTokens: 0,
            creatorAccrued: 0,
        }.toCell(),
    };
    return {
        workchain: MY_WORKCHAIN,
        stateInit: { code: bondingCurveV2CompiledCode(), data: initStorage.toCell() },
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
        stateInit: { code: jettonMinterV2CompiledCode(), data: initStorage.toCell() },
    };
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToMaster.fromSlice(in.body);

    match (msg) {
        CreateLaunch => {
            val options = msg.options.load();
            validateLaunchOptions(options);
            assert (in.senderAddress.getWorkchain() == MY_WORKCHAIN) throw Errors.WrongWorkchain;
            assert (in.valueCoins >= options.devBuyAmount + ton("1")) throw Errors.NotEnoughGas;
            if (options.devBuyAmount > 0) {
                val (devTokens, _) = computeBuyOut(
                    options.devBuyAmount,
                    initialVirtualReserve(options),
                    0,
                    options.supply,
                    options.creatorFeeBps,
                );
                assert (
                    devTokens > 0 && devTokens >= options.minDevTokens
                ) throw Errors.InvalidMessage;
            }

            var storage = lazy MasterStorage.load();
            assert (storage.treasury.getWorkchain() == MY_WORKCHAIN) throw Errors.WrongWorkchain;

            val curveAuto = calcDeployedBondingCurve(
                contract.getAddress(),
                in.senderAddress,
                msg.salt,
                msg.options,
            );
            val curveAddr = curveAuto.calculateAddress();
            val (_, launchKey) = curveAddr.getWorkchainAndHash();
            assert (!storage.launches.exists(launchKey)) throw Errors.InvalidOp;
            storage.launches.set(launchKey, 0);
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
                protocolTreasury: storage.treasury,
            };
            val deployCurveMsg = createMessage({
                bounce: BounceMode.RichBounceOnlyRootCell,
                dest: curveAuto,
                value: curveDeployValue,
                body: initBody,
            });
            deployCurveMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

            storage.totalLaunches += 1;
            storage.save();

            val launchEventMsg = createExternalLogMessage({
                dest: ExtOutLogBucket { topic: TOPIC_LAUNCH_CREATED },
                body: LaunchCreatedEvent {
                    creator: in.senderAddress,
                    salt: msg.salt,
                    curveAddress: curveAddr,
                    minterAddress: minterAddr,
                    virtualTonReserve: initialVirtualReserve(options),
                },
            });
            launchEventMsg.send(SEND_MODE_REGULAR);
        }

        ConfirmLaunch => {
            var storage = MasterStorage.load();
            val curve = calcDeployedBondingCurve(
                contract.getAddress(),
                msg.creator,
                msg.salt,
                msg.options,
            ).calculateAddress();
            assert (in.senderAddress == curve) throw Errors.NotOwner;
            val (_, key) = curve.getWorkchainAndHash();
            val launch = storage.launches.get(key);
            if (launch.isFound && launch.loadValue() == 0) {
                storage.launches.set(key, 1);
                storage.feesBalance += CREATE_LAUNCH_FEE;
                storage.save();
            }
        }

        CancelLaunchFees => {
            var storage = MasterStorage.load();
            val curve = calcDeployedBondingCurve(
                contract.getAddress(),
                msg.creator,
                msg.salt,
                msg.options,
            ).calculateAddress();
            assert (in.senderAddress == curve) throw Errors.NotOwner;
            val (_, key) = curve.getWorkchainAndHash();
            val launch = storage.launches.get(key);
            if (launch.isFound && launch.loadValue() == 0) {
                storage.launches.set(key, 2);
                storage.totalLaunches -= 1;
                storage.save();
                createMessage({
                    bounce: false,
                    dest: msg.creator,
                    value: CREATE_LAUNCH_FEE,
                    body: ReturnExcessesBack { queryId: msg.queryId },
                }).send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
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
            assert (msg.newTreasury.getWorkchain() == MY_WORKCHAIN) throw Errors.WrongWorkchain;
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
                msg.options,
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
            assert (storage.treasury.getWorkchain() == MY_WORKCHAIN) throw Errors.WrongWorkchain;
            assert (in.valueCoins > ton("0.5")) throw Errors.NotEnoughGas;

            val curveAuto = calcDeployedBondingCurve(
                contract.getAddress(),
                msg.creator,
                msg.salt,
                msg.options,
            );
            val curveAddr = curveAuto.calculateAddress();
            val minterAuto = calcDeployedJettonMinter(curveAddr, msg.metadata);
            val minterAddr = minterAuto.calculateAddress();

            val initBody: InitializeCurve = {
                queryId: msg.queryId,
                jettonMinter: minterAddr,
                refundTo: null,
                protocolTreasury: storage.treasury,
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
                val (_, key) = in.senderAddress.getWorkchainAndHash();
                val launch = storage.launches.get(key);
                if (!launch.isFound || launch.loadValue() != 0) {
                    return;
                }
                storage.launches.set(key, 2);

                val refundAmount = in.valueCoins + CREATE_LAUNCH_FEE;
                val balanceAfter = contract.getOriginalBalance() - refundAmount;
                val refundCanSend = balanceAfter > MASTER_STORAGE_RESERVE;

                if (storage.totalLaunches > 0) {
                    storage.totalLaunches -= 1;
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

get fun get_launch_address(creator: address, salt: uint64, options: Cell<LaunchOptions>): address {
    return calcDeployedBondingCurve(
        contract.getAddress(),
        creator,
        salt,
        options,
    ).calculateAddress();
}

get fun get_storage_reserve(): coins {
    return MASTER_STORAGE_RESERVE;
}

get fun get_launch_preview(options: Cell<LaunchOptions>): LaunchPreview {
    return previewLaunch(options.load());
}

get fun get_version(): int {
    return 0x020000;
}
