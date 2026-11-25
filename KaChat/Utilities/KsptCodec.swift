import Foundation

/// KSPT ("Kaspa Signable Partial Transaction") — the compact binary transport format KasSigner's
/// firmware scans/displays for air-gapped signing. Field order and widths below must match
/// KasSigner exactly, or the device either rejects the QR outright or (worse) silently misparses
/// it. Port of the Android client's `KsptCodec.kt`, same wire format.
///
/// Two versions are spoken here:
///
/// **0x01** (`encodeUnsigned`, read by `decode`): plain single-sig P2PK, what units on v1.0.x read.
/// KasSigner v1.1 still reads it and answers a 0x01 request in the same 0x01 shape. Unchanged.
/// ```
/// Header:  magic(4)="KSPT"  version(1)=0x01  flags(1) [bit0: signed, bit1: has redeem script]
/// Global:  txVersion(2)  numInputs(1)  numOutputs(1)  lockTime(8)  subnetworkId(20)  gas(8)
///          payloadLen(2)  payload(payloadLen)
/// Input:   prevTxId(32)  prevIndex(4)  amount(8)  sequence(8)  sigOpCount(1)
///          spkVersion(2)  spkLen(1)  spkScript(spkLen)
///          [if signed: sigLen(1)  signature(sigLen)  sighashType(1)]
/// Output:  value(8)  spkVersion(2)  spkLen(1)  spkScript(spkLen)
/// ```
///
/// **0x06** (`encodeUnsignedV6`, read by `decode`): KasSigner v1.1's canonical version
/// (`crates/kassigner-protocol/src/kspt/mod.rs` and `writer.rs`), which carries KCC-3
/// quantum-resistant inputs. `flags` is reserved (zero); every input has a signature count and a
/// redeem length, zero when unsigned; hints and covenants are records after the outputs.
/// ```
/// Header:  magic(4)="KSPT"  version(1)=0x06  flags(1)=0x00
/// Global:  as 0x01
/// Input:   prevTxId(32)  prevIndex(4)  amount(8)  sequence(8)  sigOpCount(1)
///          spkVersion(2)  spkLen(1 | 0xFF u16)  spkScript
///          sigCount(1)  sigCount × [pubkeyPos(1) sighashType(1) signature(64)]  (ascending pos)
///          redeemLen(u16)  redeem(redeemLen)
/// Output:  value(8)  spkVersion(2)  spkLen(1 | 0xFF u16)  spkScript
/// Records: 0x43 covenant(out u8, authInput u16, id 32)   0x44 / 0x45 hint(idx, cosigner, chain, addr u32)
///          0x46 KCC-3 input hint(idx, chain, addr u32)  0x47 / 0x48 account hint(idx, chain, addr u32)
///          0x49 coin covenant(in u8, id 32)
/// ```
/// A script length is one byte below 255, else 0xFF and a u16 of at least 255 (the short form is
/// required). One hint of any kind per input and per output, one covenant per output and per coin.
///
/// A KCC-3 (`m/22'`) address is P2SH of `0x20 <32-byte x-only key> 0xAC`. K never knows that key:
/// the request carries an empty redeem script and a 0x46 hint, and the unit writes the redeem into
/// its reply.
enum KsptCodec {
    static let magic: [UInt8] = [0x4B, 0x53, 0x50, 0x54] // "KSPT"
    private static let version: UInt8 = 0x01
    private static let flagSigned: UInt8 = 0x01
    private static let flagHasRedeemScript: UInt8 = 0x02

    /// The canonical version KasSigner v1.1 writes and reads.
    static let versionV6: UInt8 = 0x06

    // Matches firmware MAX_INPUTS=32 as of KasSigner v1.0.5 (was 8; devices on older
    // firmware reject >8-input — and pre-1.0.5, even >5-input — transactions).
    static let maxInputs = 32
    static let maxOutputs = 4

    // KasSigner v1.1's `Profile::ESP32S3` (crates/kassigner-protocol/src/profile.rs), which every
    // board (M5, Waveshare, P4) uses unchanged apart from frame counts (`Capacity::derive`), and
    // firmware/kassigner-fw/src/limits.rs (MAX_INPUTS 32, MAX_OUTPUTS 8). Only for 0x06: a unit on
    // v1.0.x reads 0x01 within `maxInputs` / `maxOutputs` above.
    static let maxInputsV6 = 32
    static let maxOutputsV6 = 8
    static let maxScriptV6 = 512
    static let maxRedeemV6 = 1024
    static let maxPayloadV6 = 768
    static let maxSigsPerInputV6 = 5

    /// Total supply in sompi: a value, or a running total, above it is refused (KasSigner's
    /// `checked_add_value`, upstream's `check_transaction_output_value_ranges`).
    static let maxSompi: UInt64 = 29_000_000_000 * 100_000_000

    /// The length of KCC-3's redeem script, `0x20 <P> 0xAC`.
    static let kcc3RedeemLength = 34

