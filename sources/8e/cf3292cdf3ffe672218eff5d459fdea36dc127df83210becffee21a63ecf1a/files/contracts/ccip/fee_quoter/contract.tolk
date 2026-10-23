// SPDX-License-Identifier: BUSL-1.1
import "errors"
import "events"
import "messages"
import "types"
import "storage"

import "../common/types";
import "../common/cross_chain_address_validation"
import "../../lib/access/ownable_2step";
import "../../lib/deployable/types";
import "../../lib/funding/withdrawable"
import "../../lib/versioning/upgradeable"
import "../../lib/utils";
import "../../lib/math";
import "../router/messages"
import "../ccipsend_executor/messages"

const CONTRACT_VERSION = "1.6.3";
const RESERVE = ton("1");

fun onInternalMessage(in: InMessage) {
    val msg = lazy FeeQuoter_InMessage.fromSlice(in.body);
    match (msg) {
        FeeQuoter_AddPriceUpdater => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            st.allowedPriceUpdaters.addIfNotExists(msg.priceUpdater, ());
            st.store();
        },
        FeeQuoter_RemovePriceUpdater => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            st.allowedPriceUpdaters.delete(msg.priceUpdater);
            st.store();
        },
        FeeQuoter_UpdatePrices => {
            var st = lazy Storage.load();

            // either an allowed price updater or feeQuoter owner
            assert(st.allowedPriceUpdaters.exists(in.senderAddress) || st.ownable.owner == in.senderAddress, FeeQuoter_Error.UnauthorizedPriceUpdater);
            updatePrices(mutate st, msg.updates);
            st.store();

            sendExcessesTo(msg.sendExcessesTo, in.senderAddress);
        }
        FeeQuoter_UpdateFeeTokens => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            updateFeeTokens(mutate st, msg);

            st.store();
        }
        FeeQuoter_UpdateTokenTransferFeeConfigs => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            updateTokenTransferFeeConfigs(mutate st, msg);
            st.store();
        }
        FeeQuoter_UpdateDestChainConfigs => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            updateDestChainConfigs(mutate st, msg.updates);
            st.store();
        }
        FeeQuoter_GetValidatedFee<RemainingBitsAndRefs> => {
            assert (in.valueCoins >= FeeQuoter_Costs.GetValidatedFee()) throw FeeQuoter_Error.InsufficientFee;
            handleGetValidatedFee(msg, in.senderAddress)
        }
        Withdrawable_Withdraw => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            Withdrawable{
                reserve: RESERVE
            }.withdraw(msg, in.valueCoins);
        }
        Upgradeable_Upgrade => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            Upgradeable{ migrate, version }.upgrade(msg);
        }
        else => {
            // attempt to handle Ownable messages
            var st = lazy Storage.load();
            val handled = st.ownable.onInternalMessage(in.senderAddress, in.body);
            if (handled) {
                st.store();
                return;
            }

            // ignore empty messages, "wrong opcode" for others
            assert (in.body.isEmpty()) throw 0xFFFF
        }
    }
}

fun updateFeeTokens(mutate st: Storage, msg: FeeQuoter_UpdateFeeTokens) {
    var entry = msg.add.findFirst();
    while (entry.isFound) {
        val token = entry.getKey();
        val config = entry.loadValue();
        st.premiumMultiplierWeiPerEth.set(token, config.premiumMultiplierWeiPerEth);
        entry = msg.add.iterateNext(entry);
    }

    var iter = msg.remove.iter();
    while (!iter.empty()) {
        val tokenAddr = iter.next();
        st.premiumMultiplierWeiPerEth.delete(tokenAddr);
    }
}

