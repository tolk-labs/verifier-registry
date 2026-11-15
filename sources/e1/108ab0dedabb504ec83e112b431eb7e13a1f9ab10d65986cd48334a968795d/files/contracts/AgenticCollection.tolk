import "@stdlib/strings"

import "errors"
import "fees"
import "messages"
import "storage"
import "storage-collection"
import "wallet-content"

contract AgenticCollection {
    author: "mnemotiv"
    version: "2.0.0"
    description: "NFT collection of agentic wallets. TEP-62, TEP-64 and TEP-66 compliant."
    storage: AgenticCollectionStorage
    incomingMessages: AllowedMessageToAgenticCollection
}

type AllowedMessageToAgenticCollection =
    | RelayPublicDeployWallet
    | RelayDeployWallet
    | RequestRoyaltyParams
    | WithdrawCollectionBalance
    | RelayEditWalletContent
    | EditCollectionSettings
    | EditCollectionContent
    | ChangeCollectionAdmin

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToAgenticCollection.fromSlice(in.body);

    match (msg) {
        RelayPublicDeployWallet => {
            var storage = lazy AgenticCollectionStorage.load();
            val referralAddress = msg.referralAddress;

            assert (blockchain.globalId() == storage.networkId) throw Errors.WrongNetwork;
            assert (
                contract.getAddress().getWorkchain() == BASECHAIN
            ) throw Errors.InvalidWorkchain;
            assert (storage.publicDeployEnabled) throw Errors.PublicDeployDisabled;
            assert (
                storage.nextWalletIndex <= storage.maxWalletIndex
            ) throw Errors.WalletLimitReached;
            assert (in.senderAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;

            if (referralAddress != null) {
                assert (referralAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            }

            assert (
                in.valueCoins >= storage.deployPrice + MIN_WALLET_STORAGE
            ) throw Errors.TooSmallDeployValue;

            // adds the logical time to the seed, so each deploy in one block uses a different seed
            random.initialize();

            val content: TraitSetContent = { traitSetIndex: random.range(storage.traitSetCount) };

            val initParams: AgenticWalletInitParams = {
                ownerAddress: in.senderAddress,
                content: content.toCell(),
                delegatePublicKey: 0,
                forwardAmount: MIN_FORWARD_AMOUNT,
                forwardPayload: EmptyPayload {}.toCell().beginParse(),
            };

            val deployMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: calcDeployedAgenticWallet(
                    storage.nextWalletIndex,
                    contract.getAddress(),
                    storage.walletCode,
                ),
                value: in.valueCoins - storage.deployPrice + WALLET_DEPLOY_FEES,
                body: DeployWallet {
                    queryId: msg.queryId,
                    initParams: initParams.toCell(),
                },
            });

            // keeps the balance from before the message: sends use only the incoming value, or fail
            reserveGramsOnBalance(
                0,
                RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
            );
            // +16: a failed send bounces the request
            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

            if (referralAddress != null) {
                val referralReward = mulDivFloor(
                    storage.deployPrice,
                    storage.referralBps,
                    REFERRAL_BPS_DENOMINATOR,
                );

                if (referralReward > 0) {
                    val referralMsg = createMessage({
                        bounce: BounceMode.NoBounce,
                        dest: referralAddress,
                        value: referralReward,
                        // the text is short and constant, so it fits inline
                        body: UnsafeBodyNoRef {
                            forceInline: TextComment { text: "Referral reward".literalSlice() },
                        },
                    });

                    referralMsg.send(
                        SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
                    );
                }
            }

            storage.nextWalletIndex += 1;
            // anyone can deploy: the sender pays the deploy price
            // check-disable-next-line unauthorized-access
            storage.save();
        }

        RelayDeployWallet => {
            var storage = lazy AgenticCollectionStorage.load();

            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;
            assert (blockchain.globalId() == storage.networkId) throw Errors.WrongNetwork;
            assert (
                contract.getAddress().getWorkchain() == BASECHAIN
            ) throw Errors.InvalidWorkchain;

            val retryIndex = msg.walletIndex;
            var walletIndex = storage.nextWalletIndex;

            if (retryIndex != null) {
                // the max wallet index does not apply to a retry of an allocated index
                assert (retryIndex < storage.nextWalletIndex) throw Errors.InvalidWalletIndex;
                walletIndex = retryIndex;
            } else {
                assert (walletIndex <= storage.maxWalletIndex) throw Errors.WalletLimitReached;
            }

            val deployMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: calcDeployedAgenticWallet(
                    walletIndex,
                    contract.getAddress(),
                    storage.walletCode,
                ),
                value: msg.attachAmount,
                body: DeployWallet {
                    queryId: msg.queryId,
                    initParams: msg.initParams,
                },
            });

            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

            if (retryIndex == null) {
                storage.nextWalletIndex += 1;
                storage.save();
            }
        }

        RequestRoyaltyParams => {
            val storage = lazy AgenticCollectionStorage.load();

            val respondMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ResponseRoyaltyParams {
                    queryId: msg.queryId,
                    royaltyParams: storage.royaltyParams.load(),
                },
            });

            respondMsg.send(
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }

        WithdrawCollectionBalance => {
            val storage = lazy AgenticCollectionStorage.load();

            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;

            reserveGramsOnBalance(
                MIN_COLLECTION_STORAGE,
                RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
            );

            val payout = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: in.senderAddress,
                value: 0,
                body: WithdrawCollectionBalance { queryId: msg.queryId },
            });

            // SAFETY: only the admin can send this. The exact reserve keeps the storage reserve,
            // and mode 128 sends the rest. If the balance is less than the storage
            // reserve, +16 on both bounces the request. There is no +2/+32, so the account is never
            // destroyed. The payout is bounceable.
            payout.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        RelayEditWalletContent => {
            val storage = lazy AgenticCollectionStorage.load();

            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;
            assert (msg.walletIndex < storage.nextWalletIndex) throw Errors.InvalidWalletIndex;

            val walletAddress = calcDeployedAgenticWallet(
                msg.walletIndex,
                contract.getAddress(),
                storage.walletCode,
            ).calculateAddress();

            val relayMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: walletAddress,
                value: 0,
                body: EditWalletContent {
                    queryId: msg.queryId,
                    newContent: msg.newContent,
                },
            });

            relayMsg.send(
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            );
        }

        EditCollectionSettings => {
            var storage = lazy AgenticCollectionStorage.load();

            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;

            storage.maxWalletIndex = msg.maxWalletIndex;
            storage.publicDeployEnabled = msg.publicDeployEnabled;
            storage.deployPrice = msg.deployPrice;
            storage.referralBps = msg.referralBps;
            storage.traitSetCount = msg.traitSetCount;
            storage.save();
        }

        EditCollectionContent => {
            var storage = lazy AgenticCollectionStorage.load();

            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;

            storage.content = msg.newContent;
            storage.royaltyParams = msg.newRoyaltyParams;
            storage.save();
        }

        ChangeCollectionAdmin => {
            var storage = lazy AgenticCollectionStorage.load();

            assert (in.senderAddress == storage.adminAddress) throw Errors.NotFromAdmin;

            storage.adminAddress = msg.newAdminAddress;
            storage.save();
        }

        else => {
            // accept empty top-ups, reject any other body
            assert (in.body.isEmpty()) throw Errors.UnknownOperation;
        }
    }
}

