tolk 1.5

import "@stdlib/gas-payments"
import "@stdlib/strings"
import "membership-messages"

// CyberKonquest membership NFT collection (TEP-62, TEP-64, TEP-66). A wallet mints its membership with an
// authorization that the game server signs once it has checked the liquidity the wallet locked. The
// collection checks the signature and the limits below; a wallet mints once, for ever. The server reads
// the locks off chain: this contract reads none and relies on the signature. Its items are
// membership-nft-item.tolk; what the two share is in membership-messages.tolk.

// After Unauthorized: what a mint is refused for, in the order a mint is checked, then what an owner's
// message is refused for
enum Errors {
    Unauthorized = 801      // not the owner; for AcceptOwner, not the address the collection is offered to
    Paused = 802
    InvalidWorkchain = 803  // a minter, a new owner or a royalty destination that is not on the basechain
    AlreadyMember = 804
    InvalidTier = 805
    TierSoldOut = 806
    InvalidGeneration = 807
    Expired = 808
    ExpiryTooFar = 809
    LockNotBegun = 810
    LockEnded = 811
    LockTooShort = 812
    InsufficientValue = 813 // a mint with less than it must carry, a royalty query that cannot pay its answer
    InvalidSignature = 814
    WeakKey = 815
    NoPendingOwner = 816
    InvalidContent = 817
    RoyaltyDenominatorZero = 818
    RoyaltyTooHigh = 819
    UnknownOp = 0xFFFF
}

const CONTRACT_VERSION: int = 3

// An authorization can be used only in the hour before it expires (the server gives two minutes), so that
// one dated far ahead by mistake is not usable all that time. This is no defence against a signing key in
// the wrong hands, whose holder dates authorizations at will: the pause and a new key are.
const MAX_AUTH_LIFETIME: int = 3600

// An Ed25519 signature
const SIGNATURE_BITS: int = 512
// In a public key, the sign of x: the top bit of the last byte
const PUBLIC_KEY_SIGN_BIT: int = 0x80

// The config parameter that holds the network's global id
const GLOBAL_ID_PARAM: int = 19

// The first byte of TEP-64 content: on-chain or off-chain
const CONTENT_ON_CHAIN: int = 0x00
const CONTENT_OFF_CHAIN: int = 0x01

// The most the royalty can ever be: a tenth of a sale. No message sets more, and the collection never
// reports more, whatever its data hold.
const MAX_ROYALTY_NUMERATOR: int = 1
const MAX_ROYALTY_DENOMINATOR: int = 10

// What WithdrawGrams leaves in the collection, but for that withdrawal's own fees: this, and
// COLLECTION_RESERVE_PER_MEMBERSHIP for every membership that stands minted
const COLLECTION_RESERVE: int = grams("0.05")
// The collection's own rent reserve for each membership (an item's reserve for itself is
// ITEM_STORAGE_RESERVE). The collection's state grows by about 2 cells per member: at the full supply of
// 7 600 that costs about 1 GRAM a year at the storage price of November 2026, so the reserve covers about
// 150 years; at 1 nanoGRAM a bit and 500 a cell for 65 536 seconds, a price validators may set, about
// 5 GRAM a year and 30 years. A collection frozen for unpaid rent cannot be revived once it has about four
// thousand members (its state does not fit one message), so it must never run dry. Every mint leaves this
// amount in the collection and nothing more: of what the minter sent, the item gets what an item's
// transfer sets aside (ITEM_TRANSFER_SETS_ASIDE), the network its fees, and the rest goes back to the
// minter.
const COLLECTION_RESERVE_PER_MEMBERSHIP: int = grams("0.02")

