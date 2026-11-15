import "@stdlib/gas-payments"

import "c5-register-validation"
import "errors"
import "fees"
import "messages"
import "storage"
import "storage-wallet"

contract AgenticWallet {
    author: "mnemotiv"
    version: "2.0.0"
    description: "W5-based agentic wallet as an NFT item. TEP-62 and TEP-64 compliant."
    storage: AgenticWalletStorage
    storageAtDeployment: AgenticWalletStorageNotInitialized
    incomingMessages: AllowedMessageToAgenticWallet
    incomingExternal: AllowedExternalMessageToAgenticWallet
}

type AllowedMessageToAgenticWallet =
    | InternalSignedRequest
    | OwnerActionRequest
    | ChangeWalletOwner
    | ChangeWalletDelegate
    | RequestStaticData
    | EditWalletContent
    | DeployWallet

type AllowedExternalMessageToAgenticWallet = ExternalSignedRequest

/// Bits of an Ed25519 signature.
const SIZE_SIGNATURE = 512

/// Minimum bits of a signed internal request: opcode + walletAddress (267 bits) + validUntil
/// + seqno. The wallet checks it before the signature.
const MIN_SIGNED_REQUEST_BITS = 32 + 267 + 32 + 32

/// Checks a TEP-62 forward payload (Either Cell ^Cell):
/// bit 0 = inline payload follows, bit 1 = only a ref follows.
fun isValidForwardPayload(payload: RemainingBitsAndRefs): bool {
    val (bits, refs) = payload.remainingBitsAndRefsCount();

    if (bits == 0) {
        return false;
    }

    if (payload.preloadUint(1) != 0) {
        return bits == 1 && refs == 1;
    }

    return true;
}

fun onExternalMessage(inMsgBody: slice) {
    val msg = AllowedExternalMessageToAgenticWallet.fromSlice(
        inMsgBody,
        { throwIfOpcodeDoesNotMatch: Errors.InvalidMessageOperation },
    );

    var storage = AgenticWalletStorage.loadInitialized();

    assert (
        storage.delegatePublicKey != 0 &&
        isSignatureValid(
            inMsgBody.removeLastBits(SIZE_SIGNATURE).hash(),
            msg.signature as slice,
            storage.delegatePublicKey,
        )
    ) throw Errors.InvalidSignature;
    assert (msg.seqno == storage.seqno) throw Errors.InvalidSeqno;
    assert (msg.walletAddress == contract.getAddress()) throw Errors.InvalidWalletAddress;
    assert (msg.validUntil > blockchain.now()) throw Errors.Expired;

    acceptExternalMessage();

    // commit the seqno increment first, so nobody can replay a request that fails in compute
    storage.seqno += 1;
    storage.save();

    commitContractDataAndActions();
    setTvmRegisterC5(msg.outActions.verifyC5Actions(true));
}

