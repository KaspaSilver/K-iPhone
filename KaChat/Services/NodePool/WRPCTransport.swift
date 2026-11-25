import Foundation

// Kaspa nodes serve the same RPC over WebSocket ("wRPC", rusty-kaspa) as over gRPC. K speaks its
// JSON encoding as a second transport (2026-11-24): a `wss://` node typed into Connection Settings
// > Node, and the public nodes `PublicNodeFallback` finds when no gRPC node can be reached (DPI,
// firewalls that block gRPC's HTTP/2). Everything above `GRPCStreamConnection` - the pool, the
// subscription manager, sends - keeps working in protobuf: this file turns each request into its
// wRPC JSON message and each JSON answer back into the `Protowire_KaspadMessage` gRPC would have
// sent, so both transports go through the same request matching, health tracking and failover.
//
// The wire format (checked against kaspad 2.1.0's public nodes):
// - request:      {"id":7,"method":"getUtxosByAddresses","params":{"addresses":[...]}}
// - answer:       {"id":7,"method":"getUtxosByAddresses","params":{...}}
// - error:        {"id":7,"method":"...","error":{"code":0,"message":"...","data":null}}
// - subscribe:    method "subscribe" / "unsubscribe" with {"UtxosChanged":{"addresses":[...]}} or
//                 {"BlockAdded":{}}; answered {"id":N} / {}
// - notification: {"method":"utxosChangedNotification","params":{"UtxosChanged":{"added":[...],"removed":[...]}}}
//                 {"method":"blockAddedNotification","params":{"BlockAdded":{"block":{...}}}}
// - a script public key is one hex string: the 2-byte version, then the script.
// - an unknown method name closes the socket, so only the methods below are ever sent.

/// The JSON encoding of wRPC, both ways.
enum WRPCJSON {
    enum CodecError: Error, LocalizedError {
        case unsupportedRequest
        var errorDescription: String? { "This request can't be sent over wRPC" }
    }

    // MARK: Requests

    /// The method and params for `message`. Throws for a request K never sends.
    static func request(_ message: Protowire_KaspadMessage) throws -> (method: String, params: [String: Any]) {
        guard let payload = message.payload else { throw CodecError.unsupportedRequest }
        switch payload {
        case .getInfoRequest:
            return ("getInfo", [:])
        case .getUtxosByAddressesRequest(let r):
            return ("getUtxosByAddresses", ["addresses": r.addresses])
        case .submitTransactionRequest(let r):
            return ("submitTransaction", ["transaction": transactionJSON(r.transaction), "allowOrphan": r.allowOrphan])
        case .notifyUtxosChangedRequest(let r):
            let method = r.command == .notifyStop ? "unsubscribe" : "subscribe"
            return (method, ["UtxosChanged": ["addresses": r.addresses]])
        case .notifyBlockAddedRequest(let r):
            let method = r.command == .notifyStop ? "unsubscribe" : "subscribe"
            return (method, ["BlockAdded": [String: Any]()])
        case .getPeerAddressesRequest:
            return ("getPeerAddresses", [:])
        case .getConnectedPeerInfoRequest:
            return ("getConnectedPeerInfo", [:])
        case .getBlockDagInfoRequest:
            return ("getBlockDagInfo", [:])
        case .getCurrentNetworkRequest:
            return ("getCurrentNetwork", [:])
        case .getMempoolEntryRequest(let r):
            return ("getMempoolEntry", [
                "transactionId": r.txID,
                "includeOrphanPool": r.includeOrphanPool,
                "filterTransactionPool": r.filterTransactionPool,
            ])
        case .getFeeEstimateRequest:
            return ("getFeeEstimate", [:])
        default:
            throw CodecError.unsupportedRequest
        }
    }

