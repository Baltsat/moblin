import Foundation
import Network
import UIKit

private let drivePartSize = 8 * 1024 * 1024
private let driveChunkParts = 4
private let driveGroupBytes: Int64 = 1 << 30
private let driveMinFreeBytes: Int64 = 300 << 20

final class DriveMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAt = Date.distantPast
    private var lastSent: Int64 = 0
    private var speed = 0.0

    func report(name: String, sent: Int64, total: Int64) {
        let now = Date()
        lock.lock()
        let dt = now.timeIntervalSince(lastAt)
        guard dt >= 0.5 || sent >= total else {
            lock.unlock()
            return
        }
        if dt < 5 {
            let instant = max(Double(sent - lastSent) / dt, 0)
            speed = speed == 0 ? instant : 0.7 * speed + 0.3 * instant
        } else {
            speed = 0
        }
        lastAt = now
        lastSent = sent
        let currentSpeed = speed
        lock.unlock()
        let percent = total > 0 ? min(Int(sent * 100 / total), 100) : 0
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                daysQueue.live[name] = DaysLive(sent: sent, speed: currentSpeed, at: now)
                driveStatus.percent = percent
            }
        }
    }
}
private let driveRootFolderName = "Days"
private let drivePhoneFolderName = "phone"
private let driveMimeType = "video/mp4"
private let driveSidecarInterval: TimeInterval = 300

private let driveNameFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Makassar")
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    return formatter
}()

private func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

struct DriveSessionInfo: Codable, Sendable {
    var device: String
    var codec: String
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var localPath: String?
}

struct DriveSidecarEvent: Codable, Sendable {
    var tMs: Int64
    var type: String
    var detail: String

    enum CodingKeys: String, CodingKey {
        case tMs = "t_ms"
        case type
        case detail
    }
}

private struct DriveSidecar: Encodable {
    struct Video: Encodable {
        let codec: String
        let width: Int
        let height: Int
        let fps: Int
        let bitrateKbps: Int

        enum CodingKeys: String, CodingKey {
            case codec
            case width
            case height
            case fps
            case bitrateKbps = "bitrate_kbps"
        }
    }

    struct Audio: Encodable {
        let codec = "aac"
        let rate = 48000
        let channels = 2
    }

    let stream = "phone"
    let session: String
    let startMs: Int64
    let endMs: Int64?
    let tz = "Asia/Makassar"
    let device: String
    let video: Video
    let audio = Audio()
    let bytes: Int64
    let events: [DriveSidecarEvent]

    enum CodingKeys: String, CodingKey {
        case stream
        case session
        case startMs = "start_ms"
        case endMs = "end_ms"
        case tz
        case device
        case video
        case audio
        case bytes
        case events
    }
}

private struct DriveManifest: Codable {
    var name: String
    var startMs: Int64
    var endMs: Int64?
    var info: DriveSessionInfo
    var events: [DriveSidecarEvent] = []
    var closed = false
    var bytesTotal: Int64 = 0
    var uploadUrl: String?
    var acked: Int64 = 0
    var folderId: String?
    var videoFileId: String?
    var sidecarFileId: String?
    var sidecarSyncedEvents = 0
    var sidecarSyncedClosed = false
    var done = false
    var failed = false
    var githubHanded: Bool?
    var remStart: Int64?
    var remEnd: Int64?
    var remReadyStored: Bool?
    var bgActiveStored: Bool?
    var lane: Int?
    var fromFileStored: Bool?

    var fromFile: Bool {
        get { fromFileStored ?? false }
        set { fromFileStored = newValue }
    }

    var remReady: Bool {
        get { remReadyStored ?? false }
        set { remReadyStored = newValue }
    }

    var bgActive: Bool {
        get { bgActiveStored ?? false }
        set { bgActiveStored = newValue }
    }
}

private final class DriveSession {
    var manifest: DriveManifest
    let dir: URL
    var tailIndex = 0
    var buffer = Data()
    var handle: FileHandle?
    var needsResync = false
    var sidecarSyncedAt = Date.distantPast

    init(manifest: DriveManifest, dir: URL) {
        self.manifest = manifest
        self.dir = dir
    }

    func partUrl(_ index: Int) -> URL {
        dir.appending(component: String(format: "part-%06d.bin", index))
    }

    func tailUrl(_ index: Int) -> URL {
        dir.appending(component: String(format: "tail-%06d.bin", index))
    }

    var manifestUrl: URL {
        dir.appending(component: "manifest.json")
    }

    func save() {
        guard let data = try? JSONEncoder().encode(manifest) else {
            return
        }
        try? data.write(to: manifestUrl, options: .atomic)
    }

