import Foundation
import UIKit

private let daysBackgroundIdentifier = "com.baltsat.moblin-dais.upload"

final class DaysBackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = DaysBackgroundUploader()

    private struct Waiter {
        let continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>
        let progress: (@Sendable (Int64) -> Void)?
        var data = Data()
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    private var eventsHandler: (() -> Void)?
    private var chunkDir: URL = {
        createAndGetDirectory(root: .cachesDirectory, name: "BackgroundChunks")
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: daysBackgroundIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func attach(completionHandler: @escaping () -> Void) {
        lock.withLock { eventsHandler = completionHandler }
        _ = session
    }

    func upload(_ request: URLRequest,
                data: Data,
                wifiOnly: Bool,
                progress: (@Sendable (Int64) -> Void)?) async throws -> (HTTPURLResponse, Data)
    {
        await cleanup.value
        let file = chunkDir.appending(component: "chunk-\(UUID().uuidString).bin")
        try data.write(to: file, options: .atomic)
        return try await upload(request, file: file, wifiOnly: wifiOnly, progress: progress, deleteFile: true)
    }

    func upload(_ request: URLRequest,
                file: URL,
                wifiOnly: Bool,
                progress: (@Sendable (Int64) -> Void)?,
                deleteFile: Bool = false) async throws -> (HTTPURLResponse, Data)
    {
        await cleanup.value
        var request = request
        request.allowsCellularAccess = !wifiOnly
        defer {
            if deleteFile {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let task = session.uploadTask(with: request, fromFile: file)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiters[task.taskIdentifier] = Waiter(continuation: continuation, progress: progress)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private lazy var cleanup = Task { [self] in
        let tasks = await session.allTasks
        for task in tasks {
            task.cancel()
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: chunkDir.path)) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: chunkDir.appending(component: name))
        }
    }

    func start() {
        _ = cleanup
    }

    func urlSession(_: URLSession, task: URLSessionTask, didSendBodyData _: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend _: Int64)
    {
        let progress = lock.withLock { waiters[task.taskIdentifier]?.progress }
        progress?(totalBytesSent)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { waiters[dataTask.taskIdentifier]?.data.append(data) }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let waiter = lock.withLock({ waiters.removeValue(forKey: task.taskIdentifier) }) else {
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

    func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        let handler = lock.withLock {
            let handler = eventsHandler
            eventsHandler = nil
            return handler
        }
        guard let handler else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
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
