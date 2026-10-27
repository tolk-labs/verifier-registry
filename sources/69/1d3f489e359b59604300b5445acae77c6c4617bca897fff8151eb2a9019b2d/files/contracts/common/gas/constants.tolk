import "types"

// Резерв закрытого escrow нужен для позднего bounce и bounded automatic recovery. Это продуктовая политика
// хранения, а не оценка compute gas.
const MIN_TONS_FOR_STORAGE = grams("0.01")

// Измерено на обоих runtime и округлено вверх. Certified-проверка подписи выполняется при binding,
// а не в финальном settlement; на максимальном наборе обе реализации остаются ниже этой границы.
const GAS_ESCROW_SETTLEMENT = GasUnits { value: 16_000 }

const GAS_PER_ESCROW_ITEM = GasUnits { value: 5_200 }

// NFT transfer содержит отдельную cell текстового комментария; root сообщения в fee не считается.
const OUTGOING_MESSAGE_BITS = 2046

const OUTGOING_MESSAGE_CELLS = 2

// Full vault code, StateInit/data/terms and refund/assignment body travel in each USDT message.
// Both network profiles test the serialized envelope against these bounds after every rebuild.
const USDT_STATE_INIT_MESSAGE_BITS = 65_536
const USDT_STATE_INIT_MESSAGE_CELLS = 96
