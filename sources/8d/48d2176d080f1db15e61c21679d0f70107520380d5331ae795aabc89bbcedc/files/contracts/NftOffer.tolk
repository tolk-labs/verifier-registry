import "@stdlib/gas-payments"
import "messages"
import "nft_offer/errors"
import "nft_offer/messages"
import "nft_offer/storage"

contract NftOffer {
    author: "Telegram"
    version: "0.6.0"
    description: "Expiring single-NFT offer with permissionless external cancellation"
    storage: NftOfferStorage
    incomingMessages: NftOfferMessage
    incomingExternal: CancelNftOffer
}

fun onInternalMessage(in: InMessage) {
    var storage = NftOfferStorage.load();
    val config = storage.config.load();
    val parties = config.parties.load();

    if (in.body.isEmpty()) {
        if (storage.phase == NftOfferPhase.Funding && in.senderAddress == parties.buyer) {
            assert (blockchain.now() < config.expiresAt) throw NftOfferError.Expired;

            val rent = nftOfferStorageBudget(contract.getCode(), contract.getData(), config.expiresAt);
            val total = config.price + config.price * config.royalty.load().bps / 10000;

            assert (contract.getOriginalBalance() >= total + rent) throw NftOfferError.InsufficientFunds;

            storage.phase = NftOfferPhase.Ready;
            storage.save();
        }

        return;
    }

    val msg = lazy NftOfferMessage.fromSlice(in.body);

    match (msg) {
        OwnershipAssigned => {
            assert (in.senderAddress == config.nft) throw NftOfferError.InvalidNft;
            assert (msg.previousOwner.getWorkchain() == BASECHAIN) throw NftOfferError.InvalidNft;

            if (
                storage.phase != NftOfferPhase.Ready || blockchain.now() >= config.expiresAt ||
                msg.previousOwner != parties.seller
            ) {
                val refundNftMsg = createMessage({
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
                // Return to the actual sender, including a different owner, without spending escrow.
                refundNftMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);

                return;
            }

            assert (
                blockchain.now() < config.expiresAt && storage.phase == NftOfferPhase.Ready
            ) throw NftOfferError.Expired;

            // transfer gram to owner
            val payOwnerMsg = createMessage({
                dest: msg.previousOwner,
                value: config.price,
                bounce: false,
            });
            payOwnerMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

            val royalty = config.royalty.load();

            // transfer nft to buyer
            val sendGiftMsg = createMessage({
                bounce: false,
                dest: config.nft,
                value: NFT_OFFER_TRANSFER_VALUE,
                body: NftTransfer {
                    queryId: msg.queryId,
                    newOwner: parties.recipient,
                    responseDestination: royalty.recipient,
                    customPayload: null,
                    forwardAmount: 0,
                    forwardPayload: emptyForwardPayload(),
                },
            });
            sendGiftMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

            // royalty
            val royaltyMsg = createMessage({
                bounce: false,
                dest: royalty.recipient,
                value: 0,
            });
            // SAFETY: rest to royalty
            royaltyMsg.send(SEND_MODE_CARRY_ALL_BALANCE);

            storage.phase = NftOfferPhase.Filled;
            storage.save();
        }

        CancelByBuyer => {
            assert (in.senderAddress == parties.buyer) throw NftOfferError.InvalidMessage;
            // cancel before the expire, pay fine
            if (blockchain.now() < config.expiresAt) {
                val royalty = config.royalty.load();
                val fine = max(config.price * royalty.fineBps / 10000, royalty.fineBps * 10000000);

                val fineMsg = createMessage({
                    dest: royalty.recipient,
                    bounce: false,
                    value: fine,
                });
                fineMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            val refund = createMessage({ bounce: BounceMode.NoBounce, dest: parties.buyer, value: 0 });
            // SAFETY: end of life cycle
            refund.send(SEND_MODE_CARRY_ALL_BALANCE);

            storage.phase = NftOfferPhase.Expired;
            storage.save();
        }

        else => {
            throw NftOfferError.InvalidMessage;
        }
    }
}

fun onExternalMessage(body: slice) {
    val msg = CancelNftOffer.fromSlice(body);

    var storage = lazy NftOfferStorage.load();
    val config = lazy storage.config.load();

    assert (storage.phase == NftOfferPhase.Ready) throw NftOfferError.InvalidMessage;

    if (blockchain.now() < config.expiresAt) {
        // try to validate if not expired
        val hash = contract.getAddress().getWorkchainAndHash();
        assert (isSignatureValid(hash.1, msg.sign! as slice, storage.public)) throw NftOfferError.InvalidMessage;
    }

    acceptExternalMessage();

    val buyer = config.parties.load().buyer;

    val refund = createMessage({ bounce: BounceMode.NoBounce, dest: buyer, value: 0 });
    // SAFETY: end of life cycle
    refund.send(SEND_MODE_CARRY_ALL_BALANCE);

    storage.phase = NftOfferPhase.Expired;
    storage.save();
}

get fun nftOfferData(): NftOfferStorage {
    return NftOfferStorage.load();
}
