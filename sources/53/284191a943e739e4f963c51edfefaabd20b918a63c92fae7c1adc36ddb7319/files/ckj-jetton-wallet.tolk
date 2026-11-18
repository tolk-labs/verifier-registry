tolk 1.2

// CyberJoule (CKJ) jetton wallet (TEP-74): holds one owner's balance, sends and receives transfers, and
// burns, which is how tokens go back into the game through the minter.

const ERROR_UNAUTHORIZED: int = 705;
const ERROR_INSUFFICIENT_FUNDS: int = 706;
const ERROR_INSUFFICIENT_TON: int = 707;
const ERROR_INVALID_SENDER: int = 708;
const ERROR_ZERO_AMOUNT: int = 709;
const ERROR_WRONG_WORKCHAIN: int = 710;  // the destination is on another workchain
const ERROR_INVALID_DESTINATION: int = 711;  // the destination is addr_none
const ERROR_UNKNOWN_OP: int = 0xFFFF;

// What a wallet keeps for its storage and what handling a transfer costs it, as in the reference jetton
// wallet. Both are counted before anything is sent, so that no transfer fails once the balance has changed.
const MIN_TONS_FOR_STORAGE: int = ton("0.01");
const JETTON_WALLET_GAS_CONSUMPTION: int = ton("0.015");

