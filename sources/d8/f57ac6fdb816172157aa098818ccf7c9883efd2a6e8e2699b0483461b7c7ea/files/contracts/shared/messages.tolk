// Copyright (C) 2026 MENA
// SPDX-License-Identifier: AGPL-3.0-or-later

// Messages of the escrow's own protocol, shared by SwapEscrowNosup and
// SwapEscrowV2.
import "../messages"

// Pull delivery of a deal asset whose push delivery did not arrive.
struct (0x6d5f0006) ClaimAsset {
    queryId: uint64
    assetIndex: uint16
}

// Side 2 takes the deal: its payment (service fee, TON leg, then a reserve)
// and, per minter of its jettons, the escrow's jetton wallet address read
// off-chain from the minter's get_wallet_address. Usually the first message of
// owner2's batch, carrying the escrow's StateInit.
struct (0x6d5f0007) AcceptDeal {
    queryId: uint64
    claims: map<address, address> // minter -> claimed escrow wallet
}

// TEP-89 take_wallet_address. A minter answers addr_none for an owner it does
// not serve (an address in another workchain), so the wallet is read as
// `address?`: null is addr_none. Same opcode and layout as the shared
// TakeWalletAddress, which reads a plain `address`.
struct (0xd1735400) TakeWalletAddressNosup {
    queryId: uint64
    walletAddress: address?
    rest: RemainingBitsAndRefs // owner_address:(Maybe ^MsgAddress) — not read
}