// What a mint costs the collection, at the network's live prices: its gas, the message deploying the item
// with its code (the network counts 17 cells and 4 826 bits of it; ITEM_DEPLOY_CELLS and ITEM_DEPLOY_BITS
// are what is asked for), the event and the minter's change. Each is an upper bound, and what a mint does
// not use goes back to the minter. The gas is that of the deepest dictionary there can be. The
// last item of the full supply takes about 28 300 among wallets met by chance, some 13 of which fork the
// minter's path in the dictionary keyed by wallet. Every member whose address shares a longer prefix with
// the minter's is one more fork on that path and 625 more gas: a cell read (100), read again (25) and
// written (500). That is measured with up to 96 such members, and it is linear. The 256 bits of an address
// allow 256 forks, which by that count take 188 300: MINT_GAS leaves a margin of 31 700 above them.
const MINT_GAS: int = 220000
const ITEM_DEPLOY_BITS: int = 12000
const ITEM_DEPLOY_CELLS: int = 30
const SMALL_MSG_BITS: int = 1000
const SMALL_MSG_CELLS: int = 2

// The bits of the answer to a get_royalty_params, which is one cell: its opcode, the query id, the two
// numbers of the royalty and its destination. The answer's forward fee is charged on them (answerCost).
const ROYALTY_ANSWER_BITS: int = 395

const TIER_BRONZE: int = 0
const TIER_SILVER: int = 1
const TIER_GOLD: int = 2
const TIER_CYBER: int = 3
const MAX_TIER: int = TIER_CYBER

const MAX_SUPPLY_BRONZE: int = 5000
const MAX_SUPPLY_SILVER: int = 2000
const MAX_SUPPLY_GOLD: int = 500
const MAX_SUPPLY_CYBER: int = 100

// The least the locks counted must span, from the earliest start to the latest end the authorization
// states: 364 days, a day under a year, so that a lock made for one year still qualifies when the times
// recorded for it are a little less than a year apart
const MIN_LOCK_DURATION: int = 364 * 24 * 60 * 60

// ============== Storage ==============

// The memberships: how many stand minted in each tier, and the item each wallet minted
struct MembershipData {
    bronzeSupply: uint16
    silverSupply: uint16
    goldSupply: uint16
    cyberSupply: uint16
    minterToNft: map<address, uint64> // a wallet mints once, for ever
}

// The storage cell has no room for the 267 bits of a pending owner: it is kept in a cell of its own, with
// the memberships
struct PendingOwnerAndMembership {
    pendingOwner: address? // the address the collection is offered to, until it accepts
    membership: Cell<MembershipData>
}

// The metadata links
struct CollectionContent {
    collectionMetadata: cell // the collection's metadata (TEP-64)
    itemBaseUri: string      // an item's metadata is at "<base URI><tier>.json"
}

