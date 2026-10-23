import "../../lib/utils"

const FeeQuoter_FACILITY_NAME = "link.chain.ton.ccip.FeeQuoter";
const FeeQuoter_FACILITY_ID = 344;  // (crc32(<facility>) % 640) + 10

struct TimestampedPrice {
    value: uint224;
    timestamp: uint32;
}

struct PriceUpdates {
    tokenPriceUpdates: SnakedCell<TokenPriceUpdate>;
    gasPriceUpdates: SnakedCell<GasPriceUpdate>;
}

struct TokenPriceUpdate {
    sourceToken: address; // This is the local token
    usdPerToken: uint224;
}

struct GasPriceUpdate {
    destChainSelector: uint64;
    executionGasPrice: uint112;
    dataAvailabilityGasPrice: uint112;
}

struct FeeQuoterDestChainConfig {
    isEnabled: bool;
    maxNumberOfTokensPerMsg: uint16;
    maxDataBytes: uint32;
    maxPerMsgGasLimit: uint32;
    destGasOverhead: uint32;
    destGasPerPayloadByteBase: uint8;
    destGasPerPayloadByteHigh: uint8;
    destGasPerPayloadByteThreshold: uint16;
    destDataAvailabilityOverheadGas: uint32;
    destGasPerDataAvailabilityByte: uint16;
    destDataAvailabilityMultiplierBps: uint16;

    chainFamilySelector: uint32; // 4 bytes

    defaultTokenFeeUsdCents: uint16;
    defaultTokenDestGasOverhead: uint32;
    defaultTxGasLimit: uint32;

    // Multiplier for gas costs, 1e18 based so 11e17 = 10% extra cost.
    gasMultiplierWeiPerEth: uint64;
    gasPriceStalenessThreshold: uint32;
    networkFeeUsdCents: uint32;
}

struct GasPrice {
    executionGasPrice: uint112;
    dataAvailabilityGasPrice: uint112;
    timestamp: uint64;
}

struct TokenTransferFeeConfig {
    isEnabled: bool;
    minFeeUsdCents: uint32;
    maxFeeUsdCents: uint32;
    deciBps: uint16;
    destGasOverhead: uint32;
    destBytesOverhead: uint32;
}

const VAL_1E5:  uint256 = 100000;
const VAL_1E14: uint256 = 100000000000000;
const VAL_1E16: uint256 = 10000000000000000;
const VAL_1E18: uint256 = 1000000000000000000;

  /// @dev Any2EVMRampMessage struct has 10 fields, including 3 variable unnested arrays, sender, data and tokenAmounts.
  /// Each variable array takes 1 more slot to store its length.
  /// When abi encoded, excluding array contents, Any2EVMMessage takes up a fixed number of 13 slots, 32 bytes each.
  /// Assume 1 slot for sender
  /// For structs that contain arrays, 1 more slot is added to the front, reaching a total of 15.
  /// The fixed bytes does not cover struct data (this is represented by MESSAGE_FIXED_BYTES_PER_TOKEN)
const TON_2_EVM_MESSAGE_FIXED_BYTES = 15 * 32;

const CCIP_LOCK_OR_BURN_V1_RET_BYTES = 32;

const CHAIN_FAMILY_SELECTOR_EVM:   uint32 = 0x2812d52c;
const CHAIN_FAMILY_SELECTOR_SVM:   uint32 = 0x1e10bdc4;
const CHAIN_FAMILY_SELECTOR_TVM:   uint32 = 0x647e2ba9;
const CHAIN_FAMILY_SELECTOR_APTOS: uint32 = 0xac77ffec;
const CHAIN_FAMILY_SELECTOR_SUI:   uint32 = 0xc4e05953;


// This represents FeeQuoter's DestChainConfig (not OnRamp)
struct DestChainConfig {
    config: FeeQuoterDestChainConfig;

    usdPerUnitGas: Cell<GasPrice>;

    tokenTransferFeeConfigs: map<address, TokenTransferFeeConfig>;
}

const SVM_EXTRA_ARGS_MAX_ACCOUNTS= 64;
const SVM_MESSAGING_ACCOUNTS_OVERHEAD = 2;
const SVM_ACCOUNT_BYTE_SIZE: uint256 = 32;
/// @dev The expected static payload size of a token transfer when Borsh encoded and submitted to SVM.
/// TokenPool extra data and offchain data sizes are dynamic, and should be accounted for separately.
const SVM_TOKEN_TRANSFER_DATA_OVERHEAD: uint256 = (4 + 32) // source_pool
+ 32 // token_address
+ 4 // gas_amount
+ 4 // extra_data overhead
+ 32 // amount
+ 32 // size of the token lookup table account
+ 32 // token-related accounts in the lookup table, over-estimated to 32, typically between 11 - 13
+ 32 // token account belonging to the token receiver, e.g ATA, not included in the token lookup table
+ 32 // per-chain token pool config, not included in the token lookup table
+ 32 // per-chain token billing config, not always included in the token lookup table
+ 32; // OffRamp pool signer PDA, not included in the token lookup table

// TBD this should live in a different file
const SUI_EXTRA_ARGS_MAX_RECEIVER_OBJECT_IDS = 64;
const SUI_MESSAGING_ACCOUNTS_OVERHEAD = 1;
const SUI_ACCOUNT_BYTE_SIZE: uint256 = 32;
/// @dev The expected static payload size of a token transfer when Borsh encoded and submitted to SUI.
/// TokenPool extra data and offchain data sizes are dynamic, and should be accounted for separately.
const SUI_TOKEN_TRANSFER_DATA_OVERHEAD: uint256 = (4 + 32) // source_pool
+ 32 // token_address
+ 4 // gas_amount
+ 4 // extra_data overhead
+ 32 // amount
+ 32 // size of the token lookup table account
+ 32 // token-related accounts in the lookup table, over-estimated to 32, typically between 11 - 13
+ 32 // token account belonging to the token receiver, e.g ATA, not included in the token lookup table
+ 32 // per-chain token pool config, not included in the token lookup table
+ 32; // per-chain token billing config, not always included in the token lookup table

struct UpdateTokenTransferFeeConfig {
    add: map<address, TokenTransferFeeConfig>; // token address -> config
    remove: SnakedCell<address>;
}

struct FeeToken {
    premiumMultiplierWeiPerEth: uint64
}

struct FeeQuoter_UpdateDestChainConfig {
    destChainSelector: uint64;
    destChainConfig: FeeQuoterDestChainConfig;
}

struct Fee {
    feeTokenAmount: coins; // fee value in fee token
    feeValueJuels: uint96; // fee value in juels
}