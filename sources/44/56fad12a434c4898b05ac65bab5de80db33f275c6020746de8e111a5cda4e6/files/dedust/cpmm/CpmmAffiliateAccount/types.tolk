// decompiled by @fiscaldev
// Storage and message fields are inferred from the executable code.
// The public SDK documents affiliate IDs and fee BPS, but not these message names.
@overflow1023_policy("suppress")
struct AffiliateRuntimeStorage {
    isActivated: bool
    authority: any_address
    kindPrefix: bits1
    metadata: cell?
    identityAndFee: bits272
    owner: any_address
}

// Inferred from Pool swap processing: its first public-ABI partnerConfig
// creates kind 1; its second referrerConfig creates kind 0.
struct (0b0) ReferrerKind {}
struct (0b1) PartnerKind {}
type AffiliateKind = ReferrerKind | PartnerKind

@overflow1023_policy("suppress")
struct AffiliateGetterStorage {
    isActivated: bool
    authority: any_address
    kind: AffiliateKind
    metadata: cell?
    affiliateId: uint256
    feeBps: uint16
    owner: any_address
}

struct (0x773faf30) FeeNotification { tail: RemainingBitsAndRefs }
struct (0xe5d596b3) ActivateAffiliate { tail: RemainingBitsAndRefs }
struct (0xa43314ff) WithdrawAffiliate { tail: RemainingBitsAndRefs }
type AffiliateMessage = FeeNotification | ActivateAffiliate | WithdrawAffiliate

@overflow1023_policy("suppress")
struct ActivationBody {
    queryId: uint64
    metadata: cell
    owner: any_address
    excesses: any_address
}

@overflow1023_policy("suppress")
struct WithdrawalBody {
    queryId: uint64
    recipient: any_address
    excesses: any_address
}

struct (0xd53276db) Excesses { queryId: uint64 }
