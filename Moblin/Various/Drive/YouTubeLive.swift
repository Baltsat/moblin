import Foundation
import Network

let youTubeScope = "https://www.googleapis.com/auth/youtube"
private let youTubeApi = "https://www.googleapis.com/youtube/v3/"
private let youTubeStreamTitle = "Days phone"
private let youTubeEnabledKey = "daysYouTubeEnabled"
private let youTubeCellularKey = "daysYouTubeCellular"

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
    let session = daysSession(allowCellular: cellular, request: 15, resource: 30)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
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

private func youTubePrepare(title: String, cellular: Bool) async throws -> (url: String, broadcastId: String) {
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
    let old = try? await youTubeRequest(method: "GET",
                                        path: "liveBroadcasts",
                                        query: ["part": "id,status,contentDetails", "mine": "true", "maxResults": "50"],
                                        body: nil,
                                        token: token,
                                        cellular: cellular)
    for item in old?["items"] as? [[String: Any]] ?? [] {
        guard let id = item["id"] as? String,
              (item["contentDetails"] as? [String: Any])?["boundStreamId"] as? String == streamId,
              let status = (item["status"] as? [String: Any])?["lifeCycleStatus"] as? String
        else {
            continue
        }
        if status == "live" || status == "testing" {
            _ = try? await youTubeRequest(method: "POST",
                                          path: "liveBroadcasts/transition",
                                          query: ["part": "status", "id": id, "broadcastStatus": "complete"],
                                          body: nil,
                                          token: token,
                                          cellular: cellular)
        } else if status == "ready" || status == "created" {
            _ = try? await youTubeRequest(method: "DELETE",
                                          path: "liveBroadcasts",
                                          query: ["id": id],
                                          body: nil,
                                          token: token,
                                          cellular: cellular)
        }
    }
    let start = ISO8601DateFormatter().string(from: Date())
    let broadcast = try await youTubeRequest(
        method: "POST",
        path: "liveBroadcasts",
        query: ["part": "snippet,status,contentDetails"],
        body: [
            "snippet": ["title": title, "scheduledStartTime": start],
            "status": ["privacyStatus": "private", "selfDeclaredMadeForKids": false],
            "contentDetails": ["enableAutoStart": true, "enableAutoStop": false, "enableDvr": true],
        ],
        token: token,
        cellular: cellular
    )
    guard let broadcastId = broadcast["id"] as? String else {
        throw YouTubeError.failed("no broadcast")
    }
    pendingAdd(broadcastId)
    _ = try await youTubeRequest(method: "POST",
                                 path: "liveBroadcasts/bind",
                                 query: ["part": "id", "id": broadcastId, "streamId": streamId],
                                 body: nil,
                                 token: token,
                                 cellular: cellular)
    try? await youTubeAddToPlaylist(videoId: broadcastId, token: token, cellular: cellular)
    return (url, broadcastId)
}

private let youTubePendingKey = "daysYouTubePendingComplete"

private func pendingIds() -> [String] {
    UserDefaults.standard.stringArray(forKey: youTubePendingKey) ?? []
}

private func pendingAdd(_ id: String) {
    UserDefaults.standard.set(Array(Set(pendingIds() + [id])), forKey: youTubePendingKey)
}

private func pendingRemove(_ id: String) {
    UserDefaults.standard.set(pendingIds().filter { $0 != id }, forKey: youTubePendingKey)
}

private func youTubeComplete(_ id: String) async {
    do {
        let token = try await driveAuth.accessToken()
        _ = try await youTubeRequest(method: "POST",
                                     path: "liveBroadcasts/transition",
                                     query: ["broadcastStatus": "complete", "id": id, "part": "status"],
                                     body: nil,
                                     token: token,
                                     cellular: true)
        pendingRemove(id)
    } catch YouTubeError.failed {
        pendingRemove(id)
    } catch {}
}

private let youTubePlaylistTitle = "Days \u{00B7} phone"

private func youTubeFindPlaylist(token: String, cellular: Bool, create: Bool) async throws -> String? {
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
        playlistId = items.first {
            ($0["snippet"] as? [String: Any])?["title"] as? String == youTubePlaylistTitle
        }?["id"] as? String
        page = result["nextPageToken"] as? String
    } while playlistId == nil && page != nil
    if playlistId == nil, create {
        let created = try await youTubeRequest(
            method: "POST",
            path: "playlists",
            query: ["part": "snippet,status"],
            body: ["snippet": ["title": youTubePlaylistTitle], "status": ["privacyStatus": "private"]],
            token: token,
            cellular: cellular
        )
        playlistId = created["id"] as? String
    }
    if let playlistId {
        UserDefaults.standard.set(playlistId, forKey: daysPlaylistKey)
    }
    return playlistId
}

func youTubeResolvePlaylistId() async -> String? {
    if let id = UserDefaults.standard.string(forKey: daysPlaylistKey) {
        return id
    }
    guard let token = try? await driveAuth.accessToken() else {
        return nil
    }
    return try? await youTubeFindPlaylist(token: token, cellular: true, create: false)
}

