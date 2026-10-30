import Foundation

final class DaysGovernor: @unchecked Sendable {
    static let shared = DaysGovernor()
    static let startRate = 250_000.0
    static let minRate = 125_000.0
    static let maxRate = 2_000_000.0
    static let fastLaneRate = 750_000.0
    static let chargingStartRate = 4_000_000.0
    static let chargingMaxRate = 40_000_000.0

    private let lock = NSLock()
    private var rate = DaysGovernor.startRate
    private var dropped = 0
    private var lastDropped = 0
    private var task: Task<Void, Never>?
    private var powered = false
    private var sent = 0
    private var tickAt = Date()

    static var bytesPerSecond: Double {
        shared.lock.withLock { shared.rate }
    }

    static var thermalCalm: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .nominal || state == .fair
    }

    /// user-req: on unmetered Wi-Fi and a charger, upload everything during a take; dropped frames or heat still back off.
    static var charging: Bool {
        shared.lock.withLock { shared.powered } && DaysNet.shared.unmeteredWifi
    }

    static var lanes: Int {
        guard bytesPerSecond >= fastLaneRate, thermalCalm else {
            return 1
        }
        return charging ? 3 : 2
    }

    static func setPowered(_ value: Bool) {
        shared.lock.withLock { shared.powered = value }
    }

    static func noteSent(_ bytes: Int) {
        shared.lock.withLock { shared.sent += bytes }
    }

    static func noteDroppedFrame() {
        shared.lock.withLock { shared.dropped += 1 }
    }

    static func start() {
        shared.begin()
    }

    static func stop() {
        shared.end()
    }

    private func begin() {
        let charging = Self.charging
        let old: Task<Void, Never>? = lock.withLock {
            rate = charging ? Self.chargingStartRate : Self.startRate
            lastDropped = dropped
            sent = 0
            tickAt = Date()
            let old = task
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.charging ? 10 : 30))
                    if Task.isCancelled {
                        break
                    }
                    self?.tick()
                }
            }
            return old
        }
        old?.cancel()
    }

    private func end() {
        let old: Task<Void, Never>? = lock.withLock {
            let old = task
            task = nil
            return old
        }
        old?.cancel()
    }

    private func tick() {
        let thermal = ProcessInfo.processInfo.thermalState
        let charging = Self.charging
        let (bps, delta, sentRate): (Double, Int, Int) = lock.withLock {
            let delta = dropped - lastDropped
            lastDropped = dropped
            let sentRate = Int(Double(sent) / max(Date().timeIntervalSince(tickAt), 1))
            sent = 0
            tickAt = Date()
            if thermal == .critical {
                rate = 0
            } else if delta > 0 || thermal == .serious {
                rate = max(rate / 2, Self.minRate)
            } else if charging {
                rate = min(max(rate * 2, Self.startRate), Self.chargingMaxRate)
            } else {
                rate = min(rate + 250_000, Self.maxRate)
            }
            return (rate, delta, sentRate)
        }
        daysLog("governor bps=\(Int(bps)) sent=\(sentRate) thermal=\(thermal.rawValue) dropped=\(delta) lanes=\(Self.lanes) charging=\(charging)")
        driveUploader.event(
            type: "upload",
            detail: "{\"limit\":\(Int(bps)),\"sent\":\(sentRate),\"dropped\":\(delta),\"thermal\":\(thermal.rawValue),\"charging\":\(charging)}"
        )
    }
}
