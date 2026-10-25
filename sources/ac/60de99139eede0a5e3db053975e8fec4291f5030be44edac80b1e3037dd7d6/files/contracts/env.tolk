const JETTON_DEPLOYER = "deployer"
const MAINNET_DEPLOYER_WALLET = "admin-deploy"

// Admin of the testnet jetton. Not used on mainnet; kept for shared scripts.
const JETTON_ADMIN_ADDRESS: address = address("kQDBuGJ57OoZHJ6RdoDEuPrEp_vAPszuu20B1NMh7P0u2Jtr") //deployer wallet address

// Tether USD jetton master, mainnet. tonapi: symbol USD₮, decimals 6.
// Raw: 0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe
const USDT_MINTER_ADDRESS: address = address("EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs")

// Tether jetton wallets: data = status(uint4) + balance + owner + minter, no toShard.
const USDT_WALLET_TETHER_LAYOUT: bool = true

// Public library reference returned by get_jetton_data as wallet_code (same hash as Tether's wallet).
// Tag 0x02 plus the code hash. The full wallet code lives in the masterchain library.
// SAFETY: pushes a constant BOC cell, no side effects.
@pure
fun getUsdtWalletCode(): cell
    asm
        "B{b5ee9c72010101010023000842028f452d7a4dfd74066b682365177259ed05734435be76b5fd4bd5d8af2b7c3d68} B>boc PUSHREF"
