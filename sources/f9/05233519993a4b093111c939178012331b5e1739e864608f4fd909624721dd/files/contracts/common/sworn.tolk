tolk 1.5

import "@stdlib/exotic-cells"
import "@stdlib/gas-payments"
import "@stdlib/reflection"
import "messages"

// What every Sworn contract shares: the limits and sizes fixed for this version, the schedule's arithmetic,
// the derivation of lock and till addresses, the storage paid in advance and the cost of every operation.
// The root (sworn-root.tolk), the tills (sworn-till.tolk) and the locks (lock-base.tolk, with
// lock-core.tolk for a lock of jettons and gram-lock-core.tolk for a lock of GRAM) all import this file, so
// each number and each formula has one definition. The message layouts are in messages.tolk.
//
// A name that exists once for each kind of lock carries no mark for a lock of jettons and gram (Gram,
// GRAM_) for a lock of GRAM: InitLock and InitGramLock, Claim and ClaimGram, get_create_cost and
// get_gram_create_cost, lockBudget and gramLockBudget, LOCK_STATE_BITS and GRAM_LOCK_STATE_BITS. The
// comment of each says in words which kind it is of. Two things stand apart. SweepGram, a message both
// kinds take, is named for what it sweeps: lockSweepGramCost prices it in a lock of jettons,
// gramLockSweepGramCost in a lock of GRAM. And the errors have three names: both kinds throw LockErrors, a
// lock of jettons alone JettonErrors, a lock of GRAM alone GramErrors.

// ============== Version and limits ==============

// The version of these contracts. The terms of a lock carry it, so terms of one version never create a lock
// of another, and every contract reports it in its get methods.
const SWORN_VERSION = 8

// Number of tills. A lock pays its fees to till (index mod TILL_COUNT). 255 so that one root transaction
// can push a config change to every till (255 outgoing messages is the action limit).
const TILL_COUNT = 255

// Hard caps on the fees, checked three times: by the root (SetFees), by each till (SetTillConfig) and by
// each lock (the attestation), so that none relies on another having checked them. MAX_FLAT_FEE bounds both
// flat fees, a creation's and a top-up's. They cannot change without a new version.
const MAX_FLAT_FEE = grams("100")
const MAX_FEE_BPS = 200 // 2% of what is locked
// The cap on the royalty the root reports for marketplace sales of transferable locks (SetRoyalty)
const MAX_ROYALTY_BPS = 500 // 5%
// What a fee or a share in basis points is a part of
const BPS_DENOMINATOR = 10000

// ============== Times ==============

const SECONDS_PER_DAY = 86400
const SECONDS_PER_YEAR = 365 * SECONDS_PER_DAY

// How far ahead of now the end of a schedule may be, at creation and at an extension. It also refuses an
// end written in milliseconds. A lock meant to last longer is made permanent.
const MAX_LOCK_DURATION = 50 * SECONDS_PER_YEAR

// A creation must complete within this time of its InitLock (InitGramLock for a lock of GRAM); after it,
// the lock cancels instead of funding, and anyone (not only the creator) may cancel it. The budget carries
// the storage for it.
const SETUP_WINDOW = 7 * SECONDS_PER_DAY
// The terms' createBefore may be at most this far ahead of the InitLock or InitGramLock that uses them. The
// creator can come back for that long: tokens sent without the InitLock (a wallet short of GRAM skips it
// and still sends the transfer) are recovered by creating the lock and cancelling it. It is far shorter
// than the decades it takes for a lock's prepaid storage to run out and for its debt to grow until the
// network deletes it, so a deleted lock can never be created again.
const MAX_CREATE_AHEAD = SECONDS_PER_YEAR
// How long a jetton transfer of the lock is given to bounce back: a bounce comes back within a few blocks,
// and a day leaves room for a network under load. A Sweep and a SweepGram wait this long after the lock's
// latest fee-token transfer to its till: until then that transfer may still bounce (restoring feeOwed), a
// Sweep must not take those tokens, and a SweepGram must not take the GRAM that pays for restoring the
// record. In a cancelled lock, only the creator recovers unrecorded tokens through the lock's wallet within
// this time of the latest refund transfer: a refund that bounces after such a recovery is not restored to
// the record.
const TRANSFER_SETTLE = SECONDS_PER_DAY
// From this long after the lock's end, a Sweep neither waits for a fee transfer to settle nor pays owed fee
// tokens first, and a SweepGram does not wait for them: they are given up, so that a fee transfer the
// wallet always refuses cannot keep what is the owner's in the lock for ever. Until then anyone can have
// the lock pay them (RetryFee), as often as it takes.
const FEE_GIVE_UP = 30 * SECONDS_PER_DAY
// A quoted cost that grows with time (the storage due in get_extend_cost and get_top_up_cost) still covers
// a message that lands this long after the quote (a slow wallet, a multisig); the unused part comes back
// with the excesses
const QUOTE_MARGIN = 30 * SECONDS_PER_DAY

// ============== Storage paid in advance ==============

// Storage is paid in advance for what is left of the lock's life plus this grace (time to come and claim),
// and, for a permanent lock, for PERMANENT_STORAGE_HORIZON: the longest life a schedule can give
// (MAX_LOCK_DURATION). Anyone can add to it (a message with no body, or a StorageTopUp).
const STORAGE_GRACE = 3 * SECONDS_PER_YEAR
const PERMANENT_STORAGE_HORIZON = 50 * SECONDS_PER_YEAR
// No storage prepayment (prepayFor) is less than this, however short the time it is for: a month of the
// storage of a lock of jettons at the floor price, 48 days of a lock of GRAM's. A DeployTill also brings a
// till this much at least.
const MIN_STORAGE_PREPAY = grams("0.01")
// The seconds a storage price is for (ConfigParam 18)
const STORAGE_PRICE_PERIOD = 65536
// The storage prices in force until 2026-04-29 (the first entry of ConfigParam 18 on mainnet and on
// testnet), per bit and per cell for STORAGE_PRICE_PERIOD, on the basechain and (MC) on the masterchain.
// That day validators cut the basechain's about 7 times, and what they lowered they can raise again: no
// storage is paid in advance at less than these.
const FLOOR_BIT_PRICE = 1
const FLOOR_CELL_PRICE = 500
const FLOOR_MC_BIT_PRICE = 1000
const FLOOR_MC_CELL_PRICE = 500000
// A cancelled lock keeps the storage of this much life: its creator may still have things to take out of it
// (RecoverUnrecorded from a lock of jettons, ClaimForeign and SweepGram from a lock of GRAM,
// ClaimForeignNft from either). A lock of either kind keeps as much, at most, after a SweepGram.
const CANCELLED_STORAGE_HORIZON = 2 * SECONDS_PER_YEAR

// The account sizes storage is priced at. For a lock and a till: what the network charges them for (their
// storage stat: code, data and the account cell) at its largest, with a margin. They are never below the
// real size, so a storage fee computed from them at the prices in force is an upper bound. Each kind of
// lock is priced at its own size, and a test holds its largest state to 95% of its bounds.

