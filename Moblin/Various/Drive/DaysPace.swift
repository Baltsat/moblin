import Foundation

final class DaysPace: @unchecked Sendable {
    static let shared = DaysPace()
    static let chunkBytes = 1 << 20
    static let bytesPerSecond = 250_000.0

    private let lock = NSLock()
    private var liveValue = false

    static var live: Bool {
        shared.lock.withLock { shared.liveValue }
    }

    static func setLive(_ value: Bool) {
        shared.lock.withLock { shared.liveValue = value }
    }

    static func sleep(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while live, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    static func space(bytes: Int, since start: Date) async {
        await sleep(seconds: Double(bytes) / bytesPerSecond - Date().timeIntervalSince(start))
    }

    static func pauseWhileLive() async {
        while live, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
