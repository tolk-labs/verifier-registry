// SPDX-License-Identifier: BUSL-1.1
import "../common/types"
import "../ccipsend_executor/types"
import "../../lib/utils"
import "../../lib/deployable/types"
import "../../lib/deployable/namespace"

const OnRamp_FACILITY_NAME = "link.chain.ton.ccip.OnRamp";
const OnRamp_FACILITY_ID = 134;  // (crc32(<facility>) % 640) + 10

struct OnRamp_DestChainConfig {
    router: address; // Local router address that is allowed to send messages to the destination chain.
    sequenceNumber: uint64;
    allowlistEnabled: bool;
    allowedSenders: map<address, bool>;
}

struct OnRamp_DynamicConfig {
    feeQuoter: address;
    // destination address that will receive tokens on withdrawFees
    feeAggregator: address;
    allowlistAdmin: address;
    reserve: coins;
}

struct OnRampUpdateDestChainConfig {
    destChainSelector: uint64;
    router: address;
    allowlistEnabled: bool;
}

struct ExecutorDeployment {
    deployableCode: cell;
    executorCode: cell; // code for SendExecutor
}

@inline
fun ExecutorDeployment.autoDeployAddress(self, executorID: CCIPSendExecutor_ID): AutoDeployAddress {
    return AutoDeployAddress {
        stateInit: ContractState {
            code: self.deployableCode,
            data: NamespacedDeployableData({
                namespace: DeployableNamespace_CCIPSendExecutor,
                owner: contract.getAddress(),
                id: executorID,
            }),
        }
    }
}

struct UpdateAllowlist {
    destChainSelector: uint64;
    add: SnakedCell<address>;
    remove: SnakedCell<address>
}

struct Metadata {
    sender: address,
    value: coins,
}

struct TVM2AnyRampMessage {
    header: RampMessageHeader;
    sender: address;
    body: Cell<TVM2AnyRampMessageBody>;
    feeValueJuels: uint96; // entire supply of LINK always fits into u96
}

struct TVM2AnyRampMessageBody {
    receiver: Cell<CrossChainAddress>;
    data: cell;
    extraArgs: cell;
    tokenAmounts: cell;
    feeToken: address;
    feeTokenAmount: uint256;
}

fun TVM2AnyRampMessage.generateMessageId(self, metadataHash: uint256): uint256 {
    // Loosely based on https://github.com/smartcontractkit/chainlink/blob/d1a9f8be2f222ea30bdf7182aaa6428bfa605cf7/contracts/src/v0.8/ccip/libraries/Internal.sol#L137-L154
    return beginCell()
        .storeSlice(LEAF_DOMAIN_SEPARATOR)
        .storeUint(metadataHash, 256)
        // header
        .storeAddress(self.sender)
        .storeUint(self.header.sequenceNumber, 64)
        .storeUint(self.header.nonce, 64)
        // message
        .storeRef(self.body) // receiver, data, extraArgs, tokenAmounts, feeToken (addr, amount) NOTE: feeValueJuels deliberately excluded
        .endCell()
        .hash()
}

