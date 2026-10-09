// decompiled by @fiscaldev
import "@stdlib/gas-payments"
import "deployment-message"
import "matches"
import "types"

// Preserve both archived operations; current Tolk otherwise folds them to THROWIF.
fun requireBasechain(workchain: int): void
    asm "0 EQINT 30 THROWIFNOT"

@inline_ref
fun walletDeployment(code: cell, master: any_address, owner: any_address): AutoDeployAddress {
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
        toShard: { fixedPrefixLength: 8, closeTo: owner as address },
    };
}

@inline
fun registerAddressVariants(value: ContractState | AddressShardingOptions): int {
    return (value is ContractState) ? 1 : 0;
}

fun onInternalMessage(in: InMessage) {
    val message = Incoming.fromSlice(
        in.body,
        { throwIfOpcodeDoesNotMatch: 65535, assertEndAfterReading: false },
    );
    match (message) {
        InternalTransfer => {
            var data = contract.getData().beginParse();
            val balance = data.loadCoins();
            val savedTail = data;
            val owner = data.loadAddressAny();
            val master = data.loadAddressAny();
            if (!((in.senderAddress as slice).bitsEqual(master as slice))) {
                val peer = walletDeployment(contract.getCode(), master, message.from);
                assert (peer.matchesArchivedAddress(in.senderAddress)) throw 25;
            }
            val updatedBalance = balance + message.amount;
            contract.setData(
                beginCell().storeCoins(updatedBalance).storeSlice(savedTail).endCell(),
            );
            if (message.forwardTon != 0) {
                val body = Notification {
                    queryId: message.queryId,
                    amount: message.amount,
                    from: message.from,
                    payload: message.payload,
                }.toCell();
                sendRawMessage(
                    beginCell()
                        .storeUint(0x10, 6)
                        .storeSlice(owner as slice)
                        .storeCoins(message.forwardTon)
                        .storeUint(1, 107)
                        .storeRef(body)
                        .endCell(),
                    17,
                );
            }
            if (isStandardAddress(message.excessesTo)) {
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
                        .storeSlice(message.excessesTo as slice)
                        .storeUint(0xd53276db, 143)
                        .storeUint(message.queryId, 64)
                        .endCell(),
                    130,
                );
            }
        }
        Transfer => {
            val required = (message.forwardTon != 0 ? 2 : 1) * in.originalForwardFee +
            message.forwardTon +
            calculateGasFee(0, 8628) +
            calculateGasFee(0, 9282) +
            calculateForwardFeeWithoutLumpPrice(0, 812, 3) +
            calculateStorageFee(0, 157680000, 970, 3);
            // This diagnostic instruction is present in the archived executable.
            debug.print(required);
            assert (required <= in.valueCoins) throw 23;
            var data = contract.getData().beginParse();
            val balance = data.loadCoins();
            val savedTail = data;
            val owner = data.loadAddressAny();
            val master = data.loadAddressAny();
            assert ((in.senderAddress as slice).bitsEqual(owner as slice)) throw 25;
            requireBasechain((message.destination as address).getWorkchain());
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
                contract.getStoragePaidPayment() + calculateGasFee(0, 5115) +
                calculateGasFee(0, 7880) +
                in.originalForwardFee <=
                in.valueCoins
            ) throw 23;
            var data = contract.getData().beginParse();
            val balance = data.loadCoins();
            val savedTail = data;
            val owner = data.loadAddressAny();
            val master = data.loadAddressAny();
            assert ((in.senderAddress as slice).bitsEqual(owner as slice)) throw 25;
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
                    .storeSlice(master as slice)
                    .storeUint(1, 111)
                    .storeRef(body)
                    .endCell(),
                80,
            );
        }
        Sell => {
            assert (
                contract.getStoragePaidPayment() + calculateGasFee(0, 5588) +
                calculateGasFee(0, 22543) +
                calculateGasFee(0, 1586) +
                (in.originalForwardFee << 1) <=
                in.valueCoins
            ) throw 23;
            var data = contract.getData().beginParse();
            val balance = data.loadCoins();
            val savedTail = data;
            val owner = data.loadAddressAny();
            val master = data.loadAddressAny();
            assert ((in.senderAddress as slice).bitsEqual(owner as slice)) throw 25;
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
                    .storeSlice(master as slice)
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

get fun get_wallet_data(): (int, any_address, any_address, cell) {
    val storage = WalletStorage.fromCell(contract.getData(), { assertEndAfterReading: false });
    return (storage.balance, storage.owner, storage.master, contract.getCode());
}
// Recovered from mainnet eefce5ce3d1e555a5010a309348c965dfaf72ebdf3233b4f691fa3d37bdb5605.
// V2 deliberately preserves its permissive payload/address decoding.
