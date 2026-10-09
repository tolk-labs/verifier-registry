// decompiled by @fiscaldev
// Byte-identical Pool V1 incoming handlers; shared handlers are imported from V2.
import "@stdlib/gas-payments"
import "../CpmmPoolV2/storage"
import "../CpmmPoolV2/messages"
import "../CpmmPoolV2/wallets"
import "../CpmmPoolV2/transfers"
import "processing"
import "transfers-v1"
import "../CpmmPoolV2/settlement"
import "../CpmmPoolV2/payment"
import "../CpmmPoolV2/payout-config"
import "../CpmmPoolV2/routing"
import "../CpmmPoolV2/liquidity-handlers"
import "../CpmmPoolV2/claim-handlers"
import "../CpmmPoolV2/transaction-context"

fun poolExceptionHasContext(value:unknown):bool asm "ISTUPLE"
fun poolExceptionContext(value:unknown):(any_address,PoolPayoutOptions) asm "5 UNTUPLE"

@inline
fun defaultPoolPaymentReject(sender:any_address):(any_address,PoolPayoutOptions) {
    return (sender,{destination:sender,extraGas:0,payload:null,wrapPayload:false});
}

@inline
fun buildPoolInitializationResult(to:any_address,queryId:uint64,exitCode:int):cell {
    val payload:cell?=null;
    val message=beginCell().storeUint(0x10,6).storeSlice(to as slice).storeUint(3457702871,143)
        .storeUint(queryId,64).storeInt(exitCode,32).storeDict(payload).endCell();
    return message;
}

@inline
fun initializePool(storage:PoolStorage,message:InitPool,in:PoolInboundContext) {
    try {
        val initialCost=50000000+calculateGasFee(0,40000)+poolOriginalForwardFee();
        assert(in.valueCoins() >= initialCost) throw 25;
        assert(storage.status is PoolUninitialized) throw 20;
        val config=PoolConfig.fromCell(storage.config);
        assert(!(config.assetX as slice).bitsEqual(config.assetY as slice)) throw 26;
        assert(config.creatorFee <= 5000) throw 35;
        val depositActive=config.depositActivation == null;
        val swapActive=config.swapActivation == null;
        var requested=0;
        var extra=PoolExtra.fromCell(storage.extra);
        if(config.assetX.isInternal()) {
            val (isNew,resolver)=schedulePoolWallets(mutate extra.wallets,config.assetX,config.customResolvers);
            if(isNew) {requestPoolWalletAddressV1(resolver,message.queryId);requested+=1;}
        }
        if(config.assetY.isInternal()) {
            val (isNew,resolver)=schedulePoolWallets(mutate extra.wallets,config.assetY,config.customResolvers);
            if(isNew) {requestPoolWalletAddressV1(resolver,message.queryId);requested+=1;}
        }
        var reward=config.allowedRewards.findFirst();
        while(reward.isFound) {
            val allowed=reward.loadValue();
            if(allowed.asset.isInternal()) {
                val (isNew,resolver)=schedulePoolWallets(mutate extra.wallets,allowed.asset,config.customResolvers);
                if(isNew) {requestPoolWalletAddressV1(resolver,message.queryId);requested+=1;}
            }
            reward=config.allowedRewards.iterateNext(reward);
        }
        val resolverCost=(calculateForwardFee(0,364,1)+calculateGasFee(0,25000))+calculateForwardFee(0,1,364);
        assert(initialCost+(resolverCost+calculateGasFee(0,14500))*requested <= in.valueCoins()) throw 25;
        storage.extra=extra.toCell();
        reserveToncoinsOnBalance(50000000,2);
        if(requested > 0) {
            storage.status=PoolInitializing{initiator:in.senderAddress() as any_address};
            sendPoolExcesses(in.senderAddress() as any_address,message.queryId,128);
        } else {
            storage.status=PoolInitialized{};
            sendRawMessage(buildPoolInitializationResult(in.senderAddress(),message.queryId,0),128);
        }
        storage.depositActive=depositActive;storage.swapActive=swapActive;
        contract.setData(storage.toCell());
    } catch(code,value) {
        sendRawMessage(buildPoolInitializationResult(in.senderAddress(),message.queryId,code),64);
        commitContractDataAndActions();throw code;
    }
}

@inline
fun receivePoolWallet(storage:PoolStorage,message:TakeWalletAddress,in:PoolInboundContext) {
    assert(storage.status is PoolInitializing) throw 21;
    assert(message.wallet.isInternal()) throw 24;
    var extra=PoolExtra.fromCell(storage.extra);
    extra.wallets=finishWalletResolution(extra.wallets,in.senderAddress() as any_address,message.wallet);
    storage.extra=extra.toCell();
    if(extra.wallets.resolutions.findFirst().isFound) {
        sendPoolExcesses(storage.status.initiator,message.queryId,64);
    } else {
        sendRawMessage(buildPoolInitializationResult(storage.status.initiator,message.queryId,0),64);
        storage.status=PoolInitialized{};
    }
    contract.setData(storage.toCell());
}

