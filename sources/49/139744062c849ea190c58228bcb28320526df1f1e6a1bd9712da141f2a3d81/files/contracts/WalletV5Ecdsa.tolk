// Wallet V5 R1 with ECDSA (secp256k1) signature support — Tolk implementation
//
// Port of contracts/wallet_v5_ecdsa.fc (which is based on the official
// ton-blockchain/wallet-contract-v5 FunC implementation). Tolk idioms follow
// the official Tolk wallet from ton-blockchain/acton-contracts (w5.2).
//
// Extensions over the original wallet v5:
//   * Two new operation prefixes for requests signed with ECDSA (secp256k1):
//       external: 0x73696765 ("sige"),  internal: 0x73696E65 ("sine")
//     The original Ed25519 prefixes ("sign"/"sint") keep working unchanged,
//     so both keys can authorize requests (hybrid mode).
//   * ECDSA signature wire format (512 bits, same slot size as Ed25519):
//       r            : uint256  — first part of the signature
//       v*2^255 + s  : uint256  — v is the recovery parity of R.y (0 or 1),
//                                 s is the canonical (low-s) second part, s < 2^255
//     The signed message is the same as for Ed25519: the 256-bit hash of the
//     request cell (op + wallet_id + valid_until + seqno + actions).
//   * The ECDSA public key is stored in the data cell as an uncompressed
//     curve point (x, y) — two uint256 values appended after the Ed25519 key,
//     before the extensions dictionary.
//   * Signature verification is auto-selecting:
//       - on TVM with global version >= 4 the native ECRECOVER opcode is used
//         (activated in the network on Dec 20, 2023);
//       - on older TVM versions a pure-Tolk secp256k1 verifier is used
//         (significantly more expensive in gas, see the notes below).
//     The version is read from config parameter 8 (GlobalVersion).
//
// Data cell layout:
//   is_signature_allowed:bool  seqno:uint32  wallet_id:uint32
//   ed25519_public_key:uint256  ecdsa_public_key_x:uint256  ecdsa_public_key_y:uint256
//   extensions:dict(256 -> int1)
//
// Request layout (external and internal signed requests):
//   op:uint32  wallet_id:uint32  valid_until:uint32  seqno:uint32  <actions>
//   signature:512   (Ed25519 for "sign"/"sint", ECDSA r/v/s for "sige"/"sine")

import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"

