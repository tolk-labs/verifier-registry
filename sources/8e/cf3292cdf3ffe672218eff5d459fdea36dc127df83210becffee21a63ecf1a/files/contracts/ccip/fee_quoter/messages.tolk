// SPDX-License-Identifier: BUSL-1.1
import "types"
import "../router/messages"
import "../../lib/utils"
import "../../lib/funding/withdrawable"
import "../../lib/versioning/upgradeable"
import "../ccipsend_executor/messages"

type FeeQuoter_InMessage =
    | FeeQuoter_AddPriceUpdater
    | FeeQuoter_RemovePriceUpdater
    | FeeQuoter_UpdatePrices
    | FeeQuoter_UpdateFeeTokens
    | FeeQuoter_UpdateTokenTransferFeeConfigs
    | FeeQuoter_UpdateDestChainConfigs
    | FeeQuoter_GetValidatedFee<RemainingBitsAndRefs>
    | Withdrawable_Withdraw
    | Upgradeable_Upgrade;
    ;

struct (0xde852b1b) FeeQuoter_UpdatePrices {
    updates: PriceUpdates
    sendExcessesTo: address?;
}

struct (0x7496FF56) FeeQuoter_GetValidatedFee<T> {
    msg: Cell<Router_CCIPSend>
    context: T;
}

struct (0xD0984986) FeeQuoter_UpdateFeeTokens {
    add: map<address, FeeToken>; // token -> config
    remove: SnakedCell<address>;
}

// --- Outgoing messages ---

struct (0x1fa60374) FeeQuoter_MessageValidated<T> {
    fee: Fee,
    msg: Cell<Router_CCIPSend>
    context: T
}

struct (0xbcf0ab0f) FeeQuoter_MessageValidationFailed<T> {
    error: uint256,
    msg: Cell<Router_CCIPSend>,
    context: T
}


// NOTE: we just merged this into UpdateFeeTokens
// UpdatePremiumMultiplierWeiPerEth { // token, multiplier }

struct (0xB2826316) FeeQuoter_UpdateTokenTransferFeeConfigs {
    updates: map<uint64, UpdateTokenTransferFeeConfig>; // destChainSelector -> updates
}

struct (0x2d2410f6) FeeQuoter_UpdateDestChainConfigs {
    updates: SnakedCell<FeeQuoter_UpdateDestChainConfig>;
}

struct (0x71DF848A) FeeQuoter_AddPriceUpdater {
    priceUpdater: address;
}

struct (0x5DFBB1BC) FeeQuoter_RemovePriceUpdater {
    priceUpdater: address;
}

// Costs associated with FeeQuoter operations
struct FeeQuoter_Costs {}

// Minimum value for calling FeeQuoter_GetValidatedFee
fun FeeQuoter_Costs.GetValidatedFee(): int {
    return 
        + ton("0.05") // computeFee
        + ton("0.019") // MessageValidated | MessageValidationFailed fwdFee
        ;
}

fun FeeQuoter_Costs.updatePrices(): int {
    // when we support token transfers the message value amount should depend on the quantity of supported tokens
    return ton("0.01");
}