    /// A transaction as wRPC takes it. `mass` and `storageMass` must match when both are given
    /// (the node refuses the request otherwise), so both carry the protobuf's `storageMass`.
    static func transactionJSON(_ tx: Protowire_RpcTransaction) -> [String: Any] {
        var inputs: [[String: Any]] = []
        for input in tx.inputs {
            var outpoint: [String: Any] = [:]
            outpoint["transactionId"] = input.previousOutpoint.transactionID
            outpoint["index"] = NSNumber(value: input.previousOutpoint.index)
            var json: [String: Any] = [:]
            json["previousOutpoint"] = outpoint
            json["signatureScript"] = input.signatureScript
            json["sequence"] = NSNumber(value: input.sequence)
            json["sigOpCount"] = NSNumber(value: input.sigOpCount)
            json["computeBudget"] = NSNumber(value: input.computeBudget)
            inputs.append(json)
        }
        var outputs: [[String: Any]] = []
        for output in tx.outputs {
            var json: [String: Any] = [:]
            json["value"] = NSNumber(value: output.amount)
            json["scriptPublicKey"] = scriptHex(version: output.scriptPublicKey.version,
                                                script: output.scriptPublicKey.scriptPublicKey)
            if output.hasCovenant {
                var binding: [String: Any] = [:]
                binding["authorizingInput"] = NSNumber(value: output.covenant.authorizingInput)
                binding["covenantId"] = output.covenant.covenantID
                json["covenant"] = binding
            } else {
                json["covenant"] = NSNull()
            }
            outputs.append(json)
        }
        var json: [String: Any] = [:]
        json["version"] = NSNumber(value: tx.version)
        json["inputs"] = inputs
        json["outputs"] = outputs
        json["lockTime"] = NSNumber(value: tx.lockTime)
        json["subnetworkId"] = tx.subnetworkID
        json["gas"] = NSNumber(value: tx.gas)
        json["payload"] = tx.payload
        json["mass"] = NSNumber(value: tx.storageMass)
        json["storageMass"] = NSNumber(value: tx.storageMass)
        return json
    }

    // MARK: Answers and notifications

    /// What one message from the node means.
    enum Incoming {
        /// An answer (an error answer in its request's shape, as gRPC sends one) or a
        /// notification, in gRPC's form.
        case message(Protowire_KaspadMessage)
        case ignored
    }

    /// Decodes one text frame. `typeOf` takes the request type sent under an id (wRPC answers a
    /// subscribe and an unsubscribe of either kind with the same method name, and an error answer
    /// with no payload to tell its type by).
    static func decode(_ text: String, typeOf: (UInt64) -> KaspaRequestType?) -> Incoming {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        let method = root["method"] as? String ?? ""

        if let rawId = root["id"], !(rawId is NSNull) {
            let id = u64(rawId)
            // An answer to nothing sent on this socket (or sent and since forgotten) is dropped.
            guard let type = typeOf(id) else { return .ignored }
            if let error = root["error"], !(error is NSNull) {
                let text = (error as? [String: Any])?["message"] as? String ?? String(describing: error)
                return .message(errorAnswer(text.isEmpty ? "Node error" : text, for: type))
            }
            let params = root["params"] as? [String: Any] ?? [:]
            return .message(answer(params, for: type))
        }

        let params = root["params"] as? [String: Any] ?? [:]
        switch method {
        case "utxosChangedNotification":
            let body = params["UtxosChanged"] as? [String: Any] ?? params
            var n = Protowire_UtxosChangedNotificationMessage()
            n.added = (body["added"] as? [[String: Any]] ?? []).map(utxoEntry)
            n.removed = (body["removed"] as? [[String: Any]] ?? []).map(utxoEntry)
            var msg = Protowire_KaspadMessage()
            msg.utxosChangedNotification = n
            return .message(msg)
        case "blockAddedNotification":
            let body = params["BlockAdded"] as? [String: Any] ?? params
            let block = body["block"] as? [String: Any] ?? [:]
            var n = Protowire_BlockAddedNotificationMessage()
            var rpcBlock = Protowire_RpcBlock()
            if ExplorerBlockDetail.wanted {
                // The Explorer lists the block itself: its hash, scores, time, parents, children
                // and every transaction, as gRPC sends them.
                if let header = block["header"] as? [String: Any] { rpcBlock.header = blockHeader(header) }
                if let verbose = block["verboseData"] as? [String: Any] { rpcBlock.verboseData = blockVerboseData(verbose) }
                rpcBlock.transactions = (block["transactions"] as? [[String: Any]] ?? []).map(transaction)
            } else if BlockScanRegistry.shared.hasHandlers {
                // Only what a payload scan reads (`ScannedBlock`): the transactions that carry
                // one. Ten blocks a second arrive.
                rpcBlock.transactions = (block["transactions"] as? [[String: Any]] ?? [])
                    .filter { !((($0["payload"] as? String) ?? "").isEmpty) }
                    .map(transaction)
            }
            // With nothing listening the block stays empty: the subscription manager only needs
            // to see that one arrived.
            n.block = rpcBlock
            var msg = Protowire_KaspadMessage()
            msg.blockAddedNotification = n
            return .message(msg)
        default:
            return .ignored
        }
    }

