// Copyright (C) 2026 MENA
// SPDX-License-Identifier: AGPL-3.0-or-later

// Settlement model: every coin that arrives is recorded against the side that
// sent it; each side pays for moving its own assets; everything else the deal
// spends — gas, service messages, the storage floor — is shared equally.
//
// Refunds are split from R, the amount actually left on the balance, using the
// per-side counters only for the DIFFERENCE between the sides:
//   refund1 = (R + N1 - N2) / 2,  refund2 = R - refund1
// where Ni is side i's contribution net of its own costs. With S the shared
// costs and U any unattributed inflow, R = N1 + N2 - S + U, so
// refund1 = N1 - S/2 + U/2: its own contribution minus half of what was shared.
// Because the total comes from the balance, overstated counters (deposit gas is
// credited gross) cannot make the split pay out more than the balance holds.
import "types"

// Everything `side` has paid into the deal.
fun paidBy(g: GramState, side: int): coins {
    return side == 1
        ? g.gram1Received + g.serviceFee1 + g.gram1DepositReserve
        : g.gram2Received + g.serviceFee2 + g.gram2DepositReserve;
}

// Credit a payment to side 2: its service fee first, then its TON leg, the
// rest as a deposit reserve. All three count in paidBy, so the order only
// decides which gate a payment meets first.
fun GramState.creditSide2(mutate self, value: coins) {
    var rest = value;
    if (self.serviceFee2 < SERVICE_FEE) {
        val gap = SERVICE_FEE - self.serviceFee2;
        val fee = rest < gap ? rest : gap;
        self.serviceFee2 += fee;
        rest -= fee;
    }
    if (self.gram2Received < self.gram2Amount) {
        val gap = self.gram2Amount - self.gram2Received;
        val leg = rest < gap ? rest : gap;
        self.gram2Received += leg;
        rest -= leg;
    }
    self.gram2DepositReserve += rest;
}

fun transferCost(nfts: int, jettons: int): coins {
    return NFT_TRANSFER_VALUE * nfts + JETTON_TRANSFER_VALUE * jettons;
}

// Split R between the sides. A side whose formula share falls below zero gets
// nothing and the other side gets all of R; the two always sum to R.
fun splitRefunds(r: coins, n1: coins, n2: coins): (coins, coins) {
    if (r <= 0) {
        return (0, 0);
    }
    var r1 = (r + n1 - n2) / 2;
    if (r1 < 0) {
        r1 = 0;
    }
    if (r1 > r) {
        r1 = r;
    }
    return (r1, r - r1);
}

// Top-ups that keep both formula shares at or above zero, so splitRefunds
// never cuts one and each side bears exactly half of what was shared. Side
// i's share is (R ± (N1 − N2)) / 2; a top-up `a` by side i raises both R and
// Ni by a, so that share grows by a and the other share does not move. Odd
// amounts round the top-up up.
fun noClampTopUps(r: int, n1: int, n2: int): (coins, coins) {
    val x1 = r + n1 - n2;
    val x2 = r - n1 + n2;
    val a1 = x1 < 0 ? (-x1 + 1) / 2 : 0;
    val a2 = x2 < 0 ? (-x2 + 1) / 2 : 0;
    return (a1, a2);
}