// The largest lock of jettons is a soulbound one that records the largest amounts, with the fees at their
// caps: 105 626 bits and 232 cells (tests/GasStorage.spec.ts; tests/StorageQuotes.spec.ts holds a lock
// through its top-ups, a gift and an extension: 105 594 bits and 232 cells).
const LOCK_STATE_BITS = 115000
const LOCK_STATE_CELLS = 250
// The largest lock of GRAM is a soulbound one that holds the largest amounts, most of them paid out, with
// the fees at their caps: 66 507 bits and 158 cells (tests/GramCustody.spec.ts)
const GRAM_LOCK_STATE_BITS = 72500
const GRAM_LOCK_STATE_CELLS = 170
// For a jetton wallet, whose code varies from jetton to jetton: the largest wallet among the deployed
// jettons sampled has 19 976 bits and 47 cells as the network counts its account (tests/Receipts.spec.ts,
// which holds each of them within these bounds)
const JETTON_WALLET_STATE_BITS = 32000
const JETTON_WALLET_STATE_CELLS = 80
// A till with the fees at their caps has 10 306 bits and 29 cells (tests/StorageQuotes.spec.ts, which holds
// it to nine tenths of these bounds)
const TILL_STATE_BITS = 12000
const TILL_STATE_CELLS = 34
// The gas a jetton wallet is allowed to take in a plain GRAM transfer. An extension pays it with the
// storage it sends the wallet: without it a short extension would buy the wallet nothing, its few nanoGRAM
// going to that gas.
const WALLET_PLAIN_GAS = 1500

// ============== Values of messages to other code ==============

// The value of a jetton transfer, a message handled by code Sworn does not control. TEP-74 caps what a
// transfer may keep: the wallets must send back all of its value but forward_ton_amount, 2 *
// max_tx_gas_price and 2 * fwd_fee. That much, priced live on the wallet's own chain (a master may derive
// its wallets on the masterchain), is what a transfer attaches at least, and unused value comes back as
// excesses. It is the least Sworn attaches, not a promise that it is enough: TEP-74 lets a wallet refuse a
// transfer that does not cover its own storage and operation costs, and some deployed ones have fixed gas
// constants above this value. A refusal loses nothing, and whoever moves tokens can attach more (Claim,
// Sweep, RetryRefund, RetryFee, RecoverUnrecorded, ClaimForeign).
const MAX_TX_GAS = 1000000 // gas_limit of ConfigParams 20 and 21 (immutable code does not parse the config)
// A transfer never attaches less than this, should gas get much cheaper: some wallets have fixed gas
// constants in their code (the reference wallet asks for 0.04 GRAM plus fees)
const JETTON_TRANSFER_VALUE_FLOOR = grams("0.06")
// The least an AttestFees carries, for the till's answer and the lock's handling of it (attestValue). At
// the prices in force those cost 0.0041 GRAM at their bounds, and the floor is more than three times that
// (tests/PricingQuotes.spec.ts); what the request does not use comes back to the lock with the answer.
const ATTEST_VALUE_FLOOR = grams("0.015")
// Some deployed wallets deliver less than forward_ton_amount, by an amount that goes with where the
// transfer's payload is: up to 0.0142 GRAM less of a forward amount of 0.02 GRAM or more where the transfer
// has no payload or an inline one, which is the most over every layout, and 0.0042 GRAM less with the
// payload in a ref, as a lock's fee transfer and the SDK write it (measured: tests/RealJettons.spec.ts).
// What is quoted as a forward amount leaves room for that, and comes back when unused.
const FORWARD_SLACK = grams("0.02")

// ============== Gas and message sizes ==============

// Gas bounds of Sworn's own handlers, priced from the live config wherever a cost is worked out. Each is an
// upper bound for every path of its handler: none depends on anything but the message and the contract's
// fixed-size state. tests/GasStorage.spec.ts runs the paths of a lock of jettons, of the root and of a
// till, tests/GramCustody.spec.ts those of a lock of GRAM, and both fail above a bound. After each bound is
// the most gas its handler used in them: in a lock of jettons, the root or a till, and then, where a lock
// of GRAM has that handler, in a lock of GRAM. Each suite compares those figures with what it measures, and
// every bound is at least 16% above its figures.
// An InitLock whose schedule cannot start creates the lock and cancels it at once: 33 093, counted at
// LOCK_GAS_INIT + LOCK_GAS_CANCEL (unstartableCost; tests/Creation.spec.ts).
const LOCK_GAS_INIT = 33000 // InitLock or InitGramLock: 27 774, 23 204
const LOCK_GAS_SETUP_STEP = 20000 // a setup event that does not complete the funding: 15 302
const LOCK_GAS_COMPLETE = 52000 // the setup event that completes (or cancels) the funding: 39 506, 21 704
// Any other transfer notification (deposits, top-ups sent back)
const LOCK_GAS_NOTIFY = 25000 // 20 597, 9 644
const LOCK_GAS_BOUNCE = 21000 // a bounce restoring a record: 14 641, 6 150
// A claim, and what moves tokens as one does (ClaimForeign, RecoverUnrecorded). The cells of what the owner
// adds to a claim are counted apart (GAS_PER_PAYLOAD_CELL, in lock-base).
const LOCK_GAS_CLAIM = 24000 // 19 047, 17 321
// A Sweep, or the fee transfer a Sweep makes instead while fee tokens are owed
const LOCK_GAS_SWEEP = 35000 // 20 613
// A SweepGram. A lock of GRAM settles its accounting and emits the sweep's event in it.
const LOCK_GAS_SWEEP_GRAM = 20000 // 12 487, 16 313
const LOCK_GAS_NFT_TRANSFER = 17500 // 14 636, 13 417
const LOCK_GAS_TOP_UP = 40000 // 33 760, 17 776
const LOCK_GAS_CANCEL = 39000 // 29 212, 20 334
const LOCK_GAS_EXTEND = 26000 // 21 606, 17 920
const LOCK_GAS_RETRY = 22000 // RetryFunding, RetryRefund, RetryFee: 18 088, 11 125
// A request answered on its own value, without the lock's content: GetStaticData, RequestLockState,
// ClaimForeignNft, and a ProveOwnership or a RequestOwner that does not ask for the content
const LOCK_GAS_ANSWER = 15000 // 11 858, 11 928
// A ProveOwnership or a RequestOwner answered with the lock's content, which is the index written in
// decimal digits: writing it takes most of this
const LOCK_GAS_ANSWER_CONTENT = 62000 // 51 379, 51 124
const TILL_GAS_ATTEST = 4000 // 3 125
// A fee receipt. It takes the most where the notification names who paid the fee as an addr_var with an
// anycast prefix; as wallets write an address, 7 101; for a FeeNotice, 5 117.
const TILL_GAS_RECEIPT = 11000 // 8 857
const TILL_GAS_CONFIG = 6500 // 5 272
// A withdrawal from a till, at the till and at the root: of a jetton, of GRAM or of an NFT. The root takes
// the most for an NFT, whose StateInit it reads to tell it from a lock. The root's handling of a
// WithdrawRootJetton and of a WithdrawRootNft, which no till handles, is within ROOT_GAS_WITHDRAW_TILL too.
const TILL_GAS_WITHDRAW = 6000 // 4 977
const ROOT_GAS_WITHDRAW_TILL = 12000 // 9 578
// WithdrawRootGrams, which counts the root's data to price what the root keeps: the most with a content of
// MAX_CONTENT_CELLS cells in force and another waiting. It is counted for every withdrawal of GRAM
// (withdrawGramsCost): the way through a till, the root's handler and the till's, takes less than the
// root's own.
const ROOT_GAS_WITHDRAW_GRAMS = 75000 // 61 868
const ROOT_GAS_DEPLOY_TILL = 7500 // 5 881
// SetFees or SetCreationEnabled: TILL_COUNT messages, each with an address derivation
const ROOT_GAS_BROADCAST = 710000 // 565 706
// GetRoyaltyParams, the one request the root answers on the request's own value
const ROOT_GAS_ANSWER = 4500 // 3 456
// SetRoyalty, SetContent or AcceptAdmin, each recorded by an event of the root. A SetContent takes the
// most: it measures the content it is given, of MAX_CONTENT_CELLS cells at most.
const ROOT_GAS_SETTING = 18000 // 15 297

