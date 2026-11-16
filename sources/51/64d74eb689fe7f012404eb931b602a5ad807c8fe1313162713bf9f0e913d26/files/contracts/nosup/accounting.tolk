// Copyright (C) 2026 MENA
// SPDX-License-Identifier: AGPL-3.0-or-later

import "storage"
// Per-contract settlement helpers that read the contract's Storage. The pure
// settlement model is in shared/accounting.tolk.
import "../shared/accounting"
import "../shared/types"

// Cost of moving `side`'s received assets (delivery on execute, return on
// cancel — the same per-asset values either way), from the received counters.
fun Storage.ownTransferCost(self, side: int): coins {
    val total = side == 1 ? (self.received1Count as int) : (self.received2Count as int);
    val jettons = side == 1 ? (self.receivedJettons1 as int) : (self.receivedJettons2 as int);
    return transferCost(total - jettons, jettons);
}

// The same cost from the registry, before the deposits have arrived. Walks
// every entry: get-methods only.
fun Storage.registryTransferCost(self, side: int): coins {
    var nfts = 0;
    var jettons = 0;
    var r = self.assets.findFirst();
    while (r.isFound) {
        val a = r.loadValue();
        if ((a.ownerSide as int) == side) {
            if (a.kind == 1) {
                jettons += 1;
            } else {
                nfts += 1;
            }
        }
        r = self.assets.iterateNext(r);
    }
    return transferCost(nfts, jettons);
}
