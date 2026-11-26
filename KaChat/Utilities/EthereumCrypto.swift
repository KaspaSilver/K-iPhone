import Foundation

/// The Ethereum pieces K needs for Buy Kaspa with Debit Card (owner, 2026-11-26): Keccak-256,
/// EIP-55 addresses and EIP-712 typed-data hashing. Pure Swift with no key handling, so it's
/// tested on its own (`scripts/test_ethereum_crypto.swift`). The key and the signing are in
/// `EthereumAccount`.

/// Keccak-256 as Ethereum uses it: the original Keccak padding (0x01), not NIST SHA3-256 (0x06).
enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotations: [UInt64] = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
    private static let lanes: [Int] = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]
    /// 1088 bits: what Keccak-256 absorbs per permutation.
    private static let rate = 136

    @inline(__always) private static func rotl(_ x: UInt64, _ n: UInt64) -> UInt64 { (x << n) | (x >> (64 - n)) }

    private static func permute(_ s: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            for i in 0..<5 { c[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20] }
            for i in 0..<5 {
                let t = c[(i + 4) % 5] ^ rotl(c[(i + 1) % 5], 1)
                for j in stride(from: 0, to: 25, by: 5) { s[j + i] ^= t }
            }
            var t = s[1]
            for i in 0..<24 {
                let j = lanes[i]
                let next = s[j]
                s[j] = rotl(t, rotations[i])
                t = next
            }
            for j in stride(from: 0, to: 25, by: 5) {
                for i in 0..<5 { c[i] = s[j + i] }
                for i in 0..<5 { s[j + i] ^= (~c[(i + 1) % 5]) & c[(i + 2) % 5] }
            }
            s[0] ^= roundConstants[round]
        }
    }

    static func hash<D: DataProtocol>(_ data: D) -> Data {
        var message = [UInt8](data)
        message.append(0x01)
        while message.count % rate != 0 { message.append(0) }
        message[message.count - 1] |= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for block in stride(from: 0, to: message.count, by: rate) {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for b in 0..<8 { lane |= UInt64(message[block + i * 8 + b]) << UInt64(8 * b) }
                state[i] ^= lane
            }
            permute(&state)
        }
        var out = Data(capacity: 32)
        for i in 0..<4 {
            for b in 0..<8 { out.append(UInt8((state[i] >> UInt64(8 * b)) & 0xFF)) }
        }
        return out
    }
}

enum EthereumHex {
    static func string<D: DataProtocol>(_ data: D) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// "0x..." or plain hex to bytes; nil if it isn't hex.
    static func bytes(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// The EIP-55 mixed-case form of a 20-byte address.
    static func checksumAddress<D: DataProtocol>(_ address: D) -> String {
        let lower = string(address)
        let hash = string(Keccak256.hash(Data(lower.utf8)))
        var out = "0x"
        for (char, nibble) in zip(lower, hash) {
            if char.isLetter, let value = Int(String(nibble), radix: 16), value >= 8 {
                out.append(char.uppercased())
            } else {
                out.append(char)
            }
        }
        return out
    }

    /// "0x" and 40 hex digits.
    static func isAddress(_ text: String) -> Bool {
        text.count == 42 && text.lowercased().hasPrefix("0x") && bytes(text)?.count == 20
    }
}

/// EIP-712 typed-data hashing (`eth_signTypedData_v4`): structs, the atomic types and arrays.
enum EIP712 {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    typealias Field = (name: String, type: String)
    typealias Types = [String: [Field]]

    /// The 32 bytes a wallet signs: keccak256(0x19 0x01 ‖ domainSeparator ‖ hashStruct(message)).
    static func digest(typedData: [String: Any]) throws -> Data {
        let types = try parseTypes(typedData["types"])
        guard let primary = typedData["primaryType"] as? String, types[primary] != nil else {
            throw Failure(message: "The typed data has no primary type.")
        }
        guard let domain = typedData["domain"] as? [String: Any], types["EIP712Domain"] != nil else {
            throw Failure(message: "The typed data has no domain.")
        }
        guard let message = typedData["message"] as? [String: Any] else {
            throw Failure(message: "The typed data has no message.")
        }
        let domainSeparator = try hashStruct("EIP712Domain", domain, types: types)
        let messageHash = try hashStruct(primary, message, types: types)
        return Keccak256.hash(Data([0x19, 0x01]) + domainSeparator + messageHash)
    }

    static func parseTypes(_ value: Any?) throws -> Types {
        guard let raw = value as? [String: Any] else { throw Failure(message: "The typed data has no types.") }
        var types: Types = [:]
        for (name, fields) in raw {
            guard let list = fields as? [[String: Any]] else { throw Failure(message: "Type \(name) is malformed.") }
            types[name] = try list.map { field in
                guard let fieldName = field["name"] as? String, let fieldType = field["type"] as? String else {
                    throw Failure(message: "Type \(name) has a malformed field.")
                }
                return (fieldName, fieldType)
            }
        }
        return types
    }

    static func hashStruct(_ type: String, _ value: [String: Any], types: Types) throws -> Data {
        Keccak256.hash(try encodeData(type, value, types: types))
    }

    static func typeHash(_ type: String, types: Types) throws -> Data {
        Keccak256.hash(Data(try encodeType(type, types: types).utf8))
    }

    /// "Mail(Person from,Person to,string contents)Person(string name,address wallet)": the type,
    /// then the struct types it uses, sorted by name.
    static func encodeType(_ type: String, types: Types) throws -> String {
        var found = Set<String>()
        try collect(type, types: types, into: &found)
        found.remove(type)
        return try ([type] + found.sorted()).map { name in
            guard let fields = types[name] else { throw Failure(message: "Unknown type \(name).") }
            return "\(name)(" + fields.map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"
        }.joined()
    }