fun updateTokenTransferFeeConfigs(mutate st: Storage, msg: FeeQuoter_UpdateTokenTransferFeeConfigs) {
    var entry = msg.updates.findFirst();
    while (entry.isFound) {
        val destChainSelector = entry.getKey();
        val update = entry.loadValue();
        var configEntry = st.destChainConfigs.get(destChainSelector);
        if (configEntry.isFound) {
            var destChainConfig = configEntry.loadValue();

            var tokenEntry = update.add.findFirst();
            while (tokenEntry.isFound) {
                val tokenAddr = tokenEntry.getKey();
                val config = tokenEntry.loadValue();

                destChainConfig.tokenTransferFeeConfigs.set(tokenAddr, config);
                tokenEntry = update.add.iterateNext(tokenEntry);
            }

            var iter = update!.remove.iter();
            while (!iter.empty()) {
                val tokenAddr = iter.next();
                destChainConfig.tokenTransferFeeConfigs.delete(tokenAddr);
            }

            st.destChainConfigs.replaceIfExists(destChainSelector, destChainConfig);
        }
        entry = msg.updates.iterateNext(entry);
    }
}

fun updateDestChainConfigs(mutate st: Storage, updates: SnakedCell<FeeQuoter_UpdateDestChainConfig>) {
    var iter = updates.iter();

    while (!iter.empty()) {
        val update = iter.next();
        // create or update entries
        val entry = st.destChainConfigs.get(update.destChainSelector);
        if (entry.isFound) {
            var destChainConfig = entry.loadValue();
            destChainConfig.config = update.destChainConfig;
            st.destChainConfigs.replaceIfExists(update.destChainSelector, destChainConfig);
        } else {
            st.destChainConfigs.set(update.destChainSelector, DestChainConfig {
                config: update.destChainConfig,
                usdPerUnitGas: GasPrice {
                    executionGasPrice: 0,
                    dataAvailabilityGasPrice: 0,
                    timestamp: 0,
                }.toCell(),
                tokenTransferFeeConfigs: createEmptyMap()
            })
        }
    }
}

fun updatePrices(mutate st: Storage, priceUpdates: PriceUpdates) {
    val timestamp = blockchain.now();

    var iter = priceUpdates.tokenPriceUpdates.iter();
    while (!iter.empty()) {
        val update = iter.next();

        st.usdPerToken.set(update.sourceToken, TimestampedPrice {
            value: update.usdPerToken,
            timestamp
        });

        emit(USD_PER_TOKEN_UPDATED_TOPIC, UsdPerTokenUpdated {
            sourceToken: update.sourceToken,
            usdPerToken: update.usdPerToken,
            timestamp,
        })
    }

    var iter2 = priceUpdates.gasPriceUpdates.iter();
    while (!iter2.empty()) {
        val update = iter2.next();

        val entry = st.destChainConfigs.get(update.destChainSelector);
        // NOTE: this only allows pushing gas updates to chains with a destChainConfig
        if (entry.isFound) {
            var destChainConfig = entry.loadValue();
            destChainConfig.usdPerUnitGas = GasPrice {
                executionGasPrice: update.executionGasPrice,
                dataAvailabilityGasPrice: update.dataAvailabilityGasPrice,
                timestamp
            }.toCell();
            st.destChainConfigs.replaceIfExists(update.destChainSelector, destChainConfig);

            emit(USD_PER_UNIT_GAS_UPDATED, UsdPerUnitGasUpdated {
                destChainSelector: update.destChainSelector,
                executionGasPrice: update.executionGasPrice,
                dataAvailabilityGasPrice: update.dataAvailabilityGasPrice,
                timestamp,
            })
        }
    }


}

// apply_premium_multiplier_wei_per_eth_updates??

fun DestChainConfig.getValidatedGasPrice(self): (uint112, uint112) {
    val price = self.usdPerUnitGas.load();
    val threshold = self.config.gasPriceStalenessThreshold as int64;
    val elapsedTime = blockchain.now() - price.timestamp;

    assert(threshold == 0 || threshold > elapsedTime, FeeQuoter_Error.StaleGasPrice);

    return (price.executionGasPrice, price.dataAvailabilityGasPrice)
}

// Note: Equivalent to validatedFee for cell encoding instead of using stack
get fun validatedFeeCell(msg: Cell<Router_CCIPSend>): coins {
    return validatedFee(msg.load());
}

get fun validatedFee(msg: Router_CCIPSend): coins {
    val (fee, _) = calculateValidatedFee(msg);
    return fee.feeTokenAmount;
}

