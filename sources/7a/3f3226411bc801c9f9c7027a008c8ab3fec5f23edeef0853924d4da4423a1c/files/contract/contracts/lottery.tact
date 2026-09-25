import "@stdlib/deploy";

// ===== Constants =====
const TICKET_PRICE: Int = ton("1.0");        // 1 TON per ticket (informational; split is proportional)
const MIN_PAYMENT: Int = ton("0.99");        // защита от пыли; TMA шлёт 1.05 TON для буфера на forward fee
const CALLER_BONUS: Int = ton("0.1");        // reward to whoever triggers draw (if not owner)
const STORAGE_RESERVE: Int = ton("0.05");    // keep on contract for future storage
const DAY_SECONDS: Int = 86400;

// ===== Messages =====
message BuyTicket {}

message DrawResult {
    round: Int as uint32;
    winner: Address;
    reward: Int as coins;
    participants: Int as uint32;
}

// ===== Contract =====
contract Lottery with Deployable {
    owner: Address;
    round: Int as uint32 = 0;
    nextDrawTs: Int as uint64;                 // unix timestamp (seconds UTC)
    participantsCount: Int as uint32 = 0;
    participants: map<Int, Address>;           // 1..participantsCount
    joined: map<Address, Bool>;                // one ticket per wallet per round
    lastWinner: Address;
    lastReward: Int as coins = 0;
    lastRound: Int as uint32 = 0;
    totalRounds: Int as uint32 = 0;

    init(owner: Address, firstDrawTs: Int) {
        self.owner = owner;
        self.nextDrawTs = firstDrawTs;
        self.lastWinner = owner;  // placeholder until first draw
    }

    // --- Buy a ticket ---
    receive(msg: BuyTicket) {
        let ctx: Context = context();
        require(now() < self.nextDrawTs, "Ticket sale closed; wait for next round");
        require(ctx.value >= MIN_PAYMENT, "Send at least 1 TON (ticket + gas buffer)");
        require(self.joined.get(ctx.sender) == null, "This wallet already has a ticket in current round");

        // Record participant with sequential index 1..N
        self.participantsCount = self.participantsCount + 1;
        self.participants.set(self.participantsCount, ctx.sender);
        self.joined.set(ctx.sender, true);

        // Atomic proportional 10% split to owner — works for any value >= MIN_PAYMENT
        let ownerCut: Int = ctx.value / 10;
        send(SendParameters{
            to: self.owner,
            value: ownerCut,
            mode: SendPayGasSeparately,
            bounce: false
        });
    }

    // --- Permissionless daily draw ---
    receive("draw") {
        let ctx: Context = context();
        require(now() >= self.nextDrawTs, "Draw time not reached");

        // Rollover if no participants (nobody played today)
        if (self.participantsCount == 0) {
            self.nextDrawTs = self.nextDrawTs + DAY_SECONDS;
            self.round = self.round + 1;
            return;
        }

        // Fair random — MUST randomize LT before random()
        nativeRandomizeLt();
        let winIndex: Int = random(1, self.participantsCount + 1);
        let winner: Address = self.participants.get(winIndex)!!;

        // Caller bonus only if caller is NOT the owner (we don't reward ourselves)
        let bonusForCaller: Int = 0;
        if (ctx.sender != self.owner) {
            bonusForCaller = CALLER_BONUS;
        }

        let reward: Int = myBalance() - bonusForCaller - STORAGE_RESERVE;
        require(reward > 0, "Insufficient balance for reward");

        // Save result BEFORE sending (state must be settled before external calls)
        self.lastWinner = winner;
        self.lastReward = reward;
        self.lastRound = self.round;
        self.totalRounds = self.totalRounds + 1;

        // Reset round state
        self.participants = emptyMap();
        self.joined = emptyMap();
        self.participantsCount = 0;
        self.nextDrawTs = self.nextDrawTs + DAY_SECONDS;
        self.round = self.round + 1;

        // Payouts (after state update — safer if send bounces)
        if (bonusForCaller > 0) {
            send(SendParameters{
                to: ctx.sender,
                value: bonusForCaller,
                mode: SendPayGasSeparately,
                bounce: false
            });
        }
        send(SendParameters{
            to: winner,
            value: reward,
            mode: SendPayGasSeparately,
            bounce: false
        });
    }

    // ===== Getters =====
    get fun owner(): Address { return self.owner; }
    get fun round(): Int { return self.round; }
    get fun nextDrawTs(): Int { return self.nextDrawTs; }
    get fun participantsCount(): Int { return self.participantsCount; }
    get fun totalRounds(): Int { return self.totalRounds; }
    get fun ticketPrice(): Int { return TICKET_PRICE; }
    get fun minPayment(): Int { return MIN_PAYMENT; }
    get fun hasJoined(addr: Address): Bool { return self.joined.get(addr) != null; }
    get fun participantAt(idx: Int): Address { return self.participants.get(idx)!!; }
    get fun lastWinner(): Address { return self.lastWinner; }
    get fun lastReward(): Int { return self.lastReward; }
    get fun lastRound(): Int { return self.lastRound; }
    get fun contractBalance(): Int { return myBalance(); }
}