struct Storage {
    ownerAddress: address
    nextItemIndex: uint64
    content: Cell<CollectionContent>
    nftItemCode: cell
    signerPublicKey: uint256 // the Ed25519 key mint authorizations are signed with
    generation: uint32       // raised by VoidAuthorizations: voids every authorization signed before
    royaltyNumerator: uint16
    royaltyDenominator: uint16
    royaltyDestination: address
    paused: bool             // the owner stopped minting (items and their transfers go on)
    pendingOwnerAndMembership: Cell<PendingOwnerAndMembership>
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

// The most a tier can ever have (0 for a tier that does not exist)
fun maxSupplyOf(tier: int): int {
    return match (tier) {
        TIER_BRONZE => MAX_SUPPLY_BRONZE,
        TIER_SILVER => MAX_SUPPLY_SILVER,
        TIER_GOLD => MAX_SUPPLY_GOLD,
        TIER_CYBER => MAX_SUPPLY_CYBER,
        else => 0,
    };
}

// How many memberships of a tier stand minted (0 for a tier that does not exist)
fun MembershipData.supplyOf(self, tier: int): int {
    return match (tier) {
        TIER_BRONZE => self.bronzeSupply,
        TIER_SILVER => self.silverSupply,
        TIER_GOLD => self.goldSupply,
        TIER_CYBER => self.cyberSupply,
        else => 0,
    };
}

// Adds `change` to a tier's supply: 1 at a mint, -1 when a mint is undone (nothing for a tier that does
// not exist)
fun MembershipData.changeSupplyOf(mutate self, tier: int, change: int) {
    match (tier) {
        TIER_BRONZE => {
            self.bronzeSupply += change;
        }
        TIER_SILVER => {
            self.silverSupply += change;
        }
        TIER_GOLD => {
            self.goldSupply += change;
        }
        TIER_CYBER => {
            self.cyberSupply += change;
        }
        else => {}
    }
}

// How many memberships stand minted, all tiers together
fun MembershipData.totalSupply(self): int {
    return self.bronzeSupply + self.silverSupply + self.goldSupply + self.cyberSupply;
}

// The memberships, read from the cell they share with the pending owner
fun Cell<PendingOwnerAndMembership>.loadMembership(self): MembershipData {
    return self.load().membership.load();
}

// ============== Messages ==============

// The locks an authorization counts
struct LocksCounted {
    lockersHash: uint256 // hash of their addresses
    lockedValue: coins   // their value in nano-USD (signed as a record: the tier is what counts)
    lockTime: uint32     // the earliest start among them
    unlockTime: uint32   // the latest end among them
}

// What the server signs: the hash of this cell. It names the network, this collection and the minter, so
// that it mints for that wallet, here, and nowhere else; the locks are in a ref (the hash covers it), so
// that no value can overflow the cell.
struct MintAuthorization {
    globalId: int32 // the network (ConfigParam 19)
    collection: address
    minter: address
    tier: uint8
    generation: uint32
    expiry: uint32
    locks: Cell<LocksCounted>
}

// A mint, sent by the wallet that becomes the member, carrying the server's authorization
struct (0x3c8fa817) MintMembership {
    queryId: uint64    // the minter's own, repeated in the event and in the change
    tier: uint8        // 0 to 3: Bronze, Silver, Gold, Cyber
    locks: LocksCounted
    generation: uint32 // the collection's generation when it was signed
    expiry: uint32     // unix time after which it is void
    signature: cell    // the Ed25519 signature: SIGNATURE_BITS and nothing else
}

// TEP-66 get_royalty_params
struct (0x693d3950) GetRoyaltyParams {
    queryId: uint64
}

// TEP-66 report_royalty_params
struct (0xa8cb00ad) ReportRoyaltyParams {
    queryId: uint64
    numerator: uint16
    denominator: uint16
    destination: address
}

// The owner offers the collection to another address (first step)
struct (0x44693dc5) ProposeOwner {
    queryId: uint64
    newOwner: address
}

// The address it was offered to takes it (second step)
struct (0xe455a1d7) AcceptOwner {
    queryId: uint64
}

// The owner changes the metadata links
struct (0x2240a3d7) SetContent {
    queryId: uint64
    content: Cell<CollectionContent>
}

// The owner replaces the key that signs mint authorizations
struct (0x5d3abdcd) SetSignerPublicKey {
    queryId: uint64
    publicKey: uint256
}

// The owner changes the royalty, within the maximum
struct (0x97a3657b) SetRoyalty {
    queryId: uint64
    numerator: uint16
    denominator: uint16
    destination: address
}

// The owner voids every authorization signed so far (a new generation)
struct (0x1019e4d2) VoidAuthorizations {
    queryId: uint64
}

// The owner takes GRAM held above the rent reserve (amount 0: all of it)
struct (0x8c7d0733) WithdrawGrams {
    queryId: uint64
    amount: coins
}

// The owner stops or resumes minting: the answer to a signing key in the wrong hands, until it is replaced
struct (0x152fffb5) SetPaused {
    queryId: uint64
    paused: bool
}

// Every message the collection accepts
type CollectionMessage =
    | MintMembership
    | GetRoyaltyParams
    | ProposeOwner
    | AcceptOwner
    | SetContent
    | SetSignerPublicKey
    | SetRoyalty
    | VoidAuthorizations
    | WithdrawGrams
    | SetPaused
    | Excesses

// ============== Events ==============

// Emitted at every mint, as an external message ("MbMI"): the public record of a mint, for explorers and
// indexers. The game server confirms a mint from the collection's state (get_minted_nft), not from this.
struct (0x4d624d49) MembershipMintedEvent {
    queryId: uint64
    itemIndex: uint64
    minter: address
    tier: uint8
    lockersHash: uint256
}

// ============== Helpers ==============

fun assertOwner(sender: address, owner: address) {
    assert (sender == owner) throw Errors.Unauthorized;
}

// The network this runs on (ConfigParam 19: -239 on mainnet, -3 on testnet). It is signed into every
// authorization, so that one made for a collection on testnet never mints on mainnet
fun networkGlobalId(): int {
    return blockchain.configParam(GLOBAL_ID_PARAM)!.beginParse().loadInt(32);
}

// Ed25519 public keys of small order (the eight-torsion points, in every encoding). Under one of them a
// constant signature verifies with no secret: for every message under the point of order 1, for one
// message in two, four or eight under the others. Such a key is never set, and never mints.
fun isWeakPublicKey(key: int): bool {
    val y = key & ~PUBLIC_KEY_SIGN_BIT;
    return y == 0 || y == 0x0100000000000000000000000000000000000000000000000000000000000000 ||
        y == 0x26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05 ||
        y == 0xc7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a ||
        y == 0xecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f ||
        y == 0xedffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f ||
        y == 0xeeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f;
}

// The least a mint must carry: what its item is given, the collection's rent reserve for the membership and
// what the mint costs. Anything above comes back to the minter.
fun mintMinValue(): coins {
    return ITEM_TRANSFER_SETS_ASIDE + COLLECTION_RESERVE_PER_MEMBERSHIP +
        calculateGasFee(BASECHAIN, MINT_GAS) +
        calculateForwardFee(BASECHAIN, ITEM_DEPLOY_BITS, ITEM_DEPLOY_CELLS) +
        2 * calculateForwardFee(BASECHAIN, SMALL_MSG_BITS, SMALL_MSG_CELLS);
}

// Whether a royalty is one the collection allows: a share, and no more than the maximum
fun isRoyaltyAllowed(numerator: int, denominator: int): bool {
    return denominator != 0 &&
        numerator * MAX_ROYALTY_DENOMINATOR <= denominator * MAX_ROYALTY_NUMERATOR;
}

// The royalty as the collection reports it: the one SetRoyalty stored, which is an allowed one.
// A guard on what a sale pays: data deployed with a royalty that is not allowed report the maximum.
fun reportedRoyalty(numerator: int, denominator: int): (int, int) {
    if (isRoyaltyAllowed(numerator, denominator)) {
        return (numerator, denominator);
    }
    return (MAX_ROYALTY_NUMERATOR, MAX_ROYALTY_DENOMINATOR);
}

// Where the item of an index is deployed: the item code, and the data that name the index and this
// collection
fun itemDeployment(index: uint64, nftItemCode: cell): AutoDeployAddress {
    return {
        stateInit: {
            code: nftItemCode,
            data: ItemDeploymentData {
                index,
                collectionAddress: contract.getAddress(),
            }.toCell(),
        },
    };
}

// ============== Entry point ==============

contract MembershipNftCollection {
    description: "CyberKonquest membership NFT collection: one mint per wallet, authorized by the game server"
    version: "3"
    storage: Storage
    incomingMessages: CollectionMessage
    thrownErrors: Errors
}

fun onInternalMessage(in: InMessage) {
    // A transfer with an empty body is accepted: it adds to what pays the collection's rent. One that
    // carries a comment is a message as any other
    if (in.body.isEmpty()) {
        return;
    }

    // Every message is read whole: nothing may follow its fields, and an unknown one is refused
    val msg = CollectionMessage.fromSlice(in.body, { throwIfOpcodeDoesNotMatch: Errors.UnknownOp });
    var storage = lazy Storage.load();

    match (msg) {
        MintMembership => {
            val minter = in.senderAddress;
            val now = blockchain.now();

            assert (!storage.paused) throw Errors.Paused;

            // members live on the basechain
            assert (minter.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;

            val side = storage.pendingOwnerAndMembership.load();
            var membership = side.membership.load();

            // A wallet mints once, for ever: not again after its NFT is sold or sent away, and not to move
            // to another tier. The record is of the mint, not of who holds the NFT now (the items say that).
            assert (!membership.minterToNft.exists(minter)) throw Errors.AlreadyMember;

            assert (msg.tier <= MAX_TIER) throw Errors.InvalidTier;
            assert (membership.supplyOf(msg.tier) < maxSupplyOf(msg.tier)) throw Errors.TierSoldOut;

            // signed for this generation (VoidAuthorizations voids what was signed before)
            assert (msg.generation == storage.generation) throw Errors.InvalidGeneration;

            // not expired, and not dated more than MAX_AUTH_LIFETIME ahead
            assert (now <= msg.expiry) throw Errors.Expired;
            assert (msg.expiry <= now + MAX_AUTH_LIFETIME) throw Errors.ExpiryTooFar;

            // the locks have begun, have not ended, and last MIN_LOCK_DURATION at least
            assert (msg.locks.lockTime <= now) throw Errors.LockNotBegun;
            assert (msg.locks.unlockTime > now) throw Errors.LockEnded;
            assert (
                msg.locks.unlockTime >= msg.locks.lockTime + MIN_LOCK_DURATION
            ) throw Errors.LockTooShort;

            // enough for what the item is given, the rent reserve and the mint's costs
            assert (in.valueCoins >= mintMinValue()) throw Errors.InsufficientValue;

            val authorization = MintAuthorization {
                globalId: networkGlobalId(),
                collection: contract.getAddress(),
                minter,
                tier: msg.tier,
                generation: msg.generation,
                expiry: msg.expiry,
                locks: msg.locks.toCell(),
            };

            // The signature: SIGNATURE_BITS and nothing else, of the signing key over the authorization
            val signature = msg.signature.beginParse();
            assert (
                signature.remainingBitsCount() == SIGNATURE_BITS &&
                signature.remainingRefsCount() == 0
            ) throw Errors.InvalidSignature;
            // A guard on the memberships: a weak key the collection was deployed with mints nothing
            assert (!isWeakPublicKey(storage.signerPublicKey)) throw Errors.WeakKey;
            assert (
                isSignatureValid(authorization.toCell().hash(), signature, storage.signerPublicKey)
            ) throw Errors.InvalidSignature;

            // The mint is recorded: the item's index, the wallet's mint, the tier's supply
            val itemIndex = storage.nextItemIndex;
            storage.nextItemIndex += 1;
            membership.minterToNft.set(minter, itemIndex);
            membership.changeSupplyOf(msg.tier, 1);
            storage.pendingOwnerAndMembership = PendingOwnerAndMembership {
                pendingOwner: side.pendingOwner,
                membership: membership.toCell(),
            }.toCell();
            storage.save();

            // The item is deployed and initialized. It gets what an item's transfer sets aside, whole: the
            // message's forward fee is paid on top, out of the mint's value (mintMinValue counts it).
            // Should the item refuse, the message comes back and the mint is undone (onBouncedMessage).
            val deployMessage = createMessage({
                bounce: BounceMode.RichBounceOnlyRootCell,
                dest: itemDeployment(itemIndex, storage.nftItemCode),
                value: ITEM_TRANSFER_SETS_ASIDE,
                body: InitNftItem {
                    index: itemIndex,
                    minter,
                    content: { tier: msg.tier, mintTimestamp: now },
                },
            });
            deployMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);

            // an event carries no value: its fee comes out of the balance before the reserve below is
            // taken, and so out of what the minter sent
            val mintEvent = createExternalLogMessage({
                dest: createAddressNone(),
                body: MembershipMintedEvent {
                    queryId: msg.queryId,
                    itemIndex,
                    minter,
                    tier: msg.tier,
                    lockersHash: msg.locks.lockersHash,
                },
            });
            mintEvent.send(SEND_MODE_REGULAR);

            // The collection keeps its rent reserve for the membership and nothing else: the rest of what the
            // minter sent goes back. The least value asked above covers all of it; were it ever short, the
            // whole mint is undone (and a bounceable mint's GRAM bounces), so that a mint never leaves the
            // collection with less than it had plus the reserve.
            reserveGramsOnBalance(
                COLLECTION_RESERVE_PER_MEMBERSHIP,
                RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
            );
            val excessesMessage = createMessage({
                bounce: BounceMode.NoBounce,
                dest: minter,
                value: 0,
                body: Excesses { queryId: msg.queryId },
            });
            // SAFETY: the reserve above holds back what the collection had before this mint plus the
            // membership's rent reserve, so the balance carried here is only the rest of the minter's own
            // value, back to the minter.
            excessesMessage.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        GetRoyaltyParams => {
            // TEP-66: the royalty, to whoever asks, on the request's own value. The request carries what
            // its answer costs (get_answer_cost), or it is refused, and bounces with its value if it
            // asked to
            assert (
                in.valueCoins >= answerCost(ROYALTY_ANSWER_BITS, in.senderAddress.getWorkchain())
            ) throw Errors.InsufficientValue;

            val (numerator, denominator) = reportedRoyalty(
                storage.royaltyNumerator,
                storage.royaltyDenominator,
            );
            val royaltyMessage = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ReportRoyaltyParams {
                    queryId: msg.queryId,
                    numerator: numerator as uint16,
                    denominator: denominator as uint16,
                    destination: storage.royaltyDestination,
                },
            });
            royaltyMessage.send(ON_REQUEST_VALUE);
        }

        ProposeOwner => {
            // First step: the offer replaces an earlier one, and nothing changes until that address accepts
            assertOwner(in.senderAddress, storage.ownerAddress);
            assert (msg.newOwner.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;

            val side = storage.pendingOwnerAndMembership.load();
            storage.pendingOwnerAndMembership = PendingOwnerAndMembership {
                pendingOwner: msg.newOwner,
                membership: side.membership,
            }.toCell();
            storage.save();
        }

        AcceptOwner => {
            // Second step: the address the collection was offered to becomes its owner
            val side = storage.pendingOwnerAndMembership.load();
            val pendingOwner = side.pendingOwner;
            assert (pendingOwner != null) throw Errors.NoPendingOwner;
            assert (in.senderAddress == pendingOwner) throw Errors.Unauthorized;

            storage.ownerAddress = pendingOwner;
            storage.pendingOwnerAndMembership = PendingOwnerAndMembership {
                pendingOwner: null,
                membership: side.membership,
            }.toCell();
            storage.save();
        }

        SetContent => {
            assertOwner(in.senderAddress, storage.ownerAddress);

            // read whole: its two refs and nothing else
            val content = msg.content.load();

            // the collection's metadata begins with a TEP-64 prefix
            var metadata = content.collectionMetadata.beginParse();
            assert (metadata.remainingBitsCount() >= 8) throw Errors.InvalidContent;
            val prefix = metadata.loadUint(8);
            assert (
                prefix == CONTENT_ON_CHAIN || prefix == CONTENT_OFF_CHAIN
            ) throw Errors.InvalidContent;

            // the base URI is a snake string of whole bytes, as get_nft_content joins it with the file
            // name
            var chunk = content.itemBaseUri.beginParse();
            var hasNext = true;
            while (hasNext) {
                assert (chunk.remainingBitsCount() % 8 == 0) throw Errors.InvalidContent;
                assert (chunk.remainingRefsCount() <= 1) throw Errors.InvalidContent;
                hasNext = chunk.remainingRefsCount() == 1;
                if (hasNext) {
                    chunk = chunk.loadRef().beginParse();
                }
            }

            storage.content = msg.content;
            storage.save();
        }

        SetSignerPublicKey => {
            assertOwner(in.senderAddress, storage.ownerAddress);
            assert (!isWeakPublicKey(msg.publicKey)) throw Errors.WeakKey;
            storage.signerPublicKey = msg.publicKey;
            storage.save();
        }

        SetRoyalty => {
            assertOwner(in.senderAddress, storage.ownerAddress);
            assert (msg.denominator != 0) throw Errors.RoyaltyDenominatorZero;
            assert (isRoyaltyAllowed(msg.numerator, msg.denominator)) throw Errors.RoyaltyTooHigh;
            assert (msg.destination.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;

            storage.royaltyNumerator = msg.numerator;
            storage.royaltyDenominator = msg.denominator;
            storage.royaltyDestination = msg.destination;
            storage.save();
        }

        VoidAuthorizations => {
            assertOwner(in.senderAddress, storage.ownerAddress);
            // an authorization names the generation it was signed for: none signed so far names the new one
            storage.generation += 1;
            storage.save();
        }

        WithdrawGrams => {
            assertOwner(in.senderAddress, storage.ownerAddress);

            // The state grows with every mint (an entry in the dictionary keyed by wallet): the rent
            // reserve of the memberships that stand stays, so that no withdrawal leaves the collection to
            // freeze (frozen, it would answer neither the marketplaces nor the game server). The balance
            // counted includes this message's value; an amount above what is free takes what is free.
            val membership = storage.pendingOwnerAndMembership.loadMembership();
            val reserve: coins = COLLECTION_RESERVE +
                membership.totalSupply() * COLLECTION_RESERVE_PER_MEMBERSHIP;
            val balance = contract.getOriginalBalance();
            val available: coins = balance > reserve ? balance - reserve : 0;
            val withdrawAmount: coins = msg.amount == 0 ? available : min(msg.amount, available);

            if (withdrawAmount > 0) {
                val withdrawalMessage = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: storage.ownerAddress,
                    value: withdrawAmount,
                    body: Excesses { queryId: msg.queryId },
                });
                // the amount leaves whole: its forward fee and this transaction's gas are paid on top, out
                // of what stays, which is then that much under the reserve (the next withdrawal takes its
                // own out of its own message's value: they do not add up)
                withdrawalMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
        }

        SetPaused => {
            assertOwner(in.senderAddress, storage.ownerAddress);
            storage.paused = msg.paused;
            storage.save();
        }

        Excesses => {
            // what is left of a message that named the collection as its response destination: accepted,
            // it adds to what pays the rent
        }
    }
}

// An item refused its deployment: the mint is undone, and the minter gets back what came back with the
// rent reserve. InitNftItem is the one message the collection sends bounceable, and it comes back whole
// (BounceMode.RichBounceOnlyRootCell): it names the minter, the item's index and the tier.
fun onBouncedMessage(in: InMessageBounced) {
    val rich = lazy RichBounceBody.fromSlice(in.bouncedBody);
    val init = InitNftItem.fromCell(rich.originalBody);
    val itemIndex = init.index;

    var storage = lazy Storage.load();
    // A guard on the memberships and the tier's supply: the bounce comes from the item whose index it names
    if (in.senderAddress != itemDeployment(itemIndex, storage.nftItemCode).calculateAddress()) {
        return;
    }

    val side = storage.pendingOwnerAndMembership.load();
    var membership = side.membership.load();

    // A guard on the memberships and the tier's supply: the mint undone is the one recorded for that wallet
    val recorded = membership.minterToNft.get(init.minter);
    if (!recorded.isFound || recorded.loadValue() != itemIndex) {
        return;
    }

    // The mint never happened: the wallet may mint again, and the tier gets its place back
    membership.minterToNft.delete(init.minter);
    membership.changeSupplyOf(init.content.tier, -1);

    // the index is free again only if no item was minted after this one
    if (itemIndex + 1 == storage.nextItemIndex) {
        storage.nextItemIndex = itemIndex;
    }

    storage.pendingOwnerAndMembership = PendingOwnerAndMembership {
        pendingOwner: side.pendingOwner,
        membership: membership.toCell(),
    }.toCell();
    storage.save();

    // What bounced goes back to the minter, with the rent reserve kept for an item that does not exist.
    // The reserve goes only if the collection has it apart from this message: short of it, the bounced
    // value must still go back, and one message asking for more than there is would not be sent at all.
    val own = contract.getOriginalBalance() - in.valueCoins;
    val refundMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: init.minter,
        value: own >= COLLECTION_RESERVE_PER_MEMBERSHIP ? COLLECTION_RESERVE_PER_MEMBERSHIP : 0,
    });
    refundMessage.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