fun calculateValidatedFee(msg: Router_CCIPSend): (Fee, ExtraArgs) {
    var st = lazy Storage.load();

    val destChainConfigResult = st.destChainConfigs.get(msg.destChainSelector);
    assert (destChainConfigResult.isFound) throw FeeQuoter_Error.DestChainNotEnabled;
    var destChainConfig = destChainConfigResult.loadValue();

    assert(destChainConfig.config.isEnabled, FeeQuoter_Error.DestChainNotEnabled);
    assert(msg.feeToken != null, FeeQuoter_Error.FeeTokenNotSupported);
    val feeToken = msg.feeToken!;
    val premiumMultiplier = st.premiumMultiplierWeiPerEth.mustGet(feeToken, FeeQuoter_Error.FeeTokenNotSupported as int);
    val feeTokenPrice = st.usdPerToken.mustGet(feeToken, FeeQuoter_Error.FeeTokenNotSupported as int);

    val (msgDataLen, errorCode) = msg.data.canonicalByteSnakeSafe();
    match (errorCode) {
        0 => { /* continue */ }
        8 => {
            throw FeeQuoter_Error.MsgDataTooLarge;
        }
        Utils_Error.InvalidData as int => {
            throw FeeQuoter_Error.InvalidMsgData;
        }
        else => {
            throw errorCode;
        }
    }

    var (validatedExtraArgs, gasLimit) = validateMessageAndResolveGasLimitForDestination(msg.extraArgs, destChainConfig.config, msg, msgDataLen);

    val (executionGasPrice: uint112, dataAvailabilityGasPrice: uint112) = destChainConfig.getValidatedGasPrice();

    val premiumFeeUsdWei = mustProd(destChainConfig.config.networkFeeUsdCents, VAL_1E16, FeeQuoter_Error.PremiumFeeOverflow as int);

    val dataAvailabilityCost = _dataAvailabilityCost(
        destChainConfig,
        dataAvailabilityGasPrice,
        msgDataLen,
        0,
        0,
    );

    val calldataLen = msgDataLen; // + token transfer overheads, not supported in TON yet
    var calldataGas = mustProd(calldataLen, destChainConfig.config.destGasPerPayloadByteBase, FeeQuoter_Error.ExecutionCostOverflow as int);
    val calldataThreshold = destChainConfig.config.destGasPerPayloadByteThreshold;
    if (calldataLen > calldataThreshold) {
        val baseCalldataGas = mustProd(destChainConfig.config.destGasPerPayloadByteBase, calldataThreshold, FeeQuoter_Error.ExecutionCostOverflow as int);
        val extraBytes = calldataLen - calldataThreshold;
        val extraCalldataGas = mustProd(extraBytes, destChainConfig.config.destGasPerPayloadByteHigh, FeeQuoter_Error.ExecutionCostOverflow as int);
        calldataGas = mustAdd(baseCalldataGas, extraCalldataGas, FeeQuoter_Error.ExecutionCostOverflow as int);
    }

    val executionGas = mustAdd(mustAdd(gasLimit, destChainConfig.config.destGasOverhead, FeeQuoter_Error.ExecutionCostOverflow as int), calldataGas, FeeQuoter_Error.ExecutionCostOverflow as int);

    val executionCost = mustProd(mustProd(executionGasPrice, executionGas, FeeQuoter_Error.ExecutionCostOverflow as int), destChainConfig.config.gasMultiplierWeiPerEth, FeeQuoter_Error.ExecutionCostOverflow as int);

    val premiumFee = mustProd(premiumFeeUsdWei, premiumMultiplier, FeeQuoter_Error.PremiumFeeOverflow as int);
    val feeTokenValue = mustAdd(mustAdd(premiumFee, executionCost, FeeQuoter_Error.FeeCalculationOverflow as int), dataAvailabilityCost, FeeQuoter_Error.FeeCalculationOverflow as int);

    // Check for division by zero (zero token prices)
    assert(feeTokenPrice.value > 0, FeeQuoter_Error.TokenPriceTooLow);
    val feeTokenAmount = (feeTokenValue / feeTokenPrice.value);

    // Equivalent to processMessageArgs in Solidity FeeQuoter
    val feeValueJuels = calculateFeeValueJuels(st, feeToken, feeTokenValue, feeTokenAmount);

    return (Fee {
            feeTokenAmount: mustCastToCoin(feeTokenAmount, FeeQuoter_Error.FeeOverflow as int),
            feeValueJuels: feeValueJuels as uint96, // safe because already checked against maxFeeJuelsPerMsg
        },
        validatedExtraArgs,
    );
}

