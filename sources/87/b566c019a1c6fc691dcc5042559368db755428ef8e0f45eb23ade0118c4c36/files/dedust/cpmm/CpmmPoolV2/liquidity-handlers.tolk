// decompiled by @fiscaldev
// Readable liquidity handlers; whole-Pool byte identity is still pending.
import "@stdlib/gas-payments"
import "storage"
import "messages"
import "addresses"
import "compat-address"
import "rewards"
import "wallets"
import "settlement"
import "payout-config"
import "payout-basic"
import "events"
import "math"
import "transaction-context"
import "stdlib-legacy-stateinit"
import "deployment-message"

@pure
fun poolLiquidityIsZero(value:coins):bool asm "0 EQINT"

@inline
fun assertPoolDeploymentSender(deployment:AutoDeployAddress,in:PoolInboundContext) {
    val state=deployment.stateInit;
    val shard=deployment.toShard;
    val sender=in.senderAddress();
    var stateHash:uint256;
    if(state is ContractState) {
        if(shard is AddressShardingOptions) {
            stateHash=archivedStateHashPrefix(shard.fixedPrefixLength,state.code,state.data);
        } else {stateHash=archivedStateHash(state.code,state.data);}
    } else {stateHash=state.hash();}
    // The archived check ignores the shard prefix on both addresses.
    if(shard is AddressShardingOptions) {stateHash &= (1 << (256-shard.fixedPrefixLength))-1;}
    var (senderWorkchain,senderHash)=sender.getWorkchainAndHash();
    if(shard is AddressShardingOptions) {senderHash &= (1 << (256-shard.fixedPrefixLength))-1;}
    assert(((senderHash == stateHash) as int & (senderWorkchain == deployment.workchain) as int) != 0) throw 23;
}

@overflow1023_policy("suppress")
struct (0x855afcbd) PoolCreditLiquidity {
    queryId:uint64
    liquidity:coins
    lockedShare:uint16
    notifyGas:coins
    payload:cell?
    receiver:any_address
    xCheckpoint:varuint32
    yCheckpoint:varuint32
    rewards:map<uint2,PoolReward>
}

@inline
fun joinPoolLiquidity(storage:PoolStorage,message:JoinLiquidity,in:PoolInboundContext) {
    val deposit=InitialDepositConfig.fromCell(message.config);
    assertPoolDeploymentSender(depositDeployment(message.initiator,deposit.targetX,deposit.targetY,
        deposit.minimalLiquidity,deposit.lockedShare,deposit.payout),in);
    val wallets=PoolExtra.fromCell(storage.extra).wallets;
    try {
        val rewards=synchronizePoolRewards(storage.rewards,storage.liquidity);
        var usedX=message.x;var usedY=message.y;
        var minted:coins;
        if(poolLiquidityIsZero(storage.liquidity)) {minted=poolLiquiditySqrt(message.x*message.y);}
        else {
            usedX=min(usedX,mulDivFloor(usedY,storage.reserveX,storage.reserveY));
            usedY=min(usedY,mulDivFloor(usedX,storage.reserveY,storage.reserveX));
            minted=min(mulDivFloor(usedX,storage.liquidity,storage.reserveX),mulDivFloor(usedY,storage.liquidity,storage.reserveY));
        }
        val checkedDeposit=InitialDepositConfig.fromCell(message.config);
        assert(minted > 0 && minted >= checkedDeposit.minimalLiquidity) throw 30;
        storage.reserveX+=usedX;storage.reserveY+=usedY;storage.liquidity+=minted;
        storage.depositActive=true;
        // Copy the new reward map when its field is stored, retaining the same
        // original map value for the following Position credit message.
        var updatedStorage=beginCell().storeRef(storage.config).storeRef(storage.fees).storeRef(storage.extra);
        updatedStorage.storeDict(rewards.toLowLevelDict());
        updatedStorage.storeAny(storage.status).storeBool(storage.depositActive).storeBool(storage.swapActive)
            .storeCoins(storage.liquidity).storeCoins(storage.reserveX).storeCoins(storage.reserveY);
        contract.setData(updatedStorage.endCell());
        storage.rewards=rewards;
        val payout=PoolExtendedPayout.fromCell(checkedDeposit.payout);
        val nextState=beginCell().storeCoins(storage.reserveX).storeCoins(storage.reserveY).storeCoins(storage.liquidity).storeRef(storage.fees).endCell();
        emitPoolDeposit({amountX:usedX,amountY:usedY,liquidity:minted,initiator:message.initiator,
            recipient:payout.fulfill.destination,nextState});
        settlePoolAssets(message.queryId,storage.config,wallets,message.x-usedX,message.y-usedY,payout.fulfill,payout.excessesTo,true);
        val fees=PoolFees.fromCell(storage.fees);
        val position=positionDeployment(payout.fulfill.destination);
        val credit=PoolCreditLiquidity{
            queryId:message.queryId,liquidity:minted,lockedShare:checkedDeposit.lockedShare,notifyGas:payout.fulfill.extraGas,
            payload:payout.fulfill.payload,receiver:payout.excessesTo,xCheckpoint:fees.xCheckpoint,yCheckpoint:fees.yCheckpoint,rewards,
        }.toCell();
        val output=archivedPoolRefDeploymentHeader(position).storeRef(credit).endCell();
        sendRawMessage(output,128);
    } catch(code,value) {
        val rejected=InitialDepositConfig.fromCell(message.config);
        val payout=PoolExtendedPayout.fromCell(rejected.payout);
        settlePoolAssets(message.queryId,storage.config,wallets,message.x,message.y,payout.reject,payout.excessesTo,false);
        commitContractDataAndActions();throw code;
    }
}