    private static func collect(_ type: String, types: Types, into found: inout Set<String>) throws {
        let base = baseType(type)
        guard let fields = types[base], !found.contains(base) else { return }
        found.insert(base)
        for field in fields { try collect(field.type, types: types, into: &found) }
    }

    /// "Person[]" or "uint256[3]" → "Person" / "uint256".
    private static func baseType(_ type: String) -> String {
        guard let bracket = type.firstIndex(of: "[") else { return type }
        return String(type[..<bracket])
    }

    static func encodeData(_ type: String, _ value: [String: Any], types: Types) throws -> Data {
        guard let fields = types[type] else { throw Failure(message: "Unknown type \(type).") }
        var out = try typeHash(type, types: types)
        for field in fields {
            guard let fieldValue = value[field.name] else {
                throw Failure(message: "\(type) has no \(field.name).")
            }
            out += try encodeValue(field.type, fieldValue, types: types)
        }
        return out
    }

    static func encodeValue(_ type: String, _ value: Any, types: Types) throws -> Data {
        if type.hasSuffix("]"), let bracket = type.lastIndex(of: "[") {
            let itemType = String(type[..<bracket])
            guard let items = value as? [Any] else { throw Failure(message: "\(type) needs a list.") }
            let size = type[type.index(after: bracket)..<type.index(before: type.endIndex)]
            if !size.isEmpty, Int(size) != items.count { throw Failure(message: "\(type) has the wrong length.") }
            var joined = Data()
            for item in items { joined += try encodeValue(itemType, item, types: types) }
            return Keccak256.hash(joined)
        }
        if types[type] != nil {
            guard let object = value as? [String: Any] else { throw Failure(message: "\(type) needs an object.") }
            return try hashStruct(type, object, types: types)
        }
        switch type {
        case "string":
            guard let text = value as? String else { throw Failure(message: "A string field isn't text.") }
            return Keccak256.hash(Data(text.utf8))
        case "bytes":
            guard let text = value as? String, let bytes = EthereumHex.bytes(text) else { throw Failure(message: "A bytes field isn't hex.") }
            return Keccak256.hash(bytes)
        case "bool":
            let flag: Bool
            if isBoolean(value), let bool = value as? Bool { flag = bool }
            else if let text = value as? String, ["true", "false"].contains(text) { flag = text == "true" }
            else { throw Failure(message: "A bool field isn't true or false.") }
            return word(flag ? 1 : 0)
        case "address":
            guard let text = value as? String, EthereumHex.isAddress(text), let bytes = EthereumHex.bytes(text) else {
                throw Failure(message: "An address field isn't an address.")
            }
            return Data(repeating: 0, count: 12) + bytes
        default:
            if type.hasPrefix("uint") || type.hasPrefix("int") {
                // negative ints aren't needed by anything K signs, and are refused
                return try uint256(value)
            }
            if type.hasPrefix("bytes"), let size = Int(type.dropFirst(5)), (1...32).contains(size) {
                guard let text = value as? String, let bytes = EthereumHex.bytes(text), bytes.count == size else {
                    throw Failure(message: "A \(type) field has the wrong length.")
                }
                return bytes + Data(repeating: 0, count: 32 - size)
            }
            throw Failure(message: "K can't sign the type \(type).")
        }
    }

    /// A JSON true / false. Not `value is Bool`: a JSON 1 or 0 (an NSNumber) passes that too, so
    /// `chainId: 1` would read as a bool.
    private static func isBoolean(_ value: Any) -> Bool {
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        return value is Bool
    }

    private static func word(_ value: UInt8) -> Data {
        var data = Data(repeating: 0, count: 32)
        data[31] = value
        return data
    }

    /// A non-negative integer (a JSON number, a decimal string or a 0x hex string) as 32 bytes.
    static func uint256(_ value: Any) throws -> Data {
        if let number = value as? NSNumber, !isBoolean(value) {
            let double = number.doubleValue
            guard double >= 0, double.rounded() == double, double < 9_007_199_254_740_992 else {
                throw Failure(message: "A number field isn't a whole number K can sign.")
            }
            return try uint256(String(number.uint64Value))
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw Failure(message: "A number field is empty.")
        }
        if text.lowercased().hasPrefix("0x") {
            var hex = String(text.dropFirst(2))
            if hex.count % 2 == 1 { hex = "0" + hex }
            guard let bytes = EthereumHex.bytes(hex) else { throw Failure(message: "A number field isn't hex.") }
            let trimmed = bytes.drop(while: { $0 == 0 })
            guard trimmed.count <= 32 else { throw Failure(message: "A number field is too large.") }
            return Data(repeating: 0, count: 32 - trimmed.count) + trimmed
        }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw Failure(message: "A number field isn't a number.") }
        var out = [UInt8](repeating: 0, count: 32)
        for char in text {
            var carry = Int(char.asciiValue! - 48)
            for i in stride(from: 31, through: 0, by: -1) {
                let v = Int(out[i]) * 10 + carry
                out[i] = UInt8(v & 0xFF)
                carry = v >> 8
            }
            guard carry == 0 else { throw Failure(message: "A number field is too large.") }
        }
        return Data(out)
    }

    /// A decimal string of at most 19 digits as a UInt64 (USDC amounts, deadlines); nil otherwise.
    static func smallUInt(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber, !isBoolean(value) {
            let double = number.doubleValue
            return double >= 0 && double.rounded() == double && double < 1e18 ? number.uint64Value : nil
        }
        guard let text = value as? String else { return nil }
        if text.lowercased().hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        return UInt64(text)
    }
}