fun calculateFeeValueJuels(st: Storage, feeToken: address, feeTokenValue: coins, feeTokenAmount: coins): coins {
    var feeValueJuels = feeTokenAmount;
    if (feeToken != st.linkToken) {
        val linkTokenPrice = st.usdPerToken.mustGet(st.linkToken, FeeQuoter_Error.TokenNotSupported as int);
        // Check for division by zero (zero token prices)
        assert(linkTokenPrice.value > 0, FeeQuoter_Error.TokenPriceTooLow);
        // convert from USD to juels
        feeValueJuels = feeTokenValue / linkTokenPrice.value;
    }

    assert (feeValueJuels <= st.maxFeeJuelsPerMsg) throw FeeQuoter_Error.MessageFeeTooHigh;
    return feeValueJuels;
}

fun _dataAvailabilityCost(
    destChainConfig: DestChainConfig,
    dataAvailabilityGasPrice: uint112,
    msgDataLen: uint256,
    tokenCount: uint256,
    tokenTransferBytesOverhead: uint256,
): uint256 {
    assert (tokenCount == 0) throw FeeQuoter_Error.TokenTransfersNotSupported;
    assert (tokenTransferBytesOverhead == 0) throw FeeQuoter_Error.TokenTransfersNotSupported;
    // Sums up byte lengths of fixed message fields and dynamic message fields.
    // Fixed message fields do account for the offset and length slot of the dynamic fields.
    val dataAvailabilityLengthBytes = TON_2_EVM_MESSAGE_FIXED_BYTES
        + msgDataLen;
        // Token transfers not supported in TON yet
        // + tokenCount as uint256 * TON_2_EVM_MESSAGE_FIXED_BYTES_PER_TOKEN
        // + tokenTransferBytesOverhead

    // dest_data_availability_overhead_gas is a separate config value for flexibility to be updated
    // independently of message codestChainConfig. Its value is determined by CCIP lane implementation, e.g.
    // the overhead data posted for OCR.
    val daLengthCost = mustProd(dataAvailabilityLengthBytes, destChainConfig.config.destGasPerDataAvailabilityByte, FeeQuoter_Error.DataAvailabilityCostOverflow as int);
    val dataAvailabilityGas = mustAdd(daLengthCost, destChainConfig.config.destDataAvailabilityOverheadGas, FeeQuoter_Error.DataAvailabilityCostOverflow as int);

    // data_availability_gas_price is in 18 decimals, dest_data_availability_multiplier_bps is in 4 decimals
    // We pad 14 decimals to bring the result to 36 decimals, in line with token bps and execution fee.
    val daPrice = mustProd(dataAvailabilityGasPrice, dataAvailabilityGas, FeeQuoter_Error.DataAvailabilityCostOverflow as int);
    val daWithMultiplier = mustProd(daPrice, destChainConfig.config.destDataAvailabilityMultiplierBps, FeeQuoter_Error.DataAvailabilityCostOverflow as int);
    return mustProd(daWithMultiplier, VAL_1E14, FeeQuoter_Error.DataAvailabilityCostOverflow as int);
}