// The size one of Sworn's own messages is counted at for its forward fee (smallMessageFee, messageFeeOn):
// the bits and the cells below its root cell, which is what the network charges for. It is an upper bound
// for every internal message and every event whose fee a cost counts, but for the creation's event and the
// events of the root's settings, which are counted at sizes of their own (createdEventFee,
// rootSettingCost). The largest of the messages, a fee-token transfer with its tag and an amount of 15
// bytes through a jetton wallet on the masterchain, has 1 355 bits in 2 cells (tests/GasStorage.spec.ts,
// which reads every message of a funding with the largest amounts as the chain lays it out, through a
// wallet on each chain: 1 347 through one on the basechain); the largest of the other events, a till's
// receipt of fee tokens, has 1 257 bits in 2 cells with what a wallet on the masterchain forwards and 1 249
// with a basechain wallet's (the same suite).
const SMALL_MSG_BITS = 1400
const SMALL_MSG_CELLS = 3
// The creation's event (LockCreatedEvent) carries the terms, and has a size of its own (createdEventFee).
// Its layout is fixed: the event, the terms and their parties, a cell each. With the widest terms, a jetton
// and every amount of 15 bytes, it has 2 010 bits in those 3 cells (tests/Creation.spec.ts).
const CREATED_EVENT_BITS = 2100
const CREATED_EVENT_CELLS = 3
// The size the answer to a request that a lock answers on the request's own value is counted at for its
// forward fee (answerCost, in lock-base). It is an upper bound for the five answers, without the payload a
// TEP-85 answer passes on, which is counted apart: the largest, the LockState of a lock of jettons with
// three amounts of 15 bytes, has 1 678 bits in 2 cells (the same test).
const ANSWER_MSG_BITS = 1700
const ANSWER_MSG_CELLS = 2
// The most cells a collection content may have (SetContent): a content in force and another waiting keep
// the root's data well within what a withdrawal counts
const MAX_CONTENT_CELLS = 64
// The size the event of a SetContent is counted at for its forward fee (rootSettingCost), the largest event
// of the root: the content it carries with every cell full, of 1 023 bits, the item base URI in a cell of
// its own, the cell that pairs them and the event's own, with a full cell of bits to spare. With a content
// of MAX_CONTENT_CELLS full cells and the longest URI it has 66 480 bits in 66 cells (tests/Root.spec.ts).
const CONTENT_EVENT_BITS = (MAX_CONTENT_CELLS + 2) * 1023
const CONTENT_EVENT_CELLS = MAX_CONTENT_CELLS + 3

// ============== The GRAM a message brings ==============
// One rule in all six contracts for how the GRAM a message brings is checked and spent. The comment of each
// handler refers to it.
// 1. The root and a till spend no GRAM of their own for a message: a transaction of the root or of a till
// ends with at least the balance it started with, the storage fee apart, whoever sent the message and
// whatever it carried. The root checks, before it pays for anything out of its balance (an event, a message
// with its fee on top), that the message brought what that costs at its bounds. A till pays for an event
// out of the message that caused it and out of nothing else: it keeps the balance it had, and the event
// leaves if what is left pays for it (emitPaidEvent, in sworn-till), so a receipt, which cannot be refused
// (tokens do not bounce, and a fee never goes back), is kept whatever it brought, with its event when what
// it brought pays for it; a config is recorded when its message pays for the handler's gas, with its event
// when it pays for that too. One handler of a till rests on the root's check: TillWithdrawGrams pays the
// withdrawal's forward fee on top of `amount` out of what the root passed on, which the root checked at the
// prices of its own transaction (withdrawGramsCost). The only exception is the admin's withdrawals of GRAM
// (WithdrawRootGrams, TillWithdrawGrams), which take out `amount` exactly. A lock holds its own budgets
// (lock-base).
// 2. A handler whose message travels on the request's own value first checks that the request carries what
// that costs: the gas of every handler on the way at its bound, the forward fee of every message on the
// way, and what the last receiver needs. It refuses with InsufficientValue otherwise, and sends with
// ON_REQUEST_VALUE. Each such cost has a get method.
// 3. A send that is made only if it can be, and dropped otherwise (SEND_MODE_IGNORE_ERRORS), says why where
// it is made. They are: an excess, or stray tokens sent back when the GRAM allows (refusing there would
// give nothing back); a fee notice, a wallet's storage or a helper's change, skipped so that the funding,
// the top-up, the extension or the cancel it belongs to stands; an event of a till, skipped when its
// message does not pay for it; a lock's event of a record a bounce restored, skipped when it cannot be paid
// for, the record standing; the notice of a bounced ownership proof, dropped because a bounce has no sender
// to refuse.
// ON_REQUEST_VALUE is the mode of rule 2: the message leaves with all that is left of the request's value
// (SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE), which pays its forward fee. With the check before it, the
// send does not fail. Should a rule of the network ever make it fail all the same, the request bounces with
// its value if it asked to, instead of leaving it on the contract (SEND_MODE_BOUNCE_ON_ACTION_FAIL). A lock
// also checks that an account the request names for the message is on a chain a message can be sent to
// (reachableWorkchain, in lock-base).
const ON_REQUEST_VALUE = SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE |
    SEND_MODE_BOUNCE_ON_ACTION_FAIL

// ============== Lock and till addresses ==============

// The two low bits of a lock's index are its kind, the rest is the hash of its terms. Bit 0: soulbound
// (TEP-85) when set, a transferable NFT otherwise. Bit 1: a lock of GRAM when set, of a jetton otherwise.
const INDEX_SOULBOUND_BIT = 1 << 0
const INDEX_GRAM_BIT = 1 << 1
const INDEX_KIND_MASK = INDEX_SOULBOUND_BIT | INDEX_GRAM_BIT

@inline
fun isSoulboundIndex(index: int): bool {
    return (index & INDEX_SOULBOUND_BIT) != 0;
}

@inline
fun isGramIndex(index: int): bool {
    return (index & INDEX_GRAM_BIT) != 0;
}

// Initial data of a lock (TEP-62 style: collection + index). The index is the hash of the lock's terms with
// its two low bits set to the kind, so the address commits to the terms.
struct LockInitData {
    collection: address
    index: uint256
}

// The size of that data: an internal address, of 267 bits, and the index. A lock that was created holds
// more (isInitialized, in lock-base), and the root takes an NFT deployed with data of that size for a lock
// (isSwornLock, in sworn-root).
const LOCK_INIT_DATA_BITS = 267 + 256

