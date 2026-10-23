// SPDX-License-Identifier: MIT
import "../../ccip/common/types"

/// @notice Family-agnostic message routed to a Receiver.
struct Any2TVMMessage {
    messageId: uint256;
    sourceChainSelector: uint64;
    sender: CrossChainAddress;
    data: cell;
    /// Note: currently unused, added for compatibility on upgrades
    tokenAmounts: cell?;
}