struct Storage {
    balance: coins
    ownerAddress: address
    jettonMasterAddress: address  // the CKJ minter
    jettonWalletCode: cell      // this code, to derive other owners' wallets
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

// ============== Messages ==============

// TEP-74 transfer, from the owner
struct (0x0f8a7ea5) TransferMessage {
    queryId: uint64
    amount: coins
    destination: address        // the new owner of the tokens
    responseDestination: address  // where the change goes
    customPayload: cell?
    forwardTonAmount: coins     // GRAM sent to the new owner with the notification
    forwardPayload: cell?       // passed on in the notification
}

// TEP-74 internal_transfer, from another wallet or from the minter
struct (0x178d4519) InternalTransfer {
    queryId: uint64
    amount: coins
    fromAddress: address
    responseAddress: address
    forwardTonAmount: coins
    forwardPayload: cell?
}

// TEP-74 burn, from the owner
struct (0x595f07bc) BurnMessage {
    queryId: uint64
    amount: coins
    responseDestination: address  // where the change goes
    customPayload: cell?        // optional data for the game (the player's id)
}

// TEP-74 burn_notification, to the minter
struct (0x7bdd97de) BurnNotification {
    queryId: uint64
    amount: coins
    senderAddress: address
    responseDestination: address
    customPayload: cell?
}

// TEP-74 excesses: change returned
struct (0xd53276db) Excesses {
    queryId: uint64
}

// TEP-74 transfer_notification, to the new owner
struct (0x7362d09c) TransferNotification {
    queryId: uint64
    amount: coins
    sender: address
    forwardPayload: cell?
}

// Every message the wallet accepts
type WalletMessage = TransferMessage | InternalTransfer | BurnMessage;

// The two messages whose bounce gives the balance back
type BouncedMessage = InternalTransfer | BurnNotification;

// ============== Helpers ==============

// The data a jetton wallet is deployed with
fun createWalletData(
    ownerAddress: address,
    jettonMasterAddress: address,
    walletCode: cell
): cell {
    return beginCell()
        .storeCoins(0)  // a wallet starts empty: its address is that of its initial data
        .storeAddress(ownerAddress)
        .storeAddress(jettonMasterAddress)
        .storeRef(walletCode)
        .endCell();
}

fun getWalletDeployAddress(
    ownerAddress: address,
    jettonMasterAddress: address,
    walletCode: cell
): AutoDeployAddress {
    val walletData = createWalletData(ownerAddress, jettonMasterAddress, walletCode);
    return {
        stateInit: {
            code: walletCode,
            data: walletData
        }
    };
}

fun calculateWalletAddress(
    ownerAddress: address,
    jettonMasterAddress: address,
    walletCode: cell
): address {
    val deployAddr = getWalletDeployAddress(ownerAddress, jettonMasterAddress, walletCode);
    return deployAddr.calculateAddress();
}

// Tokens stay on the wallet's own workchain
fun checkSameWorkchain(addr: address) {
    val myWorkchain = contract.getAddress().getWorkchain();
    assert(addr.getWorkchain() == myWorkchain) throw ERROR_WRONG_WORKCHAIN;
}

// ============== Entry point ==============

fun onInternalMessage(in: InMessage) {
    // a plain transfer is accepted
    if (in.body.isEmpty()) {
        return;
    }

    val msg = lazy WalletMessage.fromSlice(in.body);
    var storage = lazy Storage.load();

    match (msg) {
        TransferMessage => {
            assert(in.senderAddress == storage.ownerAddress) throw ERROR_UNAUTHORIZED;

            // TEP-74 allows addr_none as the response destination, not as the destination
            assert(msg.destination != createAddressNone()) throw ERROR_INVALID_DESTINATION;

            checkSameWorkchain(msg.destination);

            assert(msg.amount > 0) throw ERROR_ZERO_AMOUNT;

            assert(storage.balance >= msg.amount) throw ERROR_INSUFFICIENT_FUNDS;

            // the balance goes down now; a bounce of the transfer gives it back
            storage.balance -= msg.amount;
            storage.save();

            // The value must pay for the whole chain, and this is checked here, where a failure still bounces: the
            // forward amount, the fees of the messages that follow, and the receiving wallet's gas and storage.

            // one message for the transfer, one more for the notification when there is a forward amount
            var forwardedMessagesCount = msg.forwardTonAmount > 0 ? 2 : 1;

            assert(in.valueCoins >
                msg.forwardTonAmount +
                forwardedMessagesCount * in.originalForwardFee +
                (2 * JETTON_WALLET_GAS_CONSUMPTION + MIN_TONS_FOR_STORAGE)
            ) throw ERROR_INSUFFICIENT_TON;

            val destWalletDeploy = getWalletDeployAddress(
                msg.destination,
                storage.jettonMasterAddress,
                storage.jettonWalletCode
            );

            val internalTransferMsg = InternalTransfer {
                queryId: msg.queryId,
                amount: msg.amount,
                fromAddress: storage.ownerAddress,
                responseAddress: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload
            };

            // Deploys the recipient's wallet if it does not exist yet. A bounce returns the start of the body, which
            // holds the amount to give back.
            createMessage({
                bounce: true,
                dest: destWalletDeploy,
                value: 0,
                body: internalTransferMsg
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        InternalTransfer => {
            // only the minter, or the jetton wallet of the owner the transfer names, can credit this wallet
            val expectedWallet = calculateWalletAddress(
                msg.fromAddress,
                storage.jettonMasterAddress,
                storage.jettonWalletCode
            );
            val isMinter = in.senderAddress == storage.jettonMasterAddress;
            val isValidWallet = in.senderAddress == expectedWallet;
            assert(isMinter || isValidWallet) throw ERROR_INVALID_SENDER;

            storage.balance += msg.amount;
            storage.save();

            // What can be passed on is worked out before anything is sent: a message that failed to send would not
            // bounce, and the tokens are already credited.

            var msgValue = in.valueCoins;
            var tonBalanceBeforeMsg = contract.getOriginalBalance() - msgValue;

            // the wallet tops its own balance up to MIN_TONS_FOR_STORAGE first
            var storageFee = MIN_TONS_FOR_STORAGE - min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE);

            msgValue -= (storageFee + JETTON_WALLET_GAS_CONSUMPTION);

            // TEP-74: the owner is notified when the transfer carries a forward amount
            if (msg.forwardTonAmount > 0) {
                msgValue -= (msg.forwardTonAmount + in.originalForwardFee);

                val notificationMsg = TransferNotification {
                    queryId: msg.queryId,
                    amount: msg.amount,
                    sender: msg.fromAddress,
                    forwardPayload: msg.forwardPayload
                };

                createMessage({
                    bounce: false,  // the owner may be an account that is not deployed
                    dest: storage.ownerAddress,
                    value: msg.forwardTonAmount,
                    body: notificationMsg
                }).send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            // the rest goes back as change
            if (msg.responseAddress != createAddressNone() && msgValue > 0) {
                val excessMsg = Excesses {
                    queryId: msg.queryId
                };

                createMessage({
                    bounce: false,
                    dest: msg.responseAddress,
                    value: msgValue,
                    body: excessMsg
                }).send(SEND_MODE_IGNORE_ERRORS);
            }
        }

        BurnMessage => {
            assert(in.senderAddress == storage.ownerAddress) throw ERROR_UNAUTHORIZED;

            assert(msg.amount > 0) throw ERROR_ZERO_AMOUNT;

            assert(storage.balance >= msg.amount) throw ERROR_INSUFFICIENT_FUNDS;

            storage.balance -= msg.amount;
            storage.save();

            // the minter takes the amount off the supply; should it refuse, the bounce gives the balance back
            val burnNotificationMsg = BurnNotification {
                queryId: msg.queryId,
                amount: msg.amount,
                senderAddress: storage.ownerAddress,
                responseDestination: msg.responseDestination,
                customPayload: msg.customPayload
            };

            createMessage({
                bounce: true,
                dest: storage.jettonMasterAddress,
                value: 0,
                body: burnNotificationMsg
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE + SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        else => {
            assert(in.body.isEmpty()) throw ERROR_UNKNOWN_OP;
        }
    }
}

// A transfer or a burn came back: the balance is restored
fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();

    val msg = lazy BouncedMessage.fromSlice(in.bouncedBody);

    // the amount is within the part of the body a bounce returns, in both messages
    val restoreAmount = match (msg) {
        InternalTransfer => msg.amount,
        BurnNotification => msg.amount,
    };

    var storage = lazy Storage.load();
    storage.balance += restoreAmount;
    storage.save();
}

// ============== Get methods ==============

// TEP-74: (balance, owner, jetton_master, jetton_wallet_code)
get fun get_wallet_data(): (coins, address, address, cell) {
    val storage = lazy Storage.load();
    return (
        storage.balance,
        storage.ownerAddress,
        storage.jettonMasterAddress,
        storage.jettonWalletCode
    );
}
