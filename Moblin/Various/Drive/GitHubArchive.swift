import Foundation
import UIKit

private let githubClientId = "178c6fc778ccc68e1d6a"
private let githubRepo = "balkonsta/days-archive"
private let githubPartSize: Int64 = 1_900_000_000
private let githubLoginKey = "daysGitHubLogin"

private enum GitHubError: Error {
    case unauthorized
    case retryable(String)
    case fatal(String)
}

final class GitHubAuth: @unchecked Sendable {
    private let lock = NSLock()
    private let keychain = Keychain(streamId: "token", server: "github.com", logPrefix: "github: auth")
    private var cached: String?

    init() {
        cached = keychain.load()
    }

    var token: String? {
        lock.withLock { cached }
    }

    var isSignedIn: Bool {
        token != nil
    }

    func set(_ value: String?) {
        lock.withLock { cached = value }
        if let value {
            keychain.store(value: value)
        } else {
            keychain.remove()
        }
    }
}

let githubAuth = GitHubAuth()

@MainActor
final class GitHubStatus: ObservableObject {
    @Published var signedIn = githubAuth.isSignedIn
    @Published var login = UserDefaults.standard.string(forKey: githubLoginKey) ?? ""
    @Published var repoOk = false
    @Published var userCode: String?
    @Published var verificationUri = "https://github.com/login/device"
    @Published var connecting = false
    @Published var text = ""
    var task: Task<Void, Never>?
}

@MainActor
let githubStatus = GitHubStatus()

private struct GitHubJob: Codable {
    var tag: String
    var localPath: String?
    var done: [String] = []
    var releaseId: Int?
    var uploadUrl: String?
    var failed = false
}

private struct GitHubAsset {
    let id: Int
    let state: String
    let size: Int64
}

private struct GitHubItem {
    let name: String
    let contentType: String
    let url: URL
    let offset: Int64
    let length: Int64
    let temporary: Bool
}

