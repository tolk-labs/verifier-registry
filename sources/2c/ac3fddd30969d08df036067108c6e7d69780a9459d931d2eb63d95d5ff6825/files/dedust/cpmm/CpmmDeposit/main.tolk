// decompiled by @fiscaldev
// Reconstructed from mainnet code 2cac3fddd30969d08df036067108c6e7d69780a9459d931d2eb63d95d5ff6825.
// Names are inferred from the public DeDust ABI; this is not the author's source.
import "@stdlib/gas-payments"

import "types"

@inline_ref
fun sendExcesses(recipient: any_address, queryId: uint64, mode: int) {
    // Internal, non-bouncing message; zero value/fees/timestamps; inline Excesses body.
    val message = beginCell().storeUint(0x10, 6).storeSlice(recipient as slice)
        .storeUint(0xd53276db, 143).storeUint(queryId, 64).endCell();
    sendRawMessage(message, mode | SEND_MODE_IGNORE_ERRORS);
}

@noinline
fun DepositStorage.save(self) {
    saveDataInReferencedCell(self);
}

// Reserve the three outgoing variants before the incoming union. Tolk assigns
// union IDs in lowering order; the original bundle used 132/133 for incoming messages.
// This unused function has no emitted code, but makes that compiler layout explicit.
@inline
fun registerOutgoingUnionLayout(message: JoinLiquidity | RefundDeposit | Excesses): int {
    return ((message is JoinLiquidity) ? 1 : 0)
        + ((message is RefundDeposit) ? 2 : 0)
        + ((message is Excesses) ? 4 : 0);
}

fun onInternalMessage(in: InMessage) {
    val message = DepositMessage.fromSlice(in.body, { throwIfOpcodeDoesNotMatch: 65535 });
    var storage = DepositStorage.fromCell(contract.getData());

    match (message) {
        CreditAsset => {
            assert ((in.senderAddress as slice).bitsEqual(storage.pool as slice)) throw 23;
            if (message.isX) {
                storage.balanceX += message.amount;
            } else {
                storage.balanceY += message.amount;
            }

            val config = storage.config.load();
            if (storage.balanceX >= config.targetX && storage.balanceY >= config.targetY) {
                val body = JoinLiquidity {
                        queryId: message.queryId,
                        config: storage.config,
                        balanceX: storage.balanceX,
                        balanceY: storage.balanceY,
                        initiator: storage.initiator,
                    }.toCell();
                val outgoing = beginCell().storeUint(0x10, 6).storeSlice(storage.pool as slice)
                    .storeUint(1, 111).storeRef(body).endCell();
                sendRawMessage(outgoing, SEND_MODE_DESTROY | SEND_MODE_CARRY_ALL_BALANCE);
                storage.balanceX = 0;
                storage.balanceY = 0;
            } else {
                val payout = config.payoutConfig.load();
                sendExcesses(payout.excesses, message.queryId, SEND_MODE_CARRY_ALL_BALANCE);
            }
            storage.save();
        }
        CancelDeposit => {
            assert ((in.senderAddress as slice).bitsEqual(storage.initiator as slice)) throw 23;
            val config = storage.config.load();
            val payout = config.payoutConfig.load();
            val (cells, bits, _) = (storage.config as cell).calculateSizeStrict(512);
            val forwardFee = calculateForwardFee(0, bits, cells);
            val assetCount = storage.balanceX > 0 && storage.balanceY > 0 ? 2 : 1;
            val requiredValue = contract.getStoragePaidPayment()
                + calculateGasFee(0, 6500)
                + calculateGasFee(0, 21000)
                + forwardFee
                + assetCount * (forwardFee + payout.refundNotifyExtraGas + 50000000);
            assert (in.valueCoins >= requiredValue) throw 25;

            val body = RefundDeposit {
                    queryId: message.queryId,
                    config: storage.config,
                    balanceX: storage.balanceX,
                    balanceY: storage.balanceY,
                    initiator: storage.initiator,
                }.toCell();
            val outgoing = beginCell().storeUint(0x10, 6).storeSlice(storage.pool as slice)
                .storeUint(1, 111).storeRef(body).endCell();
            sendRawMessage(outgoing, SEND_MODE_DESTROY | SEND_MODE_CARRY_ALL_BALANCE);
            storage.balanceX = 0;
            storage.balanceY = 0;
            storage.save();
        }
    }
}

get fun get_deposit_data(): (any_address, any_address, any_address, int, int, int, int, int, int) {
    val storage = DepositStorage.fromCell(contract.getData());
    val config = storage.config.load();
    val payout = config.payoutConfig.load();
    return (
        storage.pool, payout.recipient, payout.refundRecipient,
        config.targetX, config.targetY, config.lockedShare, config.minLiquidity,
        storage.balanceX, storage.balanceY,
    );
}

// The original dictionary entry 2 contains a reference to its code cell.
// Pack DepositStorage in field order and set c4. Using a referenced asm block
// fixes the physical layout without embedding any original code bytes.
fun saveDataInReferencedCell(storage: DepositStorage): void
    asm "<{ s0 s4 XCHG NEWC STREF s1 s3 XCHG STSLICE STSLICE SWAP STGRAMS SWAP STGRAMS ENDC c4 POP }>c ref,"
