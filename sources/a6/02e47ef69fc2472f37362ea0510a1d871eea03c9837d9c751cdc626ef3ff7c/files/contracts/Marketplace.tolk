import "types"

// The single registry contract. A client creates an order with ONE transfer of
// USDT to the Marketplace, with the order's parameters (CreateOrder) in the
// forward payload. The Marketplace's USDT wallet reports it with a JettonNotify;
// the Marketplace then deploys a new Order and forwards the USDT to it. The
// native coin the client attaches as forwardTonAmount pays for all of it and
// becomes the order's fee buffer.
//
// Note on discovery: an order's address is the hash of its initial state, so
// only someone who knows that order's initial data can recompute its address.
// The frontend recomputes its OWN orders' addresses; a global feed needs a
// read-only TON indexer that reads the Marketplace's outgoing deploy messages.

// Lowest reward an order may carry: 1 USDT (6 decimals). A reward of 0 (or dust)
// creates an order no courier has any reason to accept: it just sits Open,
// clutters the Feed, and strands the client's create fee. The UI asks for
// $10..$1000; this is only the on-chain floor against spam.
const MIN_REWARD = 1000000

// The delivery time a client may pick (OrderStorage.deliveryTime): one day to
// two weeks. Outside that range the USDT goes back.
const MIN_DELIVERY_TIME = 24 * 60 * 60
const MAX_DELIVERY_TIME = 14 * 24 * 60 * 60

// Native coin the client must attach (as the transfer's forwardTonAmount) for an
// order to be created. The client attaches exactly the 0.1 create fee in total
// (the UI forwards 0.08 of it here); every network fee of the create comes out of
// it and ALL that is left ends up on the order as its fee buffer: half of it is
// the order's deploy value, the rest carries the USDT to the order's wallet, and
// the unused coin of that hop is sent to the order (responseDestination). Below
// this the USDT goes back.
//
// There is no fixed amount for either part: both are shares of what the client
// attached. Should the network ever raise its prices, the app attaches more and
// the contract, which can never change, keeps working.
const CREATE_MIN_VALUE = ton("0.05")

// Passed on to the order with the JettonNotify that turns it Open. Running that
// costs ~0.002 today. Should it ever not be enough, nothing is lost: the order
// stays Funding, the client cancels it for free and the USDT goes back.
const ORDER_NOTIFY_TON = ton("0.01")

// Gas for sending USDT back when an order cannot be created.
const REFUND_GAS = ton("0.05")

contract Marketplace {
    author: "SwiftDelivery"
    version: "1.0.0"
    description: "Registry that deploys Order escrow contracts for USDT rewards"
    storage: MarketplaceStorage
    incomingMessages: MarketplaceMessage
}

// A USDT wallet's initial state, Tether's stablecoin layout
// (ton-blockchain/stablecoin-contract, jetton-utils.fc). A wallet's address is
// the hash of this state, so this is how we know which address is the REAL
// wallet of a given owner. Checked off-chain against live USDT wallets on both
// networks before it went into the contract.
struct UsdtWalletStorage {
    status: uint4
    balance: coins
    owner: address
    master: address
}

fun calcUsdtWallet(owner: address, st: MarketplaceStorage): address {
    val data = UsdtWalletStorage {
        status: 0,
        balance: 0,
        owner,
        master: st.usdtMaster,
    };
    return AutoDeployAddress {
        stateInit: ContractState {
            code: st.jettonWalletCode,
            data: data.toCell(),
        },
    }.calculateAddress();
}

// The initial state of an order. The handler that deploys orders and the
// orderAddress getter share it, so the two can never disagree.
fun orderStateInit(
    st: MarketplaceStorage,
    client: address,
    reward: coins,
    p: CreateOrder,
): ContractState {
    val orderData = OrderStorage {
        client,
        courier: null,
        description: p.description,
        area: p.area,
        origin: p.origin,
        reward,
        status: OrderStatus.Funding,
        nonce: p.nonce,
        createdAt: p.createdAt,
        acceptedAt: 0, // set by Order when a courier accepts
        deliveryTime: p.deliveryTime,
        extra: (OrderExtra {
            owner: st.owner,
            clientContact: p.clientContact,
            courierContact: createEmptyCell(),
            secretHash: p.secretHash,
            referral: p.referral,
            jetton: (OrderJetton {
                marketplace: contract.getAddress(),
                wallet: null,
                acceptKey: p.acceptKey,
            }).toCell(),
        }).toCell(),
    };
    return ContractState {
        code: st.orderCode,
        data: orderData.toCell(),
    };
}

