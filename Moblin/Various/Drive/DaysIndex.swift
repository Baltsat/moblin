import Combine
import Foundation
import SwiftUI

private let daysIndexFolderKey = "daysIndexFolderId"
private let daysIndexPhoneFileKey = "daysIndexPhoneFileId"
private let daysIndexMacFileKey = "daysIndexMacFileId"
private let daysIndexEndsKey = "daysIndexEnds"
private let daysIndexThumbsKey = "daysIndexThumbs"
private let daysIndexThumbFolderKey = "daysIndexThumbFolderId"
private let daysStaleMs: Int64 = 180_000
private let daysMergeGapMs: Int64 = 10000
private let daysPremiere = (year: 2026, month: 10, day: 12)

private func daysNull(_ value: String?) -> Any {
    if let value {
        return value
    }
    return NSNull()
}

struct DaysLiveAngle {
    var angle: String
    var youtube: String?
    var thumbs: [String] = []
}

struct DaysAngle: Equatable {
    var angle: String
    var youtube: String?
    var driveId: String?
    var bytes: Int64
    var uploaded: Int64
    var thumbs: [String] = []

    var label: String {
        switch angle {
        case "screen": "Screen"
        case "face": "Face"
        default: "iPhone"
        }
    }
}

struct DaysRawScene {
    var session: String
    var startMs: Int64
    var endMs: Int64?
    var failed: Bool
    var angles: [DaysAngle]
}

struct DaysRawLive {
    var session: String
    var startMs: Int64
    var angles: [DaysLiveAngle]
}

struct DaysRawIndex {
    var device: String
    var tz: String
    var updatedMs: Int64
    var live: DaysRawLive?
    var scenes: [DaysRawScene]

