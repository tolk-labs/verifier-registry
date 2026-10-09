// decompiled by @fiscaldev
// Readable fee/reward/state handlers; whole-Pool byte identity is still pending.
import "@stdlib/gas-payments"
import "storage"
import "messages"
import "addresses"
import "compat-address"
import "liquidity-handlers"
import "rewards"
import "wallets"
import "settlement"
import "payment"
import "transfers"
import "payout-config"
import "transaction-context"

type PoolOptionalProvidedRewards=PoolProvidedRewards | null

// Retain the archived materialized null predicate without emitting an opcode.
@pure
fun preservePoolStatePredicate(value:bool):bool asm "nop"

fun PoolOptionalProvidedRewards.packToBuilder(self,mutate b:builder) {
    if(preservePoolStatePredicate(self == null)) {b.storeBool(false);}
    else {b.storeBool(true).storeAny(self!);}
}

// Preserve the callback argument evaluation order of the archived caller.
// This typed identity emits no TVM instruction and does not change its values.
@pure
fun poolRewardCallbackContext(excesses:any_address,queryId:uint64,exitCode:int32):(any_address,uint64,int32) asm "nop"

@inline
fun poolStandardAddressOrFallback(value:any_address,in:PoolInboundContext):any_address {
    if(!value.isInternal()) {value=in.senderAddress();}
    return value;
}

@overflow1023_policy("suppress")
struct (0x25f19752) PoolClaimAvailableFees {
    queryId:uint64
    excessesTo:any_address
    xCheckpoint:varuint32
    yCheckpoint:varuint32
}

@inline
fun claimPoolPositionFees(storage:PoolStorage,message:ClaimPositionFees,in:PoolInboundContext) {
    assert(storage.status is PoolInitialized) throw 22;
    val config=PoolConfig.fromCell(storage.config);
    val assetsToPay=(config.feeIn is FeeFromBoth) ? 2 : 1;
    val budget=contract.getStoragePaidPayment()+calculateGasFee(0,11500)+calculateGasFee(0,6500)+calculateGasFee(0,21000)+assetsToPay*50000000;
    assert(budget <= in.valueCoins()) throw 25;
    val fees=PoolFees.fromCell(storage.fees);
    val destination=positionDeployment(in.senderAddress()).calculateArchivedAddressBuilder();
    val excessesTo=poolStandardAddressOrFallback(message.excessesTo,in);
    val body=PoolClaimAvailableFees{queryId:message.queryId,excessesTo,xCheckpoint:fees.xCheckpoint,yCheckpoint:fees.yCheckpoint}.toCell();
    val output=beginCell().storeUint(0x10,6).storeBuilder(destination).storeUint(1,111).storeRef(body).endCell();
    sendRawMessage(output,64);
}

@inline
fun payoutPoolPositionFees(storage:PoolStorage,message:PayoutPositionFees,in:PoolInboundContext) {
    assertPoolDeploymentSender(positionDeployment(message.owner),in);
    val wallets=PoolExtra.fromCell(storage.extra).wallets;
    settlePoolAssets(message.queryId,storage.config,wallets,message.x,message.y,
        {destination:message.owner,extraGas:0,payload:null,wrapPayload:false},message.excessesTo,false);
}

@inline
fun claimPoolProtocolFees(storage:PoolStorage,message:ClaimProtocolFees,in:PoolInboundContext) {
    assert(storage.status is PoolInitialized) throw 22;
    val extra=PoolExtra.fromCell(storage.extra);
    assert((in.senderAddress() as slice).bitsEqual(extra.controller as slice)) throw 23;
    val config=PoolConfig.fromCell(storage.config);
    val assetsToPay=(config.feeIn is FeeFromBoth) ? 2 : 1;
    assert(contract.getStoragePaidPayment()+calculateGasFee(0,22000)+assetsToPay*50000000 <= in.valueCoins()) throw 25;
    var fees=PoolFees.fromCell(storage.fees);
    val options:PoolPayoutOptions={destination:poolStandardAddressOrFallback(message.to,in),extraGas:0,payload:null,wrapPayload:false};
    val excessesTo=poolStandardAddressOrFallback(message.excessesTo,in);
    settlePoolAssets(message.queryId,storage.config,extra.wallets,fees.protocolX,fees.protocolY,
        options,excessesTo,false);
    fees.protocolX=0;fees.protocolY=0;
    storage.fees=fees.toCell();contract.setData(storage.toCell());
}

@inline
fun claimPoolCreatorFees(storage:PoolStorage,message:ClaimCreatorFees,in:PoolInboundContext) {
    assert(storage.status is PoolInitialized) throw 22;
    val config=PoolConfig.fromCell(storage.config);
    assert((in.senderAddress() as slice).bitsEqual(config.creator as slice)) throw 23;
    val assetsToPay=(config.feeIn is FeeFromBoth) ? 2 : 1;
    assert(contract.getStoragePaidPayment()+calculateGasFee(0,22000)+assetsToPay*50000000 <= in.valueCoins()) throw 25;
    var fees=PoolFees.fromCell(storage.fees);
    val wallets=PoolExtra.fromCell(storage.extra).wallets;
    val options:PoolPayoutOptions={destination:poolStandardAddressOrFallback(message.to,in),extraGas:0,payload:null,wrapPayload:false};
    val excessesTo=poolStandardAddressOrFallback(message.excessesTo,in);
    settlePoolAssets(message.queryId,storage.config,wallets,fees.creatorX,fees.creatorY,
        options,excessesTo,false);
    fees.creatorX=0;fees.creatorY=0;
    storage.fees=fees.toCell();contract.setData(storage.toCell());
}