/// Accepts funds returned by bounced wallet deploys, content relays and withdrawal payouts.
fun onBouncedMessage(_in: InMessageBounced) {}

/// TEP-62: the next wallet index, the collection metadata and the admin.
get fun get_collection_data(): CollectionDataReply {
    val storage = lazy AgenticCollectionStorage.load();
    val content = lazy storage.content.load();

    return {
        nextWalletIndex: storage.nextWalletIndex,
        collectionMetadata: content.collectionMetadata,
        adminAddress: storage.adminAddress,
    };
}

/// Returns the max wallet index and the public deploy settings.
get fun get_collection_settings(): CollectionSettingsReply {
    val storage = lazy AgenticCollectionStorage.load();

    return {
        maxWalletIndex: storage.maxWalletIndex,
        publicDeployEnabled: storage.publicDeployEnabled,
        deployPrice: storage.deployPrice,
        referralBps: storage.referralBps,
        traitSetCount: storage.traitSetCount,
    };
}

/// TEP-62: address of wallet `walletIndex`, deployed or not.
get fun get_nft_address_by_index(walletIndex: int): address {
    val storage = lazy AgenticCollectionStorage.load();

    val walletDeployed = calcDeployedAgenticWallet(
        walletIndex,
        contract.getAddress(),
        storage.walletCode,
    );

    return walletDeployed.calculateAddress();
}

/// Expands `TraitSetContent` into off-chain content
/// "<commonContent><traitSetIndex>/<walletIndex>.json".
/// Expands `WalletIndexContent` into "<commonContent><walletIndex>.json".
/// Both formats ignore the bits and refs after their fields.
/// Returns other content as is: it must already be TEP-64.
get fun get_nft_content(
    walletIndex: int,
    individualContent: cell,
): cell {
    val content = lazy WalletContent.fromSlice(individualContent.beginParse());

    return match (content) {
        TraitSetContent => offchainWalletContent(
            walletContentUrl().appendInt(content.traitSetIndex).append("/"),
            walletIndex,
        ),
        WalletIndexContent => offchainWalletContent(walletContentUrl(), walletIndex),
        else => individualContent,
    };
}

/// TEP-66: the royalty params.
get fun royalty_params(): RoyaltyParams {
    val storage = lazy AgenticCollectionStorage.load();

    return storage.royaltyParams.load();
}
