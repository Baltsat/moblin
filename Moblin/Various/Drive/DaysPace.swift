import Foundation

final class DaysPace: @unchecked Sendable {
    static let shared = DaysPace()
    static var chunkBytes: Int {
        DaysGovernor.charging ? 8 << 20 : 1 << 20
    }

    private let lock = NSLock()
    private var streaming = false
    private var recording = false

    static var live: Bool {
        shared.lock.withLock { shared.streaming || shared.recording }
    }

    static var lanes: Int {
        DaysGovernor.lanes
    }

    static func setStreaming(_ value: Bool) {
        update { shared.streaming = value }
    }

    static func setRecording(_ value: Bool) {
        update { shared.recording = value }
    }

    private static func update(_ change: () -> Void) {
        let (before, after) = shared.lock.withLock {
            let before = shared.streaming || shared.recording
            change()
            return (before, shared.streaming || shared.recording)
        }
        if after, !before {
            DaysGovernor.start()
        } else if before, !after {
            DaysGovernor.stop()
        }
    }

    static func sleep(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while live, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    static func space(bytes: Int, since start: Date) async {
        DaysGovernor.noteSent(bytes)
        await sleep(seconds: Double(bytes) / max(DaysGovernor.bytesPerSecond, DaysGovernor.minRate) - Date().timeIntervalSince(start))
    }

    static func pauseWhileLive() async {
        while live, DaysGovernor.bytesPerSecond == 0 || DaysNet.shared.current != .wifi, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