fun validateMessageAndResolveGasLimitForDestination(extraArgs: cell, config: FeeQuoterDestChainConfig, message: Router_CCIPSend, msgDataLen: uint256): (ExtraArgs, int) {
    // Check that payload is formed correctly.
    assert (msgDataLen <= config.maxDataBytes) throw FeeQuoter_Error.MsgDataTooLarge;
    // Token transfers are unsupported at this version: require a plain ordinary
    // empty cell. A CTOS-resolving `iter().empty()` would accept a library
    // reference, whose emitted cell is still the 264-bit descriptor.
    val (tokenAmountsSlice, tokenAmountsExotic) = message.tokenAmounts.beginParseSpecial();
    assert (!tokenAmountsExotic && tokenAmountsSlice.isEmpty()) throw FeeQuoter_Error.UnsupportedNumberOfTokens;

    // NOTE: we could deploy distinct contracts to cut down on code
    if (config.chainFamilySelector == CHAIN_FAMILY_SELECTOR_EVM ||
        config.chainFamilySelector == CHAIN_FAMILY_SELECTOR_APTOS ||
        config.chainFamilySelector == CHAIN_FAMILY_SELECTOR_TVM) {
        val genericExtraArgsV2 = parseGenericExtraArgs(extraArgs, config.defaultTxGasLimit, config.maxPerMsgGasLimit);
        val gasLimit = genericExtraArgsV2.gasLimit!; // not-nil after parsing
        validateDestFamilyAddress(config.chainFamilySelector, message.receiver, gasLimit);
        return (genericExtraArgsV2 as ExtraArgs, gasLimit);
    }
    else if (config.chainFamilySelector == CHAIN_FAMILY_SELECTOR_SUI) {
        val suiExtraArgs = parseSuiExtraArgs(extraArgs, config.maxPerMsgGasLimit);
        val gasLimit = suiExtraArgs.gasLimit;
        validateDestFamilyAddress(config.chainFamilySelector, message.receiver, gasLimit);

        // Require a canonical snake: complete elements (no element straddles a cell
        // boundary) and no exotic/branched cells.
        val receiverObjectIdsLength = validateExtraArgsCollection(
            suiExtraArgs.receiverObjectIds,
            SUI_ACCOUNT_BYTE_SIZE * 8,
        );
        // The max payload size for SUI is heavily dependent on the receiver object ids passed into extra args and the number of
        // tokens. Below, token and account overhead will count towards maxDataBytes.
        var suiExpandedDataLength = msgDataLen;

        if (a32ByteAddress.fromSlice(message.receiver).value == 0) {
            // When message receiver is zero, CCIP receiver is not invoked on SUI.
            // There should not be additional accounts specified for the receiver.
            assert (receiverObjectIdsLength == 0) throw FeeQuoter_Error.InvalidSuiReceiverAddress;
        } else {
            // The messaging accounts needed for CCIP receiver on SUI are:
            // message receiver,
            // plus remaining accounts specified in Sui extraArgs. Each receiverObjectId is 32 bytes.
            suiExpandedDataLength += ((receiverObjectIdsLength + SUI_MESSAGING_ACCOUNTS_OVERHEAD) * SUI_ACCOUNT_BYTE_SIZE);
        }
         
        assert (receiverObjectIdsLength <= SUI_EXTRA_ARGS_MAX_RECEIVER_OBJECT_IDS) throw FeeQuoter_Error.TooManySuiExtraArgsReceiverObjectIds;

        assert (suiExpandedDataLength <= config.maxDataBytes) throw FeeQuoter_Error.MsgDataTooLarge;

        return (suiExtraArgs as ExtraArgs, gasLimit);
    }
    else if (config.chainFamilySelector == CHAIN_FAMILY_SELECTOR_SVM) {
        val svmExtraArgs = parseSvmExtraArgs(extraArgs, config.maxPerMsgGasLimit);
        val gasLimit = svmExtraArgs.computeUnits;
        validateDestFamilyAddress(config.chainFamilySelector, message.receiver, gasLimit);

        // Require a canonical snake: complete elements (no element straddles a cell
        // boundary) and no exotic/branched cells.
        val accountsLength = validateExtraArgsCollection(
            svmExtraArgs.accounts,
            SVM_ACCOUNT_BYTE_SIZE * 8,
        );
        // The max payload size for SVM is heavily dependent on the receiver object ids passed into extra args and the number of
        // tokens. Below, token and account overhead will count towards maxDataBytes.
        var svmExpandedDataLength = msgDataLen;

        if (a32ByteAddress.fromSlice(message.receiver).value == 0) {
            // When message receiver is zero, CCIP receiver is not invoked on SVM.
            // There should not be additional accounts specified for the receiver.
            assert (accountsLength == 0) throw FeeQuoter_Error.InvalidSVMReceiverAddress;
        } else {
            // The messaging accounts needed for CCIP receiver on SVM are:
            // message receiver, offRamp PDA signer,
            // plus remaining accounts specified in SVM extraArgs. Each account is 32 bytes.
            svmExpandedDataLength += ((accountsLength + SVM_MESSAGING_ACCOUNTS_OVERHEAD) * SVM_ACCOUNT_BYTE_SIZE);
        }

        assert (accountsLength <= SVM_EXTRA_ARGS_MAX_ACCOUNTS) throw FeeQuoter_Error.TooManySVMExtraArgsAccounts;

        // Mirrors EVM FeeQuoter. Safe to shift: `accountsLength` is bounded by
        // SVM_EXTRA_ARGS_MAX_ACCOUNTS above.
        assert (svmExtraArgs.accountIsWritableBitmap >> accountsLength == 0) throw FeeQuoter_Error.InvalidSVMExtraArgsWritableBitmap;

        assert (svmExpandedDataLength <= config.maxDataBytes) throw FeeQuoter_Error.MsgDataTooLarge;

        return (svmExtraArgs as ExtraArgs, gasLimit);
    } else {
        throw FeeQuoter_Error.UnsupportedChainFamilySelector;
    }
}