@on_bounced_policy("manual")
fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToAgenticWallet.fromSlice(in.body);

    match (msg) {
        InternalSignedRequest => {
            // the wallet ignores invalid requests before the signature check; after it, they throw
            if (in.body.remainingBitsCount() < MIN_SIGNED_REQUEST_BITS + SIZE_SIGNATURE) {
                return;
            }

            val signature = in.body.getLastBits(SIZE_SIGNATURE);
            val signedSlice = in.body.removeLastBits(SIZE_SIGNATURE);

            var loadingStorage = AgenticWalletStorage.startLoading();

            if (!loadingStorage.isInitialized()) {
                return;
            }

            var storage = loadingStorage.endLoading();

            if (
                storage.delegatePublicKey == 0 ||
                !isSignatureValid(signedSlice.hash(), signature, storage.delegatePublicKey)
            ) {
                return;
            }

            assert (msg.seqno == storage.seqno) throw Errors.InvalidSeqno;
            assert (msg.walletAddress == contract.getAddress()) throw Errors.InvalidWalletAddress;
            assert (msg.validUntil > blockchain.now()) throw Errors.Expired;

            // no commit, unlike for externals: a failure reverts the whole transaction,
            // and the seqno too
            storage.seqno += 1;
            // the delegate signature allows this write
            // check-disable-next-line unauthorized-access
            storage.save();

            setTvmRegisterC5(msg.outActions.verifyC5Actions(false));
        }

        OwnerActionRequest => {
            var loadingStorage = AgenticWalletStorage.startLoading();

            if (!loadingStorage.isInitialized()) {
                return;
            }

            val storage = loadingStorage.endLoading();

            if (in.senderAddress != storage.ownerAddress) {
                return;
            }

            setTvmRegisterC5(msg.outActions.verifyC5Actions(false));
        }

        ChangeWalletOwner => {
            var storage = AgenticWalletStorage.loadInitialized();

            assert (in.senderAddress == storage.ownerAddress) throw Errors.NotFromOwner;
            assert (isValidForwardPayload(msg.forwardPayload)) throw Errors.IncorrectForwardPayload;
            assert (msg.newOwnerAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;

            val fwdFee = in.originalForwardFee;
            var restAmount = contract.getOriginalBalance() - MIN_WALLET_STORAGE;
            // the excess is at most the incoming value minus the forward amount and fees.
            // So the wallet balance pays only the gas, and the incoming value limits the gas.
            var requestAmount = in.valueCoins;

            if (msg.forwardAmount != 0) {
                restAmount -= (msg.forwardAmount + fwdFee);
                requestAmount -= (msg.forwardAmount + fwdFee);
            }

            if (msg.sendExcessesTo != null) {
                assert (
                    msg.sendExcessesTo.getWorkchain() == BASECHAIN
                ) throw Errors.InvalidWorkchain;

                restAmount -= fwdFee;
                requestAmount -= fwdFee;
            }

            assert (restAmount >= 0) throw Errors.TooSmallRestAmount;
            assert (requestAmount >= 0) throw Errors.TooSmallFunding;

            if (msg.forwardAmount != 0) {
                val ownershipMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.newOwnerAddress,
                    value: msg.forwardAmount,
                    body: NotificationForNewOwner {
                        queryId: msg.queryId,
                        oldOwnerAddress: storage.ownerAddress,
                        forwardPayload: msg.forwardPayload,
                    },
                });

                ownershipMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            }

            if (msg.sendExcessesTo != null) {
                val excessesMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.sendExcessesTo,
                    value: min(restAmount, requestAmount),
                    body: ReturnExcessesBack { queryId: msg.queryId },
                });

                excessesMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            }

            storage.ownerAddress = msg.newOwnerAddress;
            storage.delegatePublicKey = 0;
            // cancels pending signed requests
            storage.seqno += 1;
            // the owner check allows this write
            // check-disable-next-line unauthorized-access
            storage.save();
        }

        ChangeWalletDelegate => {
            var storage = AgenticWalletStorage.loadInitialized();

            assert (in.senderAddress == storage.ownerAddress) throw Errors.NotFromOwner;

            storage.delegatePublicKey = msg.newDelegatePublicKey;
            // cancels pending signed requests
            storage.seqno += 1;
            // the owner check allows this write
            // check-disable-next-line unauthorized-access
            storage.save();
        }

        RequestStaticData => {
            val loadingStorage = lazy AgenticWalletStorage.startLoading();

            assert (loadingStorage.isInitialized()) throw Errors.NotInitialized;

            val respondMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                // the TEP-62 index is uint256, so the compiler would use a ref.
                // With `value: 0`, the body always fits inline.
                body: UnsafeBodyNoRef {
                    forceInline: ResponseStaticData {
                        queryId: msg.queryId,
                        walletIndex: loadingStorage.walletIndex as uint256,
                        collectionAddress: loadingStorage.collectionAddress,
                    },
                },
            });

            respondMsg.send(
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }

        EditWalletContent => {
            var storage = AgenticWalletStorage.loadInitialized();

            assert (in.senderAddress == storage.collectionAddress) throw Errors.NotFromCollection;

            storage.content = msg.newContent;
            // the collection check allows this write
            // check-disable-next-line unauthorized-access
            storage.save();
        }

        DeployWallet => {
            val loadingStorage = AgenticWalletStorage.startLoading();

            assert (!loadingStorage.isInitialized()) throw Errors.AlreadyInitialized;
            assert (
                in.senderAddress == loadingStorage.collectionAddress
            ) throw Errors.NotFromCollection;

            val initParams = msg.initParams.load();

            assert (
                isValidForwardPayload(initParams.forwardPayload)
            ) throw Errors.IncorrectForwardPayload;

            var restAmount = contract.getOriginalBalance() - MIN_WALLET_STORAGE;

            if (initParams.forwardAmount != 0) {
                restAmount -= (initParams.forwardAmount + in.originalForwardFee);
            }

            assert (restAmount >= 0) throw Errors.TooSmallRestAmount;

            if (initParams.forwardAmount != 0) {
                val ownershipMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: initParams.ownerAddress,
                    value: initParams.forwardAmount,
                    body: NotificationForNewOwner {
                        queryId: msg.queryId,
                        oldOwnerAddress: loadingStorage.collectionAddress,
                        forwardPayload: initParams.forwardPayload,
                    },
                });

                ownershipMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            }

            val storage: AgenticWalletStorage = {
                seqno: loadingStorage.seqno,
                walletIndex: loadingStorage.walletIndex,
                collectionAddress: loadingStorage.collectionAddress,
                ownerAddress: initParams.ownerAddress,
                delegatePublicKey: initParams.delegatePublicKey,
                content: initParams.content,
            };

            // the collection check allows this write
            // check-disable-next-line unauthorized-access
            storage.save();
        }

        else => {
            // accepts GRAM with empty, short, unknown and bounced bodies, without loading storage
        }
    }
}

/// Returns the seqno that the next signed request must have.
get fun seqno(): uint32 {
    val loadingStorage = lazy AgenticWalletStorage.startLoading();

    return loadingStorage.seqno;
}

/// Returns the delegate public key. Returns 0 if no key is set or the wallet is not initialized.
get fun get_public_key(): uint256 {
    var loadingStorage = AgenticWalletStorage.startLoading();

    if (!loadingStorage.isInitialized()) {
        return 0;
    }

    val storage = loadingStorage.endLoading();

    return storage.delegatePublicKey;
}

/// TEP-62: the wallet data. The owner and the content are null until the wallet is initialized.
get fun get_nft_data(): NftDataReply {
    var loadingStorage = AgenticWalletStorage.startLoading();

    if (!loadingStorage.isInitialized()) {
        return {
            isInitialized: false,
            walletIndex: loadingStorage.walletIndex,
            collectionAddress: loadingStorage.collectionAddress,
        };
    }

    val storage = loadingStorage.endLoading();

    return {
        isInitialized: true,
        walletIndex: storage.walletIndex,
        collectionAddress: storage.collectionAddress,
        ownerAddress: storage.ownerAddress,
        content: storage.content,
    };
}