    private static let lenEscape: UInt8 = 0xFF
    private static let signatureLength = 64
    private static let recCovenant: UInt8 = 0x43
    private static let recHintIn: UInt8 = 0x44
    private static let recHintOut: UInt8 = 0x45
    private static let recKcc3HintIn: UInt8 = 0x46
    private static let recAccountHintIn: UInt8 = 0x47
    private static let recAccountHintOut: UInt8 = 0x48
    private static let recCoinCovenant: UInt8 = 0x49

    /// Starts with the 4-byte "KSPT" magic — the same check KasSigner's own frame-0 detector uses.
    static func looksLikeKspt(_ bytes: Data) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == magic
    }

    struct UnsignedInput {
        let prevTxId: String // 64 hex chars
        let prevIndex: UInt32
        let amountSompi: UInt64
        let sequence: UInt64
        let sigOpCount: UInt8
        let spkVersion: UInt16
        let spkScriptHex: String
    }

    struct UnsignedOutput {
        let valueSompi: UInt64
        let spkVersion: UInt16
        let spkScriptHex: String
    }

    /// Where an input's key is, for a 0x06 request. One per input at most.
    enum InputHint: Equatable {
        /// Record 0x46: a KCC-3 address, `chain`/`addrIndex` below `m/22'/111111'/0'`. The input's
        /// lock must be P2SH; its redeem goes empty and the unit supplies it.
        case kcc3(chain: UInt32, addrIndex: UInt32)
        /// Record 0x47: a single-key (`m/44'/111111'/0'`) key at `chain`/`addrIndex`. KasSigner's
        /// SDK writes it only past the unit's bank (receive index ≥ 20, change index ≥ 5); inside
        /// it the unit finds the key by itself, so it is optional there.
        case account(chain: UInt32, addrIndex: UInt32)
    }

    enum KsptError: LocalizedError {
        case invalidInputCount(Int)
        case invalidOutputCount(Int)
        case payloadTooLarge(Int)
        case badHexLength(String, Int, Int)
        case scriptTooLarge(Int)
        case badMagic
        case unsupportedVersion(UInt8)
        case multisigUnsupported
        case truncated
        // 0x06
        case reservedFlags(UInt8)
        case nonCanonicalLength(Int)
        case redeemTooLarge(Int)
        case tooManySignatures(input: Int, count: Int)
        case duplicateSignature(input: Int, pubkeyPos: UInt8)
        case signaturesOutOfOrder(input: Int, pubkeyPos: UInt8)
        case singleKeyInputSignature(input: Int)
        case unexpectedRedeem(input: Int)
        case valueOutOfRange
        case unknownRecord(marker: UInt8, at: Int)
        case repeatedRecord(marker: UInt8, at: Int)
        case recordIndexOutOfRange(marker: UInt8, at: Int, index: UInt8)
        case authorizingInputOutOfRange(output: UInt8, input: UInt16)
        case trailingData(at: Int)
        case badHint(input: Int)
        case hintCountMismatch(inputs: Int, hints: Int)

        var errorDescription: String? {
            switch self {
            case .invalidInputCount(let n): return "KSPT supports 1-\(maxInputs) inputs (\(maxInputsV6) on KasSigner v1.1), got \(n)"
            case .invalidOutputCount(let n): return "KSPT supports 1-\(maxOutputs) outputs (\(maxOutputsV6) on KasSigner v1.1), got \(n)"
            case .payloadTooLarge(let n): return "KSPT payload is too large (\(n) bytes)"
            case .badHexLength(let field, let expected, let got): return "\(field) must be \(expected) bytes, got \(got)"
            case .scriptTooLarge(let n): return "KSPT script is too large (\(n) bytes)"
            case .badMagic: return "Not a KSPT payload (bad magic)"
            case .unsupportedVersion(let v): return "Unsupported KSPT version \(v)"
            case .multisigUnsupported: return "Multisig/redeem-script KSPT isn't supported"
            case .truncated: return "KSPT payload is truncated"
            case .reservedFlags(let f): return "KSPT 0x06 flags must be zero, got \(f)"
            case .nonCanonicalLength(let at): return "KSPT script length at byte \(at) isn't in its short form"
            case .redeemTooLarge(let n): return "KSPT redeem script must be <=\(maxRedeemV6) bytes, got \(n)"
            case .tooManySignatures(let i, let n): return "KSPT input \(i) carries \(n) signatures, more than \(maxSigsPerInputV6)"
            case .duplicateSignature(let i, let p): return "KSPT input \(i) has two signatures at key position \(p)"
            case .signaturesOutOfOrder(let i, let p): return "KSPT input \(i)'s signature at position \(p) is out of order"
            case .singleKeyInputSignature(let i): return "KSPT input \(i) has one key but more than one signature, or one at another position"
            case .unexpectedRedeem(let i): return "KSPT input \(i) carries a redeem script its lock doesn't take"
            case .valueOutOfRange: return "KSPT amounts exceed the total supply"
            case .unknownRecord(let m, let at): return String(format: "KSPT has an unknown record 0x%02x at byte %d", m, at)
            case .repeatedRecord(let m, let at): return String(format: "KSPT repeats record 0x%02x at byte %d", m, at)
            case .recordIndexOutOfRange(let m, let at, let index): return String(format: "KSPT record 0x%02x at byte %d names index %d, which doesn't exist", m, at, Int(index))
            case .authorizingInputOutOfRange(let o, let i): return "KSPT binds output \(o) to input \(i), which doesn't exist"
            case .trailingData(let at): return "KSPT has trailing bytes from byte \(at)"
            case .badHint(let i): return "KSPT input \(i)'s hint doesn't fit its address"
            case .hintCountMismatch(let n, let h): return "KSPT has \(n) inputs but \(h) hints"
            }
        }
    }

    /// Builds the unsigned KSPT bytes for the given transaction shape. Doesn't take a
    /// `KaspaRpcTransaction` directly — its inputs alone have no UTXO amount or scriptPublicKey
    /// (those live on the selected UTXO list, not the tx itself), so callers assemble
    /// `UnsignedInput`/`UnsignedOutput` from their selection result instead of this function
    /// re-deriving it.
    static func encodeUnsigned(
        txVersion: UInt16,
        lockTime: UInt64,
        subnetworkIdHex: String,
        gas: UInt64,
        payloadHex: String?,
        inputs: [UnsignedInput],
        outputs: [UnsignedOutput]
    ) throws -> Data {
        guard (1...maxInputs).contains(inputs.count) else { throw KsptError.invalidInputCount(inputs.count) }
        guard (1...maxOutputs).contains(outputs.count) else { throw KsptError.invalidOutputCount(outputs.count) }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(version)
        out.append(0x00) // unsigned, no redeem script

        let payloadBytes = payloadHex.flatMap { Data(hexString: $0) } ?? Data()
        guard payloadBytes.count <= 128 else { throw KsptError.payloadTooLarge(payloadBytes.count) }

        out.appendU16LE(txVersion)
        out.append(UInt8(inputs.count))
        out.append(UInt8(outputs.count))
        out.appendU64LE(lockTime)
        guard let subnetworkBytes = Data(hexString: subnetworkIdHex), subnetworkBytes.count == 20 else {
            throw KsptError.badHexLength("subnetworkId", 20, Data(hexString: subnetworkIdHex)?.count ?? -1)
        }
        out.append(subnetworkBytes)
        out.appendU64LE(gas)
        out.appendU16LE(UInt16(payloadBytes.count))
        out.append(payloadBytes)

        for input in inputs {
            guard let txIdBytes = Data(hexString: input.prevTxId), txIdBytes.count == 32 else {
                throw KsptError.badHexLength("prevTxId", 32, Data(hexString: input.prevTxId)?.count ?? -1)
            }
            out.append(txIdBytes)
            out.appendU32LE(input.prevIndex)
            out.appendU64LE(input.amountSompi)
            out.appendU64LE(input.sequence)
            out.append(input.sigOpCount)
            out.appendU16LE(input.spkVersion)
            let spkBytes = Data(hexString: input.spkScriptHex) ?? Data()
            guard spkBytes.count <= 64 else { throw KsptError.scriptTooLarge(spkBytes.count) }
            out.append(UInt8(spkBytes.count))
            out.append(spkBytes)
        }

        for output in outputs {
            out.appendU64LE(output.valueSompi)
            out.appendU16LE(output.spkVersion)
            let spkBytes = Data(hexString: output.spkScriptHex) ?? Data()
            guard spkBytes.count <= 64 else { throw KsptError.scriptTooLarge(spkBytes.count) }
            out.append(UInt8(spkBytes.count))
            out.append(spkBytes)
        }

        return out
    }

    /// Builds an unsigned **0x06** request, as KasSigner's `write_draft` does for the same
    /// transaction: every input with no signatures and an empty redeem script, then the records,
    /// all 0x46 (KCC-3) hints in input order, then all 0x47 (account) hints in input order.
    ///
    /// `inputHints` is empty (no hints) or one entry per input. A `.kcc3` input's lock must be P2SH
    /// (`aa20 <32> 87`); an `.account` input's lock must be P2PK. A hint's chain is 0 (receive) or
    /// 1 (change) and its index below 2^31, as KasSigner's SDK refuses otherwise. Limits are
    /// v1.1's profile (`maxInputsV6` ...), and a value or the running total of inputs or outputs
    /// above the total supply is refused, as the unit would.
    static func encodeUnsignedV6(
        txVersion: UInt16,
        lockTime: UInt64,
        subnetworkIdHex: String,
        gas: UInt64,
        payloadHex: String?,
        inputs: [UnsignedInput],
        inputHints: [InputHint?] = [],
        outputs: [UnsignedOutput]
    ) throws -> Data {
        guard (1...maxInputsV6).contains(inputs.count) else { throw KsptError.invalidInputCount(inputs.count) }
        guard (1...maxOutputsV6).contains(outputs.count) else { throw KsptError.invalidOutputCount(outputs.count) }
        guard inputHints.isEmpty || inputHints.count == inputs.count else {
            throw KsptError.hintCountMismatch(inputs: inputs.count, hints: inputHints.count)
        }
        let hints: [InputHint?] = inputHints.isEmpty ? Array(repeating: nil, count: inputs.count) : inputHints

        let payloadBytes: Data
        if let payloadHex, !payloadHex.isEmpty {
            guard let bytes = Data(hexString: payloadHex) else { throw KsptError.badHexLength("payload", -1, -1) }
            payloadBytes = bytes
        } else {
            payloadBytes = Data()
        }
        guard payloadBytes.count <= maxPayloadV6 else { throw KsptError.payloadTooLarge(payloadBytes.count) }
        guard let subnetworkBytes = Data(hexString: subnetworkIdHex), subnetworkBytes.count == 20 else {
            throw KsptError.badHexLength("subnetworkId", 20, Data(hexString: subnetworkIdHex)?.count ?? -1)
        }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(versionV6)
        out.append(0x00) // flags: reserved in 0x06
        out.appendU16LE(txVersion)
        out.append(UInt8(inputs.count))
        out.append(UInt8(outputs.count))
        out.appendU64LE(lockTime)
        out.append(subnetworkBytes)
        out.appendU64LE(gas)
        out.appendU16LE(UInt16(payloadBytes.count))
        out.append(payloadBytes)

        var totalIn: UInt64 = 0
        for (i, input) in inputs.enumerated() {
            guard let txIdBytes = Data(hexString: input.prevTxId), txIdBytes.count == 32 else {
                throw KsptError.badHexLength("prevTxId", 32, Data(hexString: input.prevTxId)?.count ?? -1)
            }
            guard let spkBytes = Data(hexString: input.spkScriptHex) else {
                throw KsptError.badHexLength("scriptPublicKey", -1, -1)
            }
            totalIn = try addValue(totalIn, input.amountSompi)
            switch hints[i] {
            case .kcc3(let chain, let addrIndex):
                guard isHintLevel(chain, addrIndex), isPayToScriptHash(spkBytes) else { throw KsptError.badHint(input: i) }
            case .account(let chain, let addrIndex):
                guard isHintLevel(chain, addrIndex), isPayToPubKey(spkBytes) else { throw KsptError.badHint(input: i) }
            case nil:
                break
            }
            out.append(txIdBytes)
            out.appendU32LE(input.prevIndex)
            out.appendU64LE(input.amountSompi)
            out.appendU64LE(input.sequence)
            out.append(input.sigOpCount)
            try appendScript(&out, version: input.spkVersion, script: spkBytes)
            out.append(0x00)      // no signatures
            out.appendU16LE(0)    // no redeem script: the unit supplies KCC-3's
        }

        var totalOut: UInt64 = 0
        for output in outputs {
            guard let spkBytes = Data(hexString: output.spkScriptHex) else {
                throw KsptError.badHexLength("scriptPublicKey", -1, -1)
            }
            totalOut = try addValue(totalOut, output.valueSompi)
            out.appendU64LE(output.valueSompi)
            try appendScript(&out, version: output.spkVersion, script: spkBytes)
        }

        // The writer's fixed record order: covenants, coin covenants, 0x44, 0x46, 0x47, 0x45, 0x48.
        // K writes no covenants and no group or output hints, so 0x46s then 0x47s.
        for (i, hint) in hints.enumerated() {
            if case .kcc3(let chain, let addrIndex) = hint {
                out.append(recKcc3HintIn)
                out.append(UInt8(i))
                out.appendU32LE(chain)
                out.appendU32LE(addrIndex)
            }
        }
        for (i, hint) in hints.enumerated() {
            if case .account(let chain, let addrIndex) = hint {
                out.append(recAccountHintIn)
                out.append(UInt8(i))
                out.appendU32LE(chain)
                out.appendU32LE(addrIndex)
            }
        }
        return out
    }

    struct DecodedSignature: Equatable {
        let pubkeyPos: UInt8
        let sighashType: UInt8
        let signatureHex: String
    }

    struct DecodedInput {
        let prevTxId: String
        let prevIndex: UInt32
        let amountSompi: UInt64
        let sequence: UInt64
        let sigOpCount: UInt8
        let spkVersion: UInt16
        let spkScriptHex: String
        // Present only when the payload is a signed response and this input was actually signed —
        // a still-unsigned input in a partially-signed response round-trips with
        // signatureHex=nil. On 0x06 it is the signature record at key position 0.
        let signatureHex: String?
        let sighashType: UInt8?
        /// The redeem script the payload carries for this input (0x06), nil when empty. On a
        /// KCC-3 reply it is the unit's `0x20 <P> 0xAC`. The codec checks its shape, not that its
        /// hash is the input's P2SH lock: the caller must (blake2b-256 of it == the lock's 32 bytes).
        let redeemScriptHex: String?
        /// Every signature record on the input, ascending by key position (0x01: the one).
        let signatures: [DecodedSignature]
        /// The input's 0x46 / 0x47 hint, if the payload carries one.
        let hint: InputHint?
    }

    struct DecodedOutput {
        let valueSompi: UInt64
        let spkVersion: UInt16
        let spkScriptHex: String
    }

    /// A 0x06 record after the outputs, as read.
    enum Record: Equatable {
        case covenant(outputIndex: UInt8, authorizingInput: UInt16, covenantIdHex: String)       // 0x43
        case inputHint(index: UInt8, cosigner: UInt32, chain: UInt32, addrIndex: UInt32)        // 0x44
        case outputHint(index: UInt8, cosigner: UInt32, chain: UInt32, addrIndex: UInt32)       // 0x45
        case kcc3InputHint(index: UInt8, chain: UInt32, addrIndex: UInt32)                      // 0x46
        case accountInputHint(index: UInt8, chain: UInt32, addrIndex: UInt32)                   // 0x47
        case accountOutputHint(index: UInt8, chain: UInt32, addrIndex: UInt32)                  // 0x48
        case coinCovenant(inputIndex: UInt8, covenantIdHex: String)                             // 0x49
    }

    struct Decoded {
        /// The KSPT version read: 0x01 or 0x06.
        let version: UInt8
        /// 0x01: the signed flag. 0x06 has no flag: true when any input carries a signature.
        let signed: Bool
        let txVersion: UInt16
        let lockTime: UInt64
        let subnetworkIdHex: String
        let gas: UInt64
        let payloadHex: String
        let inputs: [DecodedInput]
        let outputs: [DecodedOutput]
        /// 0x06's records in the order they appeared (empty on 0x01). A caller that builds no
        /// covenants should refuse a reply carrying `.covenant` / `.coinCovenant`.
        let records: [Record]
    }

    /// Reads a 0x01 payload (unchanged) or a 0x06 one; any other version throws.
    static func decode(_ bytes: Data) throws -> Decoded {
        guard looksLikeKspt(bytes) else { throw KsptError.badMagic }
        guard bytes.count >= 5 else { throw KsptError.truncated }
        let ver = bytes[bytes.startIndex + 4]
        if ver == versionV6 { return try decodeV6(bytes) }

        var reader = ByteReader(bytes)
        reader.skip(4) // magic

        _ = try reader.readU8()
        guard ver == version else { throw KsptError.unsupportedVersion(ver) }
        let flags = try reader.readU8()
        let signed = flags & flagSigned != 0
        guard flags & flagHasRedeemScript == 0 else { throw KsptError.multisigUnsupported }

        let txVersion = try reader.readU16LE()
        let numInputs = Int(try reader.readU8())
        let numOutputs = Int(try reader.readU8())
        guard (1...maxInputs).contains(numInputs) else { throw KsptError.invalidInputCount(numInputs) }
        guard (1...maxOutputs).contains(numOutputs) else { throw KsptError.invalidOutputCount(numOutputs) }
        let lockTime = try reader.readU64LE()
        let subnetworkBytes = try reader.readBytes(20)
        let gas = try reader.readU64LE()
        let payloadLen = Int(try reader.readU16LE())
        guard payloadLen <= 128 else { throw KsptError.payloadTooLarge(payloadLen) }
        let payloadBytes = try reader.readBytes(payloadLen)

        var inputs: [DecodedInput] = []
        for _ in 0..<numInputs {
            let txIdBytes = try reader.readBytes(32)
            let prevIndex = try reader.readU32LE()
            let amount = try reader.readU64LE()
            let sequence = try reader.readU64LE()
            let sigOpCount = try reader.readU8()
            let spkVersion = try reader.readU16LE()
            let spkLen = Int(try reader.readU8())
            guard spkLen <= 64 else { throw KsptError.scriptTooLarge(spkLen) }
            let spkBytes = try reader.readBytes(spkLen)

            var sigHex: String?
            var sighashType: UInt8?
            if signed {
                let sigLen = Int(try reader.readU8())
                guard sigLen <= 64 else { throw KsptError.scriptTooLarge(sigLen) }
                if sigLen > 0 {
                    let sigBytes = try reader.readBytes(sigLen)
                    sigHex = sigBytes.hexString
                    sighashType = try reader.readU8()
                }
            }

            inputs.append(DecodedInput(
                prevTxId: txIdBytes.hexString,
                prevIndex: prevIndex,
                amountSompi: amount,
                sequence: sequence,
                sigOpCount: sigOpCount,
                spkVersion: spkVersion,
                spkScriptHex: spkBytes.hexString,
                signatureHex: sigHex,
                sighashType: sighashType,
                redeemScriptHex: nil,
                signatures: sigHex.map { [DecodedSignature(pubkeyPos: 0, sighashType: sighashType ?? 0, signatureHex: $0)] } ?? [],
                hint: nil
            ))
        }

        var outputs: [DecodedOutput] = []
        for _ in 0..<numOutputs {
            let value = try reader.readU64LE()
            let spkVersion = try reader.readU16LE()
            let spkLen = Int(try reader.readU8())
            guard spkLen <= 64 else { throw KsptError.scriptTooLarge(spkLen) }
            let spkBytes = try reader.readBytes(spkLen)
            outputs.append(DecodedOutput(valueSompi: value, spkVersion: spkVersion, spkScriptHex: spkBytes.hexString))
        }

        return Decoded(
            version: version,
            signed: signed,
            txVersion: txVersion,
            lockTime: lockTime,
            subnetworkIdHex: subnetworkBytes.hexString,
            gas: gas,
            payloadHex: payloadBytes.hexString,
            inputs: inputs,
            outputs: outputs,
            records: []
        )
    }

    // MARK: - 0x06

    /// Reads a canonical 0x06 payload as KasSigner's `parse` does (mod.rs), refusing what it
    /// refuses: reserved flags, zero inputs or outputs, counts and lengths past the profile, a
    /// non-canonical script length, amounts past the supply, a repeated or descending signature
    /// position, unknown records, repeated records, records naming an index the payload lacks, a
    /// covenant naming an input it lacks, and trailing bytes. Then, for safety, more than one
    /// signature (or one not at position 0) on a single-key input (a P2PK lock, a KCC-3 redeem,
    /// or a 0x46 hint), a redeem script on an input whose lock isn't P2SH, and a redeem on a
    /// KCC-3-hinted input that isn't `0x20 <32> 0xAC`.
    private static func decodeV6(_ bytes: Data) throws -> Decoded {
        var r = ByteReader(bytes)
        r.skip(4) // magic
        _ = try r.readU8() // 0x06
        let flags = try r.readU8()
        guard flags == 0 else { throw KsptError.reservedFlags(flags) }

        let txVersion = try r.readU16LE()
        let numInputs = Int(try r.readU8())
        let numOutputs = Int(try r.readU8())
        let lockTime = try r.readU64LE()
        let subnetworkBytes = try r.readBytes(20)
        let gas = try r.readU64LE()
        let payloadLen = Int(try r.readU16LE())
        guard (1...maxInputsV6).contains(numInputs) else { throw KsptError.invalidInputCount(numInputs) }
        guard (1...maxOutputsV6).contains(numOutputs) else { throw KsptError.invalidOutputCount(numOutputs) }
        guard payloadLen <= maxPayloadV6 else { throw KsptError.payloadTooLarge(payloadLen) }
        let payloadBytes = try r.readBytes(payloadLen)

        struct RawInput {
            let txId: Data, prevIndex: UInt32, amount: UInt64, sequence: UInt64, sigOpCount: UInt8
            let spkVersion: UInt16, spk: Data, signatures: [DecodedSignature], redeem: Data
        }
        var raw: [RawInput] = []
        var totalIn: UInt64 = 0
        for i in 0..<numInputs {
            let txId = try r.readBytes(32)
            let prevIndex = try r.readU32LE()
            let amount = try r.readU64LE()
            totalIn = try addValue(totalIn, amount)
            let sequence = try r.readU64LE()
            let sigOpCount = try r.readU8()
            let spkVersion = try r.readU16LE()
            let spkLen = try r.readScriptLen()
            guard spkLen <= maxScriptV6 else { throw KsptError.scriptTooLarge(spkLen) }
            let spk = try r.readBytes(spkLen)

            let sigCount = Int(try r.readU8())
            guard sigCount <= maxSigsPerInputV6 else { throw KsptError.tooManySignatures(input: i, count: sigCount) }
            var signatures: [DecodedSignature] = []
            var seen = Set<UInt8>()
            for _ in 0..<sigCount {
                let pos = try r.readU8()
                let sighash = try r.readU8()
                let sig = try r.readBytes(signatureLength)
                guard seen.insert(pos).inserted else { throw KsptError.duplicateSignature(input: i, pubkeyPos: pos) }
                if let last = signatures.last, pos < last.pubkeyPos {
                    throw KsptError.signaturesOutOfOrder(input: i, pubkeyPos: pos)
                }
                signatures.append(DecodedSignature(pubkeyPos: pos, sighashType: sighash, signatureHex: sig.hexString))
            }
            let redeemLen = Int(try r.readU16LE())
            guard redeemLen <= maxRedeemV6 else { throw KsptError.redeemTooLarge(redeemLen) }
            let redeem = try r.readBytes(redeemLen)
            raw.append(RawInput(txId: txId, prevIndex: prevIndex, amount: amount, sequence: sequence,
                                sigOpCount: sigOpCount, spkVersion: spkVersion, spk: spk,
                                signatures: signatures, redeem: redeem))
        }

        var outputs: [DecodedOutput] = []
        var totalOut: UInt64 = 0
        for _ in 0..<numOutputs {
            let value = try r.readU64LE()
            totalOut = try addValue(totalOut, value)
            let spkVersion = try r.readU16LE()
            let spkLen = try r.readScriptLen()
            guard spkLen <= maxScriptV6 else { throw KsptError.scriptTooLarge(spkLen) }
            let spk = try r.readBytes(spkLen)
            outputs.append(DecodedOutput(valueSompi: value, spkVersion: spkVersion, spkScriptHex: spk.hexString))
        }

        // Records, in any order; one hint of any kind per input and per output, one covenant per
        // output and per coin (mod.rs `validate_records`).
        var records: [Record] = []
        var hintedIn = Set<UInt8>(), hintedOut = Set<UInt8>(), bound = Set<UInt8>(), coins = Set<UInt8>()
        var hints: [Int: InputHint] = [:]
        while r.remaining > 0 {
            let at = r.position
            let marker = try r.readU8()
            switch marker {
            case recCovenant:
                let index = try r.readU8()
                let input = try r.readU16LE()
                let id = try r.readBytes(32)
                guard Int(index) < numOutputs else { throw KsptError.recordIndexOutOfRange(marker: marker, at: at, index: index) }
                guard Int(input) < numInputs else { throw KsptError.authorizingInputOutOfRange(output: index, input: input) }
                guard bound.insert(index).inserted else { throw KsptError.repeatedRecord(marker: marker, at: at) }
                records.append(.covenant(outputIndex: index, authorizingInput: input, covenantIdHex: id.hexString))
            case recHintIn, recHintOut:
                let index = try r.readU8()
                let cosigner = try r.readU32LE()
                let chain = try r.readU32LE()
                let addrIndex = try r.readU32LE()
                let isIn = marker == recHintIn
                guard Int(index) < (isIn ? numInputs : numOutputs) else {
                    throw KsptError.recordIndexOutOfRange(marker: marker, at: at, index: index)
                }
                let fresh = isIn ? hintedIn.insert(index).inserted : hintedOut.insert(index).inserted
                guard fresh else { throw KsptError.repeatedRecord(marker: marker, at: at) }
                records.append(isIn
                    ? .inputHint(index: index, cosigner: cosigner, chain: chain, addrIndex: addrIndex)
                    : .outputHint(index: index, cosigner: cosigner, chain: chain, addrIndex: addrIndex))
            case recKcc3HintIn, recAccountHintIn, recAccountHintOut:
                let index = try r.readU8()
                let chain = try r.readU32LE()
                let addrIndex = try r.readU32LE()
                let isOut = marker == recAccountHintOut
                guard Int(index) < (isOut ? numOutputs : numInputs) else {
                    throw KsptError.recordIndexOutOfRange(marker: marker, at: at, index: index)
                }
                let fresh = isOut ? hintedOut.insert(index).inserted : hintedIn.insert(index).inserted
                guard fresh else { throw KsptError.repeatedRecord(marker: marker, at: at) }
                switch marker {
                case recKcc3HintIn:
                    records.append(.kcc3InputHint(index: index, chain: chain, addrIndex: addrIndex))
                    hints[Int(index)] = .kcc3(chain: chain, addrIndex: addrIndex)
                case recAccountHintIn:
                    records.append(.accountInputHint(index: index, chain: chain, addrIndex: addrIndex))
                    hints[Int(index)] = .account(chain: chain, addrIndex: addrIndex)
                default:
                    records.append(.accountOutputHint(index: index, chain: chain, addrIndex: addrIndex))
                }
            case recCoinCovenant:
                let index = try r.readU8()
                let id = try r.readBytes(32)
                guard Int(index) < numInputs else { throw KsptError.recordIndexOutOfRange(marker: marker, at: at, index: index) }
                guard coins.insert(index).inserted else { throw KsptError.repeatedRecord(marker: marker, at: at) }
                records.append(.coinCovenant(inputIndex: index, covenantIdHex: id.hexString))
            default:
                throw KsptError.unknownRecord(marker: marker, at: at)
            }
        }
        // `remaining` reached zero, so nothing trails; kept explicit as the parser's last check.
        guard r.remaining == 0 else { throw KsptError.trailingData(at: r.position) }

        var inputs: [DecodedInput] = []
        for (i, input) in raw.enumerated() {
            let hint = hints[i]
            if !input.redeem.isEmpty, !isPayToScriptHash(input.spk) {
                throw KsptError.unexpectedRedeem(input: i)
            }
            if case .kcc3 = hint, !input.redeem.isEmpty, !isKcc3Redeem(input.redeem) {
                throw KsptError.unexpectedRedeem(input: i)
            }
            var kcc3Hinted = false
            if case .kcc3 = hint { kcc3Hinted = true }
            let singleKey = isPayToPubKey(input.spk) || isKcc3Redeem(input.redeem) || kcc3Hinted
            if singleKey, input.signatures.count > 1 || input.signatures.contains(where: { $0.pubkeyPos != 0 }) {
                throw KsptError.singleKeyInputSignature(input: i)
            }
            let first = input.signatures.first(where: { $0.pubkeyPos == 0 })
            inputs.append(DecodedInput(
                prevTxId: input.txId.hexString,
                prevIndex: input.prevIndex,
                amountSompi: input.amount,
                sequence: input.sequence,
                sigOpCount: input.sigOpCount,
                spkVersion: input.spkVersion,
                spkScriptHex: input.spk.hexString,
                signatureHex: first?.signatureHex,
                sighashType: first?.sighashType,
                redeemScriptHex: input.redeem.isEmpty ? nil : input.redeem.hexString,
                signatures: input.signatures,
                hint: hint
            ))
        }

        return Decoded(
            version: versionV6,
            signed: inputs.contains { !$0.signatures.isEmpty },
            txVersion: txVersion,
            lockTime: lockTime,
            subnetworkIdHex: subnetworkBytes.hexString,
            gas: gas,
            payloadHex: payloadBytes.hexString,
            inputs: inputs,
            outputs: outputs,
            records: records
        )
    }

    /// `0x20 <32-byte x-only key> 0xAC`: KCC-3's redeem script.
    static func isKcc3Redeem(_ script: Data) -> Bool {
        script.count == kcc3RedeemLength && script.first == 0x20 && script.last == 0xAC
    }

    /// Schnorr P2PK (`0x20 <32> 0xAC`) or ECDSA P2PK (`0x21 <33> 0xAB`).
    private static func isPayToPubKey(_ script: Data) -> Bool {
        (script.count == 34 && script.first == 0x20 && script.last == 0xAC)
            || (script.count == 35 && script.first == 0x21 && script.last == 0xAB)
    }

    /// `OP_BLAKE2B OP_DATA_32 <hash> OP_EQUAL`.
    private static func isPayToScriptHash(_ script: Data) -> Bool {
        script.count == 35 && script[script.startIndex] == 0xAA
            && script[script.startIndex + 1] == 0x20 && script.last == 0x87
    }

    /// KasSigner's `is_hint_level`: chain 0 or 1, a non-hardened index.
    private static func isHintLevel(_ chain: UInt32, _ index: UInt32) -> Bool {
        chain <= 1 && index & 0x8000_0000 == 0
    }

    private static func addValue(_ total: UInt64, _ value: UInt64) throws -> UInt64 {
        guard value <= maxSompi else { throw KsptError.valueOutOfRange }
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow, sum <= maxSompi else { throw KsptError.valueOutOfRange }
        return sum
    }

    /// spkVersion(2), the length in its canonical form (one byte below 255, else 0xFF and a u16),
    /// then the script.
    private static func appendScript(_ out: inout Data, version: UInt16, script: Data) throws {
        guard script.count <= maxScriptV6 else { throw KsptError.scriptTooLarge(script.count) }
        out.appendU16LE(version)
        if script.count < Int(lenEscape) {
            out.append(UInt8(script.count))
        } else {
            out.append(lenEscape)
            out.appendU16LE(UInt16(script.count))
        }
        out.append(script)
    }
}