fun parseGenericExtraArgs(extraArgs: cell, defaultTxGasLimit: uint32, maxPerMsgGasLimit: uint32): GenericExtraArgsV2 {
    val extra = _parseUnvalidatedEVMExtraArgs(extraArgs, defaultTxGasLimit);
    // Resolve an absent gasLimit to the default so it never escapes unresolved.
    val gasLimit = extra.gasLimit != null ? extra.gasLimit! : defaultTxGasLimit as uint256;
    assert (gasLimit <= maxPerMsgGasLimit) throw FeeQuoter_Error.GasLimitTooHigh;
    // Out of order is always enforced because we don't do ordering on non-EVMs
    assert (extra.allowOutOfOrderExecution) throw FeeQuoter_Error.ExtraArgOutOfOrderExecutionMustBeTrue;
    return GenericExtraArgsV2 { gasLimit, allowOutOfOrderExecution: extra.allowOutOfOrderExecution };
}

fun _parseUnvalidatedEVMExtraArgs(extraArgs: cell, defaultTxGasLimit: uint32): GenericExtraArgsV2 {
    if (extraArgs.beginParse().isEmpty()) {
        return GenericExtraArgsV2 {
            gasLimit: defaultTxGasLimit as uint256,
            allowOutOfOrderExecution: true,
        };
    }
    return GenericExtraArgsV2.fromCell(extraArgs);
}

fun parseSvmExtraArgs(extraArgs: cell, maxPerMsgGasLimit: uint32): SVMExtraArgsV1 {
    val extra = SVMExtraArgsV1.fromCell(extraArgs, {
        throwIfOpcodeDoesNotMatch: FeeQuoter_Error.InvalidExtraArgsData as int,
    });
    assert (extra.computeUnits <= maxPerMsgGasLimit) throw FeeQuoter_Error.GasLimitTooHigh;
    // Out of order is always enforced because we don't do ordering on non-EVMs
    assert (extra.allowOutOfOrderExecution) throw FeeQuoter_Error.ExtraArgOutOfOrderExecutionMustBeTrue;
    return extra;
}

fun parseSuiExtraArgs(extraArgs: cell, maxPerMsgGasLimit: uint32): SuiExtraArgsV1 {
    val extra = SuiExtraArgsV1.fromCell(extraArgs, {
        throwIfOpcodeDoesNotMatch: FeeQuoter_Error.InvalidExtraArgsData as int,
    });
    assert (extra.gasLimit <= maxPerMsgGasLimit) throw FeeQuoter_Error.GasLimitTooHigh;
    // Out of order is always enforced because we don't do ordering on non-EVMs
    assert (extra.allowOutOfOrderExecution) throw FeeQuoter_Error.ExtraArgOutOfOrderExecutionMustBeTrue;
    return extra;
}

