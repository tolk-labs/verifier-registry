// Fees are code constants (not storage) so nobody can change them after deploy.
const TAKER_FEE_BPS = 50 // 0.5% paid by the buyer on top of the price
const MAKER_FEE_BPS = 50 // 0.5% taken from the seller's proceeds
const BPS_DENOMINATOR = 10000

// Order lifecycle
const STATUS_UNINIT = 0          // deployed, waiting for InitOrder from the factory
const STATUS_WAITING_WALLET = 1  // asked the jetton master for this order's jetton wallet
const STATUS_AWAITING_DEPOSIT = 2 // wallet known; waiting for the maker's exact deposit
const STATUS_ACTIVE = 3          // fillable
const STATUS_CLOSED = 5          // filled or cancelled; only Sweep is allowed

// Gas / value floors (nanoGRAM)
const ORDER_STORAGE_RESERVE = 50000000   // 0.05 GRAM kept on the order for rent
const JETTON_TRANSFER_VALUE = 80000000   // 0.08 GRAM attached to every jetton transfer
const FILL_GAS = 150000000               // 0.15 GRAM minimum on top of cost + taker fee
const CANCEL_GAS = 120000000             // 0.12 GRAM minimum for cancel / close / sweep
const DEPOSIT_FORWARD = 150000000       // 0.15 GRAM forwardTonAmount the site attaches to deposits
const DEPOSIT_RETURN_VALUE = 100000000  // a wrong deposit is sent back only if it carried >= 0.1 GRAM
const CREATE_VALUE = 250000000           // 0.25 GRAM minimum to create an order
const MIN_ORDER_PRICE = 1000000000       // 1 GRAM smallest whole-order price

// queryId high byte tags outgoing jetton transfers so bounces can be told apart
const QK_FILL = 1
const QK_CANCEL = 2
const QK_RETURN = 3
const QK_SWEEP = 4
