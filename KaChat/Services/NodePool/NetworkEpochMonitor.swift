import Foundation
import Network
import Combine

/// Monitors network path changes and manages "epochs" to prevent
/// VPN/WiFi/cellular switches from poisoning node health stats
@MainActor
final class NetworkEpochMonitor: ObservableObject {
    // MARK: - Singleton

    static let shared = NetworkEpochMonitor()

    // MARK: - Published Properties

    @Published private(set) var epochId: Int = 0
    @Published private(set) var networkQuality: NetworkQuality = .good
    @Published private(set) var isOnline: Bool = true
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var isConstrained: Bool = false

    // MARK: - Private Properties

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.kachat.network.epoch.monitor")
    private var currentPath: NWPath?
    private var lastPathChangeTime: Date?

    // Callbacks for epoch changes
    private var epochChangeCallbacks: [(Int) -> Void] = []

    /// Loops that wait out an offline spell (`waitUntilOnline`), resumed when the path is back.
    private var onlineWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Lifecycle

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
        AppLog.log("[NetworkEpoch] Started monitoring")
    }

    func stop() {
        monitor.cancel()
        AppLog.log("[NetworkEpoch] Stopped monitoring")
    }

    // MARK: - Path Handling

    private func handlePathUpdate(_ path: NWPath) {
        let oldQuality = networkQuality

        // Update basic status
        isOnline = Self.isUsable(path)
        if isOnline { resumeOnlineWaiters() }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        // Detect significant path change
        let isSignificantChange = detectSignificantChange(from: currentPath, to: path)

        if isSignificantChange {
            // Bump epoch
            epochId += 1
            lastPathChangeTime = Date()

            AppLog.log("[NetworkEpoch] Path changed significantly - new epoch: %d", epochId)
            AppLog.log("[NetworkEpoch] Status: %@, Expensive: %@, Constrained: %@",
                  isOnline ? "online" : "offline",
                  isExpensive ? "yes" : "no",
                  isConstrained ? "yes" : "no")

            // Notify callbacks
            for callback in epochChangeCallbacks {
                callback(epochId)
            }
        }

        // Update network quality
        networkQuality = determineQuality(path: path)

        if networkQuality != oldQuality {
            AppLog.log("[NetworkEpoch] Network quality changed: %@ -> %@",
                  String(describing: oldQuality), String(describing: networkQuality))
        }

        currentPath = path
    }

    /// Detect if path change is significant enough to warrant epoch bump
    private func detectSignificantChange(from oldPath: NWPath?, to newPath: NWPath) -> Bool {
        guard let old = oldPath else {
            // First path update
            return true
        }

        // Status change (online <-> offline)
        if old.status != newPath.status {
            return true
        }

        // The interface traffic actually goes out on changed (WiFi <-> cellular, a VPN taking
        // over). Only the first, preferred interface counts: the whole set changes whenever
        // cellular comes up beside WiFi or a hotspot appears, and that used to tear down the
        // subscription and force a full catch-up for a path every socket was still using.
        if old.availableInterfaces.first?.type != newPath.availableInterfaces.first?.type {
            return true
        }

        // Expensive status change (usually VPN toggle)
        if old.isExpensive != newPath.isExpensive {
            return true
        }

        // Constrained status change
        if old.isConstrained != newPath.isConstrained {
            return true
        }

        return false
    }

    /// Whether traffic can go out on `path`. `.requiresConnection` counts: an on-demand VPN
    /// reports it until a connection is attempted, which is what brings the tunnel up. Read as
    /// offline, every loop waiting for the network (`waitUntilOnline`) waited until something
    /// else happened to connect (audit 2026-11-25 N9).
    private static func isUsable(_ path: NWPath) -> Bool {
        path.status == .satisfied || path.status == .requiresConnection
    }

    /// Determine network quality tier from path
    private func determineQuality(path: NWPath) -> NetworkQuality {
        guard Self.isUsable(path) else {
            return .offline
        }
        // An on-demand tunnel not up yet has no interface to judge by.
        if path.status == .requiresConnection {
            return .good
        }

        let interfaces = path.availableInterfaces

        // Check for WiFi
        let hasWifi = interfaces.contains { $0.type == .wifi }
        let hasCellular = interfaces.contains { $0.type == .cellular }

        if hasWifi {
            if path.isExpensive || path.isConstrained {
                return .good  // Metered WiFi
            }
            return .excellent
        }

        if hasCellular {
            if path.isConstrained {
                return .poor  // Low data mode
            }
            return .good
        }

        // Wired or other
        return .excellent
    }

    // MARK: - Public API

    /// True when the current network path should be treated as metered: cellular, a personal
    /// hotspot, or Low Data Mode (constrained). This is THE gate for cellular data reduction -
    /// block streams, probe cadences, sweep intervals and cloud-sync floors all key off it so
    /// WiFi behavior stays unchanged while expensive paths trade a little latency for a lot
    /// less transfer.
    var isExpensivePath: Bool {
        isExpensive || isConstrained
    }

    /// Hedge delay honoring expensive paths. NetworkQuality maps cellular (.good) to a LOWER
    /// hedge delay than unmetered WiFi (400ms vs 3000ms), which fires the duplicate backup
    /// request far more often exactly where every byte is metered. On an expensive path the
    /// hedge never fires sooner than it would on unmetered WiFi.
    var effectiveHedgeDelayMs: UInt64 {
        let base = networkQuality.hedgeDelayMs
        guard isExpensivePath else { return base }
        return max(base, NetworkQuality.excellent.hedgeDelayMs)
    }

    /// Returns once the device is online (at once if it is, or the task is cancelled). The probe,
    /// discovery and resubscribe loops wait here instead of retrying against a dead network.
    func waitUntilOnline() async {
        if isOnline || Task.isCancelled { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOnline || Task.isCancelled {
                    continuation.resume()
                } else {
                    onlineWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resumeOnlineWaiter(id) }
        }
    }

    private func resumeOnlineWaiter(_ id: UUID) {
        onlineWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeOnlineWaiters() {
        guard !onlineWaiters.isEmpty else { return }
        let waiters = onlineWaiters
        onlineWaiters.removeAll()
        for continuation in waiters.values { continuation.resume() }
    }

    /// Register a callback for epoch changes
    func onEpochChange(_ callback: @escaping (Int) -> Void) {
        epochChangeCallbacks.append(callback)
    }
}

// MARK: - Combine Publisher

extension NetworkEpochMonitor {
    /// Publisher for expensive-path (metered/constrained) transitions - see `isExpensivePath`.
    /// Emits only on actual changes so subscribers can re-evaluate gating without churn.
    var expensivePathPublisher: AnyPublisher<Bool, Never> {
        $isExpensive
            .combineLatest($isConstrained) { $0 || $1 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
