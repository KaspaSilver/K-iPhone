import Foundation

/// Finds public Kaspa nodes that speak wRPC over `wss://`, through the public node network's
/// resolvers (the same list and checks Trestly's node code uses). K reaches for one only when no
/// gRPC node answers (`NodePoolService.evaluatePublicFallback`): a network that blocks gRPC's
/// HTTP/2 (DPI, some firewalls) usually lets an ordinary HTTPS WebSocket on 443 through.
enum PublicNodeResolver {
    static let resolvers = [
        "eric.kaspa.stream", "maxim.kaspa.stream", "sean.kaspa.stream", "troy.kaspa.stream",
        "john.kaspa.red", "mike.kaspa.red", "paul.kaspa.red", "alex.kaspa.red",
        "jake.kaspa.green", "mark.kaspa.green", "adam.kaspa.green", "liam.kaspa.green",
        "noah.kaspa.blue", "ryan.kaspa.blue", "jack.kaspa.blue", "luke.kaspa.blue",
    ]

    /// Node hosts a resolver may send K to: names on the public node network's own domains.
    private static let nodeHostSuffixes = [".kaspa.stream", ".kaspa.red", ".kaspa.green", ".kaspa.blue"]
    private static let maxAnswerBytes = 16 * 1024

    /// Up to `count` distinct nodes for `network`, asking resolvers in a random order.
    static func resolve(network: NetworkType, count: Int, avoiding: Set<String> = []) async -> [Endpoint] {
        let networkId = network == .mainnet ? "mainnet" : "testnet-10"
        var found: [Endpoint] = []
        var seen = avoiding
        for host in resolvers.shuffled() {
            guard found.count < count else { break }
            guard let endpoint = await ask(host, networkId: networkId), !seen.contains(endpoint.key) else { continue }
            seen.insert(endpoint.key)
            found.append(endpoint)
        }
        return found
    }

    private static func ask(_ host: String, networkId: String) async -> Endpoint? {
        // The resolver answers for Borsh only; the node serves JSON on the same path's sibling.
        guard let url = URL(string: "https://\(host)/v2/kaspa/\(networkId)/tls/wrpc/borsh") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= maxAnswerBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = json["url"] as? String,
              let parts = URLComponents(string: answer),
              parts.scheme?.lowercased() == "wss",
              let nodeHost = parts.host?.lowercased(),
              nodeHostSuffixes.contains(where: { nodeHost.hasSuffix($0) }),
              nodeHost.dropLast(nodeHostSuffixes.first { nodeHost.hasSuffix($0) }!.count)
                  .allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              parts.percentEncodedPath.hasSuffix("/wrpc/borsh"),
              parts.percentEncodedPath.contains("/\(networkId)/") else { return nil }
        // `Endpoint(url:)` turns the Borsh path into the JSON one.
        return Endpoint(url: "wss://\(nodeHost)\(parts.percentEncodedPath)")
    }
}