    init(device: String, tz: String, updatedMs: Int64, live: DaysRawLive?, scenes: [DaysRawScene]) {
        self.device = device
        self.tz = tz
        self.updatedMs = updatedMs
        self.live = live
        self.scenes = scenes
    }

    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        device = root["device"] as? String ?? ""
        tz = root["tz"] as? String ?? TimeZone.current.identifier
        updatedMs = (root["updated_ms"] as? NSNumber)?.int64Value ?? 0
        if let live = root["live"] as? [String: Any] {
            self.live = DaysRawLive(
                session: live["session"] as? String ?? "",
                startMs: (live["start_ms"] as? NSNumber)?.int64Value ?? 0,
                angles: (live["angles"] as? [[String: Any]] ?? []).map {
                    DaysLiveAngle(angle: $0["angle"] as? String ?? "",
                                  youtube: $0["youtube"] as? String,
                                  thumbs: $0["thumbs"] as? [String] ?? [])
                }
            )
        } else {
            live = nil
        }
        scenes = (root["scenes"] as? [[String: Any]] ?? []).map { scene in
            DaysRawScene(
                session: scene["session"] as? String ?? "",
                startMs: (scene["start_ms"] as? NSNumber)?.int64Value ?? 0,
                endMs: (scene["end_ms"] as? NSNumber)?.int64Value,
                failed: scene["failed"] as? Bool ?? false,
                angles: (scene["angles"] as? [[String: Any]] ?? []).map {
                    DaysAngle(angle: $0["angle"] as? String ?? "",
                              youtube: $0["youtube"] as? String,
                              driveId: $0["drive_id"] as? String,
                              bytes: ($0["bytes"] as? NSNumber)?.int64Value ?? 0,
                              uploaded: ($0["uploaded"] as? NSNumber)?.int64Value ?? 0,
                              thumbs: $0["thumbs"] as? [String] ?? [])
                }
            )
        }
    }

    func encoded() -> Data? {
        let null = NSNull()
        var root: [String: Any] = [
            "v": 1,
            "device": device,
            "tz": tz,
            "updated_ms": updatedMs,
            "live": null,
        ]
        if let live {
            root["live"] = [
                "session": live.session,
                "start_ms": live.startMs,
                "angles": live.angles.map { ["angle": $0.angle, "youtube": daysNull($0.youtube), "thumbs": $0.thumbs] },
            ]
        }
        root["scenes"] = scenes.map { scene -> [String: Any] in
            [
                "session": scene.session,
                "start_ms": scene.startMs,
                "end_ms": scene.endMs ?? null,
                "failed": scene.failed,
                "angles": scene.angles.map { angle -> [String: Any] in
                    [
                        "angle": angle.angle,
                        "youtube": daysNull(angle.youtube),
                        "drive_id": daysNull(angle.driveId),
                        "thumbs": angle.thumbs,
                        "bytes": angle.bytes,
                        "uploaded": angle.uploaded,
                    ]
                },
            ]
        }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

struct DaysScene: Identifiable {
    var id: String
    var startMs: Int64
    var endMs: Int64?
    var angles: [DaysAngle]
    var number = 0
    var live: Bool

    var safe: Bool {
        endMs != nil && angles.allSatisfy { $0.bytes > 0 && $0.uploaded >= $0.bytes }
    }

    var leftBytes: Int64 {
        angles.reduce(0) { $0 + max($1.bytes - $1.uploaded, 0) }
    }

    func durationMs(now: Int64) -> Int64 {
        max((endMs ?? now) - startMs, 0)
    }

    func angle(_ name: String) -> DaysAngle? {
        angles.first { $0.angle == name }
    }

    var youtubeId: String? {
        ["screen", "face", "phone"].compactMap { angle($0)?.youtube }.first
    }

    var present: [DaysAngle] {
        ["screen", "face", "phone"].compactMap { angle($0) }
    }
}

struct DaysEpisode: Identifiable {
    var id: String
    var day: Date
    var season: Int
    var number: Int
    var scenes: [DaysScene]
    var failed: Int

    var leftBytes: Int64 {
        scenes.reduce(0) { $0 + $1.leftBytes }
    }

    func durationMs(now: Int64) -> Int64 {
        scenes.reduce(0) { $0 + $1.durationMs(now: now) }
    }

    var angleLabels: String {
        let names = ["screen", "face", "phone"].filter { name in
            scenes.contains { $0.angle(name) != nil }
        }
        return names.map { DaysAngle(angle: $0, bytes: 0, uploaded: 0).label }.joined(separator: " + ")
    }
}

struct DaysSeason: Identifiable {
    var n: Int
    var start: Date
    var episodes: [DaysEpisode]

    var id: Int {
        n
    }

    func totalMs(now: Int64) -> Int64 {
        episodes.reduce(0) { $0 + $1.durationMs(now: now) }
    }
}

struct DaysVerdict {
    enum Tone { case red, amber, green }

    var text: String
    var tone: Tone

    var color: Color {
        switch tone {
        case .red: DaysUI.red
        case .amber: DaysUI.amber
        case .green: DaysUI.green
        }
    }
}

@MainActor
final class DaysIndex: ObservableObject {
    static let shared = DaysIndex()

    @Published private(set) var mac: DaysRawIndex?
    @Published private(set) var phone = DaysRawIndex(device: "iphone",
                                                     tz: TimeZone.current.identifier,
                                                     updatedMs: 0,
                                                     live: nil,
                                                     scenes: [])
    @Published private(set) var seasons: [DaysSeason] = []
    @Published private(set) var today = DaysEpisode(id: "", day: Date(), season: 1, number: 1, scenes: [], failed: 0)
    @Published private(set) var macLive: DaysRawLive?
    @Published private(set) var phoneRecording = false

    private let api = DriveApi()
    private var model: Model?
    private var cancellables: Set<AnyCancellable> = []
    private var pullTimer: Timer?
    private var pushTimer: Timer?
    private var recordingStartMs: Int64 = 0
    private var rate = 0.0
    private var lastLeft: (bytes: Int64, at: Date)?
    private var fixtures = false
    private var thumbTimer: Timer?
    private(set) var tz = TimeZone.current

    var leftEta: String? {
        let left = today.leftBytes
        guard left > 0, rate > 1000 else {
            return nil
        }
        return "~\(max(Int((Double(left) / rate / 60).rounded(.up)), 1)) min"
    }

    var recordingNow: Bool {
        phoneRecording || macLive != nil
    }

    func attach(model: Model) {
        guard self.model == nil else {
            return
        }
        self.model = model
        #if DEBUG
            if UserDefaults.standard.bool(forKey: "DaysPortrait") {
                model.database.portrait = true
                model.updateIsPortrait()
                AppDelegate.orientationLock = .portrait
            }
            if let dir = UserDefaults.standard.string(forKey: "DaysFixtures") {
                loadFixtures(dir: dir)
                return
            }
        #endif
        model.$isRecording.removeDuplicates().sink { [weak self] value in
            self?.recordingChanged(value)
        }.store(in: &cancellables)
        daysQueue.$items.sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildPhone() }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.startPulling()
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in
            self?.pullTimer?.invalidate()
            self?.pullTimer = nil
        }.store(in: &cancellables)
        rebuildPhone()
        startPulling()
        pushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phoneRecording || daysQueue.items.contains(where: { !$0.driveDone }) else {
                    return
                }
                self.push()
            }
        }
    }

    #if DEBUG
        private func loadFixtures(dir: String) {
            fixtures = true
            let base = URL(fileURLWithPath: dir)
            DaysThumbs.shared.localDir = base.appendingPathComponent("thumbs")
            if let data = try? Data(contentsOf: base.appendingPathComponent("mac.json")) {
                mac = DaysRawIndex(data: data)
            }
            if let data = try? Data(contentsOf: base.appendingPathComponent("iphone.json")),
               let loaded = DaysRawIndex(data: data)
            {
                phone = loaded
            }
            rebuild()
        }
    #endif

    private func startPulling() {
        pullTimer?.invalidate()
        pull()
        pullTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
    }

    private func recordingChanged(_ value: Bool) {
        let now = nowMs()
        thumbTimer?.invalidate()
        thumbTimer = nil
        if value {
            recordingStartMs = now
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.captureThumb()
            }
            thumbTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureThumb() }
            }
        } else {
            captureThumb()
            var ends = UserDefaults.standard.dictionary(forKey: daysIndexEndsKey) as? [String: Int64] ?? [:]
            for item in daysQueue.items where ends[item.name] == nil && item.startMs >= recordingStartMs - 120_000 {
                ends[item.name] = now
            }
            UserDefaults.standard.set(ends, forKey: daysIndexEndsKey)
        }
        rebuildPhone()
        push()
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func rebuildPhone() {
        let recording = model?.isRecording ?? false
        phoneRecording = recording
        let ends = UserDefaults.standard.dictionary(forKey: daysIndexEndsKey) as? [String: Int64] ?? [:]
        let phoneThumbs = UserDefaults.standard.dictionary(forKey: daysIndexThumbsKey) as? [String: [String]] ?? [:]
        var scenes: [DaysRawScene] = []
        var live: DaysRawLive?
        for (index, item) in daysQueue.items.enumerated().reversed() {
            let isLive = recording && index == 0 && ends[item.name] == nil
            let end: Int64? = isLive ? nil : (ends[item.name] ?? item.startMs)
            let bytes = item.driveTotal
            let uploaded = item.driveDone ? bytes : min(item.driveAcked, bytes)
            scenes.append(DaysRawScene(
                session: item.name,
                startMs: item.startMs,
                endMs: end,
                failed: end != nil && bytes == 0 && !item.driveDone,
                angles: [DaysAngle(angle: "phone",
                                   youtube: item.youTubeId,
                                   driveId: item.driveFileId,
                                   bytes: bytes,
                                   uploaded: uploaded,
                                   thumbs: phoneThumbs[item.name] ?? [])]
            ))
            if isLive {
                live = DaysRawLive(session: item.name,
                                   startMs: item.startMs,
                                   angles: [DaysLiveAngle(angle: "phone",
                                                          youtube: item.youTubeId,
                                                          thumbs: phoneThumbs[item.name] ?? [])])
            }
        }
        phone = DaysRawIndex(device: "iphone",
                             tz: tz.identifier,
                             updatedMs: nowMs(),
                             live: live,
                             scenes: scenes)
        rebuild()
    }

    func rebuild() {
        let now = nowMs()
        if let identifier = mac?.tz, let zone = TimeZone(identifier: identifier) {
            tz = zone
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.firstWeekday = 2
        var raw: [DaysRawScene] = []
        var failedStarts: [Int64] = []
        for file in [mac, phone].compactMap({ $0 }) {
            let live = file.live != nil && now - file.updatedMs < daysStaleMs
            for scene in file.scenes {
                if scene.failed {
                    failedStarts.append(scene.startMs)
                    continue
                }
                var scene = scene
                if scene.endMs == nil, !live || scene.session != file.live?.session {
                    scene.endMs = file.updatedMs
                }
                raw.append(scene)
            }
        }
        macLive = mac.flatMap { file in
            now - file.updatedMs < daysStaleMs ? file.live : nil
        }
        raw.sort { $0.startMs < $1.startMs }
        var merged: [DaysScene] = []
        for scene in raw {
            let isLive = scene.endMs == nil
            if var last = merged.last, scene.startMs <= (last.endMs ?? now) + daysMergeGapMs {
                for angle in scene.angles {
                    if let index = last.angles.firstIndex(where: { $0.angle == angle.angle }) {
                        if angle.bytes > last.angles[index].bytes {
                            last.angles[index] = angle
                        }
                    } else {
                        last.angles.append(angle)
                    }
                }
                if let end = scene.endMs, let lastEnd = last.endMs {
                    last.endMs = max(end, lastEnd)
                } else {
                    last.endMs = nil
                }
                last.live = last.live || isLive
                merged[merged.count - 1] = last
            } else {
                merged.append(DaysScene(id: scene.session,
                                        startMs: scene.startMs,
                                        endMs: scene.endMs,
                                        angles: scene.angles,
                                        live: isLive))
            }
        }
        var byDay: [Date: [DaysScene]] = [:]
        for scene in merged {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: Double(scene.startMs) / 1000))
            byDay[day, default: []].append(scene)
        }
        var failedByDay: [Date: Int] = [:]
        for start in failedStarts {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: Double(start) / 1000))
            failedByDay[day, default: 0] += 1
        }
        let premiere = cal.date(from: DateComponents(timeZone: tz,
                                                     year: daysPremiere.year,
                                                     month: daysPremiere.month,
                                                     day: daysPremiere.day)) ?? Date()
        let nowDate = Date()
        let todayStart = cal.startOfDay(for: nowDate)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: nowDate)?.start ?? todayStart
        let seasonCount = max((cal.dateComponents([.day], from: premiere, to: weekStart).day ?? 0) / 7 + 1, 1)
        func episode(season: Int, offset: Int, start: Date) -> DaysEpisode? {
            guard let day = cal.date(byAdding: .day, value: offset, to: start), day <= todayStart else {
                return nil
            }
            var scenes = byDay[day] ?? []
            for index in scenes.indices {
                scenes[index].number = index + 1
            }
            let formatter = DateFormatter()
            formatter.calendar = cal
            formatter.timeZone = tz
            formatter.dateFormat = "yyyy-MM-dd"
            return DaysEpisode(id: formatter.string(from: day),
                               day: day,
                               season: season,
                               number: offset + 1,
                               scenes: scenes,
                               failed: failedByDay[day] ?? 0)
        }
        var result: [DaysSeason] = []
        for n in stride(from: seasonCount, through: 1, by: -1) {
            guard let start = cal.date(byAdding: .day, value: (n - 1) * 7, to: premiere) else {
                continue
            }
            let episodes = (0 ..< 7).reversed().compactMap { episode(season: n, offset: $0, start: start) }
            result.append(DaysSeason(n: n, start: start, episodes: episodes))
        }
        seasons = result
        if let current = result.first?.episodes.first {
            today = current
        }
        trackRate(left: today.leftBytes)
    }

    private func trackRate(left: Int64) {
        let now = Date()
        if let last = lastLeft, left < last.bytes {
            let seconds = now.timeIntervalSince(last.at)
            if seconds > 0.5 {
                let sample = Double(last.bytes - left) / seconds
                rate = rate == 0 ? sample : rate * 0.7 + sample * 0.3
            }
        }
        if left == 0 {
            rate = 0
        }
        lastLeft = (left, now)
    }

    func verdict(_ episode: DaysEpisode) -> DaysVerdict {
        if episode.id == today.id, recordingNow {
            return DaysVerdict(text: "\u{25CF} Recording", tone: .red)
        }
        let left = episode.leftBytes
        if left > 0 {
            var text = "\u{2191} \(daysSize(left)) left"
            if episode.id == today.id, let eta = leftEta {
                text += " \u{00B7} \(eta)"
            }
            return DaysVerdict(text: text, tone: .amber)
        }
        if episode.failed > 0 {
            return DaysVerdict(text: "\u{26A0} \(episode.failed) failed start\(episode.failed == 1 ? "" : "s")",
                               tone: .amber)
        }
        return DaysVerdict(text: "\u{2713} All safe", tone: .green)
    }

    func scene(_ id: String) -> (DaysScene, DaysEpisode)? {
        for season in seasons {
            for episode in season.episodes {
                if let scene = episode.scenes.first(where: { $0.id == id }) {
                    return (scene, episode)
                }
            }
        }
        return nil
    }

    func episode(_ id: String) -> DaysEpisode? {
        seasons.flatMap(\.episodes).first { $0.id == id }
    }

    private func pull() {
        guard !fixtures, driveAuth.isSignedIn else {
            return
        }
        Task {
            guard let folder = try? await indexFolderId() else {
                return
            }
            var fileId = UserDefaults.standard.string(forKey: daysIndexMacFileKey)
            if fileId == nil {
                fileId = try? await api.findFile(name: "mac.json", folderId: folder)
                UserDefaults.standard.set(fileId, forKey: daysIndexMacFileKey)
            }
            guard let fileId else {
                return
            }
            do {
                let data = try await api.downloadMedia(fileId: fileId)
                if let loaded = DaysRawIndex(data: data) {
                    mac = loaded
                    rebuild()
                }
            } catch DriveError.sessionGone {
                UserDefaults.standard.removeObject(forKey: daysIndexMacFileKey)
            } catch {}
        }
    }

    func push() {
        guard !fixtures, driveAuth.isSignedIn, let data = phone.encoded() else {
            return
        }
        Task {
            guard let folder = try? await indexFolderId() else {
                return
            }
            var fileId = UserDefaults.standard.string(forKey: daysIndexPhoneFileKey)
            if fileId == nil {
                fileId = try? await api.findFile(name: "iphone.json", folderId: folder)
            }
            do {
                if let fileId {
                    try await api.updateJson(fileId: fileId, content: data)
                    UserDefaults.standard.set(fileId, forKey: daysIndexPhoneFileKey)
                } else {
                    let created = try await api.createJson(name: "iphone.json", folderId: folder, content: data)
                    UserDefaults.standard.set(created, forKey: daysIndexPhoneFileKey)
                }
            } catch DriveError.sessionGone {
                UserDefaults.standard.removeObject(forKey: daysIndexPhoneFileKey)
            } catch {}
        }
    }

    private func captureThumb() {
        guard !fixtures, driveAuth.isSignedIn, let model, let session = daysQueue.items.first?.name else {
            return
        }
        model.media.takeSnapshot(age: 0) { [weak self] image, _, _ in
            guard let self, let jpeg = daysThumbJpeg(image) else {
                return
            }
            self.uploadThumb(jpeg, session: session)
        }
    }

    private func uploadThumb(_ jpeg: Data, session: String) {
        Task {
            guard let folder = try? await thumbFolderId() else {
                return
            }
            var all = UserDefaults.standard.dictionary(forKey: daysIndexThumbsKey) as? [String: [String]] ?? [:]
            let number = (all[session]?.count ?? 0) + 1
            guard let id = try? await api.createFile(name: "\(session)_phone_\(number).jpg",
                                                     folderId: folder,
                                                     content: jpeg,
                                                     mimeType: "image/jpeg")
            else {
                return
            }
            var ids = all[session] ?? []
            ids.append(id)
            if ids.count > 12 {
                ids.remove(at: ids.count / 2)
            }
            all[session] = ids
            UserDefaults.standard.set(all, forKey: daysIndexThumbsKey)
            rebuildPhone()
            push()
        }
    }

    private func thumbFolderId() async throws -> String {
        if let id = UserDefaults.standard.string(forKey: daysIndexThumbFolderKey) {
            return id
        }
        let root = daysQueue.rootFolderId ?? daysDefaultRootFolderId
        let id = try await api.findOrCreateFolder(name: "_thumbs", parentId: root)
        UserDefaults.standard.set(id, forKey: daysIndexThumbFolderKey)
        return id
    }

    private func indexFolderId() async throws -> String {
        if let id = UserDefaults.standard.string(forKey: daysIndexFolderKey) {
            return id
        }
        let root = daysQueue.rootFolderId ?? daysDefaultRootFolderId
        let id = try await api.findOrCreateFolder(name: "_index", parentId: root)
        UserDefaults.standard.set(id, forKey: daysIndexFolderKey)
        return id
    }
}

func daysSize(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    if gb >= 1 {
        return String(format: "%.1f GB", gb)
    }
    return String(format: "%.0f MB", max(Double(bytes) / 1_000_000, 1))
}

func daysThumbJpeg(_ image: UIImage) -> Data? {
    let width: CGFloat = 480
    let size = CGSize(width: width, height: image.size.height * width / max(image.size.width, 1))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    return resized.jpegData(compressionQuality: 0.7)
}

@MainActor
final class DaysThumbs {
    static let shared = DaysThumbs()
    var localDir: URL?
    private let memory = NSCache<NSString, UIImage>()
    private let api = DriveApi()
    private let dir: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DaysThumbs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        memory.countLimit = 40
    }

    func image(_ id: String) async -> UIImage? {
        if let image = memory.object(forKey: id as NSString) {
            return image
        }
        let file = (localDir ?? dir).appendingPathComponent("\(id).jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: id as NSString)
            return image
        }
        guard localDir == nil, driveAuth.isSignedIn,
              let data = try? await api.downloadMedia(fileId: id),
              let image = UIImage(data: data)
        else {
            return nil
        }
        try? data.write(to: file)
        memory.setObject(image, forKey: id as NSString)
        return image
    }
}
