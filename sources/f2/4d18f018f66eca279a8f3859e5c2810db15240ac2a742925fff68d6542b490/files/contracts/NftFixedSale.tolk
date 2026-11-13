tolk 1.5

import "errors"
import "fees"
import "messages"
import "storage"

contract NftFixedSale {
    author: "Telegram and/or TON Core (maybe)"
    version: "1.0.0"
    description: "Source code reconstructed by @ai_terminal. Fixed-price sale of one NFT. The fee address gets a fee and the rest of the balance."
    storage: Storage
    incomingMessages: AllowedMessage
}

/// Builds the TEP-62 transfer of the NFT to `newOwner`, with no forward amount.
@inline
fun buildTransferNft(
    queryId: uint64,
    newOwner: address,
    responseDestination: address,
): TransferNft {
    return {
        queryId,
        newOwner,
        responseDestination,
        customPayload: null,
        forwardAmount: 0,
        forwardPayload: EMPTY_FORWARD_PAYLOAD,
    };
}

/// Handles the messages of the sale. An empty body is a top-up.
fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    var storage = lazy Storage.load();
    val config = lazy storage.config.load();

    val msg = lazy AllowedMessage.fromSlice(in.body);
    match (msg) {
        OwnershipAssigned => {
            assert (in.senderAddress == config.nft) throw Errors.InvalidOwnershipAssigned;
            assert (
                msg.prevOwner.getWorkchain() == BASECHAIN
            ) throw Errors.InvalidOwnershipAssigned;

            if (storage.phase != Phase.AwaitingNft) {
                // the sale does not wait for an NFT: send this one back to the previous owner
                val returnMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: config.nft,
                    value: 0,
                    body: buildTransferNft(msg.queryId, msg.prevOwner, msg.prevOwner),
                });
                returnMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
                return;
            }

            assert (
                storage.price > 0 && config.fee.load().feeBps <= BPS_DENOMINATOR
            ) throw Errors.InvalidParams;
            storage.phase = Phase.Active;
            storage.save();
        }

        ChangePrice => {
            assert (in.senderAddress == config.seller) throw Errors.NotPermitted;
            assert (storage.phase == Phase.Active) throw Errors.NotActive;
            assert (msg.newPrice > 0) throw Errors.InvalidParams;
            storage.price = msg.newPrice;
            storage.save();
        }

        Buy => {
            assert (storage.phase == Phase.Active) throw Errors.NotActive;
            assert (storage.price > 0 && msg.maxPrice >= storage.price) throw Errors.PriceTooLow;
            assert (
                msg.newOwner.getWorkchain() == BASECHAIN &&
                in.senderAddress.getWorkchain() == BASECHAIN
            ) throw Errors.InvalidParams;

            val fee = config.fee.load();
            val maxFullPrice = msg.maxPrice + calcFee(msg.maxPrice, fee.feeBps);
            val fullPrice = calcFee(storage.price, fee.feeBps) + storage.price;
            assert (
                in.valueCoins >= maxFullPrice + MIN_BUY_EXTRA_AMOUNT
            ) throw Errors.NotEnoughValue;
            val overpayment = maxFullPrice - fullPrice;

            val paymentMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: config.seller,
                value: storage.price,
            });
            paymentMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

            // the buyer gets the overpayment back as the excess of the NFT transfer
            val transferMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: config.nft,
                value: NFT_TRANSFER_AMOUNT + overpayment,
                body: buildTransferNft(msg.queryId, msg.newOwner, in.senderAddress),
            });
            transferMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

            val feeMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: fee.feeAddress,
                value: 0,
            });
            // SAFETY: the sale ends here. The seller has the price and the NFT transfer has its
            // value, so the fee address gets the fee and the remaining balance.
            feeMsg.send(SEND_MODE_CARRY_ALL_BALANCE);

            storage.phase = Phase.Sold;
            storage.save();
        }

        Cancel => {
            assert (in.senderAddress == config.seller) throw Errors.NotPermitted;
            assert (storage.phase == Phase.Active) throw Errors.NotPermitted;
            assert (in.valueCoins >= NFT_TRANSFER_AMOUNT) throw Errors.NotEnoughValue;

            val returnMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: config.nft,
                value: 0,
                body: buildTransferNft(msg.queryId, config.seller, msg.responseDestination),
            });
            // SAFETY: only the seller can cancel, and the sale ends here. The NFT transfer gets
            // all of the balance, and the response destination gets the excess.
            returnMsg.send(SEND_MODE_CARRY_ALL_BALANCE);

            storage.phase = Phase.Cancelled;
            storage.save();
        }

        else => throw Errors.UnknownOperation,
    }
}

/// Returns the persistent data: the terms, the current price and the phase.
get fun saleData(): Storage {
    return Storage.load();
}