    /// An error answer in the shape of the request it answers, as gRPC sends one.
    static func errorAnswer(_ text: String, for type: KaspaRequestType) -> Protowire_KaspadMessage {
        var error = Protowire_RPCError()
        error.message = text
        var msg = Protowire_KaspadMessage()
        switch type {
        case .getInfo: var r = Protowire_GetInfoResponseMessage(); r.error = error; msg.getInfoResponse = r
        case .getUtxosByAddresses: var r = Protowire_GetUtxosByAddressesResponseMessage(); r.error = error; msg.getUtxosByAddressesResponse = r
        case .submitTransaction: var r = Protowire_SubmitTransactionResponseMessage(); r.error = error; msg.submitTransactionResponse = r
        case .notifyUtxosChanged: var r = Protowire_NotifyUtxosChangedResponseMessage(); r.error = error; msg.notifyUtxosChangedResponse = r
        case .notifyBlockAdded: var r = Protowire_NotifyBlockAddedResponseMessage(); r.error = error; msg.notifyBlockAddedResponse = r
        case .getPeerAddresses: var r = Protowire_GetPeerAddressesResponseMessage(); r.error = error; msg.getPeerAddressesResponse = r
        case .getConnectedPeerInfo: var r = Protowire_GetConnectedPeerInfoResponseMessage(); r.error = error; msg.getConnectedPeerInfoResponse = r
        case .getBlockDagInfo: var r = Protowire_GetBlockDagInfoResponseMessage(); r.error = error; msg.getBlockDagInfoResponse = r
        case .getCurrentNetwork: var r = Protowire_GetCurrentNetworkResponseMessage(); r.error = error; msg.getCurrentNetworkResponse = r
        case .getMempoolEntry: var r = Protowire_GetMempoolEntryResponseMessage(); r.error = error; msg.getMempoolEntryResponse = r
        case .getFeeEstimate: var r = Protowire_GetFeeEstimateResponseMessage(); r.error = error; msg.getFeeEstimateResponse = r
        }
        return msg
    }