@overflow1023_policy("suppress")
struct (0x2e0cccba) PoolClaimPositionReward {
    queryId:uint64
    rewardId:uint2
    remainingTime:uint40
    remainingBudget:coins
    checkpoint:varuint32
    lastUpdate:uint40
    excessesTo:any_address
}

@inline
fun claimPoolReward(storage:PoolStorage,message:ClaimReward,in:PoolInboundContext) {
    assert(storage.status is PoolInitialized) throw 22;
    val budget=contract.getStoragePaidPayment()+(poolOriginalForwardFee() << 2)+calculateGasFee(0,18500)+
        calculateGasFee(0,10000)+calculateGasFee(0,19000)+50000000;
    assert(budget <= in.valueCoins()) throw 25;
    val reward=accruePoolReward(storage.rewards.mustGet(message.rewardId,46),storage.liquidity);
    storage.rewards.set(message.rewardId,reward);contract.setData(storage.toCell());
    reserveToncoinsOnBalance(contract.getStoragePaidPayment(),4);
    val destination=positionDeployment(in.senderAddress()).calculateArchivedAddressBuilder();
    val excessesTo=poolStandardAddressOrFallback(message.excessesTo,in);
    val body=PoolClaimPositionReward{queryId:message.queryId,rewardId:message.rewardId,
        remainingTime:reward.remainingTime,remainingBudget:reward.remainingBudget,checkpoint:reward.checkpoint,lastUpdate:reward.lastUpdate,excessesTo}.toCell();
    val output=beginCell().storeUint(0x10,6).storeBuilder(destination).storeUint(1,111).storeRef(body).endCell();
    sendRawMessage(output,128);
}

@inline
fun payoutPoolReward(storage:PoolStorage,message:PayoutReward,in:PoolInboundContext) {
    assertPoolDeploymentSender(positionDeployment(message.owner),in);
    val config=PoolConfig.fromCell(storage.config);
    val asset=config.allowedRewards.mustGet(message.rewardId,42).asset;
    val wallets=PoolExtra.fromCell(storage.extra).wallets;
    val previousBalance=contract.getOriginalBalance()+contract.getStoragePaidPayment()-poolIncomingCoins();
    val wallet=poolWalletForAsset(wallets,asset);
    // Unlike two-asset settlement, this handler sends even a zero amount.
    val options:PoolPayoutOptions={destination:message.owner,extraGas:0,payload:null,wrapPayload:false};
    val (callbackExcesses,callbackQuery,callbackExit)=poolRewardCallbackContext(message.excessesTo,message.queryId,0);
    val (principal,fee)=sendPoolPayment(asset,wallet,message.amount,
        options,callbackExcesses,callbackQuery,callbackExit);
    reserveToncoinsOnBalance(previousBalance+(fee-principal),2);
    sendPoolExcesses(message.excessesTo,message.queryId,128);
}

@inline
fun providePoolState(storage:PoolStorage,message:ProvidePoolState,in:PoolInboundContext) {
    reserveToncoinsOnBalance(contract.getStoragePaidPayment(),4);
    val recipient=in.senderAddress();
    val config=message.includeConfig ? storage.config : null;
    val fees=message.includeFees ? storage.fees : null;
    val rewards:PoolOptionalProvidedRewards=message.includeRewards ? PoolProvidedRewards{rewards:storage.rewards} : null;
    val codeHash:uint256?=message.includeCodeHash ? contract.getCode().hash() : null;
    val body=PoolStateResponse{queryId:message.queryId,status:storage.status,
        depositActive:storage.depositActive,swapActive:storage.swapActive,liquidity:storage.liquidity,
        reserveX:storage.reserveX,reserveY:storage.reserveY,config,fees,rewards,codeHash}.toCell();
    val output=beginCell().storeUint(0x10,6).storeSlice(recipient as slice).storeUint(1,111).storeRef(body).endCell();
    sendRawMessage(output,128);
}

@overflow1023_policy("suppress")
struct (0x870a9579) PoolStateResponse {
    queryId:uint64
    status:PoolStatus
    depositActive:bool
    swapActive:bool
    liquidity:coins
    reserveX:coins
    reserveY:coins
    config:cell?
    fees:cell?
    rewards:PoolOptionalProvidedRewards
    codeHash:uint256?
}

@inline
fun upgradePool(storage:PoolStorage,message:UpgradePool,in:PoolInboundContext) {
    val extra=PoolExtra.fromCell(storage.extra);
    assert((extra.controller as slice).bitsEqual(in.senderAddress() as slice)) throw 23;
    contract.setCodePostponed(message.code);
    sendPoolExcesses(in.senderAddress(),message.queryId,128);
}
