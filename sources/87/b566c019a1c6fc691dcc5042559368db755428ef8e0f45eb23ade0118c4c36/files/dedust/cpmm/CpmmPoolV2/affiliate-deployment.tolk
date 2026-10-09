// decompiled by @fiscaldev
import "@stdlib/exotic-cells"
import "addresses"

const POOL_REFERRER_TAG = 132
const POOL_PARTNER_TAG = 163

fun poolAffiliateLibrary(): cell
    asm "<b 2 8 u, 0x4456fad12a434c4898b05ac65bab5de80db33f275c6020746de8e111a5cda4e6 256 u, b>spec PUSHREF"

fun poolAffiliateAuthority(): any_address
    asm "x{80187666419A78C39863E64E5F9F264FFC283A7C7BF82DA37ADD3A2E8318691F227_} PUSHSLICE"

fun poolAffiliateNone(): any_address asm "b{00} PUSHSLICE"

// Kind tags describe the Pool's wide union ABI, not serialized opcodes.
@inline_ref
fun affiliateDeployment(kind: int, identity: uint256, fee: uint16): AutoDeployAddress {
    val workchain = 0;
    val code = poolAffiliateLibrary().loadSpecial();
    val authority = poolAffiliateAuthority();
    val metadata: cell? = null;
    val owner = poolAffiliateNone();
    var data = beginCell().storeBool(false).storeSlice(authority as slice);
    if (POOL_REFERRER_TAG == kind) { data.storeBool(false); }
    else { data.storeBool(true); }
    val initialData = data.storeDict(metadata).storeUint(identity, 256).storeUint(fee, 16)
        .storeSlice(owner as slice).endCell();
    return { workchain, stateInit: { code, data: initialData }, toShard: null };
}
