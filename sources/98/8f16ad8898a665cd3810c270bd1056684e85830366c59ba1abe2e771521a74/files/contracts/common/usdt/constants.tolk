const USDT_DEPOSIT_PREPARATION_OVERHEAD = grams("0.05")

// Sixteen committed contributor wallets can each deposit principal and fee.
const MAX_USDT_DEPOSITS = 32

const MAX_AUTOMATIC_USDT_ASSIGNMENT_ATTEMPTS = 2

const USDT_ASSIGNMENT_RETRY_TIMEOUT = 300

// Год даёт пользователю длинное окно для permissionless recovery, но не заставляет каждую сделку
// заранее оплачивать десятилетие хранения трёх контрактов. Поздний recovery может сам приложить
// TON до заморозки; этот reserve защищает обычный путь без дополнительной дозаправки.
const USDT_RECOVERY_RETENTION_SECONDS = 365 * 86400

const USDT_STORAGE_SIZE_LIMIT = 4096

const AUTOMATIC_USDT_RETRY_OVERHEAD = grams("0.02")
