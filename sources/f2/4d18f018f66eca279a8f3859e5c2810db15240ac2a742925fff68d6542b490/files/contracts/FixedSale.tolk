import "errors"
import "messages"
import "storage"

contract FixedSale {
    author: "Telegram"
    version: "0.2.0"
    description: "NFT fixed sale with upfront settlement, royalty and NFT excess cashback"
    storage: SaleStorage
    incomingMessages: SaleMessage
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    var storage = lazy SaleStorage.load();
    val config = lazy storage.config.load();

    val msg = lazy SaleMessage.fromSlice(in.body);

    match (msg) {
        OwnershipAssigned => {
            assert (in.senderAddress == config.nft) throw Errors.InvalidNft;
            assert (msg.previousOwner.getWorkchain() == 0) throw Errors.InvalidNft;

            if (storage.phase != SalePhase.Waiting) {
                val refund = createMessage({
                    bounce: false,
                    dest: config.nft,
                    value: 0,
                    body: NftTransfer {
                        queryId: msg.queryId,
                        newOwner: msg.previousOwner,
                        responseDestination: msg.previousOwner,
                        customPayload: null,
                        forwardAmount: 0,
                        forwardPayload: emptyForwardPayload(),
                    },
                });
                // Return an unaccepted deposit using only its notification budget.
                refund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);

                return;
            }

            assert (storage.price > 0 && config.royalty.load().bps <= 10000) throw Errors.InvalidRequest;

            storage.phase = SalePhase.Active;
            storage.save();
        }

        ChangePrice => {
            assert (in.senderAddress == config.seller) throw Errors.Unauthorized;
            assert (storage.phase == SalePhase.Active) throw Errors.WrongState;
            assert (msg.price > 0) throw Errors.InvalidRequest;

            storage.price = msg.price;
            storage.save();
        }

        Buy => {
            assert (storage.phase == SalePhase.Active) throw Errors.WrongState;
            assert (storage.price > 0 && msg.expectedPrice >= storage.price) throw Errors.PriceChanged;
            assert (
                msg.recipient.getWorkchain() == BASECHAIN && in.senderAddress.getWorkchain() == BASECHAIN
            ) throw Errors.InvalidRequest;

            val royalty = config.royalty.load();

            val quotedTotal = saleTotal(msg.expectedPrice, royalty.bps);
            val actualTotal = saleTotal(storage.price, royalty.bps);

            assert (in.valueCoins >= quotedTotal + BUY_GAS) throw Errors.InsufficientFunds;

            // Refund both the price reduction and its royalty difference to the payer.
            // Arbitrary value above the declared quote is execution surplus, as in NftOffer.
            val cashback = quotedTotal - actualTotal;

            val sellerPayment = createMessage({
                bounce: false,
                dest: config.seller,
                value: storage.price,
            });
            sellerPayment.send(SEND_MODE_PAY_FEES_SEPARATELY);

            val transfer = createMessage({
                bounce: false,
                dest: config.nft,
                value: NFT_TRANSFER_GAS + cashback,
                body: NftTransfer {
                    queryId: msg.queryId,
                    newOwner: msg.recipient,
                    responseDestination: in.senderAddress,
                    customPayload: null,
                    forwardAmount: 0,
                    forwardPayload: emptyForwardPayload(),
                },
            });
            transfer.send(SEND_MODE_PAY_FEES_SEPARATELY);

            val royaltyPayment = createMessage({
                bounce: false,
                dest: royalty.recipient,
                value: 0,
            });
            // SAFETY: All obligations above are explicit; the immutable royalty recipient receives the surplus.
            royaltyPayment.send(SEND_MODE_CARRY_ALL_BALANCE);

            storage.phase = SalePhase.Sold;
            storage.save();
        }

        CancelSale => {
            assert (in.senderAddress == config.seller) throw Errors.Unauthorized;
            assert (storage.phase == SalePhase.Active) throw Errors.Unauthorized;

            assert (in.valueCoins >= NFT_TRANSFER_GAS) throw Errors.InsufficientFunds;

            val transfer = createMessage({
                bounce: false,
                dest: config.nft,
                value: 0,
                body: NftTransfer {
                    queryId: msg.queryId,
                    newOwner: config.seller,
                    responseDestination: msg.feeRecipient,
                    customPayload: null,
                    forwardAmount: 0,
                    forwardPayload: emptyForwardPayload(),
                },
            });
            // SAFETY: Seller-authorized cancellation returns NFT and remaining TON through the NFT.
            transfer.send(SEND_MODE_CARRY_ALL_BALANCE);

            storage.phase = SalePhase.Cancelled;

            storage.save();
        }

        else => {
            throw Errors.InvalidMessage;
        }
    }
}

get fun saleData(): SaleStorage {
    return SaleStorage.load();
}
