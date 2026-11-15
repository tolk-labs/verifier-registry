/// Balance that a withdrawal leaves on the collection.
const MIN_COLLECTION_STORAGE = grams("0.02")

/// Balance that the deploy and transfer value checks leave on a wallet before gas.
const MIN_WALLET_STORAGE = grams("0.01")

/// The collection adds it to the wallet deploy message of a public deploy. It pays the deploy gas
/// of the wallet and the owner notification, which the wallet requires in addition to its storage
/// reserve.
const WALLET_DEPLOY_FEES = grams("0.001")

/// Smallest forward amount that still sends the owner a notification.
const MIN_FORWARD_AMOUNT = 1

/// Basis points in 100%: the reward is `deployPrice * referralBps / REFERRAL_BPS_DENOMINATOR`.
const REFERRAL_BPS_DENOMINATOR = 10000
