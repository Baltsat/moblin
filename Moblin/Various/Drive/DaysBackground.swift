import Foundation
import UIKit

private let daysBackgroundIdentifier = "com.baltsat.moblin-dais.upload"
private let daysDetachedPrefix = "remainder|"

final class DaysBackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = DaysBackgroundUploader()
    static let lanes = 6

    private struct Waiter {
        let continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>
        let progress: (@Sendable (Int64) -> Void)?
        var data = Data()
    }

    private let lock = NSLock()
    private var waiters: [String: Waiter] = [:]
    private var eventsHandlers: [String: () -> Void] = [:]
    private var detachedReports: [String: (at: Date, sent: Int64, speed: Double)] = [:]
    private var laneSessions: [URLSession?] = Array(repeating: nil, count: DaysBackgroundUploader.lanes)
    private var cleanupTask: Task<Void, Never>?
    var onDetachedComplete: (@Sendable (String) -> Void)?
    private let chunkDir: URL = {
        let url = createAndGetDirectory(root: .cachesDirectory, name: "BackgroundChunks")
        excludeFromBackup(url)
        return url
    }()

    private func identifier(_ lane: Int) -> String {
        "\(daysBackgroundIdentifier).\(lane)"
    }

    private func session(_ lane: Int) -> URLSession {
        let lane = min(max(lane, 0), DaysBackgroundUploader.lanes - 1)
        return lock.withLock {
            if let session = laneSessions[lane] {
                return session
            }
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier(lane))
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.allowsCellularAccess = true
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 6 * 3600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            laneSessions[lane] = session
            return session
        }
    }

    private func allSessions() -> [URLSession] {
        (0 ..< DaysBackgroundUploader.lanes).map { session($0) }
    }

    private func key(_ session: URLSession, _ task: URLSessionTask) -> String {
        "\(session.configuration.identifier ?? "")#\(task.taskIdentifier)"
    }

    func attach(identifier: String, completionHandler: @escaping () -> Void) {
        daysLog("handleEventsForBackgroundURLSession attach \(identifier)")
        lock.withLock { eventsHandlers[identifier] = completionHandler }
        _ = allSessions()
    }

    func upload(_ request: URLRequest,
                data: Data,
                lane: Int = 0,
                wifiOnly: Bool,
                progress: (@Sendable (Int64) -> Void)?) async throws -> (HTTPURLResponse, Data)
    {
        await cleanup().value
        let file = chunkDir.appending(component: "chunk-\(UUID().uuidString).bin")
        try data.write(to: file, options: .atomic)
        return try await upload(request, file: file, lane: lane, wifiOnly: wifiOnly, progress: progress, deleteFile: true)
    }

    func upload(_ request: URLRequest,
                file: URL,
                lane: Int = 0,
                wifiOnly: Bool,
                progress: (@Sendable (Int64) -> Void)?,
                deleteFile: Bool = false) async throws -> (HTTPURLResponse, Data)
    {
        await cleanup().value
        var request = request
        request.allowsCellularAccess = !wifiOnly
        defer {
            if deleteFile {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let laneSession = session(lane)
        let task = laneSession.uploadTask(with: request, fromFile: file)
        let taskKey = key(laneSession, task)
        daysLog("task \(taskKey) created")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiters[taskKey] = Waiter(continuation: continuation, progress: progress)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func cleanup() -> Task<Void, Never> {
        lock.withLock {
            if let cleanupTask {
                return cleanupTask
            }
            let task = Task { [self] in
                for session in allSessions() {
                    let tasks = await session.allTasks
                    for task in tasks where !(task.taskDescription ?? "").hasPrefix(daysDetachedPrefix) {
                        task.cancel()
                    }
                }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: chunkDir.path)) ?? []
                for name in names {
                    try? FileManager.default.removeItem(at: chunkDir.appending(component: name))
                }
                daysLog("cleanup done")
            }
            cleanupTask = task
            return task
        }
    }

    func startDetached(_ request: URLRequest, file: URL, name: String, base: Int64, lane: Int) {
        var request = request
        request.allowsCellularAccess = false
        request.allowsExpensiveNetworkAccess = false
        request.allowsConstrainedNetworkAccess = false
        let task = session(lane).uploadTask(with: request, fromFile: file)
        task.taskDescription = "\(daysDetachedPrefix)\(name)|\(base)"
        task.resume()
    }

    func detachedStates() async -> [(name: String, state: URLSessionTask.State, sent: Int64)] {
        var out: [(name: String, state: URLSessionTask.State, sent: Int64)] = []
        for session in allSessions() {
            for task in await session.allTasks {
                if let info = detachedInfo(task) {
                    out.append((info.name, task.state, task.countOfBytesSent))
                }
            }
        }
        return out
    }

    func cancelDetached(name: String) async {
        for session in allSessions() {
            for task in await session.allTasks where (task.taskDescription ?? "").hasPrefix("\(daysDetachedPrefix)\(name)|") {
                task.cancel()
            }
        }
    }

    func hasDetached(name: String) async -> Bool {
        for session in allSessions() {
            let tasks = await session.allTasks
            if tasks.contains(where: { task in
                (task.taskDescription ?? "").hasPrefix("\(daysDetachedPrefix)\(name)|") && task.state != .completed
            }) {
                return true
            }
        }
        return false
    }

    private func detachedInfo(_ task: URLSessionTask) -> (name: String, base: Int64)? {
        guard let text = task.taskDescription, text.hasPrefix(daysDetachedPrefix) else {
            return nil
        }
        let parts = text.dropFirst(daysDetachedPrefix.count).split(separator: "|")
        guard parts.count == 2, let base = Int64(parts[1]) else {
            return nil
        }
        return (String(parts[0]), base)
    }

    private func reportDetached(_ info: (name: String, base: Int64), taskKey: String, sent: Int64) {
        let now = Date()
        let report: (at: Date, sent: Int64, speed: Double)? = lock.withLock {
            let last = detachedReports[taskKey]
            let dt = last.map { now.timeIntervalSince($0.at) } ?? 99
            guard dt >= 2 else {
                return nil
            }
            var speed = last?.speed ?? 0
            if let last, dt < 10 {
                let instant = Double(sent - last.sent) / dt
                speed = speed == 0 ? instant : 0.7 * speed + 0.3 * instant
            }
            detachedReports[taskKey] = (now, sent, speed)
            return (now, sent, speed)
        }
        guard let report else {
            return
        }
        let total = info.base + report.sent
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                daysQueue.live[info.name] = DaysLive(sent: total, speed: report.speed, at: report.at)
            }
        }
        daysQueueUpdate(info.name) { $0.driveAcked = total }
    }

    func start() {
        _ = cleanup()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData _: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend _: Int64)
    {
        let taskKey = key(session, task)
        let progress = lock.withLock { waiters[taskKey]?.progress }
        progress?(totalBytesSent)
        if progress == nil, let info = detachedInfo(task) {
            reportDetached(info, taskKey: taskKey, sent: totalBytesSent)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskKey = key(session, dataTask)
        lock.withLock { waiters[taskKey]?.data.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskKey = key(session, task)
        daysLog("task \(taskKey) done status=\((task.response as? HTTPURLResponse)?.statusCode ?? -1) error=\(error?.localizedDescription ?? "-")")
        guard let waiter = lock.withLock({ waiters.removeValue(forKey: taskKey) }) else {
            if let info = detachedInfo(task) {
                lock.withLock { _ = detachedReports.removeValue(forKey: taskKey) }
                onDetachedComplete?(info.name)
            }
            return
        }
        if let error {
            waiter.continuation.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse {
            waiter.continuation.resume(returning: (response, waiter.data))
        } else {
            waiter.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock {
            let id = session.configuration.identifier ?? ""
            let handler = eventsHandlers[id]
            eventsHandlers[id] = nil
            return handler
        }
        guard let handler else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            handler()
        }
    }
}

@MainActor
final class DaysBackgroundTask {
    static let shared = DaysBackgroundTask()
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        guard identifier == .invalid else {
            return
        }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "days-upload") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