fun validateExtraArgsCollection(collection: cell, elemBits: int): int {
    val (count, errorCode) = collection.canonicalFixedWidthSnakeSafe(elemBits);
    match (errorCode) {
        0 => { /* continue */ }
        8 => {
            throw FeeQuoter_Error.MsgDataTooLarge;
        }
        Utils_Error.InvalidData as int => {
            throw FeeQuoter_Error.InvalidExtraArgsData;
        }
        else => {
            throw errorCode;
        }
    }
    return count;
}

fun validateDestFamilyAddress(chainFamilySelector: uint32, receiver: CrossChainAddress, gasLimit: int) {
    if (chainFamilySelector == CHAIN_FAMILY_SELECTOR_EVM) {
        return receiver.validateEVMAddress(FeeQuoter_Error.InvalidEVMReceiverAddress as int);
    } else if (chainFamilySelector == CHAIN_FAMILY_SELECTOR_SVM) {
        // SVM addresses don't have a precompile space at the first X addresses, instead we validate that if the gasLimit
        // is non-zero, the address must not be 0x0.
        return receiver.validate32ByteAddress(gasLimit > 0 ? 1 : 0, FeeQuoter_Error.Invalid32ByteReceiverAddress as int);
    } else if (chainFamilySelector == CHAIN_FAMILY_SELECTOR_APTOS) {
        return receiver.validate32ByteAddress(APTOS_PRECOMPILE_SPACE, FeeQuoter_Error.Invalid32ByteReceiverAddress as int);
    } else if (chainFamilySelector == CHAIN_FAMILY_SELECTOR_SUI) {
        return receiver.validate32ByteAddress(gasLimit > 0 ? SUI_PRECOMPILE_SPACE : 0, FeeQuoter_Error.Invalid32ByteReceiverAddress as int);
    } else {
        throw FeeQuoter_Error.UnsupportedChainFamilySelector;
    }
}