// The code and initial data of the lock with that index under `collection` (the root), hence its address
fun lockDeployAddress(lockCode: cell, collection: address, index: int): AutoDeployAddress {
    return { stateInit: { code: lockCode, data: LockInitData { collection, index }.toCell() } };
}

// Till storage. Its initial form (unconfigured, all zeros) is the same for every till of a root except n,
// so till n's address is a function of (till code, root, n) alone.
struct TillStorage {
    root: address
    n: uint8
    configured: bool // false until the root pushed a config: attestations refused meanwhile
    enabled: bool    // the root's creationEnabled: a lock whose attestation says false cancels
    flatFee: coins
    topUpFlatFee: coins
    feeBps: uint16
}

// The code and initial data of till n of that root, hence its address
fun tillDeployAddress(tillCode: cell, root: address, n: int): AutoDeployAddress {
    return {
        stateInit: {
            code: tillCode,
            data: TillStorage {
                root,
                n,
                configured: false,
                enabled: false,
                flatFee: 0,
                topUpFlatFee: 0,
                feeBps: 0,
            }.toCell(),
        },
    };
}

// ============== Schedule ==============

// Whether a lock can be created with this schedule at `now`: the cliff is not after the end, the end is
// ahead of now by MAX_LOCK_DURATION at most, the initial share is no more than the whole, and a stepped
// schedule divides the time from the cliff to the end into whole steps
fun Schedule.isValidForCreation(self, now: int): bool {
    if (self.cliff > self.end) {
        return false;
    }
    if (self.end <= now || self.end > now + MAX_LOCK_DURATION) {
        return false;
    }
    if (self.initialBps > BPS_DENOMINATOR) {
        return false;
    }
    if (self.step > 0 && ((self.end - self.cliff) % self.step) != 0) {
        return false;
    }
    return true;
}

// Whether the schedule is all zeros, as a permanent lock's must be
fun Schedule.isZero(self): bool {
    return self.cliff == 0 && self.end == 0 && self.step == 0 && self.initialBps == 0;
}

// The part of `total` this schedule has unlocked at time t, rounded down (the rule is written out at
// Schedule, in messages.tolk)
@noinline
fun Schedule.unlockedAt(self, total: int, t: int): int {
    if (t < self.cliff) {
        return 0;
    }
    if (t >= self.end) {
        return total;
    }
    val initial = mulDivFloor(total, self.initialBps, BPS_DENOMINATOR);
    var elapsed = t - self.cliff;
    if (self.step > 0) {
        elapsed -= elapsed % self.step;
    }
    return initial + mulDivFloor(total - initial, elapsed, self.end - self.cliff);
}

// An extension is allowed only if the new schedule never unlocks more than the old one at any time: the
// step stays, the cliff and the end can only move later, the initial share can only shrink, and with steps
// both moves must be whole steps (otherwise the step boundaries shift and can unlock earlier). An end that
// moves stays within MAX_LOCK_DURATION of now.
fun Schedule.isValidExtension(self, next: Schedule, now: int): bool {
    if (next.step != self.step) {
        return false;
    }
    if (next.cliff < self.cliff || next.end < self.end || next.cliff > next.end) {
        return false;
    }
    if (next.initialBps > self.initialBps) {
        return false;
    }
    if (next.end > now + MAX_LOCK_DURATION) {
        return false;
    }
    if (self.step > 0) {
        if ((next.cliff - self.cliff) % self.step != 0 || (next.end - self.end) % self.step != 0) {
            return false;
        }
    }
    return true;
}

// ============== Storage prepayment ==============

// How far ahead of `now` a lock's storage is paid: what is left of its life plus STORAGE_GRACE, or
// PERMANENT_STORAGE_HORIZON for a permanent lock
@noinline
fun storageHorizon(permanent: bool, end: int, now: int): int {
    if (permanent) {
        return PERMANENT_STORAGE_HORIZON;
    }
    return max(end - now, 0) + STORAGE_GRACE;
}

// Storage of `seconds` for an account of that size on that chain, paid in advance: at 1.5 times the live
// price or at the floor price, whichever is more. An account so paid stays paid for all that time with
// nobody doing anything, even if the price in force until 2026-04-29 returns; only a price above both
// leaves it short, and it then needs more GRAM before that time is out.
@noinline
fun storageAdvance(workchain: int, seconds: int, bits: int, cells: int): coins {
    return max(
        calculateStorageFee(workchain, seconds, bits, cells) * 3 / 2,
        floorStorageFee(workchain, seconds, bits, cells),
    );
}

// What `seconds` of storage cost at the floor prices of that chain, rounded up as the chain rounds its own
// storage fee. As the chain's own fee does, any chain but the basechain is priced as the masterchain.
@noinline
fun floorStorageFee(workchain: int, seconds: int, bits: int, cells: int): coins {
    val perPeriod = workchain == BASECHAIN
        ? bits * FLOOR_BIT_PRICE + cells * FLOOR_CELL_PRICE
        : bits * FLOOR_MC_BIT_PRICE + cells * FLOOR_MC_CELL_PRICE;
    return mulDivCeil(perPeriod, seconds, STORAGE_PRICE_PERIOD);
}

// A storage prepayment: that advance, and never less than MIN_STORAGE_PREPAY
fun prepayFor(workchain: int, seconds: int, bits: int, cells: int): coins {
    return max(storageAdvance(workchain, seconds, bits, cells), MIN_STORAGE_PREPAY);
}

// The storage prepayment of a lock of jettons for that horizon (storageHorizon), at the size a lock of
// jettons is priced at
fun lockStoragePrepay(horizon: int): coins {
    return prepayFor(BASECHAIN, horizon, LOCK_STATE_BITS, LOCK_STATE_CELLS);
}

// The storage prepayment of a lock of GRAM for that horizon, at its own size
fun gramLockStoragePrepay(horizon: int): coins {
    return prepayFor(BASECHAIN, horizon, GRAM_LOCK_STATE_BITS, GRAM_LOCK_STATE_CELLS);
}

// The jetton wallet's storage for `seconds`, on the chain the wallet lives on: masterchain storage costs
// thousands of times more, and a wallet whose storage runs out is deleted with the tokens in it
fun walletStoragePrepay(workchain: int, seconds: int): coins {
    return prepayFor(workchain, seconds, JETTON_WALLET_STATE_BITS, JETTON_WALLET_STATE_CELLS);
}

// The same for a longer life (no minimum: what an extension adds)
fun walletStorageExtra(workchain: int, seconds: int): coins {
    return storageAdvance(workchain, seconds, JETTON_WALLET_STATE_BITS, JETTON_WALLET_STATE_CELLS);
}

// The storage a cancelled lock of jettons keeps (CANCELLED_STORAGE_HORIZON)
fun lockCancelledReserve(): coins {
    return prepayFor(
        BASECHAIN,
        CANCELLED_STORAGE_HORIZON,
        LOCK_STATE_BITS,
        LOCK_STATE_CELLS,
    );
}

// The storage a cancelled lock of GRAM keeps, at its own size
fun gramLockCancelledReserve(): coins {
    return prepayFor(
        BASECHAIN,
        CANCELLED_STORAGE_HORIZON,
        GRAM_LOCK_STATE_BITS,
        GRAM_LOCK_STATE_CELLS,
    );
}