// ============== Get methods (TEP-62) ==============

// (next_item_index, collection_content, owner_address)
get fun get_collection_data(): (int, cell, address) {
    val storage = lazy Storage.load();
    val content = lazy storage.content.load();
    return (storage.nextItemIndex, content.collectionMetadata, storage.ownerAddress);
}

// The address of the item with that index, minted or not
get fun get_nft_address_by_index(index: int): address {
    val storage = lazy Storage.load();
    return itemDeployment(index, storage.nftItemCode).calculateAddress();
}

// An item's metadata link, as TEP-64 off-chain content: the base URI, then "<tier>.json". The metadata is
// one file per tier (as https://cyberkonquest.com/membership/3.json), so it depends on no API and not on
// the index. Content that is not a membership's (MembershipContent, of a tier that exists) is refused.
get fun get_nft_content(
    _index: int,
    individualContent: Cell<MembershipContent>,
): string_prefixed0x {
    val membership = individualContent.load();
    assert (membership.tier <= MAX_TIER) throw Errors.InvalidTier;

    val storage = lazy Storage.load();
    val content = lazy storage.content.load();
    return StringBuilder
        .create()
        .append(content.itemBaseUri)
        .appendInt(membership.tier)
        .append(".json")
        .build()
        .prefixWith01();
}

