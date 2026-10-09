// decompiled by @fiscaldev
import "@stdlib/gas-payments"
import "compat-address"
import "deployment-message"
import "types"

@inline_ref
fun walletDeployment(code: cell, master: address, owner: address): AutoDeployAddress {
    return {
        workchain: 0,
        stateInit: {
            code,
            data: WalletStorage {
                balance: 0,
                owner,
                master,
            }.toCell(),
        },
        toShard: { fixedPrefixLength: 8, closeTo: owner },
    };
}

@inline
fun registerAddressVariants(value: ContractState | AddressShardingOptions): int {
    return (value is ContractState) ? 1 : 0;
}

fun onInternalMessage(in: InMessage) {
    val message = Incoming.fromSlice(in.body, { throwIfOpcodeDoesNotMatch: 65535 });
    match (message) {
        InternalTransfer => {
            var data = contract.getData().beginParse();
            val balance = data.loadCoins();
            val savedTail = data;
            val owner = data.loadAddress();
            val master = data.loadAddress();
            if (!(in.senderAddress == master)) {
                val peer = walletDeployment(contract.getCode(), master, message.from!);
                assert (peer.calculateArchivedAddress() == in.senderAddress) throw 25;
            }
            val updatedBalance = balance + message.amount;
            contract.setData(
                beginCell().storeCoins(updatedBalance).storeSlice(savedTail).endCell(),
            );
            if (message.forwardTon > 0) {
                val body = Notification {
                    queryId: message.queryId,
                    amount: message.amount,
                    from: message.from,
                    payload: message.payload,
                }.toCell();
                sendRawMessage(
                    beginCell()
                        .storeUint(0x10, 6)
                        .storeAddress(owner)
                        .storeCoins(message.forwardTon)
                        .storeUint(1, 107)
                        .storeRef(body)
                        .endCell(),
                    17,
                );
            }
            if (message.excessesTo != null) {
                reserveToncoinsOnBalance(
                    max(
                        contract.getOriginalBalance() + contract.getStoragePaidPayment() -
                        in.valueCoins,
                        calculateStorageFee(0, 157680000, 970, 3),
                    ),
                    2,
                );
                sendRawMessage(
                    beginCell()
                        .storeUint(0x10, 6)
                        .storeAddress(message.excessesTo!)
                        .storeUint(0xd53276db, 143)
                        .storeUint(message.queryId, 64)
                        .endCell(),
                    130,
                );
            }
        }
        Transfer => {
            val required = (message.forwardTon > 0 ? 2 : 1) * in.originalForwardFee +
            message.forwardTon +
            calculateGasFee(0, 8526) +
            calculateGasFee(0, 8862) +
            calculateForwardFeeWithoutLumpPrice(0, 812, 3) +
            calculateStorageFee(0, 157680000, 970, 3);
            // This diagnostic instruction is present in the archived executable.
            debug.print(required);
            assert (required <= in.valueCoins) throw 23;
            var data = contract.getData().beginParse();
            val balance = data.loadCoins();
            val savedTail = data;
            val owner = data.loadAddress();
            val master = data.loadAddress();
            assert (in.senderAddress == owner) throw 25;
            assert (message.destination.getWorkchain() == 0) throw 30;
            assert (message.amount <= balance) throw 27;
            val updatedBalance = balance - message.amount;
            contract.setData(
                beginCell().storeCoins(updatedBalance).storeSlice(savedTail).endCell(),
            );
            val target = walletDeployment(contract.getCode(), master, message.destination);
            val body = InternalTransfer {
                queryId: message.queryId,
                amount: message.amount,
                from: owner,
                excessesTo: message.excessesTo,
                forwardTon: message.forwardTon,
                payload: message.payload,
            }.toCell();
            var outgoing = archivedPoolRefDeploymentHeader(target);
            outgoing.storeRef(body);
            sendRawMessage(outgoing.endCell(), 80);
        }
        Burn => {
            assert (
                contract.getStoragePaidPayment() + calculateGasFee(0, 5253) +
                calculateGasFee(0, 7518) +
                in.originalForwardFee <=
                in.valueCoins
            ) throw 23;
            var data = contract.getData().beginParse();
            val balance = data.loadCoins();
            val savedTail = data;
            val owner = data.loadAddress();
            val master = data.loadAddress();
            assert (in.senderAddress == owner) throw 25;
            assert (message.amount <= balance) throw 27;
            val updatedBalance = balance - message.amount;
            contract.setData(
                beginCell().storeCoins(updatedBalance).storeSlice(savedTail).endCell(),
            );
            val body = BurnNotification {
                queryId: message.queryId,
                amount: message.amount,
                from: owner,
                excessesTo: message.excessesTo,
            }.toCell();
            sendRawMessage(
                beginCell()
                    .storeUint(0x18, 6)
                    .storeAddress(master)
                    .storeUint(1, 111)
                    .storeRef(body)
                    .endCell(),
                80,
            );
        }
        Sell => {
            assert (
                contract.getStoragePaidPayment() + calculateGasFee(0, 5760) +
                calculateGasFee(0, 22320) +
                calculateGasFee(0, 1586) +
                (in.originalForwardFee << 1) <=
                in.valueCoins
            ) throw 23;
            var data = contract.getData().beginParse();
            val balance = data.loadCoins();
            val savedTail = data;
            val owner = data.loadAddress();
            val master = data.loadAddress();
            assert (in.senderAddress == owner) throw 25;
            assert (message.amount <= balance) throw 27;
            val updatedBalance = balance - message.amount;
            contract.setData(
                beginCell().storeCoins(updatedBalance).storeSlice(savedTail).endCell(),
            );
            val body = SellNotification {
                queryId: message.queryId,
                amount: message.amount,
                minTon: message.minTon,
                from: owner,
                excessesTo: message.excessesTo,
                partner: message.partner,
                referrer: message.referrer,
            }.toCell();
            sendRawMessage(
                beginCell()
                    .storeUint(0x18, 6)
                    .storeAddress(master)
                    .storeUint(1, 111)
                    .storeRef(body)
                    .endCell(),
                80,
            );
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var body = in.bouncedBody;
    body.loadUint(32);
    val message = lazy Bounced.fromSlice(
        body,
        { throwIfOpcodeDoesNotMatch: 63, assertEndAfterReading: false },
    );
    val amount = match (message) {
        BouncedTransfer => message.amount,
        BouncedBurn => message.amount,
        BouncedSell => message.amount,
    };
    var data = contract.getData().beginParse();
    val balance = data.loadCoins();
    val updatedBalance = balance + amount;
    contract.setData(beginCell().storeCoins(updatedBalance).storeSlice(data).endCell());
}

get fun get_wallet_data(): (int, address, address, cell) {
    val storage = WalletStorage.fromCell(contract.getData(), { assertEndAfterReading: false });
    return (storage.balance, storage.owner, storage.master, contract.getCode());
}
// Recovered from mainnet 891e5228e4300ae3ff22583163bbd50e3e1e8cd2304c0d57164f5318f9da1266.
// Names describe behavior; original author identifiers are unknown.