    private static func answer(_ p: [String: Any], for type: KaspaRequestType) -> Protowire_KaspadMessage {
        var msg = Protowire_KaspadMessage()
        switch type {
        case .getInfo:
            var r = Protowire_GetInfoResponseMessage()
            r.p2PID = str(p["p2pId"])
            r.mempoolSize = u64(p["mempoolSize"])
            r.serverVersion = str(p["serverVersion"])
            r.isUtxoIndexed = bool(p["isUtxoIndexed"])
            r.isSynced = bool(p["isSynced"])
            r.hasNotifyCommand_p = bool(p["hasNotifyCommand"])
            r.hasMessageID_p = bool(p["hasMessageId"])
            msg.getInfoResponse = r
        case .getUtxosByAddresses:
            var r = Protowire_GetUtxosByAddressesResponseMessage()
            r.entries = (p["entries"] as? [[String: Any]] ?? []).map(utxoEntry)
            msg.getUtxosByAddressesResponse = r
        case .submitTransaction:
            var r = Protowire_SubmitTransactionResponseMessage()
            r.transactionID = str(p["transactionId"])
            msg.submitTransactionResponse = r
        case .notifyUtxosChanged:
            msg.notifyUtxosChangedResponse = Protowire_NotifyUtxosChangedResponseMessage()
        case .notifyBlockAdded:
            msg.notifyBlockAddedResponse = Protowire_NotifyBlockAddedResponseMessage()
        case .getPeerAddresses:
            var r = Protowire_GetPeerAddressesResponseMessage()
            r.addresses = (p["knownAddresses"] as? [[String: Any]] ?? []).compactMap(knownAddress)
            r.bannedAddresses = (p["bannedAddresses"] as? [[String: Any]] ?? []).compactMap(knownAddress)
            msg.getPeerAddressesResponse = r
        case .getConnectedPeerInfo:
            var r = Protowire_GetConnectedPeerInfoResponseMessage()
            r.infos = (p["peerInfo"] as? [[String: Any]] ?? []).map { j in
                var info = Protowire_GetConnectedPeerInfoMessage()
                info.id = str(j["id"])
                if let a = j["address"] as? [String: Any] { info.address = hostPort(a) ?? "" }
                info.lastPingDuration = i64(j["last_ping_duration"] ?? j["lastPingDuration"])
                info.isOutbound = bool(j["is_outbound"] ?? j["isOutbound"])
                info.timeOffset = i64(j["time_offset"] ?? j["timeOffset"])
                info.userAgent = str(j["user_agent"] ?? j["userAgent"])
                info.advertisedProtocolVersion = UInt32(clamping: u64(j["advertised_protocol_version"] ?? j["advertisedProtocolVersion"]))
                info.timeConnected = i64(j["time_connected"] ?? j["timeConnected"])
                info.isIbdPeer = bool(j["is_ibd_peer"] ?? j["isIbdPeer"])
                return info
            }
            msg.getConnectedPeerInfoResponse = r
        case .getBlockDagInfo:
            var r = Protowire_GetBlockDagInfoResponseMessage()
            r.networkName = networkName(str(p["network"]))
            r.blockCount = u64(p["blockCount"])
            r.headerCount = u64(p["headerCount"])
            r.tipHashes = p["tipHashes"] as? [String] ?? []
            r.difficulty = double(p["difficulty"])
            r.pastMedianTime = i64(p["pastMedianTime"])
            r.virtualParentHashes = p["virtualParentHashes"] as? [String] ?? []
            r.pruningPointHash = str(p["pruningPointHash"])
            r.virtualDaaScore = u64(p["virtualDaaScore"])
            r.sink = str(p["sink"])
            msg.getBlockDagInfoResponse = r
        case .getCurrentNetwork:
            var r = Protowire_GetCurrentNetworkResponseMessage()
            r.currentNetwork = str(p["network"])
            msg.getCurrentNetworkResponse = r
        case .getMempoolEntry:
            var r = Protowire_GetMempoolEntryResponseMessage()
            if let e = p["mempoolEntry"] as? [String: Any] {
                var entry = Protowire_RpcMempoolEntry()
                entry.fee = u64(e["fee"])
                entry.isOrphan = bool(e["is_orphan"] ?? e["isOrphan"])
                if let tx = e["transaction"] as? [String: Any] { entry.transaction = transaction(tx) }
                r.entry = entry
            }
            msg.getMempoolEntryResponse = r
        case .getFeeEstimate:
            var r = Protowire_GetFeeEstimateResponseMessage()
            if let e = p["estimate"] as? [String: Any] {
                var estimate = Protowire_RpcFeeEstimate()
                if let b = e["priorityBucket"] as? [String: Any] { estimate.priorityBucket = bucket(b) }
                estimate.normalBuckets = (e["normalBuckets"] as? [[String: Any]] ?? []).map(bucket)
                estimate.lowBuckets = (e["lowBuckets"] as? [[String: Any]] ?? []).map(bucket)
                r.estimate = estimate
            }
            msg.getFeeEstimateResponse = r
        }
        return msg
    }

    /// wRPC names networks "mainnet" / "testnet-10"; gRPC's getBlockDagInfo says "kaspa-mainnet",
    /// which is what the registry's network checks compare against (`NodeRegistry.belongs`).
    static func networkName(_ name: String) -> String {
        guard !name.isEmpty, !name.hasPrefix("kaspa-") else { return name }
        return "kaspa-\(name)"
    }

    // MARK: Pieces

