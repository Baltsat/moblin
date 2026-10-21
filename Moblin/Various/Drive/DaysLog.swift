import Foundation

final class DaysLog: @unchecked Sendable {
    static let shared = DaysLog()
    private let lock = NSLock()
    private let url = URL.documentsDirectory.appending(component: "days-upload.log")
    private var writes = 0
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(text)\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url)
            }
        } catch {
            logger.info("days: log write failed \(error)")
        }
        writes += 1
        if writes % 50 == 0 {
            trim()
        }
    }

    private func trim() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 600 else {
            return
        }
        try? Data((lines.suffix(450).joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }
}

func daysLog(_ text: String) {
    DaysLog.shared.write(text)
}
