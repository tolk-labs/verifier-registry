// On-chain деривация собственного official-USDT wallet escrow. Адрес вычисляется из canonical
// master, точного wallet code и адреса владельца, поэтому поддельный jetton не может прислать
// доверенное notification.
//
// Код привязан к текущей mainnet-эпохе Tether wallet code, представленной exotic library-reference
// cell. При обновлении Tether адрес перестанет совпадать fail-closed: backend обязан выключить
// checkout до выпуска новой версии escrow. Раскладка побайтно сверена с mainnet
// get_wallet_address.

import "@acton/tolk-stdlib/exotic-cells"
import "@contracts/common/usdt/network_constants"

fun usdtMaster(): address {
    return address(USDT_MASTER_RAW);
}

// Точная library-reference cell: 8-bit type-2 tag и code hash.
fun usdtWalletCode(): cell {
    return beginCell()
        .storeInt(ExoticCellType.LibraryReference, 8)
        .storeUint(USDT_WALLET_CODE_HASH, 256)
        .endCellSpecial();
}

// StateInit official-USDT wallet владельца `owner`: status:uint4=0, balance:coins=0, owner, master.
// Функция общая для деривации и деплоя: расхождение даже на один бит молча даст другой адрес.
fun usdtWalletInitFor(owner: address): AutoDeployAddress {
    val walletData = beginCell()
        .storeUint(0, 4)
        .storeCoins(0)
        .storeAddress(owner)
        .storeAddress(usdtMaster())
        .endCell();

    return { stateInit: { code: usdtWalletCode(), data: walletData } };
}

// Адрес official-USDT wallet владельца `owner`.
fun deriveUsdtWalletFor(owner: address): address {
    return usdtWalletInitFor(owner).calculateAddress();
}
