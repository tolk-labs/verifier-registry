// NFT-контракты произвольны, поэтому на каждый transfer закладывается консервативный forward.
const NFT_TRANSFER_VALUE = grams("0.05")

const MAX_AUTOMATIC_NFT_DELIVERY_ATTEMPTS = 1

const UNEXPECTED_NFT_RECOVERY_DELAY = 604800

// Opcode нужен, чтобы распознать bounced-передачу NFT в onBouncedMessage.
const NFT_TRANSFER_OP = 0x5fcc3d14