/// Minimal little-endian byte cursor used only by KsptCodec.decode.
private struct ByteReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }

    var position: Int { offset }
    var remaining: Int { bytes.count - offset }

    mutating func skip(_ count: Int) { offset += count }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= bytes.count else { throw KsptCodec.KsptError.truncated }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    mutating func readU8() throws -> UInt8 {
        guard offset < bytes.count else { throw KsptCodec.KsptError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readU16LE() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[b.startIndex]) | (UInt16(b[b.startIndex + 1]) << 8)
    }

    mutating func readU32LE() throws -> UInt32 {
        let b = try readBytes(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(b[b.startIndex + i]) << (8 * i) }
        return v
    }

    mutating func readU64LE() throws -> UInt64 {
        let b = try readBytes(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[b.startIndex + i]) << (8 * i) }
        return v
    }

    /// 0x06's script length: one byte, or 0xFF then a u16 that must be at least 255.
    mutating func readScriptLen() throws -> Int {
        let at = offset
        let first = try readU8()
        guard first == 0xFF else { return Int(first) }
        let long = Int(try readU16LE())
        guard long >= 0xFF else { throw KsptCodec.KsptError.nonCanonicalLength(at) }
        return long
    }
}

private extension Data {
    mutating func appendU16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendU32LE(_ value: UInt32) {
        for i in 0..<4 { append(UInt8((value >> (8 * i)) & 0xFF)) }
    }

    mutating func appendU64LE(_ value: UInt64) {
        for i in 0..<8 { append(UInt8((value >> (8 * i)) & 0xFF)) }
    }
}
