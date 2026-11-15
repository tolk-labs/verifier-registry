// Wallet content formats and the metadata URLs that the collection builds from them.

import "@stdlib/strings"

import "storage-collection"

/// Content of a wallet from a public deploy. The collection draws `traitSetIndex` on-chain.
struct (0x02) TraitSetContent {
    /// At a public deploy: less than the `traitSetCount` of that time, or 0 if the count is 0.
    traitSetIndex: uint16
}

/// Content whose metadata URL is built from the wallet index only.
struct (0x03) WalletIndexContent {}

/// Wallet content formats that `get_nft_content` expands.
type WalletContent = TraitSetContent | WalletIndexContent

/// Start of a wallet's metadata URL: "<commonContent>".
fun walletContentUrl(): StringBuilder {
    val storage = lazy AgenticCollectionStorage.load();
    val content = lazy storage.content.load();

    return StringBuilder.create().append(content.commonContent);
}

/// Off-chain content with the URL "<url><walletIndex>.json".
fun offchainWalletContent(url: StringBuilder, walletIndex: int): cell {
    return url.appendInt(walletIndex).append(".json").build().prefixWith01() as unknown as cell;
}
