// Shared types for the SwiftDelivery contracts.
//
// The delivery REWARD is held in USDT (a TEP-74 jetton, 6 decimals) in the
// order's own USDT wallet. Everything else — the service fees, all gas, the
// referral half and the owner's payout — stays in the chain's native coin.
// ===================== Order =====================

enum OrderStatus: uint8 {
    Open = 0
    Accepted = 1
    Completed = 2
    Cancelled = 3
    Expired = 4 // deadline passed; reward -> client, courier gets nothing
    // Deployed by the Marketplace, but its USDT has not arrived yet. The
    // Marketplace forwards the reward right after the deploy; the order turns
    // Open when its own USDT wallet reports it (see JettonNotify in Order.tolk).
    // A Funding order cannot be accepted, so the Feed (Open only) never shows it.
    Funding = 5
}

enum OrderErrors {
    WrongStatus = 100
    NotClient = 101
    NotCourier = 102      // courier-release attempted by someone other than the courier
    FeeTooLow = 103       // caller attached less than the fee / payout gas this action needs
    NotExpired = 104      // claim attempted before the deadline
    DeadlinePassed = 105  // courier-release attempted after the deadline
    BadCode = 108         // confirm attempted with a secret whose hash does not match
    NotMarketplace = 109  // InitWallet from anyone but the Marketplace that deployed the order
    NotJettonWallet = 110 // jetton notification from anything but the order's own USDT wallet
    NotPayee = 111        // Rescue from anyone but the payee of the closed order
    BadInvite = 112       // accept whose invite signature is not the client's for this courier
    InviteExpired = 113   // accept after the invite's validUntil
    InvalidMessage = 0xFFFF
}

// The order's link to USDT, in its own referenced cell (the root already has
// four refs and OrderExtra is at 790 bits, so neither can take two more
// addresses). It also holds the client's invite key, for the same reason:
// OrderExtra has no room for 256 more bits (790 + 256 > 1023), this cell does
// (534 + 256 = 790). `marketplace` is part of the init data: it is the only address
// allowed to hand the order its wallet. `wallet` is null in the init data (so
// it does not change the order's address) and is set once by InitWallet.
//
// Why the Marketplace computes the wallet and not the order: a jetton wallet's
// address is the hash of its state, which includes the OWNER's address — the
// order's own address. Putting it in the init data would be a cycle, and
// computing it here would need the USDT wallet code in every order.
struct OrderJetton {
    marketplace: address // the Marketplace that deployed this order
    wallet: address?     // this order's USDT wallet; null until InitWallet
    // Public key of the client's one-time invite key pair (Ed25519). Only a
    // courier holding an invite signed with it may accept (see AcceptOrder).
    // Part of the init data, like secretHash.
    acceptKey: uint256
}

// Fields kept in a separate referenced cell (`Cell<OrderExtra>`, TL-B
// `^OrderExtra`) so the root OrderStorage cell stays well under the 1023-bit
// limit. The root already carries two full addresses (`client` + `courier`,
// 267 bits each) plus a `coins` field and the counters. When a courier accepts,
// `courier` grows from a 2-bit null to a 267-bit address, so a THIRD inline
// address (`owner`) would push the root past 1023 bits (exit_code 8, cell
// overflow). Keeping `owner` (plus the two contact cells) here keeps the root
// small, so no overflow policy is suppressed.
struct OrderExtra {
    owner: address       // marketplace owner; receives the platform fee on completion
    // Telegram contact of each party, packed as opaque text by the frontend
    // (see src/contact.js). Public on-chain, so it carries only the @username,
    // numeric id and first name — never a phone or the exact street address.
    clientContact: cell  // set by the client at create time
    courierContact: cell // empty until a courier accepts, then their contact
    // Delivery-code commitment. The client's app picks a 256-bit random secret at
    // create time and stores it locally; only this HASH of it goes on-chain. The
    // courier learns the secret from the client at hand-off (shown as a QR code)
    // and sends it with ConfirmWithCode; the contract pays the reward only when
    // hash(secret) == secretHash. So a courier can be paid ONLY with the client's
    // code — there is no "confirm" button the client could sit on. It lives here
    // in the referenced extra cell (not the root) to keep the root under 1023 bits
    // (a 256-bit field in the root would risk the same overflow).
    // It is part of the init data, so it changes the order's address like
    // clientContact does — included in CreateOrder and the orderAddress getter.
    secretHash: uint256
    // Referral: the TON wallet address of the Telegram chat whose link opened
    // the app (null = no chat). Set once at create time from CreateOrder and
    // never changed. On every terminal path (ConfirmWithCode / CancelOrder /
    // ClaimExpired) the order pays this address HALF of the accumulated fee
    // pool; the owner gets the rest (see Order.tolk). Any address is accepted
    // as-is. A client who names their own wallet gets back half of the fee
    // pool — about their own create fee — but never more than the fees paid
    // into the order, and never any of the reward. Fits here: owner(267) +
    // secretHash(256) + referral(267) = 790 bits < 1023, 3 refs.
    referral: address?
    jetton: Cell<OrderJetton>
}