// ============== Get methods (TEP-66) ==============

// (numerator, denominator, destination)
get fun royalty_params(): (int, int, address) {
    val storage = lazy Storage.load();
    val (numerator, denominator) = reportedRoyalty(
        storage.royaltyNumerator,
        storage.royaltyDenominator,
    );
    return (numerator, denominator, storage.royaltyDestination);
}

// The most the royalty can ever be, as (numerator, denominator)
get fun get_max_royalty(): (int, int) {
    return (MAX_ROYALTY_NUMERATOR, MAX_ROYALTY_DENOMINATOR);
}

// ============== Collection get methods ==============

// The Ed25519 key mint authorizations must be signed with
get fun get_signer_public_key(): int {
    val storage = lazy Storage.load();
    return storage.signerPublicKey;
}

// The generation an authorization must be signed for (VoidAuthorizations raises it)
get fun get_generation(): uint32 {
    val storage = lazy Storage.load();
    return storage.generation;
}

// Whether the owner stopped minting
get fun get_paused(): bool {
    val storage = lazy Storage.load();
    return storage.paused;
}

// The network this collection runs on (ConfigParam 19), which every authorization it accepts must name: the
// server reads it here, so what it signs follows the chain the collection is on, never a setting
get fun get_global_id(): int {
    return networkGlobalId();
}

