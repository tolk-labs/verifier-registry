// Границы времени и кворума — ОСНОВНЫЕ (Acton.toml).
// Используются для пилота в тестнете и для основной сети.
// Контракты берут их через import "@bounds/bounds"; какой файл подставится,
// решает [import-mappings] bounds в манифесте.

const IS_FAST_BOUNDS = false

const HOUR = 3600
const DAY = 86400

const VOTING_DELAY_MIN = 24 * HOUR
const VOTING_DELAY_MAX = 168 * HOUR
const DURATION_BOUND_MIN = 3 * DAY
const DURATION_BOUND_MAX = 60 * DAY

// Финализация — не раньше, чем через час после конца голосования.
const FINALIZE_GRACE = 1 * HOUR

const MIN_VOTES_BOUND_MIN = 10

// Параметры, с которыми scripts/deploy.tolk разворачивает DAO (DAO.md, раздел 3).
const DEPLOY_VOTING_DELAY = 48 * HOUR
const DEPLOY_MIN_DURATION = 7 * DAY
const DEPLOY_MAX_DURATION = 30 * DAY
const DEPLOY_MIN_VOTES_FLOOR = 10