// One delivery order. Holds the escrow and the state machine.
// `description`, `area` and `origin` are cells (text packed by the caller).
// All three are public; the exact street address is NEVER stored on-chain.
//   `area`   — the "to" city (destination).
//   `origin` — the "from" place (where the parcel starts). It is free text and
//              need NOT be a city: it can be a shop, a landmark, an airport zone
//              ("Duty Free", "H&M", "McDonald's"). The UI defaults this to
//              "All world" when the client does not care about the origin.
//
// All fields here are supplied by the creator (the frontend), NOT by block
// time or a global counter. That is on purpose: a contract's address is the
// hash of its initial state, so keeping the init data fully client-controlled
// lets the frontend recompute the address of an order it just created.
// `nonce` is a client random value that makes the address unique.
struct OrderStorage {
    client: address
    courier: address?  // null until a courier accepts
    description: cell
    area: cell         // "to" city (destination)
    origin: cell       // "from" place (source, any text); "All world" = any origin
    reward: coins      // in USDT base units (1 USDT = 1_000_000), NOT nano
    status: OrderStatus
    nonce: uint64      // client random, for a unique address
    createdAt: uint32  // client unix time, for display only
    // acceptedAt is 0 in the initial state (so it does not change the order's
    // address) and is set by the contract itself when a courier accepts; it
    // starts the delivery clock that ClaimExpired checks against the deadline.
    acceptedAt: uint32 // contract block time at AcceptOrder; 0 until accepted
    // How long the courier has to deliver, in seconds, counted from acceptedAt.
    // The client picks it at create time (the Marketplace allows 1..14 days), so
    // a quick city run does not lock the reward for two weeks when a courier
    // takes the order and disappears. Part of the init data, like the reward.
    deliveryTime: uint32
    // owner + both Telegram contacts + the USDT link, in a referenced cell.
    extra: Cell<OrderExtra>
}

fun OrderStorage.load(): OrderStorage {
    return OrderStorage.fromCell(contract.getData());
}

fun OrderStorage.save(self) {
    contract.setData(self.toCell());
}

// Accept an Open order. A stranger cannot: the courier must bring an invite,
// the client's signature over AcceptInvite { this order, this courier,
// validUntil } made with the key behind OrderJetton.acceptKey. The client's app
// signs it off-chain (no transaction) after the two agreed in Telegram. The
// invite names the courier's address, so nobody else can use it, and it
// expires, so an invited courier cannot re-lock the order with
// "release + accept" after validUntil.
struct (0xa00a0001) AcceptOrder {
    courierContact: cell // courier's Telegram contact, revealed once accepted
    validUntil: uint32   // the invite is void after this unix time
    signature: bits512   // client's Ed25519 signature of AcceptInvite's cell hash
}

// What the client's invite signs: the representation hash of this cell. Not a
// message; the frontend builds the same cell (two std addresses + uint32).
struct AcceptInvite {
    order: address
    courier: address
    validUntil: uint32
}

// Confirm a delivery by revealing the secret behind the order's secretHash. The
// courier scans the client's QR at hand-off to obtain `secret` and sends it here;
// the contract pays the courier only if hash(secret) == secretHash (see Order.tolk).
struct (0xa00a0002) ConfirmWithCode {
    secret: uint256 // preimage; the contract checks hash(secret) == secretHash
}

