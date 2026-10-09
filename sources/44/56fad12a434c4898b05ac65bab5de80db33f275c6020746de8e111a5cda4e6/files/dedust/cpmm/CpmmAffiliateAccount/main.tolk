// decompiled by @fiscaldev
// Reconstructed from mainnet code 4456fad12a434c4898b05ac65bab5de80db33f275c6020746de8e111a5cda4e6.
// Names describe observed behavior; the original identifiers are unknown.
import "types"

const RETAINED_BALANCE = 100000000

@inline_ref
fun sendExcesses(recipient: any_address, queryId: uint64, mode: int) {
    val message = beginCell().storeUint(0x10,6).storeSlice(recipient as slice)
        .storeUint(0xd53276db,143).storeUint(queryId,64).endCell();
    sendRawMessage(message, mode | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    // Internal execution deliberately allows a trailing storage suffix, as the original does.
    var storage = AffiliateRuntimeStorage.fromCell(contract.getData(), { assertEndAfterReading:false });
    val message = lazy AffiliateMessage.fromSlice(in.body);
    match (message) {
        FeeNotification => {
            return;
        }
        ActivateAffiliate => {
            assert (!storage.isActivated) throw 16;
            assert ((in.senderAddress as slice).bitsEqual(storage.authority as slice)) throw 18;
            // Incoming payload suffixes are ignored in this contract.
            val activation = ActivationBody.fromSlice(message.tail, { assertEndAfterReading:false });
            storage.isActivated = true;
            storage.metadata = activation.metadata;
            storage.owner = activation.owner;
            // These slices have just been decoded with fixed widths. The original
            // stores them directly, without adding bitsN serialization checks.
            contract.setData(storage.toCell({ skipBitsNValidation:true }));
            reserveToncoinsOnBalance(RETAINED_BALANCE, 2);
            sendExcesses(activation.excesses, activation.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }
        WithdrawAffiliate => {
            assert (storage.isActivated) throw 17;
            assert ((in.senderAddress as slice).bitsEqual(storage.owner as slice)) throw 18;
            reserveToncoinsOnBalance(RETAINED_BALANCE, 2);
            val available = max(contract.getOriginalBalance() - RETAINED_BALANCE - in.valueCoins, 0);
            val withdrawal = WithdrawalBody.fromSlice(message.tail, { assertEndAfterReading:false });
            if (available > 0) {
                val outgoing = beginCell().storeUint(0x10,6).storeSlice(withdrawal.recipient as slice)
                    .storeCoins(available).storeUint(0,107).endCell();
                sendRawMessage(outgoing, SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);
            }
            sendExcesses(withdrawal.excesses, withdrawal.queryId, SEND_MODE_CARRY_ALL_BALANCE);
        }
        else => { throw 65535; }
    }
}

// Preserve compiler-assigned getter union IDs 132/133. No runtime code is emitted.
@inline
fun registerMessageUnionLayout(message: AffiliateMessage): int {
    return ((message is FeeNotification) ? 1 : 0)
        + ((message is ActivateAffiliate) ? 2 : 0)
        + ((message is WithdrawAffiliate) ? 4 : 0);
}

get fun get_affiliate_account_data(): (bool, any_address, any_address, int, cell?, int) {
    // The getter validates the entire storage and decodes the affiliate-kind union.
    val storage = AffiliateGetterStorage.fromCell(contract.getData());
    val kind = match (storage.kind) {
        ReferrerKind => 0,
        PartnerKind => 1,
    };
    return (storage.isActivated,storage.authority,storage.owner,kind,storage.metadata,storage.feeBps);
}