// The address the collection was offered to and that has not accepted it yet, if any
get fun get_pending_owner(): address? {
    val storage = lazy Storage.load();
    val side = lazy storage.pendingOwnerAndMembership.load();
    return side.pendingOwner;
}

// The version of this contract
get fun get_version(): int {
    return CONTRACT_VERSION;
}

// ============== Membership get methods ==============

// How many memberships of a tier stand minted (0 for a tier that does not exist)
get fun get_tier_supply(tier: int): int {
    val storage = lazy Storage.load();
    return storage.pendingOwnerAndMembership.loadMembership().supplyOf(tier);
}

// The most a tier can ever have (0 for a tier that does not exist)
get fun get_tier_max_supply(tier: int): int {
    return maxSupplyOf(tier);
}

// How many memberships of a tier can still be minted
get fun get_remaining_supply(tier: int): int {
    return get_tier_max_supply(tier) - get_tier_supply(tier);
}

// How many memberships stand minted, all tiers together. An undone mint is not counted, though its index
// is not given again when a later item was minted meanwhile (next_item_index of get_collection_data).
get fun get_total_supply(): int {
    val storage = lazy Storage.load();
    return storage.pendingOwnerAndMembership.loadMembership().totalSupply();
}

// The index of the NFT a wallet minted, or -1 if it never minted. A wallet mints once, for ever: this is
// not who holds a membership now (an NFT may have been sold or sent away: its item names its owner).
get fun get_minted_nft(minter: address): int {
    val storage = lazy Storage.load();
    val recorded = storage.pendingOwnerAndMembership.loadMembership().minterToNft.get(minter);
    return recorded.isFound ? recorded.loadValue() : -1;
}

// The least a mint must carry, at the network's live prices; what is sent above it comes back to the minter
get fun get_mint_min_value(): int {
    return mintMinValue();
}

// What a get_royalty_params must carry, at the network's live prices, when its sender is on `workchain`
// (0 for the basechain, -1 for the masterchain): the gas of answering it and the answer's forward fee to
// that chain. With less it is refused; what is sent above the costs goes back with the answer.
get fun get_answer_cost(workchain: int): int {
    return answerCost(ROYALTY_ANSWER_BITS, workchain);
}
