// decompiled by @fiscaldev
// Byte-identical readable recovery of the archived mainnet CPMM Pool V2.
// Compiler/BOC/behavior evidence is recorded by the reconstruction gate.
import "getters"
import "handlers"
import "messages"
import "storage"
import "transaction-context"

fun onInternalMessage(in:InMessage) {
    val message=PoolMessage.fromSlice(in.body,{assertEndAfterReading:false,throwIfOpcodeDoesNotMatch:65535});
    val storage=PoolStorage.fromCell(contract.getData(),{assertEndAfterReading:false});
    handlePoolMessage(storage,message,PoolInboundContext{});
}
