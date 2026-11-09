// The deployed code hash is 8d48d2176d080f1db15e61c21679d0f70107520380d5331ae795aabc89bbcedc, and
// indexers recognise offers by it. Some code shapes below only keep the compiled code identical:
// the code and data locals before the state-init cell, the transfer bodies and the transfer value
// in locals before `createMessage`, and the second expiry assert after the NFT return. Compare
// the code hash after every change, and build with the toolchain pinned in Acton.toml.

import "@stdlib/gas-payments"

import "errors"
import "messages"
import "storage"

contract NftOffer {
    author: "Telegram and/or TON Core (maybe)"
    version: "1.0.0"
    description: "Source code reconstructed by @ai_terminal. Buyer-funded offer for one NFT from one seller: pays the price and a marketplace fee on sale; the buyer can cancel, paying a fee before expiry; a signed or post-expiry external cancel refunds the buyer"
    storage: Storage
    incomingMessages: AllowedMessage
    incomingExternal: CancelOffer
}

/// Denominator of the basis-point rates.
const BPS_DENOMINATOR = 10000

/// Maximum number of cells that the state-init size count visits.
const STATE_SIZE_MAX_CELLS = 1024

/// Cells added to the state size when the storage reserve is calculated.
const RESERVE_EXTRA_CELLS = 4

/// Bits added to the state size when the storage reserve is calculated.
const RESERVE_EXTRA_BITS = 1024

/// Value sent with the NFT transfer to the recipient; the excess goes to the fee address.
const NFT_TRANSFER_VALUE = grams("0.0028")

/// Minimum cancel fee for each unit of `Fee.cancelFee`.
const CANCEL_FEE_UNIT = grams("0.01")

/// Internal messages with an opcode that the offer accepts.
type AllowedMessage = OwnershipAssigned | CancelByBuyer

