// SPDX-License-Identifier: BUSL-1.1
import "./../utils.tolk";
import "types.tolk";
import "errors";


const OCR3BASE_CONFIG_SET_TOPIC: int = stringCrc32("OCR3Base_ConfigSet");
const OCR3BASE_TRANSMITTED: int = stringCrc32("OCR3Base_Transmitted");

/// @notice Event, triggers a new run of the offchain reporting protocol.
/// @param ocrPluginType OCR plugin type for which the config was set.
/// @param configDigest configDigest of this configuration.
/// @param signers ith element is address ith oracle uses to sign a report.
/// @param transmitters ith element is address ith oracle uses to transmit a report via the transmit method.
/// @param F maximum number of faulty/dishonest oracles the protocol can tolerate while still working correctly.
struct OCR3Base_ConfigSet {
    ocrPluginType: uint16;
    configDigest: uint256;
    signers: SnakedCell<uint256>;
    transmitters: SnakedCell<address>;
    bigF: uint8;
}


/// @notice Event, optionally emitted to indicate the latest configDigest and sequence number
/// for which a report was successfully transmitted. Alternatively, the contract may
/// use latestConfigDigestAndEpoch with scanLogs set to false.
struct OCR3Base_Transmitted {
   ocrPluginType: uint16;
   configDigest: uint256;
   sequenceNumber: uint64
}

/// @notice Sets offchain reporting protocol configuration incl. participating oracles.
/// NOTE: The OCR3 config must be sanity-checked against the home-chain registry configuration, to ensure home-chain
/// and remote-chain parity!
/// @param ocrConfigArgs OCR config update args.
/// @dev precondition number of transmitters should match the expected F/fChain relationship.
/// For transmitters, the function only validates that len(transmitters) > 0 && len(transmitters) <= MAX_NUM_ORACLES
/// && len(transmitters) <= len(signers) [if sig verification is enabled].
// 0x2B78359F = crc32('OCR3Base_SetOCR3Config')
struct (0x2B78359F) OCR3Base_SetOCR3Config {
    queryId: uint64;
    configDigest: uint256;
    ocrPluginType: uint16;
    bigF: uint8;
    isSignatureVerificationEnabled: bool;
    signers: SnakedCell<uint256>;
    transmitters: SnakedCell<address>;
}

struct OCR3Base {
    chainId: uint8;
    commit: Cell<OCRConfig>?;
	execute: Cell<OCRConfig>?;
}

fun OCR3Base.getConfig(self, ocrPluginType: uint16): OCRConfig? {
	if (ocrPluginType == OCR_PLUGIN_TYPE_COMMIT) {
		if (self.commit == null) {
			return null;
		}
		return self.commit!.load();

	} else if (ocrPluginType == OCR_PLUGIN_TYPE_EXECUTE) {
		if (self.execute == null) {
			return null;
		}
		return self.execute!.load();
	} else {
		throw MultiOCR3Base_Error.NonExistentOcrPluginType;
	}
}

fun OCR3Base.setOcr3Config(mutate self, msg: OCR3Base_SetOCR3Config) {
	assert(msg.bigF > 0, MultiOCR3Base_Error.BigFMustBePositive);

	var ocrConfig = self.getConfig(msg.ocrPluginType);
	if (ocrConfig == null) {
		ocrConfig = newOCRConfig();
	} 
	ocrConfig = ocrConfig!;

	// If F is 0, then the config is not yet set.
	if (ocrConfig.configInfo.bigF == 0) {
		ocrConfig.configInfo.isSignatureVerificationEnabled = msg.isSignatureVerificationEnabled;
	} else {
		assert(
			ocrConfig.configInfo.isSignatureVerificationEnabled == msg.isSignatureVerificationEnabled,
			MultiOCR3Base_Error.StaticConfigCannotBeChanged
		);
	}
	val transmitters_length = countAddresses(msg.transmitters);
	// val transmitters_length = msg.transmitters.iter().size(ADDR_KEY_LEN);

	assert(transmitters_length <= MAX_NUM_ORACLES, MultiOCR3Base_Error.TooManyTransmitters);
	assert(transmitters_length > 0, MultiOCR3Base_Error.NoTransmitters);
	
	if (msg.isSignatureVerificationEnabled) {
		val signers_length = msg.signers.iter().countBytes() / 32;
		assert(signers_length > 0, MultiOCR3Base_Error.NoSigners);
		assert(signers_length <= MAX_NUM_ORACLES, MultiOCR3Base_Error.TooManySigners);
		assert(signers_length > 3 * msg.bigF, MultiOCR3Base_Error.BigFTooHigh);
		assert(signers_length >= transmitters_length, MultiOCR3Base_Error.TooManyTransmitters);
		ocrConfig.configInfo.n = signers_length;
		ocrConfig.assignSignerOracles(msg.signers);
	}
	ocrConfig.assignTransmitterOracles(msg.transmitters);
	ocrConfig.configInfo.bigF = msg.bigF;
	ocrConfig.configInfo.configDigest = msg.configDigest;
	
	if (msg.ocrPluginType == OCR_PLUGIN_TYPE_COMMIT) {
		self.commit = ocrConfig.toCell();
	} else if (msg.ocrPluginType == OCR_PLUGIN_TYPE_EXECUTE) {
		self.execute = ocrConfig.toCell();
	}

	emit(OCR3BASE_CONFIG_SET_TOPIC, OCR3Base_ConfigSet {
			ocrPluginType: msg.ocrPluginType,
			configDigest: ocrConfig.configInfo.configDigest,
			signers: msg.signers,
			transmitters: msg.transmitters,
			bigF: ocrConfig.configInfo.bigF
		}
	);
}

