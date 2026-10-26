import Foundation

final class DaysPace: @unchecked Sendable {
    static let shared = DaysPace()
    static let chunkBytes = 1 << 20
    static let bytesPerSecond = 250_000.0

    private let lock = NSLock()
    private var streaming = false
    private var recording = false

    static var live: Bool {
        shared.lock.withLock { shared.streaming || shared.recording }
    }

    static func setStreaming(_ value: Bool) {
        shared.lock.withLock { shared.streaming = value }
    }

    static func setRecording(_ value: Bool) {
        shared.lock.withLock { shared.recording = value }
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
