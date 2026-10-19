import Foundation
import Network

let youTubeScope = "https://www.googleapis.com/auth/youtube"
private let youTubeApi = "https://www.googleapis.com/youtube/v3/"
private let youTubeStreamTitle = "Days phone"
private let youTubeEnabledKey = "daysYouTubeEnabled"
private let youTubeCellularKey = "daysYouTubeCellular"

private final class DaysPathState: @unchecked Sendable {
    private let lock = NSLock()
    private var wifi = false
    private var online = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            self.lock.withLock {
                self.online = path.status == .satisfied
                self.wifi = path.status == .satisfied && !path.usesInterfaceType(.cellular)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.baltsat.days.path"))
    }

    func canStream(cellular: Bool) -> Bool {
        lock.withLock { cellular ? online : wifi }
    }
}

private let daysPathState = DaysPathState()

private enum YouTubeError: Error {
    case failed(String)
}

private func youTubeRequest(method: String,
                            path: String,
                            query: [String: String],
                            body: [String: Any]?,
                            token: String,
                            cellular: Bool) async throws -> [String: Any]
{
    var components = URLComponents(string: youTubeApi + path)!
    components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.timeoutInterval = 15
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.allowsCellularAccess = cellular
    configuration.waitsForConnectivity = false
    let (data, response) = try await URLSession(configuration: configuration).data(for: request)
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw YouTubeError.failed(String(decoding: data.prefix(300), as: UTF8.self))
    }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func youTubeIngestUrl(_ stream: [String: Any]) -> String? {
    guard let info = (stream["cdn"] as? [String: Any])?["ingestionInfo"] as? [String: Any],
          let address = info["rtmpsIngestionAddress"] as? String,
          let name = info["streamName"] as? String
    else {
        return nil
    }
    return "\(address)/\(name)"
}

private func youTubePrepare(title: String, cellular: Bool) async throws -> String {
    let token = try await driveAuth.accessToken()
    let list = try await youTubeRequest(method: "GET",
                                        path: "liveStreams",
                                        query: ["part": "id,snippet,cdn", "mine": "true", "maxResults": "50"],
                                        body: nil,
                                        token: token,
                                        cellular: cellular)
    let items = list["items"] as? [[String: Any]] ?? []
    var stream = items.first { ($0["snippet"] as? [String: Any])?["title"] as? String == youTubeStreamTitle }
    if stream == nil {
        stream = try await youTubeRequest(
            method: "POST",
            path: "liveStreams",
            query: ["part": "snippet,cdn,contentDetails"],
            body: [
                "snippet": ["title": youTubeStreamTitle],
                "cdn": ["ingestionType": "rtmp", "resolution": "variable", "frameRate": "variable"],
                "contentDetails": ["isReusable": true],
            ],
            token: token,
            cellular: cellular
        )
    }
    guard let stream, let streamId = stream["id"] as? String, let url = youTubeIngestUrl(stream) else {
        throw YouTubeError.failed("no stream")
    }
    let start = ISO8601DateFormatter().string(from: Date())
    let broadcast = try await youTubeRequest(
        method: "POST",
        path: "liveBroadcasts",
        query: ["part": "snippet,status,contentDetails"],
        body: [
            "snippet": ["title": title, "scheduledStartTime": start],
            "status": ["privacyStatus": "private", "selfDeclaredMadeForKids": false],
            "contentDetails": ["enableAutoStart": true, "enableAutoStop": true, "enableDvr": true],
        ],
        token: token,
        cellular: cellular
    )
    guard let broadcastId = broadcast["id"] as? String else {
        throw YouTubeError.failed("no broadcast")
    }
    _ = try await youTubeRequest(method: "POST",
                                 path: "liveBroadcasts/bind",
                                 query: ["part": "id", "id": broadcastId, "streamId": streamId],
                                 body: nil,
                                 token: token,
                                 cellular: cellular)
    try? await youTubeAddToPlaylist(videoId: broadcastId, token: token, cellular: cellular)
    return url
}

private func youTubeAddToPlaylist(videoId: String, token: String, cellular: Bool) async throws {
    let title = "Days \u{00B7} phone"
    var playlistId: String?
    var page: String?
    repeat {
        var query = ["part": "id,snippet", "mine": "true", "maxResults": "50"]
        if let page {
            query["pageToken"] = page
        }
        let result = try await youTubeRequest(method: "GET", path: "playlists", query: query,
                                              body: nil, token: token, cellular: cellular)
        let items = result["items"] as? [[String: Any]] ?? []
        playlistId = items.first { ($0["snippet"] as? [String: Any])?["title"] as? String == title }?["id"] as? String
        page = result["nextPageToken"] as? String
    } while playlistId == nil && page != nil
    if playlistId == nil {
        let created = try await youTubeRequest(
            method: "POST",
            path: "playlists",
            query: ["part": "snippet,status"],
            body: ["snippet": ["title": title], "status": ["privacyStatus": "private"]],
            token: token,
            cellular: cellular
        )
        playlistId = created["id"] as? String
    }
    guard let playlistId else {
        return
    }
    _ = try await youTubeRequest(
        method: "POST",
        path: "playlistItems",
        query: ["part": "snippet"],
        body: ["snippet": ["playlistId": playlistId,
                           "resourceId": ["kind": "youtube#video", "videoId": videoId]]],
        token: token,
        cellular: cellular
    )
}

private let youTubeTitleFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

@MainActor
private var youTubeTask: Task<Void, Never>?
@MainActor
private var youTubeStreaming = false

extension Model {
    func startYouTubeIfPossible() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: youTubeEnabledKey) as? Bool ?? true,
              driveAuth.isSignedIn, driveAuth.hasScope(youTubeScope), !isLive
        else {
            return
        }
        let cellular = defaults.bool(forKey: youTubeCellularKey)
        guard daysPathState.canStream(cellular: cellular) else {
            return
        }
        let title = "\(youTubeTitleFormatter.string(from: Date())) \u{00B7} phone"
        youTubeTask = Task { [weak self] in
            guard let url = try? await youTubePrepare(title: title, cellular: cellular) else {
                return
            }
            guard !Task.isCancelled, let self, isRecording, !isLive else {
                return
            }
            stream.url = url
            youTubeStreaming = true
            startStream()
        }
    }

    func stopYouTubeIfStreaming() {
        youTubeTask?.cancel()
        youTubeTask = nil
        guard youTubeStreaming else {
            return
        }
        youTubeStreaming = false
        _ = stopStream()
    }
}
