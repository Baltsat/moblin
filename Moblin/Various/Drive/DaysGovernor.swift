import Foundation

final class DaysGovernor: @unchecked Sendable {
    static let shared = DaysGovernor()
    static let startRate = 250_000.0
    static let minRate = 125_000.0
    static let maxRate = 2_000_000.0
    static let fastLaneRate = 750_000.0

    private let lock = NSLock()
    private var rate = DaysGovernor.startRate
    private var dropped = 0
    private var lastDropped = 0
    private var task: Task<Void, Never>?

    static var bytesPerSecond: Double {
        shared.lock.withLock { shared.rate }
    }

    static var thermalCalm: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .nominal || state == .fair
    }

    static var lanes: Int {
        bytesPerSecond >= fastLaneRate && thermalCalm ? 2 : 1
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
        let old: Task<Void, Never>? = lock.withLock {
            rate = Self.startRate
            lastDropped = dropped
            let old = task
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
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
        let (bps, delta): (Double, Int) = lock.withLock {
            let delta = dropped - lastDropped
            lastDropped = dropped
            if thermal == .critical {
                rate = 0
            } else if delta > 0 || thermal == .serious {
                rate = max(rate / 2, Self.minRate)
            } else {
                rate = min(rate + 250_000, Self.maxRate)
            }
            return (rate, delta)
        }
        daysLog("governor bps=\(Int(bps)) thermal=\(thermal.rawValue) dropped=\(delta) lanes=\(Self.lanes)")
    }
}
