import Foundation
import Network
import SwiftUI

enum DaysPrefs {
    static let wifiOnly = "daysWifiOnly"
    static let youTubeEnabled = "daysYouTubeEnabled"
    static let youTubeCellular = "daysYouTubeCellular"
    static let githubArchive = "daysGitHubArchive"
    static let autoStart = "daysAutoStartRecording"
    static let torchDefault = "daysTorchDefault"
    static let dimDelay = "daysDimDelay"
    static let lastSync = "daysLastSync"

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static var isWifiOnly: Bool {
        bool(wifiOnly, true)
    }

    static var isGitHubArchive: Bool {
        bool(githubArchive, false)
    }

    static var dimSeconds: Int {
        min(UserDefaults.standard.object(forKey: dimDelay) as? Int ?? 8, 10)
    }
}

enum DaysNetKind: String {
    case wifi = "Wi-Fi"
    case cellular = "Cellular"
    case offline = "Offline"
}

final class DaysNet: @unchecked Sendable {
    static let shared = DaysNet()
    private let lock = NSLock()
    private var kind = DaysNetKind.offline
    private var observers: [@Sendable () -> Void] = []
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            let kind: DaysNetKind = if path.status != .satisfied {
                .offline
            } else if path.usesInterfaceType(.cellular) {
                .cellular
            } else {
                .wifi
            }
            daysLog("net kind=\(kind) wifi=\(path.usesInterfaceType(.wifi)) cell=\(path.usesInterfaceType(.cellular)) expensive=\(path.isExpensive) constrained=\(path.isConstrained) status=\(path.status) avail=\(path.availableInterfaces.map { "\($0.type)" })")
            let observers = self.lock.withLock {
                self.kind = kind
                return self.observers
            }
            for observer in observers {
                observer()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.baltsat.days.path"))
    }

    var current: DaysNetKind {
        lock.withLock { kind }
    }

    var isOnline: Bool {
        current != .offline
    }

    func canUpload() -> Bool {
        DaysPrefs.isWifiOnly ? current == .wifi : isOnline
    }

    func canStream(cellular: Bool) -> Bool {
        cellular ? isOnline : current == .wifi
    }

    func observe(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(observer) }
    }
}

func daysSession(allowCellular: Bool, request: TimeInterval = 90, resource: TimeInterval = 3600) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.allowsCellularAccess = allowCellular
    configuration.timeoutIntervalForRequest = request
    configuration.timeoutIntervalForResource = resource
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
}

func daysBackoff(_ failures: Int) -> Int {
    min(5 << min(max(failures, 1), 5), 120)
}

@MainActor
final class DaysNetStatus: ObservableObject {
    @Published var kind = DaysNet.shared.current
    @Published var queueCount = 0
    @Published var queueBytes: Int64 = 0
    @Published var githubPending = 0
    @Published var lastSync: Date? = UserDefaults.standard.object(forKey: DaysPrefs.lastSync) as? Date

    init() {
        DaysNet.shared.observe {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    daysNetStatus.kind = DaysNet.shared.current
                }
            }
        }
    }

    func markSynced() {
        let now = Date()
        lastSync = now
        UserDefaults.standard.set(now, forKey: DaysPrefs.lastSync)
    }
}

@MainActor
let daysNetStatus = DaysNetStatus()
