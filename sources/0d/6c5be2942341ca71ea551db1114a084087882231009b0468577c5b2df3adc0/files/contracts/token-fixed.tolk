import "creation"
import "messages"
import "token-core"
import "token-errors"
import "token-fees"
import "token-messages"
import "token-sends"
import "token-storage"

type AllowedMessageToFixedToken =
    | BurnNotificationForMinter
    | RequestWalletAddress
    | TakeGram
    | TakeTokens
    | TopUpGrams
    | TextComment

fun handleFixedTokenMessage(senderAddress: address, valueCoins: coins, body: slice) {
    val loading = ContractLoader.start();
    if (loading.isUnstarted()) {
        assert (senderAddress == loading.factory) throw TokenErrors.NotFactory;
        val start = Start.fromSlice(body);
        val params = TokenParams.fromCell(start.params);
        assert (params.maxSupply == 0) throw TokenErrors.InvalidCap;
        return startToken(
            loading,
            valueCoins,
            start,
            params,
            false,
            TOKEN_FIXED_STATE_BITS,
            TOKEN_FIXED_STATE_CELLS,
        );
    }

    val msg = lazy AllowedMessageToFixedToken.fromSlice(body);

    match (msg) {
        BurnNotificationForMinter => acceptBurnNotification(senderAddress, msg),
        RequestWalletAddress => answerWalletAddress(senderAddress, msg),
        TakeGram => takeGram(senderAddress, TOKEN_FIXED_STATE_BITS, TOKEN_FIXED_STATE_CELLS),
        TakeTokens => takeTokens(senderAddress, msg),
        TopUpGrams => {}
        TextComment => returnPlainSend(senderAddress),
        else => {
            assert (body.isEmpty()) throw 0xFFFF;
            returnPlainSend(senderAddress);
        }
    }
}