    /// rusty-kaspa's `RpcHeader` in JSON: hashes as hex strings, `parentsByLevel` as arrays of them,
    /// `timestamp` in milliseconds.
    private static func blockHeader(_ j: [String: Any]) -> Protowire_RpcBlockHeader {
        var h = Protowire_RpcBlockHeader()
        h.hash = str(j["hash"])
        h.version = UInt32(clamping: u64(j["version"]))
        if let levels = j["parentsByLevel"] as? [[String]] {
            h.parents = levels.map { hashes in
                var level = Protowire_RpcBlockLevelParents()
                level.parentHashes = hashes
                return level
            }
        } else if let levels = j["parents"] as? [[String: Any]] {
            h.parents = levels.map { l in
                var level = Protowire_RpcBlockLevelParents()
                level.parentHashes = l["parentHashes"] as? [String] ?? []
                return level
            }
        }
        h.hashMerkleRoot = str(j["hashMerkleRoot"])
        h.acceptedIDMerkleRoot = str(j["acceptedIdMerkleRoot"])
        h.utxoCommitment = str(j["utxoCommitment"])
        h.timestamp = i64(j["timestamp"])
        h.bits = UInt32(clamping: u64(j["bits"]))
        h.nonce = u64(j["nonce"])
        h.daaScore = u64(j["daaScore"])
        h.blueWork = str(j["blueWork"])
        h.blueScore = u64(j["blueScore"])
        h.pruningPoint = str(j["pruningPoint"])
        return h
    }

    /// rusty-kaspa's `RpcBlockVerboseData` in JSON.
    private static func blockVerboseData(_ j: [String: Any]) -> Protowire_RpcBlockVerboseData {
        var v = Protowire_RpcBlockVerboseData()
        v.hash = str(j["hash"])
        v.difficulty = double(j["difficulty"])
        v.selectedParentHash = str(j["selectedParentHash"])
        v.transactionIds = j["transactionIds"] as? [String] ?? []
        v.isHeaderOnly = bool(j["isHeaderOnly"])
        v.blueScore = u64(j["blueScore"])
        v.childrenHashes = j["childrenHashes"] as? [String] ?? []
        v.mergeSetBluesHashes = j["mergeSetBluesHashes"] as? [String] ?? []
        v.mergeSetRedsHashes = j["mergeSetRedsHashes"] as? [String] ?? []
        v.isChainBlock = bool(j["isChainBlock"])
        return v
    }

    private static func bucket(_ j: [String: Any]) -> Protowire_RpcFeerateBucket {
        var b = Protowire_RpcFeerateBucket()
        b.feerate = double(j["feerate"])
        b.estimatedSeconds = double(j["estimatedSeconds"])
        return b
    }

    private static func utxoEntry(_ j: [String: Any]) -> Protowire_RpcUtxosByAddressesEntry {
        var entry = Protowire_RpcUtxosByAddressesEntry()
        entry.address = str(j["address"])
        if let o = j["outpoint"] as? [String: Any] { entry.outpoint = outpoint(o) }
        if let u = j["utxoEntry"] as? [String: Any] {
            var utxo = Protowire_RpcUtxoEntry()
            utxo.amount = u64(u["amount"])
            utxo.scriptPublicKey = scriptPublicKey(u["scriptPublicKey"])
            utxo.blockDaaScore = u64(u["blockDaaScore"])
            utxo.isCoinbase = bool(u["isCoinbase"])
            utxo.covenantID = str(u["covenantId"])
            entry.utxoEntry = utxo
        }
        return entry
    }

    private static func outpoint(_ j: [String: Any]) -> Protowire_RpcOutpoint {
        var o = Protowire_RpcOutpoint()
        o.transactionID = str(j["transactionId"])
        o.index = UInt32(clamping: u64(j["index"]))
        return o
    }