@inline
fun receivePoolNativePayment(storage:PoolStorage,message:PayNative,in:PoolInboundContext) {
    try {
        assert(storage.status is PoolInitialized) throw 22;
        assert(calculateGasFee(0,10000)+poolOriginalForwardFee() <= in.valueCoins()) throw 25;
        processPoolPayment(storage,in.senderAddress() as any_address,message.queryId,message.payout,
            message.payment,poolNoneAddress(),message.amount,poolOriginalForwardFee());
    } catch(code,value) {
        val (excessesTo,reject)=poolExceptionHasContext(value) ? poolExceptionContext(value) : defaultPoolPaymentReject(in.senderAddress());
        reserveToncoinsOnBalance(contract.getStoragePaidPayment(),4);
        val insufficientValue=code == 25;
        val valueToSend=insufficientValue ? 0 as coins : message.amount+reject.extraGas;
        val callback=beginCell().storeUint(0x10,6).storeSlice(reject.destination as slice).storeCoins(valueToSend)
            .storeUint(0x3216ca09,139).storeUint(message.queryId,64).storeCoins(message.amount)
            .storeInt(code,32).storeDict(reject.payload).endCell();
        sendRawMessage(callback,insufficientValue ? 128 : 1);
        if(insufficientValue) {} else {sendPoolExcesses(excessesTo,message.queryId,128);}
        commitContractDataAndActions();throw code;
    }
}

@inline
fun receivePoolJettonPayment(storage:PoolStorage,message:JettonNotification,in:PoolInboundContext) {
    try {
        assert(storage.status is PoolInitialized) throw 22;
        assert(calculateGasFee(0,15000)+poolOriginalForwardFee()+50000000 <= in.valueCoins()) throw 25;
        val forward=(message.payload is cell) ? message.payload.beginParse() : message.payload as slice;
        val routed=PoolRoutedJettonPayment.fromSlice(forward);
        val wallets=PoolExtra.fromCell(storage.extra).wallets;
        val asset=assetForRegisteredWallet(wallets,in.senderAddress() as any_address);
        processPoolPayment(storage,message.sender,message.queryId,routed.payout,routed.payment,asset,message.amount,poolOriginalForwardFee());
    } catch(code,value) {
        val (excessesTo,reject)=poolExceptionHasContext(value) ? poolExceptionContext(value) : defaultPoolPaymentReject(message.sender);
        val forward:PoolForwardPayload=reject.wrapPayload ? PoolPaymentResult{exitCode:code,payload:reject.payload}.toCell() :
            (reject.payload != null ? reject.payload! as PoolForwardPayload : emptyPoolForwardPayload());
        reserveToncoinsOnBalance(contract.getStoragePaidPayment(),4);
        val insufficientValue=code == 25;
        val valueToSend=insufficientValue ? 0 : 50000000+reject.extraGas;
        val wallet=in.senderAddress();
        val customPayload:cell?=null;
        var transfer=beginCell().storeUint(0x0f8a7ea5,32).storeUint(message.queryId,64).storeCoins(message.amount)
            .storeSlice(reject.destination as slice).storeSlice(excessesTo as slice).storeDict(customPayload).storeCoins(reject.extraGas);
        forward.packToBuilder(mutate transfer);
        val body=transfer.endCell();
        val callback=beginCell().storeUint(0x10,6).storeSlice(wallet as slice).storeCoins(valueToSend)
            .storeUint(1,107).storeRef(body).endCell();
        sendRawMessage(callback,insufficientValue ? 128 : 1);
        if(insufficientValue) {} else {sendPoolExcesses(excessesTo,message.queryId,128);}
        commitContractDataAndActions();throw code;
    }
}

// The caller still eagerly decodes the full message union and root storage.
@inline
fun handlePoolMessage(storage:PoolStorage,message:PoolMessage,in:PoolInboundContext) {
    match(message) {
        InitPool => initializePool(storage,message,in),
        PayNative => receivePoolNativePayment(storage,message,in),
        JettonNotification => receivePoolJettonPayment(storage,message,in),
        JoinLiquidity => joinPoolLiquidity(storage,message,in),
        RefundDeposit => refundPoolDeposit(storage,message,in),
        TakeWalletAddress => receivePoolWallet(storage,message,in),
        ClaimPositionFees => claimPoolPositionFees(storage,message,in),
        PayoutPositionFees => payoutPoolPositionFees(storage,message,in),
        ClaimProtocolFees => claimPoolProtocolFees(storage,message,in),
        ClaimCreatorFees => claimPoolCreatorFees(storage,message,in),
        Withdraw => requestPoolWithdrawal(storage,message,in),
        ExitLiquidity => exitPoolLiquidity(storage,message,in),
        ProvidePoolState => providePoolState(storage,message,in),
        ClaimReward => claimPoolReward(storage,message,in),
        PayoutReward => payoutPoolReward(storage,message,in),
        UpgradePool => upgradePool(storage,message,in),
    }
}