    func committedParts() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix("tail-"), name.hasSuffix(".bin") else {
                return nil
            }
            return Int(name.dropFirst(5).dropLast(4))
        }.max() ?? 0
    }

    func tailSize(_ index: Int) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: tailUrl(index).path)[.size] as? Int) ?? 0
    }

    func pruneParts() {
        save()
        let first = Int(manifest.acked) / drivePartSize
        for index in 0 ..< first {
            try? FileManager.default.removeItem(at: partUrl(index))
        }
    }
}

enum DriveInput: Sendable {
    case arm(DriveSessionInfo)
    case disarm
    case segment(Data, initial: Bool)
    case recorderStopped
    case event(type: String, detail: String)
    case localFile(String)
    case resume
    case background(Bool)
    case bgFinished(String)
    case requeue(name: String, startMs: Int64, path: String)
    case watchdog
}

private func makeStream<T: Sendable>(
    of _: T.Type,
    policy: AsyncStream<T>.Continuation.BufferingPolicy = .unbounded
) -> (AsyncStream<T>, AsyncStream<T>.Continuation) {
    var continuation: AsyncStream<T>.Continuation?
    let stream = AsyncStream<T>(bufferingPolicy: policy) { continuation = $0 }
    return (stream, continuation!)
}

private actor DriveEngine {
    private let api = DriveApi()
    private let root = createAndGetDirectoryWithoutBackup(name: "DriveOutbox")
    private var armed: DriveSessionInfo?
    private var current: DriveSession?
    private var sessions: [String: DriveSession] = [:]
    private var failures: [String: Int] = [:]
    private var workers: [String: (lane: Int, task: Task<Void, Never>)] = [:]
    private var folderTasks: [String: Task<String, Error>] = [:]
    private var inBackground = false
    private var lastStatus = ""
    private var lastBgLog = Date.distantPast
    private var bgProgress: [String: (sent: Int64, at: Date)] = [:]
    private var folderIds: [String: String] = [:]
    private var meters: [String: DriveMeter] = [:]
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    init() {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path
        )
        let pair = makeStream(of: Void.self, policy: .bufferingNewest(1))
        wakeStream = pair.0
        wakeContinuation = pair.1
    }

    func run() async {
        for await _ in wakeStream {
            await drain()
        }
    }

    func handle(_ input: DriveInput) {
        switch input {
        case .background, .bgFinished, .recorderStopped, .arm, .disarm:
            daysLog("input \(input)")
        default:
            break
        }
        switch input {
        case let .arm(info):
            armed = info
        case .disarm:
            armed = nil
        case let .segment(data, initial):
            ingest(data, initial: initial)
        case .recorderStopped:
            closeCurrent()
        case let .event(type, detail):
            addEvent(type: type, detail: detail)
        case let .localFile(path):
            armed?.localPath = path
        case .resume:
            recover()
            wake()
        case .watchdog:
            wake()
        case let .background(value):
            inBackground = value
            recover()
            wake()
        case let .requeue(name, startMs, path):
            requeue(name: name, startMs: startMs, path: path)
            wake()
        case let .bgFinished(name):
            recover()
            if let session = sessions[name] {
                session.manifest.bgActive = false
                session.needsResync = true
                session.save()
            }
            wake()
        }
    }

    private func wake() {
        wakeContinuation.yield()
    }

    private func ingest(_ data: Data, initial: Bool) {
        if initial {
            closeCurrent()
            guard let armed else {
                return
            }
            startSession(info: armed)
        }
        guard let session = current else {
            return
        }
        session.buffer.append(data)
        try? session.handle?.write(contentsOf: data)
        var cut = false
        while session.buffer.count >= drivePartSize {
            cutPart(session)
            cut = true
        }
        if cut {
            wake()
        }
        updateStatus()
    }

    private func startSession(info: DriveSessionInfo) {
        let start = Date()
        let name = "\(driveNameFormatter.string(from: start))_phone"
        let dir = createAndGetDirectory(root: root, name: name)
        let session = DriveSession(
            manifest: DriveManifest(name: name, startMs: nowMs(), info: info),
            dir: dir
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
        FileManager.default.createFile(atPath: session.tailUrl(0).path, contents: nil)
        session.handle = try? FileHandle(forWritingTo: session.tailUrl(0))
        session.save()
        sessions[name] = session
        current = session
        daysQueueUpdate(name, startMs: session.manifest.startMs) { _ in }
        wake()
    }

    private func cutPart(_ session: DriveSession) {
        let index = session.tailIndex
        let part = Data(session.buffer.prefix(drivePartSize))
        let rest = Data(session.buffer.dropFirst(drivePartSize))
        guard (try? part.write(to: session.partUrl(index), options: .atomic)) != nil,
              (try? rest.write(to: session.tailUrl(index + 1), options: .atomic)) != nil
        else {
            logger.info("drive: Failed to cut part \(index)")
            return
        }
        try? session.handle?.close()
        session.handle = try? FileHandle(forWritingTo: session.tailUrl(index + 1))
        _ = try? session.handle?.seekToEnd()
        try? FileManager.default.removeItem(at: session.tailUrl(index))
        session.buffer = rest
        session.tailIndex = index + 1
    }

    private func closeCurrent() {
        guard let session = current else {
            return
        }
        try? session.handle?.close()
        session.handle = nil
        session.manifest.closed = true
        session.manifest.endMs = nowMs()
        session.manifest.bytesTotal = Int64(session.tailIndex * drivePartSize + session.buffer.count)
        session.save()
        current = nil
        handToGitHub(session)
        wake()
        updateStatus()
    }

    private func handToGitHub(_ session: DriveSession) {
        guard githubAuth.isSignedIn, DaysPrefs.isGitHubArchive,
              session.manifest.githubHanded != true,
              let localPath = session.manifest.info.localPath.map(daysCurrentPath),
              let sidecar = try? sidecarData(session)
        else {
            return
        }
        session.manifest.githubHanded = true
        session.save()
        let tag = session.manifest.name
        Task {
            try? await Task.sleep(for: .seconds(2))
            if await githubArchive.enqueue(tag: tag, localPath: localPath, sidecar: sidecar) {
                logger.info("drive: Started GitHub archive of \(tag) in parallel")
            }
        }
    }

    private func addEvent(type: String, detail: String) {
        guard let session = current else {
            return
        }
        session.manifest.events.append(DriveSidecarEvent(tMs: nowMs(), type: type, detail: detail))
        session.save()
    }

    private func localFile(_ manifest: DriveManifest) -> (url: URL, size: Int64)? {
        guard let path = manifest.info.localPath.map(daysCurrentPath),
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64, size > 0
        else {
            return nil
        }
        return (URL(fileURLWithPath: path), size)
    }

    private func restartFromFile(_ session: DriveSession) -> Bool {
        guard session.manifest.closed, let local = localFile(session.manifest) else {
            return false
        }
        try? FileManager.default.removeItem(at: remainderUrl(session))
        session.manifest.fromFile = true
        session.manifest.bytesTotal = local.size
        session.manifest.uploadUrl = nil
        session.manifest.acked = 0
        session.manifest.remStart = nil
        session.manifest.remEnd = nil
        session.manifest.remReady = false
        session.manifest.bgActive = false
        session.manifest.failed = false
        session.needsResync = false
        session.save()
        daysLog("restart from local file \(session.manifest.name) \(local.size)")
        return true
    }

    private func requeue(name: String, startMs: Int64, path: String) {
        let dir = root.appending(component: name)
        guard sessions[name] == nil, !FileManager.default.fileExists(atPath: dir.path),
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64, size > 0
        else {
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest = DriveManifest(name: name, startMs: startMs, info: DriveSessionInfo(
            device: "iPhone", codec: "h264", width: 1920, height: 1080, fps: 30, bitrateKbps: 12000, localPath: path
        ))
        manifest.closed = true
        manifest.bytesTotal = size
        manifest.fromFile = true
        let session = DriveSession(manifest: manifest, dir: dir)
        session.save()
        sessions[name] = session
        daysLog("requeued \(name) from \(path) \(size)")
        logger.info("drive: Re-queued \(name) from the local recording")
    }

    private func recover() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names.sorted() where sessions[name] == nil {
            let dir = root.appending(component: name)
            guard let data = try? Data(contentsOf: dir.appending(component: "manifest.json")) else {
                continue
            }
            let manifest: DriveManifest
            do {
                manifest = try JSONDecoder().decode(DriveManifest.self, from: data)
            } catch {
                daysLog("manifest decode failed \(name): \(error)")
                continue
            }
            if manifest.done {
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            let session = DriveSession(manifest: manifest, dir: dir)
            if manifest.failed {
                _ = restartFromFile(session)
            }
            session.tailIndex = session.committedParts()
            session.needsResync = true
            if !manifest.closed, !manifest.fromFile {
                let tailSize = session.tailSize(session.tailIndex)
                session.manifest.closed = true
                session.manifest.endMs = nowMs()
                session.manifest.bytesTotal = Int64(session.tailIndex * drivePartSize + tailSize)
                session.save()
            }
            sessions[name] = session
            daysLog("recovered \(name) acked=\(manifest.acked)/\(manifest.bytesTotal) closed=\(manifest.closed)")
        }
    }

    private func reconcileBackground() async {
        guard sessions.values.contains(where: { $0.manifest.bgActive }) else {
            return
        }
        let states = await DaysBackgroundUploader.shared.detachedStates()
        if Date().timeIntervalSince(lastBgLog) > 60 {
            lastBgLog = Date()
            daysLog("detached tasks \(states.map { "\($0.name.prefix(17)) state=\($0.state.rawValue) sent=\($0.sent)" })")
        }
        for session in sessions.values where session.manifest.bgActive {
            let name = session.manifest.name
            let live = states.filter { $0.name == name && $0.state != .completed }
            if live.isEmpty {
                session.manifest.bgActive = false
                session.needsResync = true
                session.save()
                bgProgress[name] = nil
                continue
            }
            guard !inBackground else {
                bgProgress[name] = nil
                continue
            }
            let sent = live.map(\.sent).max() ?? 0
            if let last = bgProgress[name], last.sent == sent {
                if Date().timeIntervalSince(last.at) > 150 {
                    daysLog("detached task stalled \(name) sent=\(sent), restarting in foreground")
                    await DaysBackgroundUploader.shared.cancelDetached(name: name)
                    session.manifest.bgActive = false
                    session.needsResync = true
                    session.save()
                    bgProgress[name] = nil
                }
            } else {
                bgProgress[name] = (sent, Date())
            }
        }
    }

    private func drain() async {
        await reconcileBackground()
        guard driveAuth.isSignedIn else {
            if sessions.values.contains(where: { !$0.manifest.done && !$0.manifest.failed }) {
                setStatus("Google Drive: sign in again")
            }
            return
        }
        guard DaysNet.shared.canUpload() else {
            if sessions.values.contains(where: { !$0.manifest.done && !$0.manifest.failed }) {
                setStatus("Google Drive: waiting for network")
            }
            updateStatus()
            return
        }
        let eligible = sessions.values
            .filter { !$0.manifest.done && !$0.manifest.failed && !$0.manifest.bgActive && workers[$0.manifest.name] == nil }
            .sorted { ($0.manifest.bytesTotal - $0.manifest.acked) < ($1.manifest.bytesTotal - $1.manifest.acked) }
        let detached = sessions.values.filter { $0.manifest.bgActive }.count
        var free = (DaysPace.live ? 1 : DaysBackgroundUploader.lanes) - workers.count - detached
        for session in eligible where free > 0 {
            guard let lane = freeLane() else {
                break
            }
            free -= 1
            let name = session.manifest.name
            daysLog("worker start \(name) lane=\(lane) acked=\(session.manifest.acked)/\(session.manifest.bytesTotal)")
            workers[name] = (lane, Task { await self.work(session, lane: lane) })
        }
        updateStatus()
    }

    private func freeLane() -> Int? {
        var used = Set(workers.values.map(\.lane))
        for session in sessions.values where session.manifest.bgActive {
            if let lane = session.manifest.lane {
                used.insert(lane)
            }
        }
        return (0 ..< DaysBackgroundUploader.lanes).first { !used.contains($0) }
    }

    private func work(_ session: DriveSession, lane: Int) async {
        let name = session.manifest.name
        session.manifest.lane = lane
        var restart = false
        loop: while true {
            guard DaysNet.shared.canUpload() else {
                setStatus("Google Drive: waiting for network")
                break
            }
            if DaysPace.live, lane != 0 {
                break
            }
            do {
                guard try await step(session, lane: lane) else {
                    break
                }
                failures[name] = 0
                updateStatus()
            } catch DriveError.notSignedIn {
                daysLog("not signed in")
                setStatus("Google Drive: sign in again")
                break
            } catch DriveError.fatal(let message) {
                daysLog("fatal \(message)")
                logger.info("drive: Fatal: \(message)")
                if !session.manifest.fromFile, restartFromFile(session) {
                    continue loop
                }
                session.manifest.failed = true
                session.save()
                setStatus("Google Drive: failed, \(message)")
                restart = true
                break
            } catch DriveError.sessionGone {
                daysLog("session gone \(name)")
                logger.info("drive: Upload session is gone")
                if session.manifest.acked < Int64(drivePartSize) {
                    session.manifest.uploadUrl = nil
                    session.manifest.acked = 0
                    session.needsResync = false
                    session.save()
                    continue loop
                }
                if restartFromFile(session) {
                    continue loop
                }
                session.manifest.failed = true
                session.save()
                setStatus("Google Drive: upload session lost, local recording missing")
                restart = true
                break
            } catch {
                session.needsResync = true
                failures[name, default: 0] += 1
                let full = "\(error)".contains("storageQuotaExceeded")
                let delay = full ? 300 : daysBackoff(failures[name] ?? 1)
                logger.info("drive: Retry in \(delay) seconds after \(error)")
                daysLog("retry \(name) in \(delay)s after \(error)")
                setStatus(full ? "Google Drive: storage is full" : "Google Drive: waiting for network, retry in \(delay) s")
                let continuation = wakeContinuation
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    continuation.yield()
                }
                break
            }
        }
        daysLog("worker end \(name) acked=\(session.manifest.acked)")
        workers[name] = nil
        if restart || session.manifest.done || session.manifest.bgActive {
            wake()
        }
    }

    private func step(_ session: DriveSession, lane: Int) async throws -> Bool {
        guard driveAuth.isSignedIn else {
            throw DriveError.notSignedIn
        }
        if session.manifest.uploadUrl == nil {
            let folder = try await ensureFolder(name: session.manifest.name)
            session.manifest.folderId = folder
            daysQueueUpdate(session.manifest.name, startMs: session.manifest.startMs) { $0.driveFolderId = folder }
            if session.manifest.fromFile, let existing = try await api.findFile(name: "\(session.manifest.name).mp4", folderId: folder) {
                daysLog("already on Drive \(session.manifest.name) \(existing)")
                session.manifest.videoFileId = existing
                session.manifest.acked = session.manifest.bytesTotal
                session.save()
                try await finish(session)
                return true
            }
            session.manifest.uploadUrl = try await api.startResumable(
                name: "\(session.manifest.name).mp4",
                folderId: folder,
                mimeType: driveMimeType
            )
            session.manifest.acked = 0
            session.save()
        }
        guard let uploadUrl = session.manifest.uploadUrl else {
            return false
        }
        if session.manifest.videoFileId != nil {
            try await finish(session)
            return true
        }
        try? await syncSidecar(session, force: false)
        if session.needsResync {
            let total = session.manifest.closed ? session.manifest.bytesTotal : nil
            daysLog("query status \(session.manifest.name)")
            let result = try await api.queryStatus(uploadUrl: uploadUrl, total: total, lane: lane)
            daysLog("status result \(result)")
            session.needsResync = false
            if try await apply(result, to: session) {
                return true
            }
        }
        if session.manifest.bgActive {
            return false
        }
        if session.manifest.remStart != nil {
            return try await stepRemainder(session, uploadUrl: uploadUrl, lane: lane)
        }
        if session.manifest.fromFile {
            return try await stepFile(session, uploadUrl: uploadUrl, lane: lane)
        }
        if inBackground, session.manifest.closed, !DaysPace.live, try await startBackground(session, uploadUrl: uploadUrl, lane: lane) {
            return false
        }
        let committed = current === session ? session.tailIndex : session.committedParts()
        let ackedParts = Int(session.manifest.acked) / drivePartSize
        if ackedParts < committed {
            let skip = Int(session.manifest.acked) - ackedParts * drivePartSize
            var chunk = Data()
            let paced = DaysPace.live
            for index in ackedParts ..< min(ackedParts + (paced ? 1 : driveChunkParts), committed) {
                let part = try Data(contentsOf: session.partUrl(index))
                chunk.append(index == ackedParts ? Data(part.dropFirst(skip)) : part)
            }
            if paced {
                chunk = Data(chunk.prefix(DaysPace.chunkBytes))
            }
            session.needsResync = true
            let started = Date()
            daysLog("put chunk \(chunk.count) at \(session.manifest.acked) paced=\(paced)")
            let result = try await api.putChunk(
                uploadUrl: uploadUrl,
                data: chunk,
                offset: session.manifest.acked,
                total: nil,
                lane: lane,
                progress: progress(for: session)
            )
            session.needsResync = false
            daysLog("chunk result \(result)")
            _ = try await apply(result, to: session)
            if paced {
                setStatus("Google Drive: Paced for live")
                await DaysPace.space(bytes: chunk.count, since: started)
            }
            return true
        }
        guard session.manifest.closed else {
            return false
        }
        let tail = (try? Data(contentsOf: session.tailUrl(committed))) ?? Data()
        let skip = max(Int(session.manifest.acked) - committed * drivePartSize, 0)
        session.needsResync = true
        let result = try await api.putChunk(
            uploadUrl: uploadUrl,
            data: Data(tail.dropFirst(skip)),
            offset: session.manifest.acked,
            total: session.manifest.bytesTotal,
            lane: lane,
            progress: progress(for: session)
        )
        session.needsResync = false
        _ = try await apply(result, to: session)
        return true
    }

    private func remainderUrl(_ session: DriveSession) -> URL {
        session.dir.appending(component: "remainder.bin")
    }

    private func clearRemainder(_ session: DriveSession) {
        try? FileManager.default.removeItem(at: remainderUrl(session))
        session.manifest.remStart = nil
        session.manifest.remEnd = nil
        session.manifest.remReady = false
        session.manifest.bgActive = false
        session.save()
    }

    private func freeBytes() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func startBackground(_ session: DriveSession, uploadUrl: String, lane: Int) async throws -> Bool {
        let manifest = session.manifest
        guard manifest.bytesTotal > manifest.acked, freeBytes() > driveMinFreeBytes else {
            return false
        }
        let remaining = manifest.bytesTotal - manifest.acked
        let end: Int64 = remaining <= driveGroupBytes
            ? manifest.bytesTotal
            : (manifest.acked + driveGroupBytes) / Int64(drivePartSize) * Int64(drivePartSize)
        session.manifest.remStart = manifest.acked
        session.manifest.remEnd = end
        session.manifest.remReady = false
        session.save()
        try assemble(session)
        return try await startDetached(session, uploadUrl: uploadUrl, lane: lane)
    }

    private func stepFile(_ session: DriveSession, uploadUrl: String, lane: Int) async throws -> Bool {
        guard let local = localFile(session.manifest) else {
            session.manifest.failed = true
            session.save()
            setStatus("Google Drive: local recording missing")
            return false
        }
        let total = session.manifest.bytesTotal
        let acked = session.manifest.acked
        if inBackground, !DaysPace.live {
            let whole = acked == 0
            session.manifest.remStart = acked
            session.manifest.remEnd = whole ? total : min(acked + driveGroupBytes, total)
            session.manifest.remReady = false
            session.save()
            try assemble(session)
            return try await startDetached(session, uploadUrl: uploadUrl, lane: lane)
        }
        let count = Int(min(Int64(driveChunkParts * drivePartSize), total - acked))
        let chunk = try daysReadRange(local.url, offset: acked, count: count)
        session.needsResync = true
        daysLog("put file chunk \(chunk.count) at \(acked)/\(total)")
        let result = try await api.putChunk(
            uploadUrl: uploadUrl,
            data: chunk,
            offset: acked,
            total: acked + Int64(chunk.count) >= total ? total : nil,
            lane: lane,
            progress: progress(for: session)
        )
        session.needsResync = false
        _ = try await apply(result, to: session)
        return true
    }

    private func assemble(_ session: DriveSession) throws {
        guard let start = session.manifest.remStart, let end = session.manifest.remEnd else {
            return
        }
        if session.manifest.fromFile, let local = localFile(session.manifest) {
            if start == 0, end == local.size {
                try daysCloneFile(local.url, out: remainderUrl(session))
            } else {
                try daysCopyRange(local.url, start: start, end: end, out: remainderUrl(session))
            }
            session.manifest.remReady = true
            session.save()
            return
        }
        try daysAssembleRemainder(
            dir: session.dir,
            partSize: drivePartSize,
            committed: session.committedParts(),
            start: start,
            end: end,
            out: remainderUrl(session)
        )
        session.manifest.remReady = true
        session.save()
    }

    private func startDetached(_ session: DriveSession, uploadUrl: String, lane: Int) async throws -> Bool {
        guard let start = session.manifest.remStart, let end = session.manifest.remEnd,
              let url = URL(string: uploadUrl)
        else {
            return false
        }
        var end = end
        let acked = session.manifest.acked
        if acked > start {
            if session.manifest.fromFile, end - acked > driveGroupBytes, let local = localFile(session.manifest) {
                end = acked + driveGroupBytes
                try daysCopyRange(local.url, start: acked, end: end, out: remainderUrl(session))
                session.manifest.remEnd = end
            } else {
                try daysTrimFile(remainderUrl(session), dropFirst: acked - start)
            }
            session.manifest.remStart = acked
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("bytes \(acked)-\(end - 1)/\(session.manifest.bytesTotal)", forHTTPHeaderField: "Content-Range")
        request.setValue("Bearer \(try await driveAuth.accessToken())", forHTTPHeaderField: "Authorization")
        DaysBackgroundUploader.shared.startDetached(
            request,
            file: remainderUrl(session),
            name: session.manifest.name,
            base: acked,
            lane: lane
        )
        session.manifest.bgActive = true
        session.save()
        daysLog("detached task started \(session.manifest.name) \(acked)-\(end - 1)/\(session.manifest.bytesTotal)")
        setStatus("Google Drive: uploading in background")
        return true
    }

    private func stepRemainder(_ session: DriveSession, uploadUrl: String, lane: Int) async throws -> Bool {
        guard let start = session.manifest.remStart, let end = session.manifest.remEnd else {
            return false
        }
        if !session.manifest.remReady {
            try assemble(session)
        }
        if session.manifest.acked >= end {
            clearRemainder(session)
            return true
        }
        if inBackground, !DaysPace.live {
            _ = try await startDetached(session, uploadUrl: uploadUrl, lane: lane)
            return false
        }
        let acked = session.manifest.acked
        let count = Int(min(Int64(driveChunkParts * drivePartSize), end - acked))
        let chunk = try daysReadRange(remainderUrl(session), offset: acked - start, count: count)
        session.needsResync = true
        let result = try await api.putChunk(
            uploadUrl: uploadUrl,
            data: chunk,
            offset: acked,
            total: session.manifest.bytesTotal,
            lane: lane,
            progress: progress(for: session)
        )
        session.needsResync = false
        _ = try await apply(result, to: session)
        return true
    }

    private func progress(for session: DriveSession) -> @Sendable (Int64) -> Void {
        let name = session.manifest.name
        let meter = meters[name] ?? DriveMeter()
        meters[name] = meter
        let base = session.manifest.acked
        let total = session.manifest.closed
            ? session.manifest.bytesTotal
            : Int64(session.tailIndex * drivePartSize + session.buffer.count)
        return { sent in
            meter.report(name: name, sent: base + sent, total: max(total, base + sent))
        }
    }

    private func apply(_ result: DriveChunkResult, to session: DriveSession) async throws -> Bool {
        switch result {
        case let .incomplete(next):
            session.manifest.acked = next
            session.pruneParts()
            if let end = session.manifest.remEnd, next >= end {
                clearRemainder(session)
            }
            updateStatus()
            return false
        case let .complete(fileId):
            session.manifest.videoFileId = fileId
            session.manifest.acked = session.manifest.bytesTotal
            session.save()
            daysQueueUpdate(session.manifest.name, startMs: session.manifest.startMs) { $0.driveFileId = fileId }
            try await finish(session)
            return true
        }
    }

    private func finish(_ session: DriveSession) async throws {
        try await syncSidecar(session, force: true)
        session.manifest.done = true
        session.save()
        let fileId = session.manifest.videoFileId
        let totalBytes = session.manifest.bytesTotal
        daysQueueUpdate(session.manifest.name, startMs: session.manifest.startMs) {
            $0.driveDone = true
            $0.driveFileId = fileId
            $0.driveAcked = totalBytes
            $0.driveTotal = totalBytes
        }
        logger.info("drive: Uploaded \(session.manifest.name) (\(session.manifest.bytesTotal) bytes)")
        let name = session.manifest.name
        meters[name] = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                daysQueue.live[name] = nil
                driveStatus.percent = nil
            }
        }
        if session.manifest.githubHanded == true, DaysPrefs.isGitHubArchive {
            logger.info("drive: GitHub archive already running for \(session.manifest.name)")
        } else if let localPath = session.manifest.info.localPath.map(daysCurrentPath) {
            if githubAuth.isSignedIn, DaysPrefs.isGitHubArchive,
               let sidecar = try? sidecarData(session),
               await githubArchive.enqueue(tag: session.manifest.name, localPath: localPath, sidecar: sidecar)
            {
                logger.info("drive: Handed \(session.manifest.name) to the GitHub archive")
            } else {
                try? FileManager.default.removeItem(atPath: localPath)
            }
        }
        sessions[session.manifest.name] = nil
        try? FileManager.default.removeItem(at: session.dir)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                daysNetStatus.markSynced()
            }
        }
        setStatus("Google Drive: uploaded \(session.manifest.name)")
        Task { @MainActor in
            DaysIndex.shared.refreshAndPush()
        }
        wake()
    }

    private func ensureFolder(name: String) async throws -> String {
        let day = String(name.prefix(10)).split(separator: "-").map(String.init)
        guard day.count == 3 else {
            return try await ensureFolderPath(["phone"])
        }
        return try await ensureFolderPath([day[0], day[1], day[2], drivePhoneFolderName])
    }

    private func ensureFolderPath(_ parts: [String]) async throws -> String {
        let dais = try await cachedFolder(key: "", name: driveRootFolderName, parent: "root")
        var parent = dais
        var key = ""
        for part in parts {
            key += "/" + part
            parent = try await cachedFolder(key: key, name: part, parent: parent)
        }
        daysSaveFolderIds(root: dais, phone: parent)
        return parent
    }

    private func cachedFolder(key: String, name: String, parent: String) async throws -> String {
        if let id = folderIds[key] {
            return id
        }
        if let task = folderTasks[key] {
            return try await task.value
        }
        let api = api
        let task = Task { try await api.findOrCreateFolder(name: name, parentId: parent) }
        folderTasks[key] = task
        defer { folderTasks[key] = nil }
        let id = try await task.value
        folderIds[key] = id
        return id
    }

    private func sidecarData(_ session: DriveSession) throws -> Data {
        let manifest = session.manifest
        let sidecar = DriveSidecar(
            session: String(manifest.name.dropLast("_phone".count)),
            startMs: manifest.startMs,
            endMs: manifest.endMs,
            device: manifest.info.device,
            video: .init(
                codec: manifest.info.codec,
                width: manifest.info.width,
                height: manifest.info.height,
                fps: manifest.info.fps,
                bitrateKbps: manifest.info.bitrateKbps
            ),
            bytes: manifest.closed
                ? manifest.bytesTotal
                : Int64(session.tailIndex * drivePartSize + session.buffer.count),
            events: manifest.events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sidecar)
    }

    private func syncSidecar(_ session: DriveSession, force: Bool) async throws {
        let manifest = session.manifest
        guard let folder = manifest.folderId else {
            return
        }
        let changed = manifest.events.count > manifest.sidecarSyncedEvents
            || (manifest.closed && !manifest.sidecarSyncedClosed)
        let stale = Date().timeIntervalSince(session.sidecarSyncedAt) > driveSidecarInterval
        guard manifest.sidecarFileId == nil || force || (changed && (stale || manifest.closed)) else {
            return
        }
        let content = try sidecarData(session)
        if let fileId = manifest.sidecarFileId {
            do {
                try await api.updateJson(fileId: fileId, content: content)
            } catch DriveError.sessionGone {
                session.manifest.sidecarFileId = try await api.createJson(
                    name: "\(manifest.name).json",
                    folderId: folder,
                    content: content
                )
            }
        } else {
            session.manifest.sidecarFileId = try await api.createJson(
                name: "\(manifest.name).json",
                folderId: folder,
                content: content
            )
        }
        session.manifest.sidecarSyncedEvents = manifest.events.count
        session.manifest.sidecarSyncedClosed = manifest.closed
        session.sidecarSyncedAt = Date()
        session.save()
    }

    private func updateStatus() {
        let pending = sessions.values.filter { !$0.manifest.done }
        guard !pending.isEmpty else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    daysNetStatus.queueCount = 0
                    daysNetStatus.queueBytes = 0
                }
            }
            return
        }
        var queued: Int64 = 0
        for session in pending {
            let total = session.manifest.closed
                ? session.manifest.bytesTotal
                : Int64(session.tailIndex * drivePartSize + session.buffer.count)
            let acked = session.manifest.acked
            daysQueueUpdate(session.manifest.name, startMs: session.manifest.startMs) {
                $0.driveAcked = acked
                $0.driveTotal = total
            }
            queued += total - session.manifest.acked
        }
        let count = pending.count
        let bytes = max(queued, 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                daysNetStatus.queueCount = count
                daysNetStatus.queueBytes = bytes
            }
        }
        let background = pending.contains { $0.manifest.bgActive }
        let live = background ? "in background, " : DaysPace.live ? "Paced for live, " : current != nil ? "recording, " : ""
        setStatus("Google Drive: \(live)\(pending.count) queued, \(UInt64(max(queued, 0)).formatBytes()) left")
    }

    private func setStatus(_ text: String) {
        if text != lastStatus {
            lastStatus = text
            daysLog("status \(text)")
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                driveStatus.text = text
            }
        }
    }
}