contract WalletV5Ecdsa {
    author: "wallet-v5-ecdsa"
    version: "1.0.0"
    description: "Wallet V5 R1 with hybrid Ed25519 + ECDSA (secp256k1) authorization"
    storage: Storage
    incomingMessages: AllowedMessageToWalletV5Ecdsa
    incomingExternal: AllowedExternalMessageToWalletV5Ecdsa
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SIZE_SIGNATURE = 512
const SIZE_SEQNO = 32
const SIZE_WALLET_ID = 32
const SIZE_PUBLIC_KEY = 256
const SIZE_ECDSA_PUBLIC_KEY = 256
const SIZE_MESSAGE_OPERATION_PREFIX = 32
const SIZE_ADDRESS_HASH = 256
const SIZE_QUERY_ID = 64
const SIZE_MESSAGE_FLAGS = 4

// number of bits in the data cell before the extensions dictionary
const SIZE_DATA_BEFORE_EXTENSIONS = 1 + SIZE_SEQNO + SIZE_WALLET_ID + SIZE_PUBLIC_KEY + SIZE_ECDSA_PUBLIC_KEY + SIZE_ECDSA_PUBLIC_KEY

const PREFIX_SIGNED_EXTERNAL = 0x7369676E           // "sign" — Ed25519 (original)
const PREFIX_SIGNED_INTERNAL = 0x73696E74           // "sint" — Ed25519 (original)
const PREFIX_SIGNED_EXTERNAL_ECDSA = 0x73696765     // "sige" — ECDSA secp256k1 (new)
const PREFIX_SIGNED_INTERNAL_ECDSA = 0x73696E65     // "sine" — ECDSA secp256k1 (new)
const PREFIX_EXTENSION_ACTION = 0x6578746E          // "extn"

// minimum bits of a signed request body: op + wallet_id + valid_until + seqno + signature
const MIN_SIGNED_BODY_BITS = SIZE_MESSAGE_OPERATION_PREFIX + SIZE_WALLET_ID + 32 + SIZE_SEQNO + SIZE_SIGNATURE

enum Errors {
    SignatureDisabled = 132
    InvalidSeqno = 133
    InvalidWalletId = 134
    InvalidSignature = 135
    Expired = 136
    ExternalSendMessageMustHaveIgnoreErrorsSendMode = 137
    InvalidMessageOperation = 138
    AddExtension = 139
    RemoveExtension = 140
    UnsupportedAction = 141
    DisableSignatureWhenExtensionsIsEmpty = 142
    ThisSignatureModeAlreadySet = 143
    RemoveLastExtensionWhenSignatureDisabled = 144
    ExtensionWrongWorkchain = 145
    OnlyExtensionCanChangeSignatureMode = 146
    InvalidC5 = 147
    EcdsaKeyNotSet = 148
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

// The extensions dictionary is handled at the raw-dict level (like the original
// FunC wallet) so that the data cell wire format stays byte-compatible with the
// FunC implementation: dict = 1 "has-dict" bit + optional root cell reference.
// Tolk's `map` struct serialization cannot be used here, because a mutation of a
// `map` field through a lazy-loaded struct does not persist (acton 1.2.1).

struct Storage {
    isSignatureAllowed: bool
    seqno: uint32
    subwalletId: uint32
    publicKey: uint256
    ecdsaPublicKeyX: uint256    // (0, 0) means that the ECDSA key is not set
    ecdsaPublicKeyY: uint256
    // extensions dict is stored in the same cell after the fields above and is
    // handled manually (raw dict API), not through this struct
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

type OutActionsCell = cell

// "extra actions" are represented in a snake format: "data".ref("data.ref("data"...))
type SnakedExtraActions = RemainingBitsAndRefs

fun SnakedExtraActions.hasNext(self): bool {
    return self.remainingRefsCount() != 0;
}

fun SnakedExtraActions.getNext(self): SnakedExtraActions {
    return self.preloadRef().beginParse();
}

struct (0x6578746E) ExtensionActionRequest {
    queryId: uint64
    @abi.clientType(Cell<OutActionWithSendMessageOnly>?)
    outActions: OutActionsCell?
    hasExtraActions: bool
    extraActions: SnakedExtraActions
}

struct (0x7369676E) ExternalSignedRequest {
    walletId: uint32
    validUntil: uint32
    seqno: uint32
    @abi.clientType(Cell<OutActionWithSendMessageOnly>?)
    outActions: OutActionsCell?
    hasExtraActions: bool
    extraActions: SnakedExtraActions
    // ends with a signature (512 bits), but it's parsed and compared separately
}

struct (0x73696765) ExternalSignedRequestEcdsa {
    walletId: uint32
    validUntil: uint32
    seqno: uint32
    @abi.clientType(Cell<OutActionWithSendMessageOnly>?)
    outActions: OutActionsCell?
    hasExtraActions: bool
    extraActions: SnakedExtraActions
    // ends with an ECDSA signature (512 bits), parsed and compared separately
}

struct (0x73696E74) InternalSignedRequest {
    walletId: uint32
    validUntil: uint32
    seqno: uint32
    @abi.clientType(Cell<OutActionWithSendMessageOnly>?)
    outActions: OutActionsCell?
    hasExtraActions: bool
    extraActions: SnakedExtraActions
    // ends with a signature (512 bits), but it's parsed and compared separately
}

struct (0x73696E65) InternalSignedRequestEcdsa {
    walletId: uint32
    validUntil: uint32
    seqno: uint32
    @abi.clientType(Cell<OutActionWithSendMessageOnly>?)
    outActions: OutActionsCell?
    hasExtraActions: bool
    extraActions: SnakedExtraActions
    // ends with an ECDSA signature (512 bits), parsed and compared separately
}

type AllowedMessageToWalletV5Ecdsa = ExtensionActionRequest | InternalSignedRequest | InternalSignedRequestEcdsa
type AllowedExternalMessageToWalletV5Ecdsa = ExternalSignedRequest | ExternalSignedRequestEcdsa

/// "OutActionList" is what's pushed to c5.
struct (0x0ec3c86d) OutActionWithSendMessageOnly {
    prev: Cell<OutActionWithSendMessageOnlyOrEmpty>
    sendMode: uint8
    outMsg: cell
}

type OutActionWithSendMessageOnlyOrEmpty = OutActionWithSendMessageOnly | void

struct (0x02) AddExtensionExtraAction {
    // any_address (LDMSGADDR) instead of address (LDSTDADDR): LDSTDADDR is a
    // TVM v5 opcode missing in some emulators; LDMSGADDR is supported everywhere.
    addr: any_address
}

struct (0x03) RemoveExtensionExtraAction {
    addr: any_address
}

struct (0x04) SetSignatureAllowedExtraAction {
    allowSignature: bool
}

type ExtraAction = AddExtensionExtraAction | RemoveExtensionExtraAction | SetSignatureAllowedExtraAction

// ---------------------------------------------------------------------------
// C5 (out actions) validation
// ---------------------------------------------------------------------------

/// put a raw list of OutActions to C5 register
// acton-disable-next-line asm-function-missing-safety-comment
fun setTvmRegisterC5(actionList: cell): void
    asm "c5 POP"

/// transform an ordinary or exotic cell into a slice, as if it were an ordinary cell
// acton-disable-next-line asm-function-missing-safety-comment
fun beginParseAllowExotic(c: cell): slice
    asm "XCTOS" "DROP"

/// verify a cell containing OutActionList that it contains only "send message" actions
fun verifyC5Actions(c5: cell, isExternal: bool): cell {
    var count = 0;

    var cs = beginParseAllowExotic(c5);
    do {
        // these checks could be cheaper in terms of gas if we just try to parse cs;
        // but we want to throw exactly `Errors.InvalidC5` (not `9` "cell underflow")
        val (nBits, nRefs) = cs.remainingBitsAndRefsCount();
        assert (nRefs == 2) throw Errors.InvalidC5;
        assert (nBits == 32 + 8) throw Errors.InvalidC5;

        val outAction = lazy OutActionWithSendMessageOnly.fromSlice(
            cs,
            { throwIfOpcodeDoesNotMatch: Errors.InvalidC5 },
        );

        if (isExternal) {
            assert (
                (outAction.sendMode & SEND_MODE_IGNORE_ERRORS) != 0
            ) throw Errors.ExternalSendMessageMustHaveIgnoreErrorsSendMode;
        }

        cs = beginParseAllowExotic(outAction.prev);
        count += 1;
    } while (!cs.isEmpty());

    assert (count <= 255) throw Errors.InvalidC5;
    return c5;
}

// ---------------------------------------------------------------------------
// Extended actions (add/remove extensions, enable/disable signatures)
// ---------------------------------------------------------------------------

/// The 1-bit value stored for every extension in the dict (same as the FunC
/// begin_cell().store_int(-1, 1)). Written in raw asm on purpose: the Tolk
/// optimizer fuses beginCell().storeInt(-1,1).endCell().beginParse() into the
/// newer BTOS opcode, which is missing in some TVM emulators.
fun extensionDictValue(): slice
    // acton-disable-next-line asm-function-missing-safety-comment
    asm "b{1} PUSHSLICE"

fun processExtraActions(cs: slice, isExtension: bool) {
    while (true) {
        val action = lazy ExtraAction.fromSlice(cs);
        match (action) {
            AddExtensionExtraAction => {
                val (extensionWorkchain, extensionAddrHash) = action.addr.getWorkchainAndHash();
                val myWorkchain = contract.getAddress().getWorkchain();
                assert (myWorkchain == extensionWorkchain) throw Errors.ExtensionWrongWorkchain;

                var dataCs = contract.getData().beginParse();
                val head = dataCs.loadBits(SIZE_DATA_BEFORE_EXTENSIONS);
                var dict = dataCs.loadDict();
                val (_, exists) = dict.uDictGet(SIZE_ADDRESS_HASH, extensionAddrHash);
                assert (!exists) throw Errors.AddExtension;
                dict.uDictSet(SIZE_ADDRESS_HASH, extensionAddrHash, extensionDictValue());
                var b = beginCell();
                b.storeSlice(head);
                b.storeDict(dict);
                contract.setData(b.endCell());
            }

            RemoveExtensionExtraAction => {
                val (extensionWorkchain, extensionAddrHash) = action.addr.getWorkchainAndHash();
                val myWorkchain = contract.getAddress().getWorkchain();
                assert (myWorkchain == extensionWorkchain) throw Errors.ExtensionWrongWorkchain;

                var dataCs = contract.getData().beginParse();
                val head = dataCs.loadBits(SIZE_DATA_BEFORE_EXTENSIONS);
                var dict = dataCs.loadDict();
                val (_, exists) = dict.uDictGet(SIZE_ADDRESS_HASH, extensionAddrHash);
                assert (exists) throw Errors.RemoveExtension;
                dict.uDictDelete(SIZE_ADDRESS_HASH, extensionAddrHash);
                // if signatures are disabled, the last extension cannot be removed
                val isSignatureAllowed = head.preloadInt(1) == -1;
                if (!isSignatureAllowed) {
                    assert (!dict.dictIsEmpty()) throw Errors.RemoveLastExtensionWhenSignatureDisabled;
                }
                var b = beginCell();
                b.storeSlice(head);
                b.storeDict(dict);
                contract.setData(b.endCell());
            }

            SetSignatureAllowedExtraAction => {
                assert (isExtension) throw Errors.OnlyExtensionCanChangeSignatureMode;

                var dataCs = contract.getData().beginParse();
                val isSignatureAllowed = dataCs.loadBool();
                assert (
                    isSignatureAllowed != action.allowSignature
                ) throw Errors.ThisSignatureModeAlreadySet;
                if (!action.allowSignature) {
                    // the "has-dict" flag of the extensions dict is the last bit of the storage
                    var skipCs = dataCs;
                    skipCs.skipBits(SIZE_SEQNO + SIZE_WALLET_ID + SIZE_PUBLIC_KEY + SIZE_ECDSA_PUBLIC_KEY + SIZE_ECDSA_PUBLIC_KEY);
                    val isExtensionsNotEmpty = skipCs.preloadInt(1) == -1;
                    assert (isExtensionsNotEmpty) throw Errors.DisableSignatureWhenExtensionsIsEmpty;
                }
                var b = beginCell();
                b.storeBool(action.allowSignature);
                b.storeSlice(dataCs);  // seqno, wallet_id, ed25519_key, ecdsa keys, extensions dict
                contract.setData(b.endCell());
            }

            else => throw Errors.UnsupportedAction,
        }
        if (cs.remainingRefsCount() == 0) {
            return;
        }
        cs = cs.loadRef().beginParse();
    }
}

fun processActions(cs: slice, isExternal: bool, isExtension: bool) {
    val outActions = cs.loadMaybeRef();
    if (outActions != null) {
        // Simply set the C5 register with all pre-computed actions after verification:
        setTvmRegisterC5(verifyC5Actions(outActions, isExternal));
    }
    val hasExtraActions = cs.loadBool();
    if (!hasExtraActions) {
        return;
    }
    processExtraActions(cs, isExtension);
}

// ---------------------------------------------------------------------------
// secp256k1 pure-Tolk verifier (fallback for TVM without ECRECOVER)
// ---------------------------------------------------------------------------

const ECDSA_P    = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
const ECDSA_N    = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
const ECDSA_C1P  = 0x1000003D1                            // 2^256 mod P
const ECDSA_C1N  = 0x14551231950B75FC4402DA1732FC9BEBF    // 2^256 mod N
const ECDSA_GX   = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
const ECDSA_GY   = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
const ECDSA_M128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF     // low 128-bit mask
const ECDSA_M192 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF     // low 192-bit mask
const ECDSA_S_MASK = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF  // low 255-bit mask

// TVM integers are signed 257-bit (-2^256 <= x < 2^256), so a product of two
// 256-bit numbers would overflow. All modular multiplications below are done
// through 128-bit halves using the identity 2^256 mod m == c1 (m is either
// ECDSA_P or ECDSA_N), and all modular additions go through ecAddmod which
// never leaves the TVM integer range.

/// (x + y) mod m for 0 <= x, y < m < 2^256 — overflow-safe
fun ecAddmod(x: int, y: int, m: int): int {
    val d = m - y;
    if (x >= d) {
        return x - d;
    }
    return x + y;
}

/// (x - y) mod m for 0 <= x, y < m < 2^256 — overflow-safe
fun ecSubmod(x: int, y: int, m: int): int {
    if (x >= y) {
        return x - y;
    }
    return x - y + m;
}

/// (x * 2^64) mod m, for 0 <= x < m < 2^256 and c1 = 2^256 mod m < 2^129.
/// Note: for the curve order n the constant c1 = 2^256 - n is 129 bits long,
/// so the shift is applied in 64-bit steps: x >> 192 < 2^64 and thus
/// x1 * c1 < 2^193 — the product always stays inside the TVM integer range.
fun ecMul64mod(x: int, m: int, c1: int): int {
    val x1 = x >> 192;
    val x0 = x & ECDSA_M192;
    val p1 = (x1 * c1) % m;
    val p2 = (x0 << 64) % m;
    return ecAddmod(p1, p2, m);
}

/// (x * 2^128) mod m, for 0 <= x < m < 2^256
fun ecSh128(x: int, m: int, c1: int): int {
    return ecMul64mod(ecMul64mod(x, m, c1), m, c1);
}

/// (a * b) mod m, for 0 <= a, b < 2^256 and c1 = 2^256 mod m < 2^129
fun ecMulmod(a: int, b: int, m: int, c1: int): int {
    val a1 = a >> 128;
    val a0 = a & ECDSA_M128;
    val b1 = b >> 128;
    val b0 = b & ECDSA_M128;
    val t1 = a1 * b1;
    val t2 = a1 * b0;
    val t3 = a0 * b1;
    val t4 = a0 * b0;
    // a*b == t1*2^256 + (t2 + t3)*2^128 + t4  (mod m)
    val r1 = ecMul64mod(ecMul64mod(ecMul64mod(ecMul64mod(t1 % m, m, c1), m, c1), m, c1), m, c1);
    val r2 = ecSh128(ecAddmod(t2 % m, t3 % m, m), m, c1);
    val r4 = t4 % m;
    return ecAddmod(ecAddmod(r1, r2, m), r4, m);
}

/// Modular arithmetic in [0, ECDSA_P) — inputs must be reduced
fun ecAddP(x: int, y: int): int {
    return ecAddmod(x, y, ECDSA_P);
}

fun ecSubP(x: int, y: int): int {
    return ecSubmod(x, y, ECDSA_P);
}

fun ecDblP(x: int): int {
    return ecAddmod(x, x, ECDSA_P);
}

fun ecMul8P(x: int): int {
    val x2 = ecDblP(x);
    val x4 = ecDblP(x2);
    return ecDblP(x4);
}

/// Jacobian point doubling on secp256k1 (a = 0).
/// Point (x, y, z) is in Jacobian coordinates, z == 0 means the point at infinity.
/// Formulas: M = 3*X^2, S = 4*X*Y^2, X3 = M^2 - 2S, Y3 = M*(S - X3) - 8*Y^4, Z3 = 2*Y*Z
fun ecDouble(x1: int, y1: int, z1: int): (int, int, int) {
    if (y1 == 0) {
        return (0, 1, 0);
    }
    val a = ecMulmod(x1, x1, ECDSA_P, ECDSA_C1P);
    val b = ecMulmod(y1, y1, ECDSA_P, ECDSA_C1P);
    val c = ecMulmod(b, b, ECDSA_P, ECDSA_C1P);
    val t = ecAddP(x1, b);
    val t2 = ecMulmod(t, t, ECDSA_P, ECDSA_C1P);
    // (X1 + B)^2 - A - C == 2*X1*B, so S = 2 * (t2 - a - c) = 4*X1*Y1^2
    val s = ecDblP(ecSubP(ecSubP(t2, a), c));
    val m = ecAddP(ecDblP(a), a);
    val f = ecMulmod(m, m, ECDSA_P, ECDSA_C1P);
    val x3 = ecSubP(f, ecDblP(s));
    val y3 = ecSubP(ecMulmod(m, ecSubP(s, x3), ECDSA_P, ECDSA_C1P), ecMul8P(c));
    val z3 = ecDblP(ecMulmod(y1, z1, ECDSA_P, ECDSA_C1P));
    return (x3, y3, z3);
}

/// Jacobian + affine point addition (P1 + (x2, y2)), Z2 = 1.
/// Formulas: H = x2*Z1^2 - X1, r = 2*(y2*Z1^3 - Y1), X3 = r^2 - J - 2V,
///           Y3 = r*(V - X3) - 2*Y1*J, Z3 = 2*Z1*H, I = (2H)^2, J = H*I, V = X1*I
fun ecAddMixed(x1: int, y1: int, z1: int, x2: int, y2: int): (int, int, int) {
    if (z1 == 0) {
        return (x2, y2, 1);
    }
    val z1z1 = ecMulmod(z1, z1, ECDSA_P, ECDSA_C1P);
    val u2 = ecMulmod(x2, z1z1, ECDSA_P, ECDSA_C1P);
    val s2 = ecMulmod(y2, ecMulmod(z1, z1z1, ECDSA_P, ECDSA_C1P), ECDSA_P, ECDSA_C1P);
    val h = ecSubP(u2, x1);
    val r = ecDblP(ecSubP(s2, y1));
    if (h == 0) {
        // same point -> doubling, opposite points -> infinity
        if (r == 0) {
            return ecDouble(x1, y1, z1);
        } else {
            return (0, 1, 0);
        }
    }
    val hh = ecMulmod(h, h, ECDSA_P, ECDSA_C1P);
    val i = ecDblP(ecDblP(hh));
    val j = ecMulmod(h, i, ECDSA_P, ECDSA_C1P);
    val v = ecMulmod(x1, i, ECDSA_P, ECDSA_C1P);
    val x3 = ecSubP(ecSubP(ecMulmod(r, r, ECDSA_P, ECDSA_C1P), j), ecDblP(v));
    val y3 = ecSubP(ecMulmod(r, ecSubP(v, x3), ECDSA_P, ECDSA_C1P), ecDblP(ecMulmod(y1, j, ECDSA_P, ECDSA_C1P)));
    val z3 = ecDblP(ecMulmod(z1, h, ECDSA_P, ECDSA_C1P));
    return (x3, y3, z3);
}

/// Simultaneous scalar multiplication k1*G + k2*Q (0 <= k1, k2 < 2^256)
fun ecMul2(k1: int, k2: int, qx: int, qy: int): (int, int, int) {
    var x = 0;
    var y = 1;
    var z = 0;
    var i = 255;
    while (i >= 0) {
        (x, y, z) = ecDouble(x, y, z);
        if (((k1 >> i) & 1) != 0) {
            (x, y, z) = ecAddMixed(x, y, z, ECDSA_GX, ECDSA_GY);
        }
        if (((k2 >> i) & 1) != 0) {
            (x, y, z) = ecAddMixed(x, y, z, qx, qy);
        }
        i -= 1;
    }
    return (x, y, z);
}

/// (base^exp) mod m by square-and-multiply, 0 <= exp < 2^256
fun ecPowmod(base: int, exp: int, m: int, c1: int): int {
    var result = 1;
    var i = 255;
    while (i >= 0) {
        result = ecMulmod(result, result, m, c1);
        if (((exp >> i) & 1) != 0) {
            result = ecMulmod(result, base, m, c1);
        }
        i -= 1;
    }
    return result;
}

/// Pure-Tolk ECDSA verification (secp256k1): does e, r, s match the public key (px, py)?
/// Expects 0 < r < N, 0 < s < N, e is the signed 256-bit hash. The parity bit v
/// (parity of R.y) is checked as well, so both verification paths behave identically.
fun checkSignatureEcdsaFallback(e: int, r: int, s: int, v: int, px: int, py: int): bool {
    if (r <= 0 || r >= ECDSA_N || s <= 0 || s >= ECDSA_N) {
        return false;
    }
    if (px >= ECDSA_P || py >= ECDSA_P) {
        return false;
    }
    // the public key must lie on the curve: y^2 == x^3 + 7 (mod P)
    val yy = ecMulmod(py, py, ECDSA_P, ECDSA_C1P);
    val xxx = ecMulmod(ecMulmod(px, px, ECDSA_P, ECDSA_C1P), px, ECDSA_P, ECDSA_C1P);
    if (ecSubP(ecAddP(xxx, 7), yy) != 0) {
        return false;
    }
    // w = s^-1 mod N (N is prime, Fermat's little theorem)
    val w = ecPowmod(s, ECDSA_N - 2, ECDSA_N, ECDSA_C1N);
    // R = (e*w mod N)*G + (r*w mod N)*Q, valid iff R.x mod N == r
    val u1 = ecMulmod(e % ECDSA_N, w, ECDSA_N, ECDSA_C1N);
    val u2 = ecMulmod(r, w, ECDSA_N, ECDSA_C1N);
    val (rx, ry, rz) = ecMul2(u1, u2, px, py);
    if (rz == 0) {
        return false;
    }
    // affine conversion of the result point
    val zi = ecPowmod(rz, ECDSA_P - 2, ECDSA_P, ECDSA_C1P);
    val z2 = ecMulmod(zi, zi, ECDSA_P, ECDSA_C1P);
    val ax = ecMulmod(rx, z2, ECDSA_P, ECDSA_C1P);
    val ay = ecMulmod(ry, ecMulmod(z2, zi, ECDSA_P, ECDSA_C1P), ECDSA_P, ECDSA_C1P);
    if (((ax % ECDSA_N) == r) && ((ay & 1) == v)) {
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// TVM version detection and the native ECDSA path
// ---------------------------------------------------------------------------

/// Global TVM version from config parameter 8 (GlobalVersion).
/// TLB: capabilities#c4 version:uint32 capabilities:uint64 = GlobalVersion;
///      _ GlobalVersion = ConfigParam 8;   (all zero if absent)
fun globalTvmVersion(): int {
    val cc = blockchain.configParam(8);
    if (cc == null) {
        return 0;
    }
    var cs = cc.beginParse();
    if (cs.remainingBitsCount() < 32) {
        return 0;
    }
    if (cs.remainingBitsCount() >= 104) {
        cs.skipBits(8);    // skip the capabilities#c4 constructor tag
    }
    return cs.loadUint(32);
}

/// ECRECOVER (F912): recovers a secp256k1 public key from a signature.
/// Stack: consumes s, r, v, hash (top to bottom); returns h, x, y, -1 on success
/// or a single 0 on failure. The asm words below normalize the stack so that
/// Tolk always gets four values (h, x, y, ok) with ok == -1 or 0:
///   * on success ECRECOVER leaves (-1, y, x, h) which is the exact layout of
///     the declared (h, x, y, ok) return;
///   * on failure it leaves a single 0, and the IFNOTJMP continuation pads the
///     stack with three zeros.
/// This opcode requires TVM global version >= 4. It must only be called after
/// a globalTvmVersion() check, otherwise old validators would abort the
/// transaction with an "invalid opcode" exception.
fun ecdsaEcrecover(hash: int, v: int, r: int, s: int): (int, int, int, int)
    // acton-disable-next-line asm-function-missing-safety-comment
    asm "ECRECOVER DUP IFNOTJMP:<{ DROP ZERO ZERO ZERO }>"

/// ECDSA (secp256k1) verification of `signature` (512 bits) over 256-bit `hash`
/// against the public key (pubX, pubY). Returns true on success.
/// Auto-selects the native ECRECOVER path or the pure-Tolk fallback.
fun checkSignatureEcdsa(hash: int, signature: slice, pubX: int, pubY: int): bool {
    var sig = signature;
    val r = sig.loadUint(SIZE_PUBLIC_KEY);
    val secondWord = sig.loadUint(SIZE_PUBLIC_KEY);
    val v = secondWord >> 255;
    val s = secondWord & ECDSA_S_MASK;
    if (r == 0 || s == 0) {
        return false;
    }
    if (pubX == 0 && pubY == 0) {
        return false;    // ECDSA key is not set
    }
    if (globalTvmVersion() >= 4) {
        val (h, x, y, ok) = ecdsaEcrecover(hash, v, r, s);
        if (ok != -1) {
            return false;
        }
        if (x == pubX) {
            if (y == pubY) {
                return true;
            }
        }
        return false;
    }
    return checkSignatureEcdsaFallback(hash, r, s, v, pubX, pubY);
}

/// Hash of a slice (bits AND refs) — the exact equivalent of the FunC
/// `slice_hash` primitive (HASHSU). Deliberately NOT slice.hash() (HASHBU):
/// HASHBU is a newer TVM opcode missing in some emulators, and the Tolk
/// optimizer fuses any builder-chain form back into it.
fun sliceCellHash(s: slice): uint256
    // acton-disable-next-line asm-function-missing-safety-comment
    asm "HASHSU"

// ---------------------------------------------------------------------------
// Wallet logic (based on the original wallet v5, with the data layout extended)
// ---------------------------------------------------------------------------

/// Processes a signed request (external or internal, Ed25519 or ECDSA).
/// `cs` here is the raw message body; the signature is its last 512 bits.
fun processSignedRequest(inMsgBody: slice, isExternal: bool, isEcdsa: bool) {
    val signature = inMsgBody.getLastBits(SIZE_SIGNATURE);
    var signedSlice = inMsgBody.removeLastBits(SIZE_SIGNATURE);
    // NOTE: Tolk's skipBits MUTATES the receiver (unlike FunC's skip_bits which
    // returns a new slice), so it must be applied to a copy of signedSlice —
    // otherwise the hash below would be computed over the body without the op prefix.
    var cs = signedSlice;
    cs.skipBits(SIZE_MESSAGE_OPERATION_PREFIX);  // skip the operation prefix
    val walletId = cs.loadUint(SIZE_WALLET_ID);
    val validUntil = cs.loadUint(32);
    val seqno = cs.loadUint(SIZE_SEQNO);

    var dataSlice = contract.getData().beginParse();
    val isSignatureAllowed = dataSlice.loadBool();
    val storedSeqno = dataSlice.loadUint(SIZE_SEQNO);
    var dataTail = dataSlice;  // wallet_id, ed25519_key, ecdsa keys, extensions dict
    val storedWalletId = dataSlice.loadUint(SIZE_WALLET_ID);
    val publicKey = dataSlice.loadUint(SIZE_PUBLIC_KEY);
    val ecdsaPublicKeyX = dataSlice.loadUint(SIZE_ECDSA_PUBLIC_KEY);
    val ecdsaPublicKeyY = dataSlice.loadUint(SIZE_ECDSA_PUBLIC_KEY);
    // the first bit of the remaining tail is the "has-dict" flag of the extensions dict
    val isExtensionsNotEmpty = dataSlice.preloadInt(1) == -1;

    var signatureIsValid = false;
    if (isEcdsa) {
        if (ecdsaPublicKeyX == 0 && ecdsaPublicKeyY == 0) {
            // the ECDSA key was never installed in this wallet
            if (isExternal) {
                throw Errors.EcdsaKeyNotSet;
            } else {
                return;
            }
        }
        signatureIsValid = checkSignatureEcdsa(sliceCellHash(signedSlice), signature, ecdsaPublicKeyX, ecdsaPublicKeyY);
    } else {
        signatureIsValid = isSignatureValid(sliceCellHash(signedSlice), signature, publicKey as uint256);
    }
    if (!signatureIsValid) {
        if (isExternal) {
            throw Errors.InvalidSignature;
        } else {
            return;
        }
    }

    // In case the wallet application has initially, by mistake, deployed a contract
    // with the wrong bit (signature is forbidden and extensions are empty) — we allow
    // such a contract to work.
    assert (
        isSignatureAllowed || !isExtensionsNotEmpty
    ) throw Errors.SignatureDisabled;
    assert (seqno == storedSeqno) throw Errors.InvalidSeqno;
    assert (walletId == storedWalletId) throw Errors.InvalidWalletId;
    assert (validUntil > blockchain.now()) throw Errors.Expired;

    if (isExternal) {
        acceptExternalMessage();
    }

    // Store and commit the seqno increment to prevent replays even if the subsequent requests fail.
    val newSeqno = storedSeqno + 1;
    var b = beginCell();
    b.storeBool(true);                      // is_signature_allowed
    b.storeUint(newSeqno, SIZE_SEQNO);
    b.storeSlice(dataTail);                 // wallet_id, ed25519_key, ecdsa keys, extensions dict
    contract.setData(b.endCell());

    if (isExternal) {
        // For external messages we commit seqno changes, so that even if an exception
        // occurs further on, the reply-protection will still work.
        commitContractDataAndActions();
    }

    processActions(cs, isExternal, false);
}

fun onExternalMessage(inMsgBody: slice) {
    val op = inMsgBody.preloadUint(SIZE_MESSAGE_OPERATION_PREFIX);
    if (op == PREFIX_SIGNED_EXTERNAL) {
        processSignedRequest(inMsgBody, true, false);
        return;
    }
    assert (op == PREFIX_SIGNED_EXTERNAL_ECDSA) throw Errors.InvalidMessageOperation;
    processSignedRequest(inMsgBody, true, true);
}

@on_bounced_policy("manual")
fun onInternalMessage(in: InMessage) {
    if (in.body.remainingBitsCount() < SIZE_MESSAGE_OPERATION_PREFIX) {
        return;    // just receive Toncoins
    }
    val op = in.body.preloadUint(SIZE_MESSAGE_OPERATION_PREFIX);
    if (op != PREFIX_EXTENSION_ACTION && op != PREFIX_SIGNED_INTERNAL && op != PREFIX_SIGNED_INTERNAL_ECDSA) {
        return;    // just receive Toncoins (also skips bounced messages with 0xFFFFFFFF prefix)
    }

    if (op == PREFIX_EXTENSION_ACTION) {
        // Authenticate extension by its address.
        val (senderWorkchain, senderAddrHash) = in.senderAddress.getWorkchainAndHash();
        val myWorkchain = contract.getAddress().getWorkchain();
        if (myWorkchain != senderWorkchain) {
            return;
        }
        var dataCs = contract.getData().beginParse();
        dataCs.skipBits(SIZE_DATA_BEFORE_EXTENSIONS);
        var dict = dataCs.loadDict();
        val (_, found) = dict.uDictGet(SIZE_ADDRESS_HASH, senderAddrHash);
        if (!found) {
            // Note that some random contract may have deposited funds with this prefix,
            // so we accept the funds silently instead of throwing an error (wallet v4 does the same).
            return;
        }
        var cs = in.body;
        cs.skipBits(SIZE_MESSAGE_OPERATION_PREFIX);
        cs.skipBits(SIZE_QUERY_ID);    // skip query_id
        processActions(cs, false, true);
        return;
    }

    // Before signature checking we handle errors silently (return), after signature
    // checking we throw exceptions. Check to make sure that there are enough bits for
    // reading before the signature check.
    if (in.body.remainingBitsCount() < MIN_SIGNED_BODY_BITS) {
        return;
    }
    processSignedRequest(in.body, false, op == PREFIX_SIGNED_INTERNAL_ECDSA);
}

// ---------------------------------------------------------------------------
// Get methods
// ---------------------------------------------------------------------------

get fun is_signature_allowed(): bool {
    var cs = contract.getData().beginParse();
    return cs.loadBool();
}

get fun seqno(): int {
    var cs = contract.getData().beginParse();
    cs.skipBits(1);
    return cs.preloadUint(SIZE_SEQNO);
}

get fun get_subwallet_id(): int {
    var cs = contract.getData().beginParse();
    cs.skipBits(1 + SIZE_SEQNO);
    return cs.preloadUint(SIZE_WALLET_ID);
}

get fun get_public_key(): int {
    var cs = contract.getData().beginParse();
    cs.skipBits(1 + SIZE_SEQNO + SIZE_WALLET_ID);
    return cs.preloadUint(SIZE_PUBLIC_KEY);
}

/// Returns the stored ECDSA (secp256k1) public key as an uncompressed curve point (x, y).
/// (0, 0) means that the ECDSA key is not set.
get fun get_ecdsa_public_key(): (int, int) {
    var cs = contract.getData().beginParse();
    cs.skipBits(1 + SIZE_SEQNO + SIZE_WALLET_ID + SIZE_PUBLIC_KEY);
    val x = cs.loadUint(SIZE_ECDSA_PUBLIC_KEY);
    val y = cs.loadUint(SIZE_ECDSA_PUBLIC_KEY);
    return (x, y);
}

/// Returns the raw dictionary (or null if empty) where keys are address hashes.
/// Workchains of extensions are the same as the wallet smart contract workchain.
get fun get_extensions(): cell? {
    var cs = contract.getData().beginParse();
    cs.skipBits(SIZE_DATA_BEFORE_EXTENSIONS);
    return cs.preloadDict();
}