fun handleGetValidatedFee(payload: FeeQuoter_GetValidatedFee<RemainingBitsAndRefs>, sender: address) {
    val msg = payload.msg.load();
    var response: OutMessage;
    try {
        val (fee, extraArgs) = calculateValidatedFee(msg);
        var ccipSend = lazy payload.msg.load();
        ccipSend.extraArgs = extraArgs.toCell();

        response = createMessage({
            bounce: true,
            value: 0,
            dest: sender,
            body: FeeQuoter_MessageValidated<RemainingBitsAndRefs> {
                fee: {
                    feeTokenAmount: fee.feeTokenAmount,
                    feeValueJuels: fee.feeValueJuels,
                },
                msg: ccipSend.toCell(),
                context: payload.context,
            }
        });
    } catch (e) {
        response = createMessage({
            bounce: true,
            value: 0,
            dest: sender,
            body: FeeQuoter_MessageValidationFailed<RemainingBitsAndRefs> {
                msg: payload.msg,
                error: e,
                context: payload.context,
            }
        });
    }
    response.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

fun sendExcessesTo(sendExcessesTo: address?, sender: address) {
    var receiver = sender;
    if (sendExcessesTo != null) {
        receiver = sendExcessesTo!;
    }

    val returnExcesses = createMessage({
        bounce: false,
        value: 0,
        dest: receiver,
        body: createEmptyCell(),
    });
    reserveToncoinsOnBalance(0, RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE);
    returnExcesses.send(SEND_MODE_CARRY_ALL_BALANCE);
}

get fun tokenPrice(token: address): TimestampedPrice {
    val st = lazy Storage.load();
    val entry = st.usdPerToken.get(token);
    assert (entry.isFound, FeeQuoter_Error.TokenNotSupported);
    return entry.loadValue();
}

// vec<TimestampedPrice>
get fun tokenPrices(tokens: tuple): tuple {
    val st = lazy Storage.load();
    var list: tuple = createEmptyTuple();
    var iter = TupleIterator<address>.new(tokens);

    while(!iter.empty()) {
        val token = iter.next();
        val entry = st.usdPerToken.get(token);
        // NOTE: Need to skip missing items as nil entries rather than fail the query
        if (entry.isFound) {
            list.push(entry.loadValue().toCell());
        } else {
            list.push(null);
        }
    }
    return list;
}

get fun destinationChainGasPrice(destChainSelector: uint64): cell {
    val st = lazy Storage.load();
    var entry = st.destChainConfigs.get(destChainSelector);
    assert (entry.isFound, FeeQuoter_Error.UnknownDestChainSelector);
    return entry.loadValue().usdPerUnitGas
}

get fun tokenAndGasPrices(token: address, destChainSelector: uint64) {
    
}

get fun premiumMultiplierWeiPerEth(token: address): uint256 {
    val st = lazy Storage.load();
    val v = st.premiumMultiplierWeiPerEth.mustGet(token, FeeQuoter_Error.FeeTokenNotSupported as int);
    return v as uint256;
}

// vec<address>
get fun feeTokens(): tuple? {
    val st = lazy Storage.load();
    var feeTokens = st.premiumMultiplierWeiPerEth;
    return keysLispList(feeTokens);
}

get fun tokenTransferFeeConfig(
    destChainSelector: uint64,
    token: address,
): TokenTransferFeeConfig {
    val st = lazy Storage.load();
    val destChainConfig = st.destChainConfigs.mustGet(destChainSelector, FeeQuoter_Error.DestChainNotEnabled as int);
    return destChainConfig.tokenTransferFeeConfigs.mustGet(token, FeeQuoter_Error.FeeTokenNotSupported as int);
}

get fun destChainConfig(destChainSelector: uint64): DestChainConfig {
    val st = lazy Storage.load();
    return st.destChainConfigs.mustGet(destChainSelector, FeeQuoter_Error.DestChainNotEnabled as int);
}

get fun staticConfig(): (uint96, address, uint32) {
    val st = lazy Storage.load();
    return (st.maxFeeJuelsPerMsg, st.linkToken, st.tokenPriceStalenessThreshold);
}

get fun dataAvailabilityCost(
    destChainSelector: uint64,
    dataAvailabilityGasPrice: uint112,
    calldataLen: uint256,
    tokenCount: uint256,
    tokenTransferBytesOverhead: uint256,
): uint256 {
    val st = lazy Storage.load();

    val destChainConfig = st.destChainConfigs.mustGet(destChainSelector, FeeQuoter_Error.DestChainNotEnabled as int);
    return _dataAvailabilityCost(
        destChainConfig,
        dataAvailabilityGasPrice,
        calldataLen,
        tokenCount,
        tokenTransferBytesOverhead,
    );
}

/// Gets the current owner of the contract.
get fun owner(): address {
    val st = lazy Storage.load();
    return st.ownable.get_owner();
}

/// Gets the pending owner of the contract, if any.
get fun pendingOwner(): address? {
    val st = lazy Storage.load();
    return st.ownable.get_pendingOwner();
}

get fun typeAndVersion(): (slice, slice) {
    return (FeeQuoter_FACILITY_NAME, CONTRACT_VERSION);
}

get fun facilityId(): uint16  {
    return FeeQuoter_FACILITY_ID;
}

get fun errorCode(local: uint16): uint16 {
    return getErrorCode(stringCrc32("link.chain.ton.ccip.FeeQuoter"), local);
}

get fun destChainSelectors(): tuple? {
    val st = lazy Storage.load();
    var d = st.destChainConfigs;
    return keysLispList(d)!;
}

get fun reserve(): coins {
    return RESERVE;
}

@method_id(1000)
fun migrate(storage: cell, version: slice): cell {
    val NEW_THRESHOLD = 24 * 60 * 60; //  86400 seconds = 24 hours
    requireSupportedVersion(version);
    var st = Storage.fromCell(storage);
    st.tokenPriceStalenessThreshold = NEW_THRESHOLD;
    return st.toCell();
}

fun requireSupportedVersion(version: slice) {
    assert (
        version.bitsEqual("1.6.0")
        || version.bitsEqual("1.6.1")
        || version.bitsEqual("1.6.2")
    ) 
    throw Upgradeable_Error.VersionMismatch;
}

@method_id(1001)
fun version(): slice { return CONTRACT_VERSION; }
