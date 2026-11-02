tolk 1.4.2

struct SignedPayload {
    signature: bits512
    payload: cell
}

struct (0x69cb28f3) DepositPayload {
    prevOwner: address
    nftAddress: address
    dealAddress: address
    toll: coins
}