struct (0xa00a0003) CancelOrder {}

struct (0xa00a0004) ClaimExpired {}

// Courier gives up an order they already accepted. Allowed ONLY before the
// deadline: once the delivery window has passed the courier has no actions left
// and the order can only be settled by the client (claim or confirm). The order
// does NOT close: it goes back to Open so another courier can take it. The courier
// pays a 0.2 TON release fee on top of the 0.1 TON accept fee they already paid;
// neither is refunded — both stay on the contract for the platform. The reward and
// the client's create fee also stay on the contract for the next courier.
struct (0xa00a0005) CourierRelease {}

// The body of the Marketplace's deploy message: the address of the order's own
// USDT wallet (see OrderJetton). Accepted once, and only from the Marketplace.
struct (0xa00a0006) InitWallet {
    wallet: address
}

// Pull USDT out of a CLOSED order's wallet, to the payee of that order only
// (the courier of a Completed order, the client of a Cancelled / Expired one).
// A jetton payout that fails on the receiving side (e.g. the payee's USDT wallet
// was locked by the issuer) silently puts the USDT back in the order's wallet,
// and the order is never told. USDT someone sends to an order by mistake lands
// there too. Rescue is the way out for both. `amount` is chosen by the caller;
// if the wallet holds less, the transfer just fails and nothing moves.
struct (0xa00a0007) Rescue {
    amount: coins
}

type OrderMessage =
    | AcceptOrder
    | ConfirmWithCode
    | CancelOrder
    | ClaimExpired
    | CourierRelease
    | InitWallet
    | Rescue
    | JettonNotify
    | Excesses

// =============== USDT (TEP-74 jetton) ===============
// Only the messages we send or receive. Tether's USDT on TON is the
// "stablecoin" jetton (ton-blockchain/stablecoin-contract); these layouts match it.

// Sent by a wallet's OWNER to that wallet: move `amount` to the wallet of
// `destination`. We never attach a forward payload of our own, so the TL-B
// `Either Cell ^Cell` payload is the single bit 0 (an empty inline payload),
// stored by `forwardPayloadInRef: false`.
struct (0x0f8a7ea5) JettonTransfer {
    queryId: uint64
    amount: coins
    destination: address
    responseDestination: address // gets the unused native coins back ("excesses")
    customPayload: cell?
    forwardTonAmount: coins      // > 0: the destination's owner gets a JettonNotify
    forwardPayloadInRef: bool
}

// Sent by a wallet to its OWNER when jettons arrive with forwardTonAmount > 0.
// ANYONE can send a message with this opcode, so a receiver must first check that
// it came from its own wallet of the jetton it expects.
struct (0x7362d09c) JettonNotify {
    queryId: uint64
    amount: coins
    from: address?                       // owner of the sending wallet; null (addr_none) for a mint
    forwardPayload: RemainingBitsAndRefs // TL-B `Either Cell ^Cell`
}

// Sent by a wallet to a transfer's `responseDestination` with the unused native
// coin. The Marketplace's create names the order as responseDestination, so
// every create ends with one of these at the order.
struct (0xd53276db) Excesses {
    queryId: uint64
}

// ===================== Events =====================
// TON has no Ethereum-style logs; the equivalent is an EXTERNAL-OUT message:
// it goes nowhere, costs a tiny forward fee from the contract balance, and is
// recorded forever in the block. Indexers (toncenter v3 etc.) filter these by
// source address + opcode. Every state change emits one, so a watcher needs no
// transaction reverse-engineering.
//
// Event opcodes live in their own 0xa00a01xx range so they can never collide
// with the incoming-message opcodes (0xa00a00xx above). The source address of
// an Order event IS the order, so the events carry no orderAddress field —
// except OrderCreated, which the Marketplace emits (one address to watch) and
// which therefore names the new order explicitly.
//
// Events are logs, not money: they are always sent with IGNORE_ERRORS so a
// failed emit can never block an order. All `reward` fields are USDT base units.

// Emitted by Marketplace when it deploys an order (the order starts Funding and
// turns Open with OrderFunded a few seconds later). Gives a watcher everything to
// start tracking the order: its address (source of all later events), who created
// it, the escrowed reward and the "to" city (the Feed's filter key).
struct (0xa00a0100) OrderCreated {
    orderAddress: address
    client: address
    reward: coins
    area: cell
}