private actor GitHubEngine {
    private let dir = createAndGetDirectory(root: .applicationSupportDirectory, name: "GitHubOutbox")
    private var jobs: [GitHubJob] = []
    private var failures = 0
    private let wifiSession = daysSession(allowCellular: false, request: 120, resource: 4 * 3600)
    private let anySession = daysSession(allowCellular: true, request: 120, resource: 4 * 3600)
    private let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    private var session: URLSession {
        DaysPrefs.isWifiOnly ? wifiSession : anySession
    }

    private var jobsUrl: URL {
        dir.appending(component: "jobs.json")
    }

    init() {
        if let data = try? Data(contentsOf: dir.appending(component: "jobs.json")),
           let loaded = try? JSONDecoder().decode([GitHubJob].self, from: data)
        {
            jobs = loaded
        }
    }

    func run() async {
        publish()
        wake()
        for await _ in wakes.stream {
            await drain()
        }
    }

    func wake() {
        wakes.continuation.yield()
    }

    func enqueue(tag: String, localPath: String, sidecar: Data) -> Bool {
        do {
            try sidecar.write(to: sidecarUrl(tag), options: .atomic)
        } catch {
            return false
        }
        if !jobs.contains(where: { $0.tag == tag }) {
            jobs.append(GitHubJob(tag: tag, localPath: localPath))
            save()
        }
        publish()
        wake()
        return true
    }

    private func sidecarUrl(_ tag: String) -> URL {
        dir.appending(component: "\(tag).json")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else {
            return
        }
        try? data.write(to: jobsUrl, options: .atomic)
    }

    private func publish() {
        let count = jobs.filter { !$0.failed }.count
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                daysNetStatus.githubPending = count
            }
        }
    }

    private func status(_ text: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                githubStatus.text = text
            }
        }
    }

    private func drain() async {
        guard githubAuth.isSignedIn, DaysPrefs.isGitHubArchive else {
            return
        }
        while let job = jobs.first(where: { !$0.failed }) {
            guard DaysNet.shared.canUpload() else {
                status("Waiting for Wi-Fi")
                return
            }
            do {
                try await process(job.tag)
                failures = 0
            } catch GitHubError.unauthorized {
                githubAuth.set(nil)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        githubStatus.signedIn = false
                        githubStatus.text = "GitHub sign-in expired"
                    }
                }
                return
            } catch let GitHubError.fatal(message) {
                logger.info("github: Fatal: \(message)")
                if let index = jobs.firstIndex(where: { $0.tag == job.tag }) {
                    jobs[index].failed = true
                    save()
                }
                status("Failed: \(message)")
                publish()
            } catch {
                failures += 1
                let delay = daysBackoff(failures)
                logger.info("github: Retry in \(delay) seconds after \(error)")
                status("Retrying in \(delay) s")
                let continuation = wakes.continuation
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    continuation.yield()
                }
                return
            }
        }
    }

    private func update(_ tag: String, _ change: (inout GitHubJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.tag == tag }) {
            change(&jobs[index])
            save()
        }
    }

    private func process(_ tag: String) async throws {
        guard var job = jobs.first(where: { $0.tag == tag }) else {
            return
        }
        if job.releaseId == nil || job.uploadUrl == nil {
            let release = try await ensureRelease(tag)
            update(tag) {
                $0.releaseId = release.0
                $0.uploadUrl = release.1
            }
            job.releaseId = release.0
            job.uploadUrl = release.1
        }
        guard let releaseId = job.releaseId, let uploadUrl = job.uploadUrl else {
            return
        }
        let assets = try await listAssets(releaseId)
        for item in try items(job) where !(jobs.first { $0.tag == tag }?.done.contains(item.name) ?? true) {
            try await upload(item, to: uploadUrl, existing: assets[item.name], tag: tag)
            update(tag) { $0.done.append(item.name) }
        }
        try? FileManager.default.removeItem(at: sidecarUrl(tag))
        if let path = job.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        jobs.removeAll { $0.tag == tag }
        save()
        publish()
        status("Archived \(tag)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                daysNetStatus.markSynced()
            }
        }
    }

    private func items(_ job: GitHubJob) throws -> [GitHubItem] {
        let sidecar = sidecarUrl(job.tag)
        var result: [GitHubItem] = []
        if let size = fileSize(sidecar) {
            result.append(GitHubItem(name: "\(job.tag).json", contentType: "application/json",
                                     url: sidecar, offset: 0, length: size, temporary: false))
        }
        guard let path = job.localPath, let size = fileSize(URL(fileURLWithPath: path)) else {
            return result
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let base = "\(job.tag).\(ext)"
        let parts = max(Int((size + githubPartSize - 1) / githubPartSize), 1)
        for index in 0 ..< parts {
            let offset = Int64(index) * githubPartSize
            result.append(GitHubItem(name: parts == 1 ? base : base + String(format: ".part%03d", index + 1),
                                     contentType: "video/mp4",
                                     url: url,
                                     offset: offset,
                                     length: min(githubPartSize, size - offset),
                                     temporary: parts > 1))
        }
        return result
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func request(_ method: String, _ url: String, json: [String: Any]? = nil) async throws -> (Int, Data) {
        guard let token = githubAuth.token, let url = URL(string: url) else {
            throw GitHubError.unauthorized
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest, file: URL? = nil) async throws -> (Int, Data) {
        do {
            let (data, response) = if let file {
                try await session.upload(for: request, fromFile: file)
            } else {
                try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                throw GitHubError.retryable("no http response")
            }
            if http.statusCode == 401 {
                throw GitHubError.unauthorized
            }
            return (http.statusCode, data)
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.retryable(error.localizedDescription)
        }
    }

    private func text(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }

    private func releaseInfo(_ data: Data) -> (Int, String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              let upload = (object["upload_url"] as? String)?.split(separator: "{").first
        else {
            return nil
        }
        return (id, String(upload))
    }

    private func ensureRelease(_ tag: String) async throws -> (Int, String) {
        let api = "https://api.github.com/repos/\(githubRepo)"
        let (status, data) = try await request("GET", "\(api)/releases/tags/\(tag)")
        if status == 200, let info = releaseInfo(data) {
            return info
        }
        if status != 404 {
            throw GitHubError.retryable("release lookup \(status)")
        }
        let body: [String: Any] = ["tag_name": tag, "name": tag, "body": "Days recording"]
        var (createStatus, createData) = try await request("POST", "\(api)/releases", json: body)
        if createStatus == 404 {
            throw GitHubError.fatal("repo \(githubRepo) not found")
        }
        if createStatus == 422 {
            _ = try await request("PUT", "\(api)/contents/README.md",
                                  json: ["message": "init", "content": "IyBEYXlzIGFyY2hpdmUK"])
            (createStatus, createData) = try await request("POST", "\(api)/releases", json: body)
        }
        if createStatus == 422 {
            let (again, againData) = try await request("GET", "\(api)/releases/tags/\(tag)")
            if again == 200, let info = releaseInfo(againData) {
                return info
            }
        }
        guard (200 ... 201).contains(createStatus), let info = releaseInfo(createData) else {
            if createStatus == 403 || createStatus == 429 || createStatus >= 500 {
                throw GitHubError.retryable("release \(createStatus)")
            }
            throw GitHubError.fatal("release \(createStatus) \(text(createData))")
        }
        return info
    }

    private func listAssets(_ releaseId: Int) async throws -> [String: GitHubAsset] {
        var result: [String: GitHubAsset] = [:]
        for page in 1 ... 10 {
            let url = "https://api.github.com/repos/\(githubRepo)/releases/\(releaseId)/assets?per_page=100&page=\(page)"
            let (status, data) = try await request("GET", url)
            guard status == 200 else {
                throw GitHubError.retryable("asset list \(status)")
            }
            let items = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            for item in items {
                if let name = item["name"] as? String, let id = item["id"] as? Int {
                    result[name] = GitHubAsset(id: id,
                                               state: item["state"] as? String ?? "",
                                               size: (item["size"] as? NSNumber)?.int64Value ?? 0)
                }
            }
            if items.count < 100 {
                break
            }
        }
        return result
    }

    private func upload(_ item: GitHubItem, to uploadUrl: String, existing: GitHubAsset?, tag: String) async throws {
        if let existing {
            if existing.state == "uploaded", existing.size == item.length {
                return
            }
            _ = try await request("DELETE", "https://api.github.com/repos/\(githubRepo)/releases/assets/\(existing.id)")
        }
        guard var components = URLComponents(string: uploadUrl) else {
            throw GitHubError.fatal("bad upload url")
        }
        components.queryItems = [URLQueryItem(name: "name", value: item.name)]
        guard let url = components.url, let token = githubAuth.token else {
            throw GitHubError.unauthorized
        }
        var file = item.url
        if item.temporary {
            file = dir.appending(component: "part.tmp")
            try copyRange(from: item.url, offset: item.offset, length: item.length, to: file)
        }
        defer {
            if item.temporary {
                try? FileManager.default.removeItem(at: file)
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(item.contentType, forHTTPHeaderField: "Content-Type")
        status("Uploading \(item.name)")
        let (code, data) = try await send(request, file: file)
        switch code {
        case 201, 422:
            return
        case 404:
            update(tag) {
                $0.releaseId = nil
                $0.uploadUrl = nil
            }
            throw GitHubError.retryable("release gone")
        case 400 ..< 500 where code != 403 && code != 408 && code != 429:
            throw GitHubError.fatal("upload \(code) \(text(data))")
        default:
            throw GitHubError.retryable("upload \(code)")
        }
    }

    private func copyRange(from source: URL, offset: Int64, length: Int64, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        try input.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            let chunk = try input.read(upToCount: Int(min(remaining, 8 * 1024 * 1024))) ?? Data()
            if chunk.isEmpty {
                break
            }
            try output.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
    }
}

final class GitHubArchive: Sendable {
    private let engine = GitHubEngine()

    init() {
        let engine = engine
        Task.detached {
            await engine.run()
        }
    }

    func enqueue(tag: String, localPath: String, sidecar: Data) async -> Bool {
        await engine.enqueue(tag: tag, localPath: localPath, sidecar: sidecar)
    }

    func resume() {
        let engine = engine
        Task {
            await engine.wake()
        }
    }
}

let githubArchive = GitHubArchive()

private struct GitHubDeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
}

private enum GitHubPoll {
    case token(String)
    case pending
    case slowDown
    case denied
    case expired
}

private func githubForm(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var components = URLComponents()
    components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
    request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
    let session = daysSession(allowCellular: true, request: 20, resource: 40)
    defer { session.finishTasksAndInvalidate() }
    let (data, _) = try await session.data(for: request)
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func githubRequestCode() async throws -> GitHubDeviceCode {
    let object = try await githubForm("https://github.com/login/device/code",
                                      ["client_id": githubClientId, "scope": "repo"])
    guard let device = object["device_code"] as? String,
          let user = object["user_code"] as? String
    else {
        throw GitHubError.retryable("device code")
    }
    return GitHubDeviceCode(deviceCode: device,
                            userCode: user,
                            verificationUri: object["verification_uri"] as? String ?? "https://github.com/login/device",
                            expiresIn: object["expires_in"] as? Int ?? 900,
                            interval: object["interval"] as? Int ?? 5)
}

private func githubPoll(_ deviceCode: String) async -> GitHubPoll {
    let object = try? await githubForm("https://github.com/login/oauth/access_token", [
        "client_id": githubClientId,
        "device_code": deviceCode,
        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
    ])
    if let token = object?["access_token"] as? String {
        return .token(token)
    }
    switch object?["error"] as? String {
    case "slow_down":
        return .slowDown
    case "access_denied":
        return .denied
    case "expired_token":
        return .expired
    default:
        return .pending
    }
}

@MainActor
func githubConnect() {
    githubStatus.task?.cancel()
    githubStatus.connecting = true
    githubStatus.text = "Contacting GitHub"
    githubStatus.task = Task {
        defer {
            githubStatus.connecting = false
            githubStatus.userCode = nil
            githubStatus.task = nil
        }
        var code: GitHubDeviceCode?
        for attempt in 0 ..< 4 where code == nil && !Task.isCancelled {
            code = try? await githubRequestCode()
            if code == nil {
                try? await Task.sleep(for: .seconds(2 << attempt))
            }
        }
        guard let code else {
            githubStatus.text = "Could not reach GitHub"
            return
        }
        githubStatus.userCode = code.userCode
        githubStatus.verificationUri = code.verificationUri
        githubStatus.text = ""
        var interval = max(code.interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            switch await githubPoll(code.deviceCode) {
            case let .token(token):
                githubAuth.set(token)
                githubStatus.signedIn = true
                githubStatus.text = ""
                await githubRefreshLogin()
                githubArchive.resume()
                return
            case .slowDown:
                interval += 5
            case .denied:
                githubStatus.text = "Access denied"
                return
            case .expired:
                githubStatus.text = "Code expired, try again"
                return
            case .pending:
                break
            }
        }
        if !Task.isCancelled {
            githubStatus.text = "Code expired, try again"
        }
    }
}

@MainActor
func githubCancelConnect() {
    githubStatus.task?.cancel()
    githubStatus.text = ""
}

@MainActor
func githubDisconnect() {
    githubCancelConnect()
    githubAuth.set(nil)
    githubStatus.signedIn = false
    githubStatus.login = ""
    githubStatus.repoOk = false
    UserDefaults.standard.removeObject(forKey: githubLoginKey)
}

@MainActor
func githubRefreshLogin() async {
    guard let token = githubAuth.token else {
        return
    }
    func get(_ url: String) async -> (Int, [String: Any])? {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = daysSession(allowCellular: true, request: 20, resource: 40)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            return nil
        }
        return (http.statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }
    if let (status, user) = await get("https://api.github.com/user") {
        if status == 401 {
            githubAuth.set(nil)
            githubStatus.signedIn = false
            return
        }
        if let login = user["login"] as? String {
            githubStatus.login = login
            UserDefaults.standard.set(login, forKey: githubLoginKey)
        }
    }
    if let (status, repo) = await get("https://api.github.com/repos/\(githubRepo)") {
        githubStatus.repoOk = status == 200 && (repo["permissions"] as? [String: Any])?["push"] as? Bool == true
    }
}
