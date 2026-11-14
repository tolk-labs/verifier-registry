import "@gen/OtcOrder.code"
import "otc-constants"
import "otc-errors"
import "otc-messages"
import "otc-storage"

contract OtcFactory {
    author: "GroypFi"
    version: "2.0.0"
    description: "GroypFi OTC desk factory: deploys isolated sell orders; admin can only pause new orders or raise the cap"
    storage: FactoryStorage
    incomingMessages: AllowedMessageToFactory
}

type AllowedMessageToFactory =
    | CreateOrder
    | SetPaused
    | RaiseCap
    | ProposeAdmin
    | ClaimAdmin

fun orderStateInit(maker: address, nonce: uint64): AutoDeployAddress {
    return {
        stateInit: {
            code: otcOrderCompiledCode(),
            data: initialOrderStorage(contract.getAddress(), maker, nonce).toCell(),
        },
    };
}

fun onBouncedMessage(_in: InMessageBounced) {
    // InitOrder never throws for the factory, so nothing bounces back here.
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToFactory.fromSlice(in.body);

    match (msg) {
        CreateOrder => {
            val storage = lazy FactoryStorage.load();
            assert (!storage.paused) throw OtcErrors.Paused;
            assert (in.valueCoins >= CREATE_VALUE) throw OtcErrors.NotEnoughValue;
            assert (in.senderAddress.getWorkchain() == BASECHAIN) throw OtcErrors.WrongWorkchain;

            val req = msg.request.load();
            assert (req.jettonMaster.getWorkchain() == BASECHAIN) throw OtcErrors.WrongWorkchain;
            if (req.privateTaker != null) {
                assert (req.privateTaker!.getWorkchain() == BASECHAIN) throw OtcErrors.WrongWorkchain;
            }
            assert (req.amountTotal > 0) throw OtcErrors.BadAmount;
            assert (req.minFill > 0 && req.minFill <= req.amountTotal) throw OtcErrors.BadAmount;
            assert (req.totalPrice >= MIN_ORDER_PRICE) throw OtcErrors.BelowMinPrice;
            assert (req.totalPrice <= storage.maxOrderNano) throw OtcErrors.AboveCap;

            val deploy = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: orderStateInit(in.senderAddress, msg.nonce),
                value: 0,
                body: InitOrder {
                    queryId: msg.queryId,
                    feeWallet: storage.feeWallet,
                    request: msg.request,
                },
            });
            deploy.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        SetPaused => {
            var storage = lazy FactoryStorage.load();
            assert (in.senderAddress == storage.admin) throw OtcErrors.NotAdmin;
            storage.paused = msg.paused;
            storage.save();
        }

        RaiseCap => {
            var storage = lazy FactoryStorage.load();
            assert (in.senderAddress == storage.admin) throw OtcErrors.NotAdmin;
            assert (msg.newMaxOrderNano > storage.maxOrderNano) throw OtcErrors.CapCanOnlyRise;
            storage.maxOrderNano = msg.newMaxOrderNano;
            storage.save();
        }

        ProposeAdmin => {
            var storage = lazy FactoryStorage.load();
            assert (in.senderAddress == storage.admin) throw OtcErrors.NotAdmin;
            storage.pendingAdmin = msg.newAdmin;
            storage.save();
        }

        ClaimAdmin => {
            var storage = lazy FactoryStorage.load();
            assert (storage.pendingAdmin != null) throw OtcErrors.NotAdmin;
            assert (in.senderAddress == storage.pendingAdmin!) throw OtcErrors.NotAdmin;
            storage.admin = storage.pendingAdmin!;
            storage.pendingAdmin = null;
            storage.save();
        }

        else => {
            assert (in.body.isEmpty()) throw OtcErrors.UnknownOp;
        }
    }
}

get fun get_factory_data(): FactoryStorage {
    return FactoryStorage.load();
}

get fun get_order_address(maker: address, nonce: int): address {
    return orderStateInit(maker, nonce).calculateAddress();
}

get fun get_order_code_hash(): int {
    return otcOrderCompiledCode().hash();
}
