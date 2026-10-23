// SPDX-License-Identifier: BUSL-1.1
import "../../lib/versioning/upgradeable"
import "../../lib/deployable/types"
import "../../lib/access/ownable_2step.tolk"
import "../../lib/funding/withdrawable.tolk"
import "../../lib/crypto/merkle_multi_proof.tolk"
import "../../lib/ocr/multi_ocr3_base"
import "../../lib/ocr/types"
import "../../lib/utils.tolk"
import "../../lib/receiver/types"
import "../../lib/deployable/namespace"

import "../common/types.tolk"

import "../fee_quoter/messages"
import "../merkle_root/messages"
import "../merkle_root/storage"
import "../receive_executor/messages"
import "../receive_executor/storage"
import "../router/messages"

import "messages"
import "errors"
import "types"
import "storage"
import "events"

const CONTRACT_VERSION = "1.6.2";
const RESERVE = ton("5");
const MIN_GASLIMIT = ton("0.025");

fun onInternalMessage(in:InMessage) {
    val msg = lazy OffRamp_InMessage.fromSlice(in.body);
    
    match(msg) {
        // Sender must be OCR transmitter
        OffRamp_Commit => {
           onCommit(msg, in.senderAddress, in.valueCoins)
        }
        // Sender must be OCR transmitter
        OffRamp_Execute => {
            onExecute(msg, in.senderAddress, in.valueCoins)
        }
        // Sender must be MerkleRoot
        OffRamp_ExecuteValidated => {
            var st = lazy Storage.load();
            assertSenderIsMerkleRoot(st, msg.root, in.senderAddress);
            onExecuteValidated(st, msg, in.senderAddress)
        }
        // Sender must be ReceiveExecutor
        OffRamp_DispatchValidated => {
            var st = lazy Storage.load();
            assertSenderIsReceiverExecutor(st, msg.execId, in.senderAddress);
            onDispatchValidated(st, msg)
        }
        // Permissionless
        OffRamp_ManuallyExecute => {
            onManuallyExecute(msg, in.valueCoins)
        }
        // Sender must be owner
        OCR3Base_SetOCR3Config => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            onSetOCR3Config(msg)
        }
        // Sender must be owner
        OffRamp_UpdateDeployables => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            onUpdateDeployables(st, msg)
        }
        // Sender must be owner
        OffRamp_UpdateSourceChainConfigs => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            onUpdateSourceChainConfigs(msg)
        }
        // Sender must be the rmnRouter
        OffRamp_UpdateCursedSubjects => {
            var st = lazy Storage.load();
            assert(in.senderAddress == st.deployables.load().rmnRouter, Error.Unauthorized);
            onUpdateCursedSubjects(msg)
        },
        // Sender must be router
        OffRamp_CCIPReceiveConfirm => {
            var st = lazy Storage.load();
            assertSenderIsTheRouter(st, msg.execId.getSourceChainSelector(), in.senderAddress);
            onCCIPReceiveConfirm(st, msg);
        }
        // Sender must be router
        OffRamp_CCIPReceiveBounced => {
            var st = lazy Storage.load();
            assertSenderIsTheRouter(st, msg.execId.getSourceChainSelector(), in.senderAddress);
            onBouncedCCIPReceive(msg);
        }
        // Sender must be ReceiveExecutor
        OffRamp_NotifySuccess => {
            var st = lazy Storage.load();
            assertSenderIsReceiverExecutor(st, msg.execId, in.senderAddress);
            onNotifySuccess(msg);
        }
        // Sender must be ReceiveExecutor
        OffRamp_NotifyFailure => {
            var st = lazy Storage.load();
            assertSenderIsReceiverExecutor(st, msg.execId, in.senderAddress);
            onNotifyFailure(msg);
        }
        // Sender must be owner
        OffRamp_SetDynamicConfig => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            onSetDynamicConfig(msg);
        }
        // Sender must be owner
        Withdrawable_Withdraw => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            Withdrawable{
                reserve: RESERVE
            }.withdraw(msg, in.valueCoins);
        }
        // Sender must be owner
        Upgradeable_Upgrade => {
            var st = lazy Storage.load();
            st.ownable.requireOwner(in.senderAddress);
            onUpgrade(msg);
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
            assert (in.body.isEmpty()) throw 0xFFFF;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    val rich = lazy RichBounceBody.fromSlice(in.bouncedBody);
    val originalMessage = lazy OffRamp_InMessageBounced.fromCell(rich.originalBody);
    match(originalMessage) {
        ReceiveExecutor_InitExecute => {
            onBouncedReceiveExecutorInitExecute(originalMessage, in.senderAddress)
        },
        Deployable_Initialize => {
            onBouncedDeployableInitialize(originalMessage, in.senderAddress)
        },
        Router_RouteMessage => {
            onBouncedRouterRouteMessage(originalMessage, in.senderAddress)
        }
    }
}

