// SPDX-License-Identifier: BUSL-1.1
import "./../utils.tolk";
import "errors";

// Maximum number of oracles the offchain reporting protocol is designed for
const MAX_NUM_ORACLES: int = 255;

const OCR_PLUGIN_TYPE_COMMIT: int = 0;
const OCR_PLUGIN_TYPE_EXECUTE: int = 1;


struct OCRConfig {
	configInfo: ConfigInfo;
	signers: map<uint256, uint8>;
	transmitters: map<address, uint8>;
}

fun newOCRConfig(): OCRConfig {
	return OCRConfig {
		configInfo: ConfigInfo{},
		signers: createEmptyMap(),
		transmitters: createEmptyMap()
	}
}


fun OCRConfig.assignSignerOracles(
	mutate self,
	signers: SnakedCell<uint256>
) {
	// We cannot validate that ed25519 public keys are valid on chain. For now we assume valid keys.
	var signersMap: map<uint256, uint8> = createEmptyMap<uint256, uint8>();
	var signersIt = signers.iter();
	var i = 0;
	while (!signersIt.empty()) {
		val signer = signersIt.next();
		assert(!signersMap.get(signer).isFound, MultiOCR3Base_Error.RepeatedSigners);
		i = i + 1;
		signersMap.set(
			signer,
			i
		);
	}
	self.signers = signersMap;
}

fun OCRConfig.assignTransmitterOracles(
	mutate self,
	transmitters: SnakedCell<address>,
) {
	var transmittersMap: map<address, uint8> = createEmptyMap<address, uint8>(); 
	var transmittersIt = transmitters.iter();
	var i = 0;
	while (!transmittersIt.empty()) {
		val transmitter = transmittersIt.next();
		assert(!transmittersMap.get(transmitter).isFound, MultiOCR3Base_Error.RepeatedTransmitters);
		i = i + 1;
		transmittersMap.set(
			transmitter,
			i
		);
	}
	self.transmitters = transmittersMap;
}

struct ConfigInfo {
	configDigest: uint256 = 0;
	bigF: uint8 = 0;
	n: uint8 = 0;
	isSignatureVerificationEnabled: bool = false;
}

struct SignatureEd25519 {
	signer: uint256
	r: uint256;
	s: uint256;
}

struct ReportContext {
	configDigest: uint256;
	_padding: bytes24;
	sequenceBytes: uint64
}