// ============== Metadata ==============

// The character "0": a decimal digit d is written as the character ASCII_ZERO + d
const ASCII_ZERO = 48
// The digits of an integer are written in limbs of this many digits, each below LIMB: three of them hold
// any index, and keep the reversal in storeDigits within an int
const LIMB_DIGITS = 26
const LIMB = 100000000000000000000000000 // 10^LIMB_DIGITS

// Appends `v` (< LIMB) in ASCII decimal digits: padded with leading zeros to `width` digits when `width` >
// 0, as short as it can be otherwise (a single 0 for zero)
fun builder.storeDigits(mutate self, v: int, width: int) {
    var digits = 0;
    var reversed = 0;
    var rest = v;
    while (rest > 0) {
        reversed = reversed * 10 + (rest % 10);
        rest /= 10;
        digits += 1;
    }
    if (width > 0) {
        repeat (width - digits) {
            self.storeUint(ASCII_ZERO, 8);
        }
    } else if (digits == 0) {
        self.storeUint(ASCII_ZERO, 8);
    }
    repeat (digits) {
        self.storeUint(ASCII_ZERO + reversed % 10, 8);
        reversed /= 10;
    }
}

// The decimal digits of a non-negative integer below 2^256, in one cell (78 digits at most: 624 bits). A
// lock's individual content (TEP-62) is its index written so, in three limbs.
fun decimalStringCell(value: int): cell {
    val hi = value / (LIMB * LIMB);
    val mid = (value / LIMB) % LIMB;
    val lo = value % LIMB;
    var b = beginCell();
    if (hi > 0) {
        b.storeDigits(hi, 0);
        b.storeDigits(mid, LIMB_DIGITS);
        b.storeDigits(lo, LIMB_DIGITS);
    } else if (mid > 0) {
        b.storeDigits(mid, 0);
        b.storeDigits(lo, LIMB_DIGITS);
    } else {
        b.storeDigits(lo, 0);
    }
    return b.endCell();
}

// ============== Payloads ==============

// Forward payload in a ref (Either bit 1). Every payload Sworn sends travels this way: TEP-74 allows inline
// or ref, but some deployed jetton wallets read Maybe ^Cell and drop inline payloads.
fun refPayload(c: cell?): RemainingBitsAndRefs {
    if (c == null) {
        return emptyForwardPayload();
    }
    return beginCell().storeBool(true).storeRef(c).endCell().beginParse();
}

fun emptyForwardPayload(): RemainingBitsAndRefs {
    return beginCell().storeBool(false).endCell().beginParse();
}

// The payload itself of an Either-encoded forward payload, inline or in a ref. Null when the Either bit is
// missing, when it announces a ref that is not there, and when that ref is an exotic cell: a library
// reference, say, is not the payload it stands for. Never throws.
fun readForwardPayload(fp: slice): slice? {
    var s = fp;
    if (s.remainingBitsCount() < 1) {
        return null;
    }
    if (s.loadBool()) {
        if (s.remainingRefsCount() < 1) {
            return null;
        }
        val (payload, exotic) = s.loadRef().beginParseSpecial();
        return exotic ? null : payload;
    }
    return s;
}

// The width of an opcode
const OPCODE_BITS = 32

// The opcode a message or payload type is declared with
fun opcodeOf<T>(): int {
    return reflect.serializationPrefixOf<T>().0;
}

// Whether a message body starts with the opcode of T. Never throws.
fun isBodyOf<T>(body: slice): bool {
    return body.remainingBitsCount() >= OPCODE_BITS &&
        body.preloadUint(OPCODE_BITS) == opcodeOf<T>();
}

// The opcode a forward payload starts with (0 when it has none) and the payload itself. Never throws.
fun payloadOp(fp: slice): (int, slice?) {
    val payload = readForwardPayload(fp);
    if (payload == null || payload.remainingBitsCount() < OPCODE_BITS) {
        return (0, payload);
    }
    return (payload.preloadUint(OPCODE_BITS), payload);
}

// ============== Costs ==============
// The GRAM each message must carry, worked out from the live prices and the bounds above: first what every
// cost is made of, then the costs of a lock of jettons.

// The forward fee of one of Sworn's own messages or events, on the basechain
@noinline
fun smallMessageFee(): coins {
    return calculateForwardFee(BASECHAIN, SMALL_MSG_BITS, SMALL_MSG_CELLS);
}

// The same for a message to an account of that workchain, at that chain's prices (a jetton wallet may live
// on its jetton's habitat workchain). It is counted for a message whose forward fee is paid on top of its
// value, which would fail its whole transaction if the fee could not be paid, and for one that pays its fee
// out of the value it carries: an answer, or a transfer sent on the request's own value.
fun messageFeeOn(workchain: int): coins {
    return calculateForwardFee(workchain, SMALL_MSG_BITS, SMALL_MSG_CELLS);
}

// The forward fee of a message of the size an answer is counted at (ANSWER_MSG_BITS, ANSWER_MSG_CELLS), to
// an account of that workchain. A lock counts it for each of its answers, the transfer of an NFT that
// reached it by mistake among them (answerCost, in lock-base); the root counts it for the same transfer out
// of a till or out of itself (withdrawNftCost).
@inline
fun answerMessageFeeOn(workchain: int): coins {
    return calculateForwardFee(workchain, ANSWER_MSG_BITS, ANSWER_MSG_CELLS);
}

// The forward fee of the creation's event (LockCreatedEvent), at its own size
fun createdEventFee(): coins {
    return calculateForwardFee(BASECHAIN, CREATED_EVENT_BITS, CREATED_EVENT_CELLS);
}

// What a wallet off the basechain may take out of a forward amount for its own message (TEP-74 lets a
// wallet deliver less than forward_ton_amount, and some do): a message fee on its chain. On the basechain
// it adds nothing, because each forward amount it is part of leaves room for such a wallet there by a term
// of its own: FORWARD_SLACK in the funding's and in a top-up's (fundForward, and the top-up's quote in
// lock-core), the small message's fee in a send-back's notice (sendBackForward). A receipt's forward amount
// does not use it: it counts a message fee on every chain (tillReceiptForward).
fun forwardShave(walletWorkchain: int): coins {
    if (walletWorkchain == BASECHAIN) {
        return 0;
    }
    return messageFeeOn(walletWorkchain);
}

// The value of an AttestFees: the till's handler and its answer, and the lock's handling of that answer,
// which may complete the funding; never less than ATTEST_VALUE_FLOOR. It is above what a till asks of an
// AttestFees by construction (tillAnswerCost: the till's handler and its answer are two of the parts
// counted here), so a till does not refuse a lock's request for its value at the prices it was sent at;
// should they rise beyond that while it travels, it bounces like any other, and the lock waits
// (RetryFunding).
fun attestValue(): coins {
    return max(
        ATTEST_VALUE_FLOOR,
        calculateGasFee(BASECHAIN, TILL_GAS_ATTEST + LOCK_GAS_COMPLETE) + 2 * smallMessageFee(),
    );
}