final class DriveUploader: @unchecked Sendable {
    private let inputs: AsyncStream<DriveInput>.Continuation

    init() {
        daysLog("DriveUploader init")
        let (stream, continuation) = makeStream(of: DriveInput.self)
        inputs = continuation
        let engine = DriveEngine()
        Task.detached {
            await engine.run()
        }
        Task.detached {
            for await input in stream {
                await engine.handle(input)
            }
        }
        DaysNet.shared.observe { [continuation] in
            continuation.yield(.resume)
        }
        DaysBackgroundUploader.shared.onDetachedComplete = { [continuation] name in
            continuation.yield(.bgFinished(name))
        }
        Task.detached {
            while true {
                try? await Task.sleep(for: .seconds(60))
                continuation.yield(.watchdog)
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil,
                                               queue: nil)
        { _ in
            daysLog("app didEnterBackground")
            continuation.yield(.background(true))
            DaysBackgroundSync.schedule()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil,
                                               queue: nil)
        { _ in
            daysLog("app willEnterForeground")
            continuation.yield(.background(false))
        }
    }

    func setBackground(_ value: Bool) {
        inputs.yield(.background(value))
    }

    func arm(info: DriveSessionInfo) {
        inputs.yield(.arm(info))
    }

    func disarm() {
        inputs.yield(.disarm)
    }

    func segment(_ data: Data, initial: Bool) {
        inputs.yield(.segment(data, initial: initial))
    }

    func recorderStopped() {
        inputs.yield(.recorderStopped)
    }

    func event(type: String, detail: String = "") {
        inputs.yield(.event(type: type, detail: detail))
    }

    func localFile(path: String) {
        inputs.yield(.localFile(path))
    }

    func resume() {
        inputs.yield(.resume)
    }

    func requeue(name: String, startMs: Int64, path: String) {
        inputs.yield(.requeue(name: name, startMs: startMs, path: path))
    }
}

let driveUploader = DriveUploader()

func daysCurrentPath(_ path: String) -> String {
    guard !FileManager.default.fileExists(atPath: path), let range = path.range(of: "/Documents/") else {
        return path
    }
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documents.appendingPathComponent(String(path[range.upperBound...])).path
}