// The forward payload is TL-B `Either Cell ^Cell`. CreateOrder has four refs and
// up to ~940 bits, which never fits inline next to the notification's own fields, so
// only the ref form is valid. Throws on anything malformed; the caller catches.
fun parseCreateOrder(payload: RemainingBitsAndRefs): CreateOrder {
    var s = payload;
    assert (s.loadBool()) throw MarketplaceErrors.InvalidMessage;
    val ref = s.loadRef();
    s.assertEnd();
    return CreateOrder.fromCell(ref);
}

// Send the USDT back to whoever sent it. Paid from the coin that came with the
// notification when there is enough of it; otherwise from the Marketplace's own
// balance, but only for a real amount — dust that brought no gas is not worth
// our coin and stays where it is.
//
// The unused coin of the refund ("excesses") goes to whoever paid for it: the
// client when it was their coin, the Marketplace when it was ours. Were it the
// client either way, a loop of low-gas refunds would move the Marketplace's
// balance to them bit by bit — and once it is gone, an honest low-gas mistake
// could no longer be refunded.
fun refundUsdt(myWallet: address, to: address?, amount: coins, incoming: coins) {
    if (to == null) {
        return; // a mint straight to the Marketplace: nobody to send it back to
    }
    var value: coins = 0;
    var mode = SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE;
    var excessesTo = to!;
    if (incoming < REFUND_GAS) {
        if (amount < MIN_REWARD) {
            return;
        }
        value = REFUND_GAS;
        mode = SEND_MODE_PAY_FEES_SEPARATELY;
        excessesTo = contract.getAddress();
    }
    emitEvent(CreateRefused {
        client: to!,
        amount,
    });
    val transfer = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value,
        dest: myWallet,
        body: JettonTransfer {
            queryId: 0,
            amount,
            destination: to!,
            responseDestination: excessesTo,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayloadInRef: false,
        },
    });
    transfer.send(mode);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy MarketplaceMessage.fromSlice(in.body);

    match (msg) {
        JettonNotify => {
            var st = lazy MarketplaceStorage.load();
            // Anyone can send this opcode. Only our own USDT wallet's word
            // counts; a notification from any other contract (a fake or any
            // other jetton) is rejected and its tokens are none of our business.
            val myWallet = calcUsdtWallet(contract.getAddress(), st);
            assert (in.senderAddress == myWallet) throw MarketplaceErrors.NotJettonWallet;

            // Real USDT is now in our wallet. From here on NOTHING may throw:
            // this contract has no admin, so USDT stuck in its wallet would be
            // stuck forever. Every problem becomes a refund instead. The only
            // step that can fail is reading the payload, so that — and nothing
            // with side effects, TVM does not roll those back — goes in `try`.
            var order: CreateOrder? = null;
            try {
                order = parseCreateOrder(msg.forwardPayload);
            } catch (_e) {
                order = null;
            }
            // A referral outside the basechain is refused too. Every closing
            // path of an Order pays the referral without IGNORE_ERRORS, and a
            // message to a workchain that does not exist fails the whole
            // transaction — such an order could never close and its USDT would
            // be locked for good. Wallets live in the basechain, so a real
            // partner never needs anything else. A delivery time outside
            // 1..14 days is refused as well.
            if (
                order == null || msg.from == null || msg.amount < MIN_REWARD || in.valueCoins <
                CREATE_MIN_VALUE || (
                    order!.referral != null && order!.referral!.getWorkchain() != BASECHAIN
                ) || order!.deliveryTime < MIN_DELIVERY_TIME ||
                order!.deliveryTime > MAX_DELIVERY_TIME
            ) {
                refundUsdt(myWallet, msg.from, msg.amount, in.valueCoins);
                return;
            }

            val client = msg.from!;
            // orderCount is kept only as a running total / stat.
            st.orderCount = st.orderCount + 1;
            st.save();

            val stateInit = orderStateInit(st, client, msg.amount, order!);
            val orderAddress = AutoDeployAddress { stateInit }.calculateAddress();

            // 1. Deploy the order FIRST, and tell it which USDT wallet is its
            //    own. The order must exist before its wallet's notification
            //    (step 3) arrives: a notification is non-bounceable, so one that
            //    reaches a not-yet-deployed address is simply lost and the order
            //    would never turn Open. The deploy is one hop with the lower lt,
            //    the notification three hops later. Should it still be lost, the
            //    order stays Funding and the client cancels it for free (the USDT
            //    is in the order's wallet by then and goes straight back).
            //    Half of the attached coin, fees from the balance.
            val deployMsg = createMessage({
                bounce: BounceMode.NoBounce,
                value: in.valueCoins / 2,
                dest: AutoDeployAddress { stateInit },
                body: InitWallet { wallet: calcUsdtWallet(orderAddress, st) },
            });
            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

            // 2. Log the new order (before step 3 takes the whole balance that
            //    pays the emit's forward fee).
            emitEvent(OrderCreated {
                orderAddress,
                client,
                reward: msg.amount,
                area: order!.area,
            });

            // 3. Forward the reward to the order with ALL that is left of the
            //    coin this client attached. Our wallet moves the USDT into the
            //    order's wallet, which notifies the order (ORDER_NOTIFY_TON) and
            //    the order turns Open; the unused coin goes to the order too
            //    (responseDestination), so a big margin costs nobody anything.
            //    The margin matters: if our wallet ever refused the transfer for
            //    want of coin, the USDT would stay in it for good.
            //    The reserve keeps the Marketplace's own balance as it was before
            //    this message, so "all balance" is only the client's coin.
            reserveToncoinsOnBalance(
                contract.getOriginalBalance() - in.valueCoins,
                RESERVE_MODE_AT_MOST,
            );
            val forward = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                value: 0 as coins,
                dest: myWallet,
                body: JettonTransfer {
                    queryId: 0,
                    amount: msg.amount,
                    destination: orderAddress,
                    responseDestination: orderAddress,
                    customPayload: null,
                    forwardTonAmount: ORDER_NOTIFY_TON,
                    forwardPayloadInRef: false,
                },
            });
            // SAFETY: the reserve right above keeps the Marketplace's own
            // balance; what this sends is what is left of the client's coin, and
            // all of it ends up on their order.
            forward.send(SEND_MODE_CARRY_ALL_BALANCE);
        }
        Excesses => {
            // The unused coin of a refund the Marketplace paid for (see
            // refundUsdt). It is already on the balance; nothing else to do.
        }
        else => {
            // Empty body (a plain top-up) is accepted as a no-op.
            assert (in.body.isEmpty()) throw MarketplaceErrors.InvalidMessage;
        }
    }
}