private func youTubeAddToPlaylist(videoId: String, token: String, cellular: Bool) async throws {
    let playlistId = try await youTubeFindPlaylist(token: token, cellular: cellular, create: true)
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

private struct YouTubeSession {
    let broadcastId: String
    let url: String
}

@MainActor
private var youTubeTask: Task<Void, Never>?
@MainActor
private var youTubeStreaming = false {
    didSet {
        DaysPace.setLive(youTubeStreaming)
    }
}
@MainActor
private var youTubeSession: YouTubeSession?
@MainActor
private weak var daysModel: Model?
@MainActor
private var pathGeneration = 0

private func youTubeCellularAllowed() -> Bool {
    UserDefaults.standard.bool(forKey: youTubeCellularKey)
}

private let daysPathObserverRegistered: Bool = {
    DaysNet.shared.observe {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                daysPathChanged()
            }
        }
    }
    return true
}()

@MainActor
private func daysPathChanged() {
    pathGeneration += 1
    let generation = pathGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        MainActor.assumeIsolated {
            guard generation == pathGeneration, let model = daysModel else {
                return
            }
            model.youTubeNetworkSettled()
        }
    }
}

@MainActor private var youTubeThermalPaused = false
@MainActor var daysQuietStop = false

extension Model {
    func youTubeThermalChanged(_ state: ProcessInfo.ThermalState) {
        if state == .critical {
            youTubeThermalPaused = true
        } else if state.rawValue <= ProcessInfo.ThermalState.fair.rawValue {
            youTubeThermalPaused = false
        }
        youTubeNetworkSettled()
    }

    fileprivate func youTubeNetworkSettled() {
        let can = DaysNet.shared.canStream(cellular: youTubeCellularAllowed()) && !youTubeThermalPaused
        if isRecording {
            if let session = youTubeSession {
                if !can, youTubeStreaming {
                    youTubeStreaming = false
                    daysQuietStop = true
                    _ = stopStream()
                    daysQuietStop = false
                } else if can, !youTubeStreaming, !isLive {
                    stream.url = session.url
                    stream.rtmp.adaptiveBitrateEnabled = true
                    youTubeStreaming = true
                    startStream()
                }
            } else if can {
                startYouTubeIfPossible()
            }
        }
        if DaysNet.shared.isOnline {
            completePendingYouTube()
        }
    }

    func youTubeLiveState() -> (id: String?, state: String)? {
        guard isRecording, UserDefaults.standard.object(forKey: youTubeEnabledKey) as? Bool ?? true else {
            return nil
        }
        if let session = youTubeSession {
            if !youTubeStreaming {
                return (session.broadcastId, "paused")
            }
            return (session.broadcastId, isStreamConnected() ? "live" : "reconnecting")
        }
        return (nil, DaysNet.shared.canStream(cellular: youTubeCellularAllowed()) ? "starting" : "offline-queued")
    }

    func completePendingYouTube() {
        daysModel = self
        _ = daysPathObserverRegistered
        let active = youTubeSession?.broadcastId
        let ids = pendingIds().filter { $0 != active }
        guard driveAuth.isSignedIn, driveAuth.hasScope(youTubeScope), !ids.isEmpty else {
            return
        }
        Task {
            for id in ids {
                await youTubeComplete(id)
            }
        }
    }

    func startYouTubeIfPossible() {
        daysModel = self
        _ = daysPathObserverRegistered
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: youTubeEnabledKey) as? Bool ?? true,
              driveAuth.isSignedIn, driveAuth.hasScope(youTubeScope), !isLive, youTubeSession == nil,
              youTubeTask == nil
        else {
            return
        }
        let cellular = youTubeCellularAllowed()
        guard DaysNet.shared.canStream(cellular: cellular), !youTubeThermalPaused else {
            return
        }
        let title = "\(youTubeTitleFormatter.string(from: Date())) \u{00B7} phone"
        youTubeTask = Task { [weak self] in
            var prepared: (url: String, broadcastId: String)?
            for attempt in 1 ... 6 where prepared == nil && !Task.isCancelled {
                prepared = try? await youTubePrepare(title: title, cellular: cellular)
                if prepared == nil {
                    try? await Task.sleep(for: .seconds(daysBackoff(attempt)))
                    if !(await self?.isRecording ?? false) {
                        return
                    }
                }
            }
            guard let prepared else {
                youTubeTask = nil
                return
            }
            guard !Task.isCancelled, let self, isRecording, !isLive else {
                await youTubeComplete(prepared.broadcastId)
                return
            }
            youTubeSession = YouTubeSession(broadcastId: prepared.broadcastId, url: prepared.url)
            daysQueue.attachYouTube(prepared.broadcastId)
            stream.url = prepared.url
            stream.rtmp.adaptiveBitrateEnabled = true
            youTubeStreaming = true
            startStream()
        }
    }

    func stopYouTubeIfStreaming() {
        youTubeTask?.cancel()
        youTubeTask = nil
        let session = youTubeSession
        youTubeSession = nil
        if youTubeStreaming {
            youTubeStreaming = false
            daysQuietStop = true
            _ = stopStream()
            daysQuietStop = false
        }
        if let session {
            Task {
                try? await Task.sleep(for: .seconds(3))
                await youTubeComplete(session.broadcastId)
            }
        }
    }
}