// TEP-74's bound on what a transfer by a jetton wallet of that workchain may keep beyond its forward amount
// (see MAX_TX_GAS), and never less than JETTON_TRANSFER_VALUE_FLOOR
@noinline
fun jettonTransferValueOn(workchain: int): coins {
    return max(
        JETTON_TRANSFER_VALUE_FLOOR,
        2 * calculateGasFee(workchain, MAX_TX_GAS) + 2 * messageFeeOn(workchain),
    );
}

// GRAM a lock sends with a fee receipt (a FeeNotice, or fee tokens' notification) for the till's handler at
// its bound and the receipt's event
fun tillReceiptValue(): coins {
    return calculateGasFee(BASECHAIN, TILL_GAS_RECEIPT) + smallMessageFee();
}

// forward_ton_amount of fee tokens sent to the till through a wallet of that workchain: the receipt's value
// and a message fee of that chain, the basechain included, for a wallet that pays its notification's
// forward fee out of the forward amount, as TEP-74 lets it (the notification is within the size that fee is
// counted at: tests/Receipts.spec.ts). Through a wallet that pays that fee itself the whole reaches the
// till. The till's event leaves when what reached it pays for it (emitPaidEvent, in sworn-till). A wallet
// that keeps more of a forward amount than its notification's fee can still leave a receipt without its
// event. Two deployed wallets do, where the receipt's forward crosses the size from which they keep a part
// of it: one between 3.7 and 4.3 times the gas and message prices in force, the other between 7.8 and 9
// times (tests/TillEvents.spec.ts). The fee tokens are in the till's wallet all the same, and no more GRAM
// is added to the forward for it.
fun tillReceiptForward(walletWorkchain: int): coins {
    return tillReceiptValue() + messageFeeOn(walletWorkchain);
}

// forward_ton_amount of the funding transfer to a lock whose jetton wallet lives on `walletWorkchain`: the
// lock's handler (which may complete the funding) and, should the slot be taken already, sending the tokens
// back through that wallet, with room for a wallet that delivers a little less
fun fundForward(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_COMPLETE) + jettonTransferValueOn(walletWorkchain) +
        smallMessageFee() +
        messageFeeOn(walletWorkchain) +
        FORWARD_SLACK +
        forwardShave(walletWorkchain);
}

// Storage of a lock of jettons while its setup runs (SETUP_WINDOW at most)
fun lockSetupStorage(): coins {
    return storageAdvance(BASECHAIN, SETUP_WINDOW, LOCK_STATE_BITS, LOCK_STATE_CELLS);
}

// What the funding pays from the budget on top of the lock's own storage prepayment: the jetton wallet's
// storage, the flat fee with its notice, the fee tokens' transfer when there are fee tokens, the event and
// the excess back to the creator
fun fundingNeeds(
    walletPrepay: coins,
    flatFee: coins,
    withFeeTokens: bool,
    walletWorkchain: int,
): coins {
    var need = walletPrepay + messageFeeOn(walletWorkchain) + flatFee + tillReceiptValue() +
        3 * smallMessageFee();
    if (withFeeTokens) {
        need += jettonTransferValueOn(walletWorkchain) + tillReceiptForward(walletWorkchain) +
            messageFeeOn(walletWorkchain);
    }
    return need;
}

// Everything an InitLock must bring besides the flat fee, whatever the till gives back and however late in
// SETUP_WINDOW the funding completes: its handler, the lock's storage prepayment and the window's storage,
// the setup request and the creation's event, the gas of the two setup events and what the funding pays,
// the jetton wallet's part priced on the chain it lives on
fun lockBudget(permanent: bool, end: int, now: int, walletWorkchain: int): coins {
    val horizon = storageHorizon(permanent, end, now);
    return lockStoragePrepay(horizon) + lockSetupStorage() +
        calculateGasFee(BASECHAIN, LOCK_GAS_INIT) +
        attestValue() +
        smallMessageFee() +
        createdEventFee() +
        calculateGasFee(BASECHAIN, LOCK_GAS_COMPLETE) +
        calculateGasFee(BASECHAIN, LOCK_GAS_SETUP_STEP) +
        fundingNeeds(walletStoragePrepay(walletWorkchain, horizon), 0, true, walletWorkchain);
}

// Value of InitLock: the flat fee the creator accepts (what the till attests is charged, the rest comes
// back) plus the lock's budget
fun createCost(
    maxFlatFee: coins,
    permanent: bool,
    end: int,
    now: int,
    walletWorkchain: int,
): coins {
    return maxFlatFee + lockBudget(permanent, end, now, walletWorkchain);
}

// Value of an InitLock whose schedule cannot start: the handler and the cancel, what a cancelled lock
// keeps, and the three messages that leave: the creation's event, the cancel's, the excess to the creator
fun unstartableCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_INIT + LOCK_GAS_CANCEL) + lockCancelledReserve() +
        createdEventFee() +
        2 * smallMessageFee();
}

// GRAM to attach (forward_ton_amount) to a top-up sent straight to a lock: the lock's work, the flat fee
// with its notice, the fee tokens' transfer through its wallet, the event and the excess back to the sender
fun topUpCost(topUpFlatFee: coins, walletWorkchain: int): coins {
    return topUpFlatFee + tillReceiptValue() + calculateGasFee(BASECHAIN, LOCK_GAS_TOP_UP) +
        jettonTransferValueOn(walletWorkchain) +
        tillReceiptForward(walletWorkchain) +
        3 * smallMessageFee() +
        messageFeeOn(walletWorkchain);
}

// GRAM a Claim must carry: the handler, the event, the transfer through the lock's wallet (of that
// workchain) with its forward amount, and the message that takes it to the wallet
fun claimCost(walletWorkchain: int, forwardTonAmount: coins): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_CLAIM) + jettonTransferValueOn(walletWorkchain) +
        forwardTonAmount +
        smallMessageFee() +
        messageFeeOn(walletWorkchain);
}

// GRAM a Sweep must carry: as a Claim with no forward amount, at the sweep's gas. While fee tokens are owed
// to the till it must carry their receipt's GRAM too: such a Sweep pays that transfer first, on its own,
// and the sweep itself follows once it has settled. That is asked for as long as feeOwed is not 0, also
// once the fee is given up; what a transfer does not use comes back.
@noinline
fun sweepCost(walletWorkchain: int, feeOwed: coins): coins {
    val base = calculateGasFee(BASECHAIN, LOCK_GAS_SWEEP) + jettonTransferValueOn(walletWorkchain) +
        smallMessageFee() +
        messageFeeOn(walletWorkchain);
    if (feeOwed > 0) {
        return base + tillReceiptForward(walletWorkchain);
    }
    return base;
}

// GRAM a SweepGram of a lock of jettons must carry: the handler and the payout, which takes the rest with
// it. There is no event.
fun lockSweepGramCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_SWEEP_GRAM) + smallMessageFee();
}

// GRAM a CancelCreation must carry: the handler, the event, the refund transfer through the lock's wallet,
// the excess to the creator and a helper's surplus back to it
fun cancelCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_CANCEL) + jettonTransferValueOn(walletWorkchain) +
        messageFeeOn(walletWorkchain) +
        3 * smallMessageFee();
}

