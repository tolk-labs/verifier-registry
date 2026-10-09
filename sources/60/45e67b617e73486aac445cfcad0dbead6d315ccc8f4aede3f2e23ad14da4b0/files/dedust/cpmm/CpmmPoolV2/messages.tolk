// decompiled by @fiscaldev
// Incoming message layouts recovered from the archived code and public ABI.
struct (0xd53276db) PoolExcesses { queryId: uint64 }
struct (0xde8402ce) InitPool { queryId: uint64; payload: cell? }
struct (0xd1735400) TakeWalletAddress { queryId: uint64; wallet: any_address; owner: cell? }
struct (0xa5a7cbf8) PayNative { queryId: uint64; amount: coins; payment: cell; payout: cell }
type PoolJettonPayload = cell | RemainingBitsAndRefs

fun PoolJettonPayload.unpackFromSlice(mutate s: slice): PoolJettonPayload {
    return s.loadUint(1) != 0 ? s.loadRef() : s as RemainingBitsAndRefs;
}

fun PoolJettonPayload.packToBuilder(self, mutate b: builder) {
    if (self is cell) { b.storeBool(true).storeRef(self); }
    else { b.storeBool(false).storeSlice(self); }
}

struct (0x7362d09c) JettonNotification {
    queryId: uint64
    amount: coins
    sender: any_address
    payload: PoolJettonPayload
}
@overflow1023_policy("suppress")
struct (0x25251ee0) JoinLiquidity { queryId: uint64; config: cell; x: coins; y: coins; initiator: any_address }
@overflow1023_policy("suppress")
struct (0x0d299e12) RefundDeposit { queryId: uint64; config: cell; x: coins; y: coins; initiator: any_address }
struct (0x5652f1df) ClaimPositionFees { queryId: uint64; excessesTo: any_address }
@overflow1023_policy("suppress")
struct (0x29ff1bcf) PayoutPositionFees { queryId: uint64; x: coins; y: coins; owner: any_address; excessesTo: any_address }
@overflow1023_policy("suppress")
struct (0x419a17b3) ClaimProtocolFees { queryId: uint64; to: any_address; excessesTo: any_address }
@overflow1023_policy("suppress")
struct (0xbe3e3179) ClaimCreatorFees { queryId: uint64; to: any_address; excessesTo: any_address }
struct (0x20b5ef89) Withdraw {
    queryId: uint64
    liquidity: coins
    minX: coins
    minY: coins
    claimFees: bool
    payout: cell
}
@overflow1023_policy("suppress")
struct (0xf6f6a3aa) ExitLiquidity {
    queryId: uint64
    liquidity: coins
    xFees: coins
    yFees: coins
    owner: any_address
    minX: coins
    minY: coins
    payout: cell
}
struct (0x00d8d379) ProvidePoolState {
    queryId: uint64
    includeConfig: bool
    includeFees: bool
    includeCodeHash: bool
    includeRewards: bool
}
struct (0x909fdb65) ClaimReward { queryId: uint64; rewardId: uint2; excessesTo: any_address }
@overflow1023_policy("suppress")
struct (0x9e17fbbe) PayoutReward { queryId: uint64; amount: coins; rewardId: uint2; owner: any_address; excessesTo: any_address }
struct (0xf287e089) UpgradePool { queryId: uint64; code: cell }

type PoolMessage = InitPool | TakeWalletAddress | PayNative | JettonNotification | JoinLiquidity | RefundDeposit
    | ClaimPositionFees | PayoutPositionFees | ClaimProtocolFees | ClaimCreatorFees | Withdraw | ExitLiquidity
    | ProvidePoolState | ClaimReward | PayoutReward | UpgradePool

// The getter's status variants follow these message tags in the original layout.
// This unused function fixes allocation order; it emits no runtime code.
@inline
fun registerPoolMessageLayout(value: PoolExcesses | PoolMessage): int {
    return ((value is PoolExcesses) ? 1 : 0) + ((value is InitPool) ? 2 : 0)
        + ((value is TakeWalletAddress) ? 3 : 0) + ((value is PayNative) ? 4 : 0)
        + ((value is JettonNotification) ? 5 : 0) + ((value is JoinLiquidity) ? 6 : 0)
        + ((value is RefundDeposit) ? 7 : 0) + ((value is ClaimPositionFees) ? 8 : 0)
        + ((value is PayoutPositionFees) ? 9 : 0) + ((value is ClaimProtocolFees) ? 10 : 0)
        + ((value is ClaimCreatorFees) ? 11 : 0) + ((value is Withdraw) ? 12 : 0)
        + ((value is ExitLiquidity) ? 13 : 0) + ((value is ProvidePoolState) ? 14 : 0)
        + ((value is ClaimReward) ? 15 : 0) + ((value is PayoutReward) ? 16 : 0)
        + ((value is UpgradePool) ? 17 : 0);
}