    static func transaction(_ j: [String: Any]) -> Protowire_RpcTransaction {
        var tx = Protowire_RpcTransaction()
        tx.version = UInt32(clamping: u64(j["version"]))
        tx.inputs = (j["inputs"] as? [[String: Any]] ?? []).map { i in
            var input = Protowire_RpcTransactionInput()
            if let o = i["previousOutpoint"] as? [String: Any] { input.previousOutpoint = outpoint(o) }
            input.signatureScript = str(i["signatureScript"])
            input.sequence = u64(i["sequence"])
            input.sigOpCount = UInt32(clamping: u64(i["sigOpCount"]))
            if let budget = i["computeBudget"], !(budget is NSNull) {
                input.computeBudget = UInt32(clamping: u64(budget))
            }
            return input
        }
        tx.outputs = (j["outputs"] as? [[String: Any]] ?? []).map { o in
            var output = Protowire_RpcTransactionOutput()
            output.amount = u64(o["value"] ?? o["amount"])
            output.scriptPublicKey = scriptPublicKey(o["scriptPublicKey"])
            if let c = o["covenant"] as? [String: Any] {
                var binding = Protowire_RpcCovenantBinding()
                binding.authorizingInput = UInt32(clamping: u64(c["authorizingInput"]))
                binding.covenantID = str(c["covenantId"])
                output.covenant = binding
            }
            if let v = o["verboseData"] as? [String: Any] {
                var verbose = Protowire_RpcTransactionOutputVerboseData()
                verbose.scriptPublicKeyType = str(v["scriptPublicKeyType"])
                verbose.scriptPublicKeyAddress = str(v["scriptPublicKeyAddress"])
                output.verboseData = verbose
            }
            return output
        }
        tx.lockTime = u64(j["lockTime"])
        tx.subnetworkID = str(j["subnetworkId"])
        tx.gas = u64(j["gas"])
        tx.payload = str(j["payload"])
        tx.storageMass = u64(j["storageMass"] ?? j["mass"])
        if let v = j["verboseData"] as? [String: Any] {
            var verbose = Protowire_RpcTransactionVerboseData()
            verbose.transactionID = str(v["transactionId"])
            verbose.hash = str(v["hash"])
            verbose.computeMass = u64(v["computeMass"])
            verbose.blockHash = str(v["blockHash"])
            verbose.blockTime = u64(v["blockTime"])
            tx.verboseData = verbose
        }
        return tx
    }

    /// "0000" + script hex (the version as two big-endian bytes, then the script), or an object.
    private static func scriptPublicKey(_ value: Any?) -> Protowire_RpcScriptPublicKey {
        var spk = Protowire_RpcScriptPublicKey()
        if let hex = value as? String {
            guard hex.count >= 4 else { return spk }
            spk.version = UInt32(hex.prefix(4), radix: 16) ?? 0
            spk.scriptPublicKey = String(hex.dropFirst(4))
        } else if let j = value as? [String: Any] {
            spk.version = UInt32(clamping: u64(j["version"]))
            spk.scriptPublicKey = str(j["script"] ?? j["scriptPublicKey"])
        }
        return spk
    }

    private static func scriptHex(version: UInt32, script: String) -> String {
        String(format: "%04x", min(version, UInt32(UInt16.max))) + script
    }

    private static func knownAddress(_ j: [String: Any]) -> Protowire_GetPeerAddressesKnownAddressMessage? {
        guard let addr = hostPort(j) else { return nil }
        var a = Protowire_GetPeerAddressesKnownAddressMessage()
        a.addr = addr
        return a
    }

    /// {"ip": "...", "port": 16111} as gRPC writes it: "host:port", "[ipv6]:port". An IPv4 address
    /// mapped into IPv6 ("::ffff:1.2.3.4") is written as plain IPv4.
    private static func hostPort(_ j: [String: Any]) -> String? {
        var ip = str(j["ip"])
        let port = u64(j["port"])
        guard !ip.isEmpty, port > 0 else { return nil }
        if ip.lowercased().hasPrefix("::ffff:"), ip.dropFirst(7).contains(".") { ip = String(ip.dropFirst(7)) }
        return ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }

    // MARK: Values (JSONSerialization hands numbers back as NSNumber)

    static func u64(_ value: Any?) -> UInt64 {
        switch value {
        case let n as NSNumber:
            if let d = n as? NSDecimalNumber { return UInt64(d.stringValue) ?? n.uint64Value }
            return n.uint64Value
        case let s as String: return UInt64(s) ?? 0
        default: return 0
        }
    }

    private static func i64(_ value: Any?) -> Int64 {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? 0
        default: return 0
        }
    }

    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func str(_ value: Any?) -> String {
        value as? String ?? ""
    }
}

// MARK: - The socket

