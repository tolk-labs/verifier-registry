import "@stdlib/gas-payments"
import "types"

// How long a courier has to deliver is set per order: OrderStorage.deliveryTime,
// counted from the moment they accept. The client picks it (1..14 days; the
// Marketplace enforces the range).

// Lowest value a courier must attach to accept: a flat 0.1 TON service fee
// (from the UI) that stays on the contract and is NEVER refunded.
// Together with the 0.1 TON the client added
// at create time it makes up the ~0.2 TON the platform keeps on a simple
// completed order. All such fees accumulate on the contract balance and are paid
// out to the owner only when the order reaches a terminal state. This floor also
// rejects grossly under-funded direct callers that bypass the UI.
const MIN_ACCEPT_FEE = ton("0.1")

// Extra service fee the client pays to CANCEL an order they created while it is
// still Open. It is on top of the 0.1 TON create fee they already paid: the
// create fee stays with the platform and this 0.3 is added, so a cancel earns the
// platform ~0.4 TON in total. The reward is always returned to the client in full.
// It is the ONLY coin the client attaches: the network fees of the cancel, the
// USDT payout included, are paid out of the order's fee pool.
const CANCEL_FEE = ton("0.3")

// Extra service fee the courier pays to RELEASE (give up) an order they already
// accepted. It is on top of the 0.1 TON accept fee they already paid (which is
// NOT refunded). Both stay on the contract balance — nothing is sent out on a
// release — so the platform's eventual earnings grow by ~0.3 TON, collected when
// the order finally settles. The reward and the client's create fee also stay on
// the contract for the next courier (the order reopens, it does not close).
const RELEASE_FEE = ton("0.2")

// Native coin handed to the order's USDT wallet for a payout: the wallet-to-wallet
// transfer (it may deploy the payee's wallet). Tether's wallet really spends
// ~0.0014 of it (measured on a mainnet fork); the rest is margin and comes back
// as "excesses". On confirm / claim / cancel the ORDER pays it out of its fee
// pool and the excesses go to the owner, so the caller attaches no payout gas at
// all. Only Rescue (a closed, empty order) takes it from the caller, who gets the
// unused part back.
const PAYOUT_GAS = ton("0.02")

// Pay the referral chat HALF of the fee pool, if a referral is set. Called on
// every terminal path right after the reward leaves and right before the owner
// sweep (mode 128), so the owner naturally receives the other half minus the
// network fees — the platform carries the gas, the chat gets a clean 50%.
// `pool` is computed by the caller (the formula differs per send mode of the
// payout, see each call site). The guard `half > 0` is defensive: the pool is
// always >= ~0.2 (create fee + at least one accept/cancel fee) on every real
// path. NoBounce because the chat's wallet may never have been deployed.
// Returns the amount actually sent to the chat (0 when no referral is set) so
// the terminal event can record the exact referral payout.
fun sendReferralHalf(referral: address?, pool: coins): coins {
    if (referral != null) {
        val half = pool / 2;
        if (half > 0) {
            val pay = createMessage({
                bounce: BounceMode.NoBounce,
                value: half,
                dest: referral!,
            });
            pay.send(SEND_MODE_PAY_FEES_SEPARATELY);
            return half;
        }
    }
    return 0;
}

// Send `amount` USDT from this order's wallet to `to`. The unused native coin of
// the transfer goes to `excessesTo` (responseDestination): the owner when the
// order paid the gas from its fee pool, the payee when the payee attached it
// (Rescue). Bounceable: if the wallet rejects the transfer (not enough USDT, e.g.
// an unfunded order), the coin comes back to the order instead of being lost; the
// order ignores the bounce.
fun sendUsdt(
    wallet: address,
    amount: coins,
    to: address,
    value: coins,
    mode: int,
    excessesTo: address,
) {
    val transfer = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value,
        dest: wallet,
        body: JettonTransfer {
            queryId: 0,
            amount,
            destination: to,
            responseDestination: excessesTo,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayloadInRef: false,
        },
    });
    transfer.send(mode);
}