// Emitted by Order on AcceptOrder: a courier took the order; the delivery
// clock starts at this transaction's block time.
struct (0xa00a0101) OrderAccepted {
    courier: address
}

// Emitted by Order on ConfirmWithCode: the courier revealed the client's
// delivery code and the reward was sent to them. referralPayout is the exact
// amount (native coin) sent to the referral chat (0 when no referral); the
// owner's payout is the rest of the fee pool minus network fees.
struct (0xa00a0102) OrderCompleted {
    courier: address
    reward: coins
    referralPayout: coins
}

// Emitted by Order on CancelOrder: the client cancelled an Open (or still
// Funding) order and the reward was sent back. referralPayout as in OrderCompleted.
struct (0xa00a0103) OrderCancelled {
    reward: coins
    referralPayout: coins
}

// Emitted by Order on ClaimExpired: the courier missed the deadline, the
// reward returned to the client. `courier` names who failed to deliver.
struct (0xa00a0104) OrderExpired {
    courier: address
    reward: coins
    referralPayout: coins
}

// Emitted by Order on CourierRelease: the courier gave the order up and it
// went back to Open for anyone else to take. `courier` names who walked away.
struct (0xa00a0105) OrderReopened {
    courier: address
}

// Emitted by Order when its USDT arrived and it turned from Funding to Open.
struct (0xa00a0106) OrderFunded {
    reward: coins
}

// Emitted by Marketplace when it could not create an order from a USDT transfer
// (bad payload, reward below the minimum, too little gas) and sent the USDT back.
struct (0xa00a0107) CreateRefused {
    client: address
    amount: coins
}

// Emit one event as an external-out message. IGNORE_ERRORS is deliberate: an
// event is a log, and a log must never make the money-moving action fail —
// if the balance cannot cover the emit's forward fee, the emit is skipped and
// the order proceeds. In terminal handlers the emit must run BEFORE the final
// CARRY_ALL_BALANCE sweep, while the balance still covers its fee.
fun emitEvent<TEvent>(event: TEvent) {
    val msg = createExternalLogMessage({
        dest: createAddressNone(),
        body: event,
    });
    msg.send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
}

// =================== Marketplace ===================

enum MarketplaceErrors {
    NotJettonWallet = 201 // jetton notification from anything but our own USDT wallet
    InvalidMessage = 0xFFFF
}

// The single registry contract. It deploys Order contracts on demand.
// `orderCode` is the compiled Order code cell, set at deploy time, so the
// Marketplace can build new Order state-init on-chain. `usdtMaster` and
// `jettonWalletCode` pin the ONE jetton the Marketplace accepts; they differ per
// network (on mainnet the wallet code is a library cell, on testnet the plain
// code) and, like everything here, can never change after deploy.
struct MarketplaceStorage {
    owner: address
    orderCode: cell
    orderCount: uint32
    usdtMaster: address
    jettonWalletCode: cell
}

fun MarketplaceStorage.load(): MarketplaceStorage {
    return MarketplaceStorage.fromCell(contract.getData());
}

fun MarketplaceStorage.save(self) {
    contract.setData(self.toCell());
}

// The order's parameters. Not a message of its own: the client puts it
// (in a ref) into the forward payload of the USDT transfer to the Marketplace,
// and the Marketplace reads it from the JettonNotify. The reward is not in here
// — it is the USDT amount that actually arrived.
struct (0xa00a0000) CreateOrder {
    nonce: uint64       // client random, for a unique order address
    createdAt: uint32   // client unix time, for display
    deliveryTime: uint32 // seconds the courier gets after accepting, 1..14 days (see OrderStorage)
    description: cell
    area: cell          // "to" city (destination)
    origin: cell        // "from" place (source, any text); "All world" = any origin
    clientContact: cell // client's Telegram contact (opaque text)
    secretHash: uint256 // hash of the client's delivery code (see OrderExtra.secretHash)
    acceptKey: uint256  // client's invite public key (see OrderJetton.acceptKey)
    referral: address?  // referral chat's wallet, or null (see OrderExtra.referral)
}

type MarketplaceMessage =
    | JettonNotify
    | Excesses
