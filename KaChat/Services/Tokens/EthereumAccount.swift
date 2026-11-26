import Foundation
import P256K

/// The account's Ethereum address, used only by Buy Kaspa with Debit Card (owner, 2026-11-26).
///
/// Trestly's buy page sells USDC on Ethereum through Stripe into the buyer's own wallet, which then
/// signs one EIP-2612 permit so Trestly's bridge can deposit it to Kaspa as kUSDT. K has no other
/// use for Ethereum, so the address is never shown as a wallet: the key is derived from the
/// account's own words at the standard path m/44'/60'/0'/0/0 (with the account's passphrase, if it
/// has one), which is the address MetaMask or any Ethereum wallet shows for the same words. USDC
/// that ever stays there (a refund) can therefore be reached with the words alone.
///
/// The private key is derived only to sign and wiped right after; the address is kept in memory
/// per account.
@MainActor
enum EthereumAccount {
    /// Ethereum mainnet. Trestly sells by card on mainnet only.
    static let chainId = 1

    /// USDC's contract on Ethereum mainnet: the only token K signs a permit for.
    static let usdcContract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

    private static var cached: (account: String, address: String)?

    /// The address for the signed-in account; nil when its words aren't on this phone.
    static func address() -> String? {
        guard let account = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        if let cached, cached.account == account { return cached.address }
        guard var key = privateKey() else { return nil }
        defer { key.zeroOut() }
        guard let address = try? address(privateKey: key) else { return nil }
        cached = (account, address)
        return address
    }

    /// Forgets the cached address (Log Out, account switch).
    static func reset() { cached = nil }

    /// m/44'/60'/0'/0/0 of the account's words and passphrase.
    static func privateKey() -> Data? {
        let manager = WalletManager.shared
        guard let seedPhrase = try? manager.getSeedPhrase(),
              var seed = BIP39.shared.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else {
            return nil
        }
        defer { seed.zeroOut() }
        let master = manager.deriveMasterKey(from: seed)
        let purpose = manager.deriveChildKey(from: master, index: 44 | 0x80000000)
        let coin = manager.deriveChildKey(from: purpose, index: 60 | 0x80000000)
        let account = manager.deriveChildKey(from: coin, index: 0 | 0x80000000)
        let change = manager.deriveChildKey(from: account, index: 0)
        return manager.deriveChildKey(from: change, index: 0).key
    }

    /// The EIP-55 address of a key: the last 20 bytes of keccak256 of its uncompressed public key.
    nonisolated static func address(privateKey: Data) throws -> String {
        let key = try P256K.Signing.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        let point = key.publicKey.dataRepresentation
        guard point.count == 65, point.first == 0x04 else { throw EIP712.Failure(message: "Bad public key.") }
        return EthereumHex.checksumAddress(Keccak256.hash(point.dropFirst()).suffix(20))
    }

    /// Signs a 32-byte digest as Ethereum does: r ‖ s ‖ v, 65 bytes, v = 27 + the recovery id.
    /// libsecp256k1 always gives the low-s form, which USDC's `ecrecover` check needs.
    nonisolated static func sign(digest: Data, privateKey: Data) throws -> Data {
        guard digest.count == 32 else { throw EIP712.Failure(message: "The digest isn't 32 bytes.") }
        let key = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey)
        let signature = try key.signature(for: HashDigest(Array(digest)))
        let compact = try signature.compactRepresentation
        guard compact.signature.count == 64, (0...1).contains(compact.recoveryId) else {
            throw EIP712.Failure(message: "The signature came out malformed.")
        }
        return compact.signature + Data([UInt8(27 + compact.recoveryId)])
    }
}