// Our USDT transfers are bounceable; a bounce only returns native coin.
fun onBouncedMessage(_in: InMessageBounced) {}

// The contract version (major, minor, patch), same as `version` in the contract block.
get fun version(): (uint8, uint8, uint8) {
    return (1, 0, 0);
}

get fun orderCount(): uint32 {
    val st = lazy MarketplaceStorage.load();
    return st.orderCount;
}

// The platform owner (fee recipient). Set at deploy time and can never
// change — no message touches it, same as the Order code.
get fun owner(): address {
    val st = lazy MarketplaceStorage.load();
    return st.owner;
}

// Hash of the Order code the Marketplace deploys. The code is set at deploy
// time and can never change — no message touches it — so this getter lets
// ops / the frontend verify the frozen Order code hash against the
// published build.
get fun orderCodeHash(): uint256 {
    val st = lazy MarketplaceStorage.load();
    return st.orderCode.hash();
}

// The one jetton this Marketplace accepts, and the hash of its wallet code —
// to check a deploy against Tether's USDT master on the right network.
get fun usdtMaster(): address {
    val st = lazy MarketplaceStorage.load();
    return st.usdtMaster;
}

get fun jettonWalletCodeHash(): uint256 {
    val st = lazy MarketplaceStorage.load();
    return st.jettonWalletCode.hash();
}

// The USDT wallet of any owner, as this Marketplace computes it. The frontend
// uses it for the Marketplace's own wallet and for an order's wallet.
get fun usdtWalletOf(owner: address): address {
    val st = lazy MarketplaceStorage.load();
    return calcUsdtWallet(owner, st);
}

// Recompute the address of an order from its initial data. The frontend uses
// this for orders it created itself (it knows all the fields it sent). `reward`
// is in USDT base units.
get fun orderAddress(
    client: address,
    reward: coins,
    nonce: uint64,
    createdAt: uint32,
    deliveryTime: uint32,
    description: cell,
    area: cell,
    origin: cell,
    clientContact: cell,
    secretHash: uint256,
    acceptKey: uint256,
    referral: address?,
): address {
    val st = lazy MarketplaceStorage.load();
    val p = CreateOrder {
        nonce,
        createdAt,
        deliveryTime,
        description,
        area,
        origin,
        clientContact,
        secretHash,
        acceptKey,
        referral,
    };
    return AutoDeployAddress {
        stateInit: orderStateInit(st, client, reward, p),
    }.calculateAddress();
}
