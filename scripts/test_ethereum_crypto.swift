import Foundation

// Buy Kaspa with Debit Card's Ethereum pieces (KaChat/Utilities/EthereumCrypto.swift): Keccak-256,
// EIP-55 and EIP-712 against published vectors, and a USDC permit shaped as Trestly's buy page asks.
// Run from the repo root with:
//
// swiftc -O -parse-as-library KaChat/Utilities/EthereumCrypto.swift scripts/test_ethereum_crypto.swift \
//   -o /tmp/test_ethereum_crypto && /tmp/test_ethereum_crypto

@main
struct TestEthereumCrypto {
    static var failures = 0

    static func check(_ name: String, _ got: String, _ want: String) {
        if got.lowercased() == want.lowercased() {
            print("ok   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)\n     got  \(got)\n     want \(want)")
        }
    }

    static func main() throws {
        // Keccak-256 (not SHA3-256)
        check("keccak empty", EthereumHex.string(Keccak256.hash(Data())),
              "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        check("keccak abc", EthereumHex.string(Keccak256.hash(Data("abc".utf8))),
              "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        // a message one byte short of the rate, so the padding's 0x01 and 0x80 share a byte
        check("keccak 135 bytes", EthereumHex.string(Keccak256.hash(Data(repeating: 0x61, count: 135))),
              "34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446")
        // exactly the rate (a whole padding block follows) and two blocks; values from
        // `openssl dgst -keccak-256` (OpenSSL 3.6)
        check("keccak 136 bytes", EthereumHex.string(Keccak256.hash(Data(repeating: 0x61, count: 136))),
              "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e")
        check("keccak 200 bytes", EthereumHex.string(Keccak256.hash(Data(repeating: 0x61, count: 200))),
              "96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d")

        // EIP-55
        for address in ["0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
                        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB", "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"] {
            check("eip55 \(address)", EthereumHex.checksumAddress(EthereumHex.bytes(address)!), address)
        }

        // EIP-712's own example (eips.ethereum.org/EIPS/eip-712, "Mail")
        let mail: [String: Any] = [
            "types": [
                "EIP712Domain": [["name": "name", "type": "string"], ["name": "version", "type": "string"],
                                 ["name": "chainId", "type": "uint256"], ["name": "verifyingContract", "type": "address"]],
                "Person": [["name": "name", "type": "string"], ["name": "wallet", "type": "address"]],
                "Mail": [["name": "from", "type": "Person"], ["name": "to", "type": "Person"], ["name": "contents", "type": "string"]],
            ],
            "primaryType": "Mail",
            "domain": ["name": "Ether Mail", "version": "1", "chainId": 1,
                       "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"],
            "message": [
                "from": ["name": "Cow", "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"],
                "to": ["name": "Bob", "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"],
                "contents": "Hello, Bob!",
            ],
        ]
        let types = try EIP712.parseTypes(mail["types"])
        check("eip712 encodeType", try EIP712.encodeType("Mail", types: types),
              "Mail(Person from,Person to,string contents)Person(string name,address wallet)")
        check("eip712 domain separator",
              EthereumHex.string(try EIP712.hashStruct("EIP712Domain", mail["domain"] as! [String: Any], types: types)),
              "f2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f")
        check("eip712 mail hash",
              EthereumHex.string(try EIP712.hashStruct("Mail", mail["message"] as! [String: Any], types: types)),
              "c52c0ee5d84264471806290a3f2c4cecfc5490626bf912d01f240d7a274b371e")
        check("eip712 digest", EthereumHex.string(try EIP712.digest(typedData: mail)),
              "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")

        // numbers: decimal strings, hex and JSON numbers say the same
        let a = try EIP712.uint256("1000000")
        check("uint256 hex", EthereumHex.string(try EIP712.uint256("0xf4240")), EthereumHex.string(a))
        check("uint256 number", EthereumHex.string(try EIP712.uint256(NSNumber(value: 1_000_000))), EthereumHex.string(a))
        check("uint256 max", EthereumHex.string(try EIP712.uint256(
            "115792089237316195423570985008687907853269984665640564039457584007913129639935")), String(repeating: "f", count: 64))
        let overflow = (try? EIP712.uint256("115792089237316195423570985008687907853269984665640564039457584007913129639936")) == nil
        check("uint256 overflow refused", String(overflow), "true")

        // a USDC permit as Trestly's buy page asks for one, sent as JSON text the way the page sends it
        let permitJSON = """
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Permit":[{"name":"owner","type":"address"},{"name":"spender","type":"address"},{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},"primaryType":"Permit","domain":{"name":"USD Coin","version":"2","chainId":1,"verifyingContract":"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"},"message":{"owner":"0x9858EfFD232B4033E47d90003D41EC34EcaEda94","spender":"0x9d9D5d596d9157b00317FCa7faCcb885DD3fAa60","value":"50000000","nonce":"0","deadline":"1800000000"}}
        """
        let permit = try JSONSerialization.jsonObject(with: Data(permitJSON.utf8)) as! [String: Any]
        let permitTypes = try EIP712.parseTypes(permit["types"])
        check("permit encodeType", try EIP712.encodeType("Permit", types: permitTypes),
              "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
        // the Permit typehash every EIP-2612 token uses
        check("permit typehash", EthereumHex.string(try EIP712.typeHash("Permit", types: permitTypes)),
              "6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9")
        // USDC's own DOMAIN_SEPARATOR on Ethereum mainnet
        check("usdc domain separator",
              EthereumHex.string(try EIP712.hashStruct("EIP712Domain", permit["domain"] as! [String: Any], types: permitTypes)),
              "06c37168a7db5138defc7866392bb87a741f9b3d104deb5094588ce041cae335")
        _ = try EIP712.digest(typedData: permit)

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