@inline
fun refundPoolDeposit(storage:PoolStorage,message:RefundDeposit,in:PoolInboundContext) {
    val deposit=InitialDepositConfig.fromCell(message.config);
    assertPoolDeploymentSender(depositDeployment(message.initiator,deposit.targetX,deposit.targetY,
        deposit.minimalLiquidity,deposit.lockedShare,deposit.payout),in);
    val checkedDeposit=InitialDepositConfig.fromCell(message.config);
    val payout=PoolExtendedPayout.fromCell(checkedDeposit.payout);
    val wallets=PoolExtra.fromCell(storage.extra).wallets;
    settlePoolAssets(message.queryId,storage.config,wallets,message.x,message.y,payout.reject,payout.excessesTo,false);
}

struct (0xbc1531a9) PoolWithdrawLiquidity {
    queryId:uint64
    liquidity:coins
    minX:coins
    minY:coins
    xCheckpoint:varuint32
    yCheckpoint:varuint32
    rewards:map<uint2,PoolReward>
    claimFees:bool
    payout:cell
}

@inline
fun requestPoolWithdrawal(storage:PoolStorage,message:Withdraw,in:PoolInboundContext) {
    assert(storage.status is PoolInitialized) throw 22;
    storage.rewards=synchronizePoolRewards(storage.rewards,storage.liquidity);
    contract.setData(storage.toCell());
    val payout=normalizePoolBasicPayout(PoolBasicPayout.fromCell(message.payout),in.senderAddress());
    val budget=contract.getStoragePaidPayment()+(poolOriginalForwardFee() << 2)+calculateGasFee(0,25000)+
        calculateGasFee(0,20000)+calculateGasFee(0,29000)+((50000000+payout.options.extraGas) << 1);
    assert(budget <= in.valueCoins()) throw 25;
    val fees=PoolFees.fromCell(storage.fees);
    val destination=positionDeployment(in.senderAddress()).calculateArchivedAddressBuilder();
    val body=PoolWithdrawLiquidity{queryId:message.queryId,liquidity:message.liquidity,minX:message.minX,minY:message.minY,
        xCheckpoint:fees.xCheckpoint,yCheckpoint:fees.yCheckpoint,rewards:storage.rewards,claimFees:message.claimFees,payout:payout.toCell()}.toCell();
    val output=beginCell().storeUint(0x10,6).storeBuilder(destination).storeUint(1,111).storeRef(body).endCell();
    sendRawMessage(output,64);
}

@inline
fun exitPoolLiquidity(storage:PoolStorage,message:ExitLiquidity,in:PoolInboundContext) {
    assertPoolDeploymentSender(positionDeployment(message.owner),in);
    val amountX=mulDivFloor(storage.reserveX,message.liquidity,storage.liquidity);
    val amountY=mulDivFloor(storage.reserveY,message.liquidity,storage.liquidity);
    assert(amountX >= message.minX && amountY >= message.minY) throw 30;
    storage.reserveX-=amountX;storage.reserveY-=amountY;storage.liquidity-=message.liquidity;
    contract.setData(storage.toCell());
    val payout=PoolBasicPayout.fromCell(message.payout);
    val nextState=beginCell().storeCoins(storage.reserveX).storeCoins(storage.reserveY).storeCoins(storage.liquidity).storeRef(storage.fees).endCell();
    emitPoolWithdrawal({liquidity:message.liquidity,amountX,amountY,initiator:message.owner,recipient:payout.options.destination,nextState});
    val wallets=PoolExtra.fromCell(storage.extra).wallets;
    settlePoolAssets(message.queryId,storage.config,wallets,amountX+message.xFees,amountY+message.yFees,payout.options,payout.excessesTo,false);
}