// GRAM a RetryRefund or a RetryFee must carry: the handler, one jetton transfer, and the gas of handling
// its bounce, which the lock keeps: anyone may send these, and a transfer its wallet refuses must not make
// the lock pay for restoring the record. A RetryFee (`ofFee`) carries the GRAM of the till's receipt on
// top, which its transfer forwards; a refund has no receipt.
fun retryCost(walletWorkchain: int, ofFee: bool): coins {
    val transfer = calculateGasFee(BASECHAIN, LOCK_GAS_RETRY) +
        jettonTransferValueOn(walletWorkchain) +
        messageFeeOn(walletWorkchain) +
        bouncePrepay();
    return ofFee ? transfer + tillReceiptForward(walletWorkchain) : transfer;
}

// Gas of a bounce that restores a record, kept by the lock from the value of a transfer anyone may trigger
// (RetryRefund, RetryFee, RecoverUnrecorded of a pending refund)
fun bouncePrepay(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_BOUNCE);
}

// GRAM a RetryFunding must carry: the handler, the request to the till and the excess back to the caller
fun retryFundingCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_RETRY) + attestValue() + 2 * smallMessageFee();
}

// ============== Costs of a lock of GRAM ==============
// A lock of GRAM has no jetton wallet to pay for: its messages carry the GRAM themselves. Its storage is
// priced at its own size (GRAM_LOCK_STATE_BITS, GRAM_LOCK_STATE_CELLS).

// Storage of a lock of GRAM while its setup runs (SETUP_WINDOW at most)
fun gramLockSetupStorage(): coins {
    return storageAdvance(BASECHAIN, SETUP_WINDOW, GRAM_LOCK_STATE_BITS, GRAM_LOCK_STATE_CELLS);
}

// What the funding of a lock of GRAM pays from the budget on top of what the lock keeps (the GRAM it locks
// and its storage prepayment): the flat fee with its notice (the fee on the amount comes out of the
// amount), the event and the excess back to the creator
fun gramFundingNeeds(flatFee: coins): coins {
    return flatFee + tillReceiptValue() + 3 * smallMessageFee();
}

// Everything an InitGramLock must bring besides the GRAM it locks and the flat fee, however late in
// SETUP_WINDOW the till answers: the lock's storage prepayment and the window's storage, the setup request
// and the creation's event, the gas of the two handlers (the creation's, the answer's) and what the funding
// pays
fun gramLockBudget(permanent: bool, end: int, now: int): coins {
    return gramLockStoragePrepay(storageHorizon(permanent, end, now)) + gramLockSetupStorage() +
        calculateGasFee(BASECHAIN, LOCK_GAS_INIT) +
        attestValue() +
        smallMessageFee() +
        createdEventFee() +
        calculateGasFee(BASECHAIN, LOCK_GAS_COMPLETE) +
        gramFundingNeeds(0);
}

// Value of InitGramLock on top of the GRAM to lock: the flat fee the creator accepts (what the till attests
// is charged, the rest comes back) plus the lock's budget
fun gramCreateCost(maxFlatFee: coins, permanent: bool, end: int, now: int): coins {
    return maxFlatFee + gramLockBudget(permanent, end, now);
}

// Value of a TopUpGram on top of the GRAM it adds: the lock's work, the flat fee with its notice, the event
// and the excess back to the sender
fun gramTopUpCost(topUpFlatFee: coins): coins {
    return topUpFlatFee + tillReceiptValue() + calculateGasFee(BASECHAIN, LOCK_GAS_TOP_UP) +
        3 * smallMessageFee();
}

// GRAM a ClaimGram must carry: the handler, the event and the payout, which takes the rest with it
fun gramClaimCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_CLAIM) + 2 * smallMessageFee();
}

// GRAM a SweepGram of a lock of GRAM must carry: the handler, the sweep's event and the payout, which takes
// the rest with it
fun gramLockSweepGramCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_SWEEP_GRAM) + 2 * smallMessageFee();
}

// GRAM an ExtendLock of a lock of GRAM must carry on top of the storage of its longer life: the handler,
// the event and the excess back
fun gramExtendCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_EXTEND) + 2 * smallMessageFee();
}

// GRAM a CancelCreation of a lock of GRAM must carry: the handler, the event, the refund to the creator and
// a helper's surplus back to it
fun gramCancelCost(): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_CANCEL) + 3 * smallMessageFee();
}

// ============== Costs of what reaches a lock, a till or the root by mistake ==============

// GRAM a ClaimForeign must carry: the handler and one transfer through a wallet of that workchain
fun claimForeignCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_CLAIM) + jettonTransferValueOn(walletWorkchain) +
        messageFeeOn(walletWorkchain);
}

// GRAM a transfer notification must bring for its tokens to be sent back through the notifying wallet (of
// that workchain): the handler and the transfer. The root and the tills hold stray tokens to the same
// bound.
fun sendBackCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, LOCK_GAS_NOTIFY) + jettonTransferValueOn(walletWorkchain) +
        messageFeeOn(walletWorkchain);
}

// GRAM a RecoverUnrecorded must carry: the handler and one transfer through a wallet of that workchain.
// When the recovery is the refund the lock owes (`ofRefund`), whose record a bounce restores, the gas of
// that bounce on top (bouncePrepay), which the lock keeps.
fun recoverCost(walletWorkchain: int, ofRefund: bool): coins {
    val transfer = calculateGasFee(BASECHAIN, LOCK_GAS_CLAIM) +
        jettonTransferValueOn(walletWorkchain) +
        messageFeeOn(walletWorkchain);
    return ofRefund ? transfer + bouncePrepay() : transfer;
}

// forward_ton_amount of tokens a lock, a till or the root sends back through a wallet of that workchain.
// What notifies their sender: the gas of a lock's notification handler at its bound, which is all a lock
// needs to record them (as free balance) should the sender be a lock, and a message fee for a wallet that
// pays its notification's forward fee out of the forward amount: a small message's, which is what such a
// wallet takes at most on the basechain, and that chain's on top off the basechain (forwardShave). The
// notification is within a small message's size, so the handler's gas reaches the lock whole through such a
// wallet (tests/SendBack.spec.ts). That much when the GRAM of the notification that brought them (`value`)
// covers it on top of the send-back itself, none otherwise.
fun sendBackForward(value: coins, walletWorkchain: int): coins {
    val notice = calculateGasFee(BASECHAIN, LOCK_GAS_NOTIFY) + smallMessageFee() +
        forwardShave(walletWorkchain);
    return value >= sendBackCost(walletWorkchain) + notice ? notice : 0;
}

// Tokens a lock, a till or the root does not keep, sent back through the wallet that reported them
// (`wallet`, the sender of the notification) to whoever it says sent them, with all that is left of the
// notification's value (`value`, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE): whatever that wallet is, it
// is sent no more GRAM than it brought. Non-bounceable and never credited: if that wallet is fake, nothing
// happens; if it is real, the tokens stay there to recover should the transfer fail. When the notification
// names no sender, or brings less GRAM than the way back costs (sendBackCost), nothing is sent: the tokens
// stay in that wallet and the GRAM stays where it came. A transfer that cannot be sent is dropped
// (SEND_MODE_IGNORE_ERRORS, rule 3): refusing a notification returns no token.
fun sendBackUncredited(wallet: address, value: coins, msg: TransferNotification, queryId: uint64) {
    val previousOwner = msg.sender;
    val workchain = wallet.getWorkchain();
    if (previousOwner != null && value >= sendBackCost(workchain)) {
        val sendBackMessage = createMessage({
            bounce: BounceMode.NoBounce,
            dest: wallet,
            value: 0,
            body: JettonTransfer {
                queryId,
                amount: msg.amount,
                destination: previousOwner,
                responseDestination: previousOwner,
                customPayload: null,
                forwardTonAmount: sendBackForward(value, workchain),
                forwardPayload: emptyForwardPayload(),
            },
        });
        sendBackMessage.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
    }
}