// Handles bounced ReceiveExecutor_InitExecute messages. This should never
// happen; if InitExecute bounced, it's probably a misconfiguration in the
// ReceiveExecutor code. Marks the execution state as failed and emits events.
fun onBouncedReceiveExecutorInitExecute(msg: ReceiveExecutor_InitExecute, senderAddress: address) {
    markStateOnRoot(
        msg.root,
        msg.sequenceNumber,
        ExecutionState.Failure
    );
    emit(RECEIVE_EXECUTOR_INIT_EXECUTE_BOUNCED, OffRamp_ReceiveExecutorInitExecuteBounced{
        receiveExecutor: senderAddress,
        root: msg.root,
        sequenceNumber: msg.sequenceNumber,
    });
    emit(EXECUTION_STATE_CHANGED_TOPIC, ExecutionStateChanged {
        sourceChainSelector: msg.sourceChainSelector,
        sequenceNumber: msg.sequenceNumber,
        messageId: msg.messageId,
        state: ExecutionState.Failure
    });
}

// Handles bounced Deployable_Initialize messages. This should never have
// bounced, but it could be from a duplicated commit report or message. Emits
// an event and tries to mark the execution as failed if it's a ReceiveExecutor.
fun onBouncedDeployableInitialize(msg: Deployable_Initialize, senderAddress: address) {
    val stateInit = msg.stateInit;
    emit(DEPLOYABLE_INITIALIZE_BOUNCED_TOPIC, OffRamp_DeployableInitializeBounced {
        deployableAddress: senderAddress
    });
    commitContractDataAndActions();

    // Try to cast the Deployable data to the ReceiveExecutor_Storage in order to mark the message execution as Failed
    // If the deploy that failed is for a MerkleRoot contract this will fail and only the previously committed emit action will take place
    val storageData = ReceiveExecutor_Storage.fromCell(stateInit.data);
    val message = Any2TVMRampMessage.fromCell(storageData.message);
    markStateOnRoot(
        storageData.root,
        message.header.sequenceNumber,
        ExecutionState.Failure
    );
    emit(EXECUTION_STATE_CHANGED_TOPIC, ExecutionStateChanged {
        sourceChainSelector: message.header.sourceChainSelector,
        sequenceNumber: message.header.sequenceNumber,
        messageId: message.header.messageId,
        state: ExecutionState.Failure
    });
}

