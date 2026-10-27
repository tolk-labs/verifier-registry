import "@contracts/common/nft/deposits"
import "@contracts/common/offer/wallets"
import "constants"
import "storage"

struct CertifiedExecutionCertificateDetails {
    contributorWallets: OfferWallets
    takerSettlementWallet: address
    items: ItemDeposits = []
    delivery: Cell<DeliveryCommitment>?
    // Binds participant/Telegram recipients agreed before payment without adding fake items.
    executionAgreementId: uint128? = null
    // Точный сбор подписан для выбранного состава; terms.takerTonFee ограничивает его сверху.
    takerTonFee: coins
}

// Подписывается hash всей cell. Верхний уровень намеренно помещается в одну cell, а два bounded
// словаря вынесены в details, чтобы wire shape не зависел от количества выбранных предметов.
struct CertifiedExecutionCertificate {
    domain: uint32
    schemaVersion: uint8
    escrow: address
    offerId: uint128
    offerExecutionNumber: uint32
    validUntil: uint32
    requirementCommitment: uint256
    details: Cell<CertifiedExecutionCertificateDetails>
}

struct (0x41434346) StartCertifiedOfferExecution {
    queryId: uint64
    signature: bits512
    signed: cell
    // Суммы не входят в подписанный certificate: certificate задаёт terms, а escrow сверяет
    // фактические deposits с неизменяемыми terms.
    paymentAmount: coins = 0
    sideFeeAmount: coins = 0
}

struct (0x464e4446) DepositCertifiedOfferPayment {
    queryId: uint64
    offerExecutionNumber: uint32
    paymentAmount: coins
    sideFeeAmount: coins = 0
}

struct (0x42555946) BuyCertifiedOffer {
    // "BUYF": атомарно связывает certificate и полную TON-оплату sale.
    queryId: uint64
    paymentAmount: coins
    signature: bits512
    signed: cell
}

struct CertifiedSettlementApprovalAuthorization {
    domain: uint32
    schemaVersion: uint8
    escrow: address
    offerId: uint128
    offerExecutionNumber: uint32
    issuedAt: uint32
    validUntil: uint32
    evidence: Cell<CertifiedSettlementApprovalEvidence>
}

struct CertifiedSettlementApprovalEvidence {
    certificateHash: uint256
    makerDeliveryCommitment: uint256?
    takerDeliveryCommitment: uint256?
}

struct CertifiedExecutionRejectionAuthorization {
    domain: uint32
    schemaVersion: uint8
    escrow: address
    offerId: uint128
    offerExecutionNumber: uint32
    certificateHash: uint256
    issuedAt: uint32
    validUntil: uint32
}

// Отдельный signed domain обязателен: обычную подпись rejection нельзя переиспользовать, чтобы
// терминально закрыть Offer. Команда применяется только к exact текущему execution attempt.
struct CertifiedExecutionRejectionAndCloseAuthorization {
    domain: uint32
    schemaVersion: uint8
    escrow: address
    offerId: uint128
    offerExecutionNumber: uint32
    certificateHash: uint256
    issuedAt: uint32
    validUntil: uint32
}

struct CertifiedCustodiedCancellationAuthorization {
    domain: uint32
    schemaVersion: uint8
    escrow: address
    offerId: uint128
    issuedAt: uint32
    validUntil: uint32
}

// Certifier подписывает только решение; caller оплачивает его доставку и не выбирает параметры.
struct (0x41554150) ApplyCertifiedSettlementApproval {
    queryId: uint64
    signature: bits512
    signed: Cell<CertifiedSettlementApprovalAuthorization>
}

struct (0x4155524a) ApplyCertifiedExecutionRejection {
    queryId: uint64
    signature: bits512
    signed: Cell<CertifiedExecutionRejectionAuthorization>
}

struct (0x41555243) ApplyCertifiedExecutionRejectionAndClose {
    queryId: uint64
    signature: bits512
    signed: Cell<CertifiedExecutionRejectionAndCloseAuthorization>
}

struct (0x524c4346) ReleaseCertifiedOfferExecutionAttempt {
    queryId: uint64
    offerExecutionNumber: uint32
}

struct (0x45585046) ExpireCertifiedOffer {
    queryId: uint64
}

struct (0x52534d46) ResumeCertifiedSettlement {
    queryId: uint64
}

// External liveness использует отдельные opcodes: sender и value внутренних команд несут
// полномочие либо бюджет и не должны случайно участвовать в contract-funded пути.
struct (0x58455846) TriggerCertifiedOfferExpiry {
    offerId: uint128
    expiresAt: uint32
}

struct (0x58524c46) TriggerCertifiedExpiredExecutionRelease {
    offerId: uint128
    offerExecutionNumber: uint32
}

struct (0x58415046) RelayCertifiedSettlementApproval {
    signature: bits512
    signed: Cell<CertifiedSettlementApprovalAuthorization>
}

struct (0x58524a46) RelayCertifiedExecutionRejection {
    signature: bits512
    signed: Cell<CertifiedExecutionRejectionAuthorization>
}

struct (0x58524a43) RelayCertifiedExecutionRejectionAndClose {
    signature: bits512
    signed: Cell<CertifiedExecutionRejectionAndCloseAuthorization>
}

struct (0x58434346) RelayCertifiedCustodiedCancellation {
    signature: bits512
    signed: Cell<CertifiedCustodiedCancellationAuthorization>
}

fun hasCertifiedExecutionDomain(signed: cell): bool {
    var body = signed.beginParse();
    if (body.remainingBitsCount() < 32 + 8) {
        return false;
    }
    return body.loadUint(32) == CERTIFIED_EXECUTION_DOMAIN &&
        body.loadUint(8) == CERTIFIED_EXECUTION_SCHEMA_VERSION;
}