fun OCR3Base.transmit(
    self,
    transmitter: address,
    ocrPluginType: int,
    reportContext: ReportContext,
    report: cell,
    signatures: SnakedCell<SignatureEd25519>,
) {
    var ocrConfig = self.getConfig(ocrPluginType);
    assert(ocrConfig != null, MultiOCR3Base_Error.NonExistentOcrPluginType);
    ocrConfig = ocrConfig!;
    var configInfo: ConfigInfo = ocrConfig.configInfo;
    
    // EVM checks transaction data length here, it's probably too expensive to do this in TON 
    
    assert(reportContext.configDigest == configInfo.configDigest, MultiOCR3Base_Error.ConfigDigestMismatch);
    
    // EVM checks assert_chain_not_forked, this is not necessary in TON
    
    val pluginTransmitters = ocrConfig.transmitters;

    assert(pluginTransmitters.get(transmitter).isFound, MultiOCR3Base_Error.UnauthorizedTransmitter);

    if (configInfo.isSignatureVerificationEnabled) {
    	var expectedSignatures = configInfo.bigF + 1;
		val signatures_length = signatures.iter().countBytes() / 96; //expensive
    	assert(signatures_length == expectedSignatures, MultiOCR3Base_Error.WrongNumberOfSignatures);
    	var hashedReport = self.hashReport(report, reportContext);
    	var pluginSigners = ocrConfig.signers;

    	self.verifySignature(pluginSigners, hashedReport, signatures);
    }

    emit(OCR3BASE_TRANSMITTED, OCR3Base_Transmitted {
	    ocrPluginType: ocrPluginType,
	    configDigest: reportContext.configDigest,
	    sequenceNumber: reportContext.sequenceBytes
    });
}

fun OCR3Base.hashReport(self, report: cell, reportContext: ReportContext): int {
	var data = beginCell()
		.storeRef(report)
		.storeUint(reportContext.configDigest, 256)
		.storeUint(0, 192) // Padding to 256 bits
		.storeUint(reportContext.sequenceBytes, 64)
		.endCell();
	return data.hash();
}

fun OCR3Base.verifySignature(
	self,
	signers: map<uint256, uint8>, // <signer -> index>
	hashedReport: uint256,
	signatures: SnakedCell<SignatureEd25519>
) {
	var seen = Bitmap256.new();
	var signaturesIt = signatures.iter(); 
	while (!signaturesIt.empty()) {
		val signature = signaturesIt.next();
		val signer = signature.signer;

		val entry = signers.get(signer);
		val authorized= entry.isFound;
		assert(authorized, MultiOCR3Base_Error.UnauthorizedSigner);
		val signerIndex = entry.loadValue();
		assert(isSignatureValid(hashedReport,signature.toCell().beginParse().skipBits(256), signer), MultiOCR3Base_Error.InvalidSignature);

		assert(!seen.has(signerIndex!), MultiOCR3Base_Error.NonUniqueSignatures);
		seen.set(signerIndex!);
	}
}