// ============== Costs of the root's operations ==============

// Value of a SetTillConfig the root sends to one till: the till's handler and its event
fun tillConfigValue(): coins {
    return calculateGasFee(BASECHAIN, TILL_GAS_CONFIG) + smallMessageFee();
}

// GRAM a SetFees / SetCreationEnabled must carry: the root's handler and a config push to every till, each
// with its forward fee
fun broadcastCost(): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_BROADCAST) +
        TILL_COUNT * (tillConfigValue() + smallMessageFee());
}

// GRAM a DeployTill must carry at least: the root's handler, the till's handling of its config, the least a
// till starts with for its storage, and the forward fee of a message that carries the till's code and data.
// Anything more stays on the till as its storage balance.
fun deployTillCost(): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_DEPLOY_TILL) + tillConfigValue() +
        MIN_STORAGE_PREPAY +
        calculateForwardFee(
            BASECHAIN,
            TILL_STATE_BITS + SMALL_MSG_BITS,
            TILL_STATE_CELLS + SMALL_MSG_CELLS,
        );
}

// GRAM a WithdrawTillJetton / WithdrawRootJetton must carry: the root's and the till's handlers and one
// transfer through a wallet of that workchain (a WithdrawRootJetton, which no till handles, is asked for
// the same)
fun withdrawJettonCost(walletWorkchain: int): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_WITHDRAW_TILL + TILL_GAS_WITHDRAW) +
        jettonTransferValueOn(walletWorkchain) +
        smallMessageFee() +
        messageFeeOn(walletWorkchain);
}

// GRAM a WithdrawTillGrams / WithdrawRootGrams must carry: the handlers on the way at their bound
// (ROOT_GAS_WITHDRAW_GRAMS, which is above the root's and the till's together) and two messages, the
// request to the till and the withdrawal, whose forward fee the till pays on top of the amount. A
// WithdrawRootGrams, which no till handles and which sends the withdrawal itself, is asked for the same.
fun withdrawGramsCost(): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_WITHDRAW_GRAMS) + 2 * smallMessageFee();
}

// GRAM a WithdrawTillNft / WithdrawRootNft must carry: the root's and the till's handlers, the request to
// the till and the transfer to the NFT, which is on the basechain (isSwornLock, in sworn-root), counted as
// a lock counts the transfer of an NFT that reached it by mistake. What is left of the value goes to the
// NFT with the transfer, as a ClaimForeignNft's does. A WithdrawRootNft, which no till handles, is asked
// for the same.
fun withdrawNftCost(): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_WITHDRAW_TILL + TILL_GAS_WITHDRAW) +
        smallMessageFee() +
        answerMessageFeeOn(BASECHAIN);
}

// GRAM a GetRoyaltyParams must carry (TEP-66), the one request the root answers on the request's own value:
// the handler's gas at its bound and the forward fee of the answer at the message prices of the chain it
// goes to. That is the asker's own chain, whatever it is: calculateForwardFee takes the basechain's prices
// for workchain 0 and the masterchain's for any other.
fun rootAnswerCost(workchain: int): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_ANSWER) + messageFeeOn(workchain);
}

// GRAM a SetRoyalty, a SetContent or an AcceptAdmin must carry: the handler's gas at its bound and the
// event that records the change, which the root pays out of its balance (rule 1 of common/sworn.tolk),
// counted at the size of the largest, a SetContent's. What such a message brings beyond what it used stays
// in the root.
fun rootSettingCost(): coins {
    return calculateGasFee(BASECHAIN, ROOT_GAS_SETTING) +
        calculateForwardFee(BASECHAIN, CONTENT_EVENT_BITS, CONTENT_EVENT_CELLS);
}

// GRAM an AttestFees must carry, the one request a till answers on the request's own value: the handler's
// gas at its bound and the forward fee of the answer at the message prices of the chain it goes to, the
// asker's own, whatever it is (as rootAnswerCost). A lock's request carries attestValue, which is above it.
fun tillAnswerCost(workchain: int): coins {
    return calculateGasFee(BASECHAIN, TILL_GAS_ATTEST) + messageFeeOn(workchain);
}

// ============== What the root and a till send alike ==============

// An event of the root: an external message to no address. It carries no value: its forward fee comes out
// of the root's balance, to which the message being handled has added its own value. The root's events
// answer messages that must carry rootSettingCost, which covers it (rule 1). A till emits its events with
// emitPaidEvent (sworn-till), a lock with emitLockEvent (lock-base).
fun emitEvent<T>(body: T) {
    createExternalLogMessage({
        dest: createAddressNone(),
        body,
    }).send(SEND_MODE_REGULAR);
}

// A jetton transfer from one of the account's own wallets, on all that is left of the incoming message's
// value (ON_REQUEST_VALUE, rule 2). The root has checked that the admin's message carries the whole way
// (withdrawJettonCost); a till, which takes this from the root alone, checks nothing more. The excess goes
// to `destination` with the tokens; a transfer the wallet refuses bounces, and the tokens stay where they
// were.
fun sendWithdrawnJetton(wallet: address, queryId: uint64, amount: coins, destination: address) {
    val jettonTransferMessage = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: wallet,
        value: 0,
        body: JettonTransfer {
            queryId,
            amount,
            destination,
            responseDestination: destination,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: emptyForwardPayload(),
        },
    });
    jettonTransferMessage.send(ON_REQUEST_VALUE);
}

// An NFT the account owns, handed to `newOwner` on all that is left of the incoming message's value
// (ON_REQUEST_VALUE, rule 2). The root has checked that the admin's message carries the whole way
// (withdrawNftCost); a till, which takes this from the root alone, checks nothing more. The excess goes to
// the new owner; a transfer the NFT refuses bounces, and the NFT stays where it was.
fun sendWithdrawnNft(nft: address, queryId: uint64, newOwner: address) {
    val nftTransferMessage = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: nft,
        value: 0,
        body: NftTransfer {
            queryId,
            newOwner,
            responseDestination: newOwner,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: emptyForwardPayload(),
        },
    });
    nftTransferMessage.send(ON_REQUEST_VALUE);
}

// `amount` GRAM of the account, to `destination`. It leaves whole: its forward fee is paid on top
// (SEND_MODE_PAY_FEES_SEPARATELY), out of what the admin's message brought, which the root has checked
// covers it (withdrawGramsCost). So `amount` leaves exactly, and the account ends with no less than what it
// had less `amount`, as rule 1 lets the admin's withdrawals.
fun sendWithdrawnGrams(destination: address, queryId: uint64, amount: coins) {
    val withdrawalMessage = createMessage({
        bounce: BounceMode.NoBounce,
        dest: destination,
        value: amount,
        body: Excesses { queryId },
    });
    withdrawalMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
}