// Handles bounced Router_RouteMessage messages. This should never happen; if
// RouteMessage bounced, it probably means the Router is misconfigured. Emits
// an event and sends a ReceiveBounced message to initiate the failure trace.
fun onBouncedRouterRouteMessage(msg: Router_RouteMessage, senderAddress: address) {
    val st = Storage.load();

    emit(ROUTE_MESSAGE_BOUNCED_TOPIC, OffRamp_RouteMessageBounced{
        router: senderAddress,
        execId: msg.execId,
    });

    // Send ReceiveBounced to initiate the failure notification trace 
    val receiveBounced = createMessage({
        bounce: false,
        value: 0,
        dest: getReceiverExecutorDeployAddress(st, msg.execId),
        body: ReceiveExecutor_Bounced{
            receiver: msg.receiver,
            reason: ReceiveExecutor_BouncedReason.BouncedFromRouter,
        }
    });
    receiveBounced.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// Handles contract upgrade requests using the Upgradeable pattern. Invokes the
// upgrade process with the current migrate function and version metadata.
fun onUpgrade(msg: Upgradeable_Upgrade) {
    Upgradeable{ migrate, version }.upgrade(msg);
}

@method_id(1000)
fun migrate(storage: cell, version: slice): cell {
    requireSupportedVersion(version);
    return storage;
}

fun requireSupportedVersion(version: slice) {
    assert (
        version.bitsEqual("1.6.0")
        || version.bitsEqual("1.6.1")
    ) 
    throw Upgradeable_Error.VersionMismatch;
}

@method_id(1001)
fun version(): slice { return CONTRACT_VERSION; }

// Handles OffRamp_CCIPReceiveBounced messages from the Router, originating
// from the CCIP receiver. The OffRamp notifies the ReceiveExecutor to update
// the execution state via ReceiveExecutor_Bounced. Only the Router is
// authorized to call this function.
//
// sequenceDiagram
//     participant Receiver
//     participant Router
//     participant OffRamp
//     participant ReceiveExecutor

//     Receiver        ->> Router:          Receiver_CCIPReceive (bounce)
//     Router          ->> OffRamp:         OffRamp_CCIPReceiveBounced
//     OffRamp         ->> ReceiveExecutor: ReceiveExecutor_Bounced
//     ReceiveExecutor ->> OffRamp:         OffRamp_NotifyFailure
fun onBouncedCCIPReceive(msg: OffRamp_CCIPReceiveBounced) {
    val st = Storage.load();

    val receiveBounced = createMessage({
        bounce: false,
        value: 0,
        dest: getReceiverExecutorDeployAddress(st, msg.execId),
        body: ReceiveExecutor_Bounced{
            receiver: msg.receiver,
            reason: ReceiveExecutor_BouncedReason.BouncedFromReceiver,
        }
    });
    receiveBounced.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// Sends a MerkleRoot_MarkState message to update the execution state of a
// specific sequence number in a MerkleRoot contract.
fun markStateOnRoot(root: address, seqNum: uint64, state: ExecutionState) {
    val markState= createMessage({
        bounce: false,
        value: MerkleRoot_Costs.markState(),
        dest: root,
        body: MerkleRoot_MarkState {
            seqNum,
            state,
        },
    });
    markState.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

// Received from ReceiveExecutor after validating that the confirm message
// came from the correct receiver.
//
// sequenceDiagram
//     participant OffRamp
//     participant ReceiveExecutor
//
//     OffRamp         ->> ReceiveExecutor: ReceiveExecutor_Confirm
//     ReceiveExecutor ->> OffRamp:         OffRamp_NotifySuccess
fun onNotifySuccess(msg: OffRamp_NotifySuccess) {
    // propagate state change to root
    markStateOnRoot(msg.root, msg.header.sequenceNumber, ExecutionState.Success);

    val messageHeader = msg.header;
    emit(EXECUTION_STATE_CHANGED_TOPIC, ExecutionStateChanged {
        sourceChainSelector: messageHeader.sourceChainSelector,
        sequenceNumber: messageHeader.sequenceNumber,
        messageId: messageHeader.messageId,
        state: ExecutionState.Success
    });
}

// Received from ReceiveExecutor after validating that the bounce message came from the correct
// receiver and enabling manual execute to retry.
//
// sequenceDiagram
//     participant OffRamp
//     participant ReceiveExecutor
//
//     OffRamp         ->> ReceiveExecutor: ReceiveExecutor_Bounced
//     ReceiveExecutor ->> OffRamp:         OffRamp_NotifyFailure
fun onNotifyFailure(msg: OffRamp_NotifyFailure) {
    // propagate state change to root
    markStateOnRoot(msg.root, msg.header.sequenceNumber, ExecutionState.Failure);

    val messageHeader = msg.header;
    emit(EXECUTION_STATE_CHANGED_TOPIC, ExecutionStateChanged {
        sourceChainSelector: messageHeader.sourceChainSelector,
        sequenceNumber: messageHeader.sequenceNumber,
        messageId: messageHeader.messageId,
        state: ExecutionState.Failure
    });
}

// Sent by the Receiver via the Router to confirm successful message receipt.
// ReceiveExecutor must verify that the sender matches the intended receiver.
// Only the Router is authorized to call this function.
//
// sequenceDiagram
//     participant Receiver
//     participant Router
//     participant OffRamp
//     participant ReceiveExecutor

//     Receiver        ->> Router:          Receiver_CCIPReceive
//     Router          ->> OffRamp:         Router_CCIPReceiveConfirm
//     OffRamp         ->> ReceiveExecutor: OffRamp_CCIPReceiveConfirm
//     ReceiveExecutor ->> OffRamp:         OffRamp_NotifySuccess/Failure
fun onCCIPReceiveConfirm(st: Storage, msg: OffRamp_CCIPReceiveConfirm) {
    val receiveConfirm = createMessage({
        bounce: true,
        value: 0,
        dest:  getReceiverExecutorDeployAddress(st, msg.execId),
        body: ReceiveExecutor_Confirm {
            receiver: msg.receiver,
        },
    });
    receiveConfirm.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// Dispatches a validated message to the receiver via the Router_RouteMessage.
// Verifies sender ownership which should be the corresponing receiver executor,
// resolves the Router from the source selector, and applies a gas override only
// if it exceeds the original gasLimit.
//
// Includes routing cost in value and forwards execId and receiver details.
//
// sequenceDiagram
//     participant ReceiveExecutor
//     participant OffRamp
//     participant Router

//     ReceiveExecutor ->> OffRamp:  OffRamp_DispatchValidated
//     OffRamp         ->> Router:   Router_RouteMessage
//     Router          ->> Receiver: Receiver_CCIPReceive
fun onDispatchValidated(st: Storage, msg: OffRamp_DispatchValidated) {
    val message: Any2TVMRampMessage = msg.message.load();
    val router = getRouterFromSelector(st, message.header.sourceChainSelector);

    // If there is a gasOverride, replace gas limit only if override is greater than original gasLimit
    // Otherwise, keep original limit
    var gasLimit: coins = message.gasLimit;
    if (msg.gasOverride != null && msg.gasOverride >= gasLimit) {
        gasLimit = msg.gasOverride;
    }
    if (gasLimit < MIN_GASLIMIT) {
        return blockMsg(st, msg.execId, message.receiver);
    }
    val routeMessage = createMessage({
        bounce: BounceMode.RichBounce,
        value: gasLimit + Router_Costs.routeMessage(),
        dest: router,
        body: Router_RouteMessage {
            message: Any2TVMMessage {
                messageId: message.header.messageId,
                sourceChainSelector: message.header.sourceChainSelector,
                sender: CrossChainAddress.fromCell(message.sender),
                data: message.data,
                tokenAmounts: message.tokenAmounts,
            }.toCell(),
            execId: msg.execId,
            receiver: message.receiver,
            gasLimit: gasLimit,
        }
    });

    routeMessage.send(SEND_MODE_REGULAR);
}

fun blockMsg(st: Storage, execId: uint192, receiver: address) {
    val receiveBounced = createMessage({
        bounce: false,
        value: 0,
        dest: getReceiverExecutorDeployAddress(st, execId),
        body: ReceiveExecutor_Bounced{
            receiver: receiver,
            reason: ReceiveExecutor_BouncedReason.NotEnoughGas,
        }
    });
    receiveBounced.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// Sets a new OCR3 configuration for the contract. Only the contract owner can call this function.
fun onSetOCR3Config(msg: OCR3Base_SetOCR3Config) {
    var st = lazy Storage.load();

    var ocr3Base = st.ocr3Base.load();
    ocr3Base.setOcr3Config(msg);

    // validation and reset latestPriceSequenceNumber
    // Note: this mirrors EVM's _afterOCR3ConfigSet hook, but direct implementation
    if (msg.ocrPluginType == OCR_PLUGIN_TYPE_COMMIT) {
        // signature verification must be enabled for commit plugin
        assert(msg.isSignatureVerificationEnabled, Error.SignatureVerificationRequiredInCommitPlugin);
        
        // reset price sequence number when commit OCR config changes
        // (scoped per config digest, roots persist across reconfigurations)
        st.latestPriceSequenceNumber = 0;
    } else if (msg.ocrPluginType == OCR_PLUGIN_TYPE_EXECUTE) {
        // signature verification must be disabled for execution plugin
        assert(!msg.isSignatureVerificationEnabled, Error.SignatureVerificationNotAllowedInExecutionPlugin);
    }

    st.ocr3Base = ocr3Base.toCell();
    st.store();
}

// Updates the deployable contract codes for ReceiveExecutor and MerkleRoot. Only the contract owner can call this function.
fun onUpdateDeployables(st: Storage, msg: OffRamp_UpdateDeployables) {
    var deployables = st.deployables.load();

    if (msg.receiveExecutorCode != null) {
        deployables.receiveExecutorCode = msg.receiveExecutorCode!;
    }

    if (msg.merkleRootCode != null) {
        deployables.merkleRootCode = msg.merkleRootCode!;
    }

    st.deployables = deployables.toCell();
    st.store();
}

// Processes commit reports: refreshes prices if the OCR sequence is newer,
// initializes/updates MerkleRoot contract, validates OCR3 signatures, and
// emits CommitReportAccepted when everything is valid.
//
// sequenceDiagram
//     participant Wallet
//     participant OffRamp
//     participant FeeQuoter
//     participant MerkleRoot

//     Wallet  ->> OffRamp:    OffRamp_Commit
//     OffRamp ->> FeeQuoter:  FeeQuoter_UpdatePrices (if contrains price updates)
//     OffRamp ->> MerkleRoot: Deployable_Initialize
fun onCommit(msg: OffRamp_Commit, sender: address, value: coins) {
    var st = lazy Storage.load();
    val report = msg.report;
    val hasRoots = !report.merkleRoots.empty();

    assert (report.priceUpdates != null || hasRoots, Error.EmptyCommitReport);
    var root: MerkleRoot? = null;

    if (hasRoots) {
        // no batching of roots supported for now, check that there is exactly one root in the SnakedCell
        var iter = report.merkleRoots.iter();
        root = iter.next();
        assert(iter.empty(), Error.BatchingNotSupported);
    }

    // Non-empty Commit reports will always have price updates
    val priceUpdatesOnlyReport = !hasRoots;

    // check that the amount attached is enough to cover message execution and delivery of outgoing messages
    // required amount is lower for reports with only price updates
    assert(value >= OffRamp_Costs.commit(priceUpdatesOnlyReport), Error.InsufficientFee);

    if (root != null) {
        // validate lane is enabled and not cursed

        var sourceChainConfig = st.sourceChainConfigs.mustGet(root.sourceChainSelector, Error.SourceChainNotEnabled as int);
        assert(sourceChainConfig.isEnabled, Error.SourceChainNotEnabled);
        assert(!st.cursedSubjects.isCursed(root.sourceChainSelector as uint128), Error.SubjectCursed);

        // hard cap of 64 messages per report
        assert((root.maxSeqNr - root.minSeqNr) < 64, Error.TooManyMessagesInReport);

        assert(sourceChainConfig.onRamp.bitsEqual(root.onRampAddress), Error.OnRampAddressMismatch);

        assert(
            (sourceChainConfig.minSeqNr == root.minSeqNr) && // No seqNr skipped
            (root.maxSeqNr >= root.minSeqNr), // valid root range
            Error.InvalidInterval
        );

        assert(root.merkleRoot != 0, Error.MerkleRootCannotBeZero);

        // set next expected sequence number to maxSeqNr + 1 (matches EVM implementation)
        sourceChainConfig.minSeqNr = root.maxSeqNr + 1;
        st.sourceChainConfigs.replaceIfExists(root.sourceChainSelector, sourceChainConfig);

        // initialize MerkleRoot subcontract
        val initMsg = createMessage({
            bounce: BounceMode.RichBounce,
            value: AMOUNT_FOR_MERKLE_ROOT_DEPLOYMENT,
            dest: getMerkleRootDeployAddress(st, root.merkleRoot),
            body: Deployable_Initialize {
                stateInit: {
                    code: st.deployables.load().merkleRootCode,
                    data: MerkleRoot_Storage {
                        root: root.merkleRoot,
                        owner: contract.getAddress(),
                        timestamp: blockchain.now(),
                        minMsgNr: root.minSeqNr,
                        maxMsgNr: root.maxSeqNr,
                        messageStates: 0,
                    }.toCell(),
                }
            },
        });
        initMsg.send(SEND_MODE_REGULAR);
    }

    // Update token/gas prices if there are any updates.
    // Don't send the UpdatePrices message if both tokenPriceUpdates and gasPriceUpdates are empty.

    if (report.priceUpdates != null) {
        val priceUpdates = report.priceUpdates!.load();

        // Ignore price updates if both are empty
        if (!(priceUpdates.tokenPriceUpdates.empty() && priceUpdates.gasPriceUpdates.empty())) {
            // extract OCR sequence number from report context (matches EVM implementation)
            val ocrSequenceNumber = msg.reportContext.sequenceBytes;

            // check for price staleness based on the OCR sequence number
            if (st.latestPriceSequenceNumber < ocrSequenceNumber) {
                // if prices are not stale, update the latest sequence number
                st.latestPriceSequenceNumber = ocrSequenceNumber;

                // and update the prices in the fee quoter

                val updatePricesMsg = createMessage({
                    bounce: true,
                    value: FeeQuoter_Costs.updatePrices(),
                    dest: st.feeQuoter,
                    body: FeeQuoter_UpdatePrices {
                        updates: report.priceUpdates!.load(),
                        sendExcessesTo: sender,
                    }
                });
                updatePricesMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
        }
    }


    // store updated state (latestPriceSequenceNumber and sourceChainConfigs)
    st.store();

    // Verifies signatures and emits Transmitted event
    st.ocr3Base.load().transmit(
        sender,
        OCR_PLUGIN_TYPE_COMMIT,
        msg.reportContext,
        report.toCell(),
        msg.signatures
    );
    emit(
        TOPIC_COMMIT_REPORT_ACCEPTED,
        CommitReportAccepted { merkleRoot: root, priceUpdates: report.priceUpdates }
    );
}

// Manually executes a single cross-chain execution report.
//
// sequenceDiagram
//     participant Wallet
//     participant OffRamp
//     participant MerkleRoot

//     Wallet  ->> OffRamp:    OffRamp_ManuallyExecute
//     OffRamp ->> MerkleRoot: MerkleRoot_Validate
fun onManuallyExecute(msg: OffRamp_ManuallyExecute, value: coins) {
    onExecuteSingleReport(msg.report, msg.gasOverride, value);
}

// Executes a single cross-chain execution report.
//
// sequenceDiagram
//     participant Wallet
//     participant OffRamp
//     participant MerkleRoot

//     Wallet  ->> OffRamp:    OffRamp_Execute
//     OffRamp ->> MerkleRoot: MerkleRoot_Validate
fun onExecute(msg: OffRamp_Execute, sender: address, value: coins) {
    onExecuteSingleReport(msg.report, null, value);

    var st = Storage.load();

    st.ocr3Base.load().transmit(
        sender,
        OCR_PLUGIN_TYPE_EXECUTE,
        msg.reportContext,
        msg.report.toCell(),
        createEmptyCell(),
    );
}

// Executes a single cross-chain execution report. Verifies source chain
// configuration, checks for curses, and ensures message integrity before
// sending it for MerkleRoot validation.
//
// sequenceDiagram
//     participant Wallet
//     participant OffRamp
//     participant MerkleRoot

//     Wallet  ->> OffRamp:    OffRamp_Execute/ManuallyExecute
//     OffRamp ->> MerkleRoot: MerkleRoot_Validate
fun onExecuteSingleReport(report: ExecutionReport, gasOverride: coins?, value: coins) {
    var st = Storage.load();

    // check if chain was cursed by RMNRemote
    val isCursed = st.cursedSubjects.isCursed(report.sourceChainSelector as uint128);
    assert(!isCursed, Error.SubjectCursed);

    assert(!report.messages.beginParse().isEmpty(), Error.EmptyExecutionReport);

    // No execution batching so no need to use iterator
    val message = Any2TVMRampMessage.fromCell(report.messages);

    if(gasOverride != null && (gasOverride >= message.gasLimit)) {
        assert(value >= (OffRamp_Costs.execute() + gasOverride), Error.InsufficientFee);
    } else {
        assert(value >= (OffRamp_Costs.execute() + message.gasLimit), Error.InsufficientFee);
    }

    var sourceChainConfigResult = st.sourceChainConfigs.get(report.sourceChainSelector);
    assert(sourceChainConfigResult.isFound, Error.SourceChainNotEnabled);

    val sourceChainConfig = sourceChainConfigResult.loadValue();
    assert(sourceChainConfig.isEnabled, Error.SourceChainNotEnabled);

    //  Hashing all of the message fields ensures that the message being executed is correct and not tampered with.
    //Including the known OnRamp ensures that the message originates from the correct OnRamp version.
    //We know the sourceChainSelector and destChainSelector are correct because we revert below when they are not.
    val metadataHash = MessageMetadata {
        sourceChainSelector: report.sourceChainSelector,
        destChainSelector: st.chainSelector,
        onRamp: sourceChainConfig.onRamp.toCell(),
    }.toCell().hash();

    // Commits do not verify the destChainSelector in the message since only the root is committed, so we
    // have to check it explicitly. This check is also important as we have assumed the metaDataHash above uses
    // the st.chainSelector as the destChainSelector.
    assert(message.header.destChainSelector == st.chainSelector, Error.InvalidMessageDestChainSelector);

    // If the message source chain selector does not match the report's source chain selector and the root has not
    // been committed for the report source chain selector this will be caught by the root verification.
    // This acts as an extra check to ensure the message source chain selector matches the report's source chain.
    assert(message.header.sourceChainSelector == report.sourceChainSelector, Error.SourceChainSelectorMismatch);

    var leafTuple: tuple = createEmptyTuple();
    leafTuple.push(message.generateMessageId(metadataHash));

    val root = merkleRoot(TupleIterator<uint256>.new(leafTuple), report.proofs.iter(), report.proofFlagBits);

    // send message to MerkleRoot (execute)
    val executeMsg = createMessage({
        bounce: true,
        value: MerkleRoot_Costs.validate(),
        dest: getMerkleRootDeployAddress(st, root),
        body: MerkleRoot_Validate {
            message: report.messages as Cell<Any2TVMRampMessage>,
            metadataHash: metadataHash,
            permissionlessExecutionThresholdSeconds: st.permissionlessExecutionThresholdSeconds,
            gasOverride,
        },
    });
    executeMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

/*
Updates or initializes a SourceChainConfig entry. Only the contract owner can call this function.
*/
fun onUpdateSourceChainConfigs(msg: OffRamp_UpdateSourceChainConfigs) {
    var st = lazy Storage.load();

    var configIterator = msg.configs.iter();
    while (!configIterator.empty()) {
        var configUpdate = configIterator.next();
        var config: SourceChainConfig;
        var existingConfigEntry = st.sourceChainConfigs.get(configUpdate.sourceChainSelector);

        if (!existingConfigEntry.isFound) {
            config = SourceChainConfig {
                router: configUpdate.config.router,
                isEnabled: configUpdate.config.isEnabled,
                minSeqNr: 1,
                isRMNVerificationDisabled: true, // RMN verification is always disabled
                onRamp: configUpdate.config.onRamp,
            };
            emit(SOURCE_CHAIN_SELECTOR_ADDED_TOPIC, SourceChainSelectorAdded {
                sourceChainSelector: configUpdate.sourceChainSelector,
            });
        } else {
            // OnRamp updates should only happen due to a misconfiguration.
            // If an OnRamp is misconfigured, no reports should have been
            // committed and no messages should have been executed.
            config = existingConfigEntry.loadValue();
            assert (config.minSeqNr == 1 || config.onRamp.bitsEqual(configUpdate.config.onRamp)) throw Error.InvalidOnRampUpdate;
            config.router = configUpdate.config.router;
            config.isEnabled = configUpdate.config.isEnabled;
            config.onRamp = configUpdate.config.onRamp;
        }
        st.sourceChainConfigs.set(configUpdate.sourceChainSelector, config);
        emit(SOURCE_CHAIN_CONFIG_UPDATED_TOPIC, SourceChainConfigUpdated {
            sourceChainSelector: configUpdate.sourceChainSelector,
            sourceChainConfig: config,
        });
    }
    st.store();
}

/*
Updates the list of cursed subjects in storage. Only the Router contract is
authorized to perform this action.
*/
fun onUpdateCursedSubjects(msg: OffRamp_UpdateCursedSubjects) {
    var st = Storage.load();

    st.cursedSubjects = msg.cursedSubjects;
    st.store();
}

// Executes a validated OffRamp message after MerkleRoot verification.
// Ensures the sender is an owned MerkleRoot, emits execution state change,
// deploys the ReceiveExecutor if needed, and triggers execution flow.
//
// sequenceDiagram
//     participant OffRamp
//     participant MerkleRoot
//     participant ReceiveExecutor

//     OffRamp    ->> MerkleRoot:      MerkleRoot_Validate
//     MerkleRoot ->> OffRamp:         OffRamp_ExecuteValidated
//     OffRamp    ->> ReceiveExecutor: ReceiveExecutor_InitExecute
fun onExecuteValidated(st: Storage, msg: OffRamp_ExecuteValidated, sender: address) {
    val message = msg.message.load();

    emit(EXECUTION_STATE_CHANGED_TOPIC, ExecutionStateChanged {
        sourceChainSelector: message.header.sourceChainSelector,
        sequenceNumber: message.header.sequenceNumber,
        messageId: message.header.messageId,
        state: ExecutionState.InProgress
    });

    val messageId = message.generateMessageId(msg.metadataHash);
    val execId = getOwnedReceiveExecutorContractId(messageId, message.header.sourceChainSelector);

    val executorAddress: AutoDeployAddress = getReceiverExecutorDeployAddress(st, execId);

    // Check if this is the first time the exec flow is running given that in that case we need to
    // initialize the executor
    if (msg.executionState == ExecutionState.Untouched) {
        val deployMsg = createMessage({
            bounce: BounceMode.RichBounce,
            value: AMOUNT_FOR_RECEIVE_EXECUTOR_DEPLOYMENT,
            dest: executorAddress,
            body: Deployable_Initialize {
                stateInit: {
                    code: st.deployables.load().receiveExecutorCode,
                    data: ReceiveExecutor_Storage {
                        owner: contract.getAddress(),
                        message: message.toCell(),
                        root: sender,
                        execId: execId,
                    }.toCell(),
                }
            },
        });
        deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
    }

    // Initiate the execution in the ReceiveExecutor
    val initExecMsg = createMessage ({
        bounce: BounceMode.RichBounce,
        value: ReceiveExecutor_Costs.initExec(),
        dest: executorAddress,
        body: ReceiveExecutor_InitExecute {
            gasOverride: msg.gasOverride,
            root: sender,
            sequenceNumber: message.header.sequenceNumber,
            sourceChainSelector: message.header.sourceChainSelector,
            messageId: message.header.messageId,
        }
    });
    initExecMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

/*
Retrieves the Router address associated with a given sourceChainSelector.
Throws an error if the source chain is not enabled in the stored configs.
*/
fun getRouterFromSelector(st: Storage, sourceChainSelector: uint64): address {
    val sourceChainConfig = st.sourceChainConfigs.mustGet(sourceChainSelector, Error.SourceChainNotEnabled as int);
    return sourceChainConfig.router;
}

/*
Generates a unique ReceiveExecutorId by combining the sourceChainSelector
and the lower 160 bits of the internal messageId. Used to derive the
ReceiveExecutor contract identifier for message execution tracking
*/
fun getOwnedReceiveExecutorContractId(messageId: uint256, sourceChainSelector: uint64): ReceiveExecutorId {
    var cs = beginCell().storeUint(messageId, 256)
        .endCell().beginParse();

    return beginCell()
        .storeUint(sourceChainSelector, 64)
        .storeUint(cs.loadUint(RECEIVE_EXECUTOR_ID_SIZE - 64), RECEIVE_EXECUTOR_ID_SIZE - 64)
        .endCell()
        .beginParse()
        .loadUint(RECEIVE_EXECUTOR_ID_SIZE);
}

/*
Derives the receiver executor contract address from the execId
*/
fun getReceiverExecutorDeployAddress(st: Storage, execId: ReceiveExecutorId): AutoDeployAddress {
    return {
        stateInit: {
            code: st.deployables.load().deployer,
            data: NamespacedDeployableData({
                namespace: DeployableNamespace_ReceiveExecutor,
                owner: contract.getAddress(),
                id: execId,
            }),
        }
    }
}

/*
Verifies that the caller corresponds to a receiver exector contract
*/
fun assertSenderIsReceiverExecutor(st: Storage, execId: ReceiveExecutorId, sender: address) {
    val expectedAddress: AutoDeployAddress = getReceiverExecutorDeployAddress(st, execId);
    assert(expectedAddress.addressMatches(sender)) throw Error.MessageNotFromOwnedContract;
}

/*
Derives the merkle root contract address from the merkleRootId
*/
fun getMerkleRootDeployAddress(st: Storage, merkleRoot: MerkleRootId): AutoDeployAddress {
    return {
        stateInit: {
            code: st.deployables.load().deployer,
            data: NamespacedDeployableData({
                namespace: DeployableNamespace_MerkleRoot,
                owner: contract.getAddress(),
                id: merkleRoot
            }),
        }
    }
}

/*
Verifies that the caller corresponds to a merkle root contract
*/
fun assertSenderIsMerkleRoot(st: Storage, merkleRoot: MerkleRootId, sender: address) {
    val expectedAddress: AutoDeployAddress = getMerkleRootDeployAddress(st, merkleRoot);
    assert(expectedAddress.addressMatches(sender)) throw Error.MessageNotFromOwnedContract;
}

/*
Verifies that the caller corresponds to the router asociated with the given chain selector
*/
fun assertSenderIsTheRouter(st: Storage, sourceChainSelector: uint64, sender: address) {
    val router = getRouterFromSelector(st, sourceChainSelector);
    assert(sender == router, Error.Unauthorized);
}

/*
Updates the dynamic configuration parameters for the OffRamp contract.
Validates that the feeQuoter address is non-zero, updates the stored
configuration and emits a DYNAMIC_CONFIG_SET_TOPIC event.
*/
fun onSetDynamicConfig(msg: OffRamp_SetDynamicConfig) {
    var st = Storage.load();

    // NOTE: address now is guaranteed to be non-zero, address? allows zero

    st.feeQuoter = msg.feeQuoter;
    st.permissionlessExecutionThresholdSeconds = msg.permissionlessExecutionThresholdSeconds;
    st.store();

    emit(DYNAMIC_CONFIG_SET_TOPIC, OffRamp_DynamicConfigSet{
        feeQuoter: msg.feeQuoter,
        permissionlessExecutionThresholdSeconds: msg.permissionlessExecutionThresholdSeconds,
    });
}

get fun latestPriceSequenceNumber(): uint64 {
    var st = lazy Storage.load();
    return st.latestPriceSequenceNumber
}

get fun sourceChainSelectors(): tuple? {
    val st = lazy Storage.load();
    var d = st.sourceChainConfigs;
    return keysLispList(d)!;
}

get fun ocr3Config(): OCR3Base {
    var st = lazy Storage.load();
    return st.ocr3Base.load();
}

get fun config(): Config {
    val st = lazy Storage.load();
    return {
        chainSelector: st.chainSelector,
        feeQuoter: st.feeQuoter,
        permissionlessExecutionThresholdSeconds: st.permissionlessExecutionThresholdSeconds,
    }
}

get fun sourceChainConfig(sourceChainSelector: uint64): SourceChainConfig {
    val st = lazy Storage.load();
    return st.sourceChainConfigs.mustGet(sourceChainSelector,Error.SourceChainNotEnabled as int);
}

get fun allSourceChainConfigs(): map<uint64, SourceChainConfig> {
    val st = lazy Storage.load();
    return st.sourceChainConfigs;
}

get fun verifyNotCursed(subject: uint128): bool {
    val st = lazy Storage.load();
    return !st.cursedSubjects.isCursed(subject);
}

get fun cursedSubjects(): tuple? {
    val st = lazy Storage.load();
    return keysLispList(st.cursedSubjects.data)!;
}

get fun deployableHashes() : DeployableHashes {
    val st = lazy Storage.load();
    val deployables = st.deployables.load();
    return DeployableHashes {
        merkleRoot: deployables.merkleRootCode.hash(),
        receiveExecutor: deployables.receiveExecutorCode.hash(),
        deployer: deployables.deployer.hash(),
    }
}

get fun rmnRouter(): address {
    val st = lazy Storage.load();
    val deployables = st.deployables.load();
    return deployables.rmnRouter;
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
    return (OffRamp_FACILITY_NAME, CONTRACT_VERSION);
}

get fun facilityId(): uint16  {
    return OffRamp_FACILITY_ID;
}

get fun errorCode(local: uint16): uint16 {
    return getErrorCode(stringCrc32("link.chain.ton.ccip.OffRamp"), local);
}

get fun reserve(): coins {
    return RESERVE;
}