/// One WebSocket to a node's wRPC JSON listener. Frames are decoded off the connection actor, in
/// order, and handed to it as gRPC messages through `incoming`.
final class WRPCSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Ten blocks a second and an address with many coins: URLSession's 1 MiB default is too small.
    private static let maximumMessageSize = 32 * 1024 * 1024

    let url: URL
    let incoming: AsyncStream<Protowire_KaspadMessage>
    private let incomingContinuation: AsyncStream<Protowire_KaspadMessage>.Continuation

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var nextId: UInt64 = 0
    /// Requests sent and not yet answered, by id. An id the node never answers would stay for the
    /// socket's life, so old ones are dropped (`trimSentTypes`): no request waits that long.
    private var sentTypes: [UInt64: (type: KaspaRequestType, at: Date)] = [:]
    private static let sentTypesLimit = 256
    private static let sentTypeMaxAge: TimeInterval = 120
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var opened = false
    private var finished = false
    /// Called once, when the socket closes or fails after it opened.
    var onClose: (@Sendable (Error?) -> Void)?

    init(url: URL) {
        self.url = url
        var continuation: AsyncStream<Protowire_KaspadMessage>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        incomingContinuation = continuation
        super.init()
    }

    /// Opens the socket; returns once the handshake is done.
    func open() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        // URLSessionWebSocketTask treats this as an idle timeout on receive: at 15 s the standby
        // (pinged every 60 s) was cut and redialed with TLS again and again. The connect is
        // bounded by `GRPCStreamConnection`'s own connect timeout.
        config.timeoutIntervalForRequest = 300
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumMessageSize
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume(throwing: KasiaError.networkError("Connection closed"))
                    return
                }
                openContinuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.close()
        }
        receiveNext()
    }

    /// Sends a request; `completion` gets the write's failure, if any.
    func send(_ message: Protowire_KaspadMessage, type: KaspaRequestType,
              completion: @escaping @Sendable (Error?) -> Void) {
        let request: (method: String, params: [String: Any])
        do {
            request = try WRPCJSON.request(message)
        } catch {
            completion(error)
            return
        }
        lock.lock()
        guard let task, !finished else {
            lock.unlock()
            completion(KasiaError.networkError("Connection closed"))
            return
        }
        nextId += 1
        let id = nextId
        if sentTypes.count >= 32 { trimSentTypes() }
        sentTypes[id] = (type, Date())
        lock.unlock()

        let body: [String: Any] = ["id": NSNumber(value: id), "method": request.method, "params": request.params]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else {
            forget(id)
            completion(WRPCJSON.CodecError.unsupportedRequest)
            return
        }
        task.send(.string(text)) { [weak self] error in
            if error != nil { self?.forget(id) }
            completion(error)
        }
    }

    func close() {
        lock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        let pendingOpen = openContinuation
        openContinuation = nil
        let wasFinished = finished
        finished = true
        sentTypes.removeAll()
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        pendingOpen?.resume(throwing: KasiaError.networkError("Connection closed"))
        if !wasFinished { incomingContinuation.finish() }
    }

    /// Called with the lock held: forgets answers older than any request's timeout, then the
    /// oldest ones past the limit.
    private func trimSentTypes() {
        let cutoff = Date().addingTimeInterval(-Self.sentTypeMaxAge)
        sentTypes = sentTypes.filter { $0.value.at >= cutoff }
        if sentTypes.count >= Self.sentTypesLimit {
            for id in sentTypes.keys.sorted().prefix(sentTypes.count - Self.sentTypesLimit + 1) {
                sentTypes[id] = nil
            }
        }
    }

    private func forget(_ id: UInt64) {
        lock.lock()
        sentTypes[id] = nil
        lock.unlock()
    }

    private func typeOf(_ id: UInt64) -> KaspaRequestType? {
        lock.lock()
        defer { lock.unlock() }
        return sentTypes.removeValue(forKey: id)?.type
    }

    private func receiveNext() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text {
                    if case .message(let msg) = WRPCJSON.decode(text, typeOf: { id in self.typeOf(id) }) {
                        self.incomingContinuation.yield(msg)
                    }
                }
                self.receiveNext()
            case .failure(let error):
                self.finish(error)
            }
        }
    }

    /// The socket ended on its own (not through `close()`).
    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pendingOpen = openContinuation
        openContinuation = nil
        let wasOpen = opened
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        let onClose = self.onClose
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        incomingContinuation.finish()
        if let pendingOpen {
            pendingOpen.resume(throwing: error ?? KasiaError.networkError("Connection failed"))
        } else if wasOpen {
            onClose?(error)
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        opened = true
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(KasiaError.networkError("Socket closed (\(closeCode.rawValue))"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error ?? KasiaError.networkError("Socket closed"))
    }
}