/// A message with no data and no refs from the buyer funds an offer in `Funding`; any other such
/// message is a top-up. A text comment has an opcode, so it isn't empty and is rejected.
/// `ownership_assigned` from the offer NFT completes the sale or returns the NFT.
/// `CancelByBuyer` closes the offer. Bounced messages are ignored.
fun onInternalMessage(in: InMessage) {
    var storage = Storage.load();
    val config = storage.config.load();
    val parties = config.parties.load();

    if (in.body.isEmpty()) {
        if (storage.phase == Phase.Funding && in.senderAddress == parties.buyer) {
            assert (blockchain.now() < config.expiresAt) throw Errors.Expired;
            // Storage reserve: twice the storage fee until expiry, for the current state plus a
            // size margin.
            val code = contract.getCode();
            val data = contract.getData();
            val stateInit = beginCell().storeRef(code).storeRef(data).endCell();
            val (cells, bits, _) = stateInit.calculateSizeStrict(STATE_SIZE_MAX_CELLS);
            val storageReserve = calculateStorageFee(
                BASECHAIN,
                max(0, config.expiresAt - blockchain.now()),
                bits + RESERVE_EXTRA_BITS,
                cells + RESERVE_EXTRA_CELLS,
            ) *
                2;
            val fee = config.fee.load();
            val cost = config.price + fee.feeBps * config.price / BPS_DENOMINATOR;
            assert (
                contract.getOriginalBalance() >= cost + storageReserve
            ) throw Errors.NotEnoughFunds;
            storage.phase = Phase.Active;
            storage.save();
            return;
        }
        return;
    }

    val msg = lazy AllowedMessage.fromSlice(in.body);
    match (msg) {
        OwnershipAssigned => {
            assert (in.senderAddress == config.nft) throw Errors.InvalidOwnershipAssigned;
            assert (
                msg.prevOwner.getWorkchain() == BASECHAIN
            ) throw Errors.InvalidOwnershipAssigned;
            // The offer returns an NFT that it can't buy, with the remaining message value.
            if (
                storage.phase != Phase.Active || blockchain.now() >= config.expiresAt ||
                msg.prevOwner != parties.seller
            ) {
                val transfer: NftTransfer = {
                    queryId: msg.queryId,
                    newOwner: msg.prevOwner,
                    responseDestination: msg.prevOwner,
                };
                val returnNft = createMessage({
                    bounce: false,
                    dest: config.nft,
                    value: 0,
                    body: transfer,
                });
                returnNft.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
                return;
            }
            assert (
                blockchain.now() < config.expiresAt && storage.phase == Phase.Active
            ) throw Errors.Expired;

            val sellerPayment = createMessage({
                bounce: false,
                dest: msg.prevOwner,
                value: config.price,
            });
            sellerPayment.send(SEND_MODE_PAY_FEES_SEPARATELY);

            val fee = config.fee.load();
            val transferValue = NFT_TRANSFER_VALUE;
            val transfer: NftTransfer = {
                queryId: msg.queryId,
                newOwner: parties.recipient,
                responseDestination: fee.feeAddress,
            };
            val nftToRecipient = createMessage({
                bounce: false,
                dest: config.nft,
                value: transferValue,
                body: transfer,
            });
            nftToRecipient.send(SEND_MODE_PAY_FEES_SEPARATELY);

            val remainder = createMessage({
                bounce: false,
                dest: fee.feeAddress,
                value: 0,
            });
            // SAFETY: the sale is complete and the phase becomes Sold below, so the rest of the
            // balance has no other claim; the fee address gets it.
            remainder.send(SEND_MODE_CARRY_ALL_BALANCE);

            storage.phase = Phase.Sold;
            storage.save();
        }
        CancelByBuyer => {
            assert (in.senderAddress == parties.buyer) throw Errors.Forbidden;
            // If the balance, including the value of this message, can't cover the cancel fee,
            // the action phase fails: no message goes out and the phase doesn't change.
            if (blockchain.now() < config.expiresAt) {
                val fee = config.fee.load();
                val cancelFeeAmount = max(
                    config.price * fee.cancelFee / BPS_DENOMINATOR,
                    fee.cancelFee * CANCEL_FEE_UNIT,
                );
                val cancelFeeMessage = createMessage({
                    bounce: false,
                    dest: fee.feeAddress,
                    value: cancelFeeAmount,
                });
                cancelFeeMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            val refund = createMessage({
                bounce: false,
                dest: parties.buyer,
                value: 0,
            });
            // SAFETY: only the buyer gets here and the phase becomes Closed below, so the buyer
            // gets the rest of the balance after the cancel fee.
            refund.send(SEND_MODE_CARRY_ALL_BALANCE);

            storage.phase = Phase.Closed;
            storage.save();
        }
        else => throw Errors.Forbidden,
    }
}

/// `CancelOffer`: closes an Active offer and sends the balance to the buyer. Anyone can send it;
/// before expiry it needs the signature of the offer key.
fun onExternalMessage(inMsg: slice) {
    val msg = CancelOffer.fromSlice(inMsg);
    var storage = lazy Storage.load();
    val config = lazy storage.config.load();
    assert (storage.phase == Phase.Active) throw Errors.Forbidden;
    if (blockchain.now() < config.expiresAt) {
        val (_, addressHash) = contract.getAddress().getWorkchainAndHash();
        assert (
            isSignatureValid(addressHash, msg.signature! as slice, storage.publicKey)
        ) throw Errors.Forbidden;
    }
    acceptExternalMessage();
    val parties = config.parties.load();
    val refund = createMessage({
        bounce: false,
        dest: parties.buyer,
        value: 0,
    });
    // SAFETY: only an Active offer gets here, cancelled by the offer key or after expiry, and the
    // phase becomes Closed below, so the buyer's funds go back once.
    refund.send(SEND_MODE_CARRY_ALL_BALANCE);

    storage.phase = Phase.Closed;
    storage.save();
}

/// Full offer storage: the config cell, the offer key and the phase.
get fun nftOfferData(): Storage {
    return Storage.load();
}