// The last step of every terminal path: everything left on the balance (the
// owner's half of the fee pool, minus gas) goes to the platform owner.
//
// There is NO self-destruct (no SEND_MODE_DESTROY here). The
// reward sits in a separate contract — the order's USDT wallet — and a payout
// that fails on the receiving side puts the USDT back into that wallet without
// telling the order. If the order were gone, nobody could ever move that USDT
// again. So the closed order stays, with a zero balance and its terminal status,
// and the payee can pull any such USDT out with Rescue. Its storage rent is a
// fraction of a cent per year and is paid by whoever calls it next.
fun sweepToOwner(owner: address) {
    val fee = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0 as coins,
        dest: owner,
    });
    // SAFETY: called only on a terminal path, after the reward was sent out of
    // the order's USDT wallet and the referral half was paid. The native coin left
    // is the platform's fee pool, so draining it all to the owner is intended.
    // The order is NOT destroyed (no SEND_MODE_DESTROY), see above.
    fee.send(SEND_MODE_CARRY_ALL_BALANCE);
}

// One delivery order: an escrow plus a small state machine.
//   Funding --JettonNotify(own USDT wallet, from the Marketplace, == reward)--> Open
//   Open --AcceptOrder(invited courier, +0.1 fee)--> Accepted
//        --ConfirmWithCode(the courier only, +network fee)--> Completed  (reward USDT -> courier, ~0.2 buffer -> owner)
//        --ClaimExpired(client, after deadline, +network fee)--> Expired  (reward USDT -> client, ~0.2 buffer -> owner, courier gets nothing)
//        --CourierRelease(courier, +0.2 fee, BEFORE deadline only)--> Open  (order reopens; accept fee + release fee accumulate in contract; owner paid at terminal state only; courier gets nothing back. After the deadline this is rejected — the courier has no actions left.)
//   Open / Funding --CancelOrder(client, +0.3 fee (only the network fee while Funding))--> Cancelled  (reward USDT -> client; the create fee is kept and the 0.3 cancel fee is added, so ~0.4 -> owner)
//   Completed / Cancelled / Expired --Rescue(the payee, +payout gas)--> (same status; stray USDT -> payee)
//
// The reward is USDT held in the order's own USDT wallet; every fee and all gas
// are the native coin on the order's balance. The payouts are jetton transfers
// the order asks its wallet to make.
//
// One fee per action, and nothing on top: a caller attaches exactly the service
// fee (accept 0.1, release 0.2, cancel 0.3) and every network fee of that action
// comes out of it. The actions with no service fee (confirm, claim, a Funding
// cancel) attach only what running this code costs, as the app measured it by
// emulation; once the caller is checked the order pays its own gas, so any
// shortfall — and the payout they trigger — comes from the order's fee pool.
// What is left of the pool goes to the owner (half to the referral chat, if
// any).
//
// Delivery is confirmed by a CODE, not a button: the client's app picks a 256-bit
// secret at create time and puts only its hash on-chain (secretHash). The courier
// learns the secret from the client at hand-off (a QR code) and reveals it with
// ConfirmWithCode; the reward is paid only when hash(secret) == secretHash AND the
// caller is the courier who accepted the order. So the courier is paid ONLY with
// the client's code, and only the courier can trigger that payment — there is no
// client "confirm" button
// to stall, and a courier with no code cannot be paid (the order expires to the
// client). The contract checks an objective math fact (the hash), so neither side's
// word matters and no arbiter is needed.
contract Order {
    author: "SwiftDelivery"
    version: "1.0.0"
    description: "A single delivery order with a USDT escrow"
    storage: OrderStorage
    incomingMessages: OrderMessage
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy OrderMessage.fromSlice(in.body);
    var s = lazy OrderStorage.load();

    match (msg) {
        InitWallet => {
            // Rides on the Marketplace's deploy message. Only that Marketplace
            // may set the wallet, and only once: anyone who learned the order's
            // init data could deploy it first with a wallet of their own, so the
            // message-sender check — not "first message wins" — is what makes it safe.
            var extra = s.extra.load();
            var jetton = extra.jetton.load();
            assert (in.senderAddress == jetton.marketplace) throw OrderErrors.NotMarketplace;
            assert (jetton.wallet == null) throw OrderErrors.WrongStatus;
            jetton.wallet = msg.wallet;
            extra.jetton = jetton.toCell();
            s.extra = extra.toCell();
            s.save();
        }
        JettonNotify => {
            // Anyone can send this opcode, so only our own USDT wallet counts.
            val jetton = s.extra.load().jetton.load();
            assert (
                jetton.wallet != null && in.senderAddress == jetton.wallet!
            ) throw OrderErrors.NotJettonWallet;
            // The funding transfer is the Marketplace's, for exactly the reward.
            // Real USDT arriving any other way (a gift, a mistake) just stays in
            // the wallet — the payee of the closed order can pull it out with
            // Rescue.
            val fromMarketplace = msg.from != null && msg.from! == jetton.marketplace;
            if (s.status == OrderStatus.Funding && msg.amount == s.reward && fromMarketplace) {
                s.status = OrderStatus.Open;
                s.save();
                emitEvent(OrderFunded { reward: s.reward });
            } else if (fromMarketplace) {
                // A second create with the very same fields (a resent create)
                // lands at this same address. It is always the client's money:
                // the client is part of the order's address, and the Marketplace
                // forwards only what that client sent. Left in the wallet, the
                // payee of the closed order could take it with Rescue — the
                // courier of a Completed one. So it goes straight back to the
                // client. The duplicate's create coin is already on the balance
                // (its deploy and top-up) and pays the payout; its unused part
                // goes back to the client too. A payout the wallet cannot cover
                // just bounces, and nothing moves.
                sendUsdt(
                    jetton.wallet!,
                    msg.amount,
                    s.client,
                    PAYOUT_GAS,
                    SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
                    s.client,
                );
            }
        }
        Excesses => {
            // The unused coin of a USDT hop, part of the client's create fee.
            // It is already on the balance; nothing else to do.
        }
        AcceptOrder => {
            assert (s.status == OrderStatus.Open) throw OrderErrors.WrongStatus;
            // The courier attaches a flat 0.1 TON service fee (from the UI),
            // which stays on the contract and is NOT refunded — it becomes
            // part of the platform's ~0.2 TON earnings.
            assert (in.valueCoins >= MIN_ACCEPT_FEE) throw OrderErrors.FeeTooLow;
            // Only a courier the client invited (see AcceptOrder in types).
            // The signed cell names this order and the sender, so an invite
            // cannot be replayed by anyone else or on another order.
            assert (blockchain.now() <= msg.validUntil) throw OrderErrors.InviteExpired;
            var extra = s.extra.load();
            val invite = AcceptInvite {
                order: contract.getAddress(),
                courier: in.senderAddress,
                validUntil: msg.validUntil,
            };
            assert (
                isSignatureValid(
                    invite.toCell().hash(),
                    msg.signature as slice,
                    extra.jetton.load().acceptKey,
                )
            ) throw OrderErrors.BadInvite;
            s.courier = in.senderAddress;
            s.status = OrderStatus.Accepted;
            s.acceptedAt = blockchain.now() as uint32; // start the delivery clock
            // courierContact lives in the referenced extra cell (loaded above):
            // set the courier's contact and re-pack the ref.
            extra.courierContact = msg.courierContact;
            s.extra = extra.toCell();
            s.save();
            emitEvent(OrderAccepted { courier: in.senderAddress });
        }
        ConfirmWithCode => {
            assert (s.status == OrderStatus.Accepted) throw OrderErrors.WrongStatus;
            // Only the courier who accepted this order may confirm it. The secret
            // is the delivery proof, but binding the call to s.courier matches the
            // real hand-off (only the courier scans the client's QR) and closes the
            // gap where ANYONE who learned a leaked secret could force settlement
            // before delivery. status Accepted guarantees courier is set, so `!` is
            // safe. It also means the single payee is the courier, which lets the
            // payout carry the courier's gas change (see below).
            assert (s.courier! == in.senderAddress) throw OrderErrors.NotCourier;
            // Delivery proof: the hash of the revealed secret must match the one
            // fixed at create time. hash(secret) is the representation hash of a
            // cell holding the 256-bit secret, which the frontend reproduces with
            // @ton/core (round-trip covered by a test). The preimage becomes public
            // here, but the order turns terminal in the same transaction, so a
            // replay is impossible.
            val extra = s.extra.load();
            val h = beginCell().storeUint(msg.secret, 256).endCell().hash();
            assert (h == extra.secretHash) throw OrderErrors.BadCode;
            // Every check passed: the order now pays for its own gas, like a
            // wallet does. The courier attaches the gas the app measured by
            // emulating this call; if the real run needs a bit more, the fee
            // pool covers it, so the call never fails for want of gas. Safe to
            // open up only here: a stranger or a wrong code was stopped above
            // on the caller's own coin, and this call closes the order, so it
            // cannot be repeated. The payout below is paid by the order too.
            setGasLimitToMaximum();
            s.status = OrderStatus.Completed;
            s.save();
            // 1. The reward goes to the courier. The order's fee pool pays the
            //    payout gas (fees from the balance too) and the unused part
            //    comes back to the owner, so the courier pays nothing extra.
            sendUsdt(
                extra.jetton.load().wallet!,
                s.reward,
                s.courier!,
                PAYOUT_GAS,
                SEND_MODE_PAY_FEES_SEPARATELY,
                extra.owner,
            );
            // 2. Referral: half of the fee pool goes to the chat whose link
            //    brought this order. The pool is the whole balance, this
            //    message's value included: the reward is not on it at all (it
            //    is USDT in the order's wallet), and the payout gas above and
            //    every fee come out of the owner's half.
            val referralPayout = sendReferralHalf(
                extra.referral,
                contract.getOriginalBalance(),
            );
            // 3. Log the completion (before the sweep below drains the balance
            //    that pays the emit's forward fee).
            emitEvent(OrderCompleted {
                courier: s.courier!,
                reward: s.reward,
                referralPayout,
            });
            // 4. The rest of the pool is the platform's earnings.
            sweepToOwner(extra.owner);
        }
        ClaimExpired => {
            // After the deadline the order can be unwound — a TON contract cannot
            // fire on a timer by itself, so the app shows the client a "Claim"
            // button. Only the CLIENT may claim: the reward returns to them and no
            // one else has any reason to trigger this. Restricting it to the client
            // also means there is a single payee, so the payout can carry the
            // client's gas change.
            assert (s.status == OrderStatus.Accepted) throw OrderErrors.WrongStatus;
            assert (blockchain.now() > s.acceptedAt + s.deliveryTime) throw OrderErrors.NotExpired;
            assert (s.client == in.senderAddress) throw OrderErrors.NotClient;
            // Checks passed: the order pays for its own gas from here on (see
            // ConfirmWithCode).
            setGasLimitToMaximum();
            s.status = OrderStatus.Expired;
            s.save();
            val extra = s.extra.load();
            // The courier did not deliver in time, so they get nothing. The
            // reward returns to the client; the order pays the payout gas and
            // its unused part goes to the owner (same as ConfirmWithCode).
            sendUsdt(
                extra.jetton.load().wallet!,
                s.reward,
                s.client,
                PAYOUT_GAS,
                SEND_MODE_PAY_FEES_SEPARATELY,
                extra.owner,
            );
            // Referral: same pool formula as ConfirmWithCode.
            val referralPayout = sendReferralHalf(
                extra.referral,
                contract.getOriginalBalance(),
            );
            // Log the expiry (before the sweep below drains the balance that
            // pays the emit's forward fee). status Accepted guaranteed courier
            // was set, so `!` is safe: this names who failed to deliver.
            emitEvent(OrderExpired {
                courier: s.courier!,
                reward: s.reward,
                referralPayout,
            });
            sweepToOwner(extra.owner);
        }
        CancelOrder => {
            // Funding too: an order whose "USDT arrived" notice never came (it
            // would have to overtake the deploy, see the Marketplace) must still
            // be closable. Its USDT normally IS in the wallet and the payout
            // below returns it; if not, the payout just bounces off the empty
            // wallet, and USDT landing later is pulled out with Rescue.
            assert (
                s.status == OrderStatus.Open || s.status == OrderStatus.Funding
            ) throw OrderErrors.WrongStatus;
            assert (s.client == in.senderAddress) throw OrderErrors.NotClient;
            // Cancelling costs a flat 0.3 TON service fee, on top of the 0.1 TON
            // the client already paid at create time — and nothing else: the
            // network fees, the payout gas included, come out of the fee pool.
            // Reject a caller who did not attach it so the platform always earns
            // the cancel fee (and a direct caller cannot cancel for free). A
            // Funding order is stuck through no fault of the client, so there the
            // fee is waived: the client attaches only what running this code
            // costs, and the create fee pays the payout.
            val funding = s.status == OrderStatus.Funding;
            if (!funding) {
                assert (in.valueCoins >= CANCEL_FEE) throw OrderErrors.FeeTooLow;
            }
            // Checks passed: the order pays for its own gas from here on (see
            // ConfirmWithCode) — what a Funding cancel needs; an Open cancel's
            // 0.3 covers it anyway.
            setGasLimitToMaximum();
            s.status = OrderStatus.Cancelled;
            s.save();
            val extra = s.extra.load();
            // 1. Return the reward to the client. The order pays the payout gas
            //    and its unused part goes to the owner.
            sendUsdt(
                extra.jetton.load().wallet!,
                s.reward,
                s.client,
                PAYOUT_GAS,
                SEND_MODE_PAY_FEES_SEPARATELY,
                extra.owner,
            );
            // 2. Referral: half of the whole balance (the create fee plus the
            //    incoming cancel fee). A Funding order never went live and holds
            //    only the create fee, which has to pay the payout, so no chat
            //    earns on it.
            val referralPayout = sendReferralHalf(
                funding ? null : extra.referral,
                contract.getOriginalBalance(),
            );
            // 3. Log the cancellation (before the sweep below drains the
            //    balance that pays the emit's forward fee).
            emitEvent(OrderCancelled {
                reward: s.reward,
                referralPayout,
            });
            // 4. The create fee plus the cancel fee (minus the referral's half
            //    when a chat is set) go to the platform owner.
            sweepToOwner(extra.owner);
        }
        CourierRelease => {
            // Only the courier who accepted this order may give it up, and only
            // while it is still Accepted (not yet delivered or expired).
            assert (s.status == OrderStatus.Accepted) throw OrderErrors.WrongStatus;
            // status Accepted guarantees courier is set, so `!` is safe here.
            assert (s.courier! == in.senderAddress) throw OrderErrors.NotCourier;
            // A courier may give up ONLY before the deadline. Once the delivery
            // window has passed there is no point reopening a stale order — a new
            // courier has nothing left to deliver — so after
            // the deadline the courier cannot release, and the order is settled by
            // ClaimExpired (the client) or ConfirmWithCode (the courier). This guard
            // is the exact mirror of ClaimExpired's `now > acceptedAt + deliveryTime`:
            // up to and including the deadline only release is possible; strictly
            // after it only claim is, so the two can never race.
            assert (blockchain.now() <= s.acceptedAt + s.deliveryTime) throw OrderErrors.DeadlinePassed;
            // Giving up an accepted order costs a flat 0.2 TON service fee, on
            // top of the 0.1 TON accept fee the courier already paid (which is
            // NOT refunded). Reject a caller who did not attach it.
            assert (in.valueCoins >= RELEASE_FEE) throw OrderErrors.FeeTooLow;
            // The order does NOT close — it reopens so another courier can take
            // it. Reset it to exactly the Open shape it had before this courier
            // accepted: clear the courier, the accept time, and their contact.
            s.status = OrderStatus.Open;
            s.courier = null;
            s.acceptedAt = 0;
            var extra = s.extra.load();
            extra.courierContact = createEmptyCell();
            s.extra = extra.toCell();
            s.save();
            // All service fees accumulate in the contract balance. The 0.1 accept
            // fee already held and the 0.2 release fee just received stay here and
            // are paid to the owner as part of the final mode-128 transfer when the
            // order reaches a terminal state (ConfirmWithCode, CancelOrder, or
            // ClaimExpired). No internal message is sent here — only the event.
            emitEvent(OrderReopened { courier: in.senderAddress });
        }
        Rescue => {
            // A closed order's USDT belongs to the one it was paid to: the
            // courier of a Completed order, the client otherwise. Only they may
            // pull it, and only to themselves, so the amount can be anything.
            assert (
                s.status == OrderStatus.Completed || s.status == OrderStatus.Cancelled ||
                s.status == OrderStatus.Expired
            ) throw OrderErrors.WrongStatus;
            val payee = s.status == OrderStatus.Completed ? s.courier! : s.client;
            assert (in.senderAddress == payee) throw OrderErrors.NotPayee;
            // A closed order's balance is 0, so the storage rent it owes since
            // it closed was taken out of this message's value before we see it.
            // Count that rent as attached, or the minimum is never enough.
            assert (
                in.valueCoins + contract.getStoragePaidPayment() >= PAYOUT_GAS
            ) throw OrderErrors.FeeTooLow;
            sendUsdt(
                s.extra.load().jetton.load().wallet!,
                msg.amount,
                payee,
                0,
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
                payee,
            );
        }
        else => {
            // Empty body (a plain top-up) is accepted as a no-op.
            assert (in.body.isEmpty()) throw OrderErrors.InvalidMessage;
        }
    }
}

// The only bounceable message an order sends is a USDT transfer to its own
// wallet. If the wallet rejects it (e.g. no USDT in an order cancelled while
// still Funding) the native coin simply comes back; nothing else to do.
fun onBouncedMessage(_in: InMessageBounced) {}

get fun orderData(): OrderStorage {
    val s = lazy OrderStorage.load();
    return s;
}

get fun status(): OrderStatus {
    val s = lazy OrderStorage.load();
    return s.status;
}
