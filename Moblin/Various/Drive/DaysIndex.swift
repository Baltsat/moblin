import AVFoundation
import Combine
import Foundation
import SwiftUI

private let daysIndexFolderKey = "daysIndexFolderId"
private let daysIndexPhoneFileKey = "daysIndexPhoneFileId"
private let daysIndexMacFileKey = "daysIndexMacFileId"
private let daysIndexSpritesKey = "daysIndexSprites"
private let daysSpriteTriesKey = "daysIndexSpriteTries"
private let daysIndexEndsKey = "daysIndexEnds2"
private let daysIndexDurationsKey = "daysIndexDurations"
private let daysIndexDurTriesKey = "daysIndexDurTries2"
private let daysIndexRepairedKey = "daysIndexRepaired1"
private let daysEstimateBitrate = 12_000_000.0
private let daysIndexThumbsKey = "daysIndexThumbs"
private let daysIndexHistoryKey = "daysIndexPhoneHistory"
private let daysThumbTriesKey = "daysIndexThumbTries2"
private let daysIndexThumbFolderKey = "daysIndexThumbFolderId"
private let daysStaleMs: Int64 = 180_000
private let daysMergeGapMs: Int64 = 10000
private let daysPremiere = (year: 2026, month: 10, day: 19)

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
    var sprite: DaysSprite?
}

struct DaysAngle: Equatable {
    var angle: String
    var youtube: String?
    var driveId: String?
    var bytes: Int64
    var uploaded: Int64
    var thumbs: [String] = []
    var sprite: DaysSprite?

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
    var endEst = false
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
    var titles: [String: String] = [:]

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
        titles = root["titles"] as? [String: String] ?? [:]
        tz = root["tz"] as? String ?? TimeZone.current.identifier
        updatedMs = (root["updated_ms"] as? NSNumber)?.int64Value ?? 0
        if let live = root["live"] as? [String: Any] {
            self.live = DaysRawLive(
                session: live["session"] as? String ?? "",
                startMs: (live["start_ms"] as? NSNumber)?.int64Value ?? 0,
                angles: (live["angles"] as? [[String: Any]] ?? []).map {
                    DaysLiveAngle(angle: $0["angle"] as? String ?? "",
                                  youtube: $0["youtube"] as? String,
                                  thumbs: $0["thumbs"] as? [String] ?? [],
                                  sprite: ($0["sprite"] as? [String: Any]).flatMap { DaysSprite($0) })
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
                              thumbs: $0["thumbs"] as? [String] ?? [],
                              sprite: ($0["sprite"] as? [String: Any]).flatMap { DaysSprite($0) })
                },
                endEst: scene["end_est"] as? Bool ?? false
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
                "angles": live.angles.map { angle -> [String: Any] in
                    var out: [String: Any] = ["angle": angle.angle, "youtube": daysNull(angle.youtube), "thumbs": angle.thumbs]
                    if let sprite = angle.sprite {
                        out["sprite"] = sprite.dict
                    }
                    return out
                },
            ]
        }
        root["scenes"] = scenes.map { scene -> [String: Any] in
            var out: [String: Any] = [
                "session": scene.session,
                "start_ms": scene.startMs,
                "end_ms": scene.endMs ?? null,
                "failed": scene.failed,
                "angles": scene.angles.map { angle -> [String: Any] in
                    var out: [String: Any] = [
                        "angle": angle.angle,
                        "youtube": daysNull(angle.youtube),
                        "drive_id": daysNull(angle.driveId),
                        "thumbs": angle.thumbs,
                        "bytes": angle.bytes,
                        "uploaded": angle.uploaded,
                    ]
                    if let sprite = angle.sprite {
                        out["sprite"] = sprite.dict
                    }
                    return out
                },
            ]
            if scene.endEst {
                out["end_est"] = true
            }
            return out
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
    var sessions: [String] = []
    var title: String?

    func isShort(now: Int64) -> Bool {
        endMs != nil && durationMs(now: now) < 60000
    }

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
    private var requeued = Set<String>()
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
    private var frameTimer: Timer?
    private var liveFrames: [UIImage] = []
    private var spriteBusy = false
    private var wasRecording = false
    private var resolving = false
    private var thumbsMap: [String: [String]] = [:]
    private var seeded = false
    private var generating = false
    private var pulls = 0
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
        daysLog("build titles-shorts-nav season1=2026-10-19")
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
        if driveAuth.isSignedIn, !UserDefaults.standard.bool(forKey: daysIndexRepairedKey) {
            UserDefaults.standard.set(true, forKey: daysIndexRepairedKey)
            push()
        }
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
            DaysSprites.shared.localDir = base.appendingPathComponent("sprites")
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
        guard value != wasRecording else {
            return
        }
        wasRecording = value
        let now = nowMs()
        thumbTimer?.invalidate()
        thumbTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        if value {
            liveFrames = []
            frameTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.collectFrame() }
            }
            recordingStartMs = now
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.captureThumb()
            }
            thumbTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.captureThumb()
                    self?.uploadLiveSprite()
                }
            }
        } else {
            captureThumb()
            finalizeSprite()
            var ends = UserDefaults.standard.dictionary(forKey: daysIndexEndsKey) as? [String: Int64] ?? [:]
            for item in daysQueue.items
                where ends[item.name] == nil && recordingStartMs > 0 && item.startMs >= recordingStartMs - 120_000
            {
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

    func refreshAndPush() {
        rebuildPhone()
        push()
    }

    private func rebuildPhone() {
        let recording = model?.isRecording ?? false
        phoneRecording = recording
        let ends = UserDefaults.standard.dictionary(forKey: daysIndexEndsKey) as? [String: Int64] ?? [:]
        let phoneThumbs = UserDefaults.standard.dictionary(forKey: daysIndexThumbsKey) as? [String: [String]] ?? [:]
        let phoneSprites = (UserDefaults.standard.dictionary(forKey: daysIndexSpritesKey) as? [String: [String: Any]] ?? [:])
            .compactMapValues { DaysSprite($0) }
        let durations = UserDefaults.standard.dictionary(forKey: daysIndexDurationsKey) as? [String: Double] ?? [:]
        func resolved(_ session: String, _ start: Int64, _ bytes: Int64) -> (Int64, Bool) {
            if let end = ends[session] {
                return (end, false)
            }
            if let seconds = durations[session] {
                return (start + Int64(seconds * 1000), false)
            }
            return (start + Int64(Double(bytes) * 8 / daysEstimateBitrate * 1000), true)
        }
        var scenes: [DaysRawScene] = []
        var live: DaysRawLive?
        for (index, item) in daysQueue.items.enumerated().reversed() {
            let isLive = recording && index == 0 && ends[item.name] == nil
            let bytes = item.driveTotal
            let estimate = resolved(item.name, item.startMs, bytes)
            let end: Int64? = isLive ? nil : estimate.0
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
                                   thumbs: phoneThumbs[item.name] ?? [],
                                   sprite: phoneSprites[item.name])],
                endEst: !isLive && estimate.1
            ))
            if isLive {
                live = DaysRawLive(session: item.name,
                                   startMs: item.startMs,
                                   angles: [DaysLiveAngle(angle: "phone",
                                                          youtube: item.youTubeId,
                                                          thumbs: phoneThumbs[item.name] ?? [],
                                                          sprite: phoneSprites[item.name])])
            }
        }
        let names = Set(scenes.map(\.session))
        for var old in storedHistory().scenes where !names.contains(old.session) {
            let estimate = resolved(old.session, old.startMs, old.angles.first?.bytes ?? 0)
            old.endMs = estimate.0
            old.endEst = estimate.1
            scenes.append(old)
        }
        scenes.sort { $0.startMs < $1.startMs }
        for index in scenes.indices {
            for angleIndex in scenes[index].angles.indices where scenes[index].angles[angleIndex].thumbs.isEmpty {
                scenes[index].angles[angleIndex].thumbs = phoneThumbs[scenes[index].session] ?? []
            }
            for angleIndex in scenes[index].angles.indices where scenes[index].angles[angleIndex].sprite == nil {
                scenes[index].angles[angleIndex].sprite = phoneSprites[scenes[index].session]
            }
        }
        phone = DaysRawIndex(device: "iphone",
                             tz: tz.identifier,
                             updatedMs: nowMs(),
                             live: live,
                             scenes: scenes)
        if let data = phone.encoded() {
            UserDefaults.standard.set(data, forKey: daysIndexHistoryKey)
        }
        rebuild()
        requeueMissing()
    }

    private func requeueMissing() {
        guard !fixtures, driveAuth.isSignedIn else {
            return
        }
        let files = localRecordings()
        for scene in phone.scenes where scene.endMs != nil && scene.session != phone.live?.session && !requeued.contains(scene.session) {
            guard let angle = scene.angles.first(where: { $0.angle == "phone" }), angle.driveId == nil, angle.bytes > 0,
                  let url = localFile(for: scene, in: files),
                  let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
                  Date().timeIntervalSince(modified) > 120
            else {
                continue
            }
            requeued.insert(scene.session)
            daysLog("index requeue \(scene.session) \(url.lastPathComponent)")
            driveUploader.requeue(name: scene.session, startMs: scene.startMs, path: url.path)
        }
    }

    private func storedHistory() -> DaysRawIndex {
        let data = UserDefaults.standard.data(forKey: daysIndexHistoryKey)
        return data.flatMap { DaysRawIndex(data: $0) }
            ?? DaysRawIndex(device: "iphone", tz: tz.identifier, updatedMs: 0, live: nil, scenes: [])
    }

    private func seedHistory(_ remote: DaysRawIndex) {
        var stored = storedHistory()
        let known = Set(stored.scenes.map(\.session)).union(daysQueue.items.map(\.name))
        let extra = remote.scenes.filter { !known.contains($0.session) }
        guard !extra.isEmpty else {
            return
        }
        stored.scenes += extra
        if let data = stored.encoded() {
            UserDefaults.standard.set(data, forKey: daysIndexHistoryKey)
        }
        var ids = UserDefaults.standard.dictionary(forKey: daysIndexThumbsKey) as? [String: [String]] ?? [:]
        for scene in extra {
            if let thumbs = scene.angles.first?.thumbs, !thumbs.isEmpty, ids[scene.session] == nil {
                ids[scene.session] = thumbs
            }
        }
        UserDefaults.standard.set(ids, forKey: daysIndexThumbsKey)
        rebuildPhone()
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
                for index in scene.angles.indices where scene.angles[index].thumbs.isEmpty {
                    if let id = scene.angles[index].driveId, let ids = thumbsMap[id] {
                        scene.angles[index].thumbs = ids
                    }
                }
                if scene.endMs == nil, !live || scene.session != file.live?.session {
                    scene.endMs = file.updatedMs
                }
                if scene.endEst, let end = scene.endMs {
                    let bytes = scene.angles.map(\.bytes).max() ?? 0
                    let estimate = Int64(Double(bytes) * 8 / daysEstimateBitrate * 1000)
                    scene.endMs = min(end, scene.startMs + estimate)
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
                last.sessions.append(scene.session)
                merged[merged.count - 1] = last
            } else {
                merged.append(DaysScene(id: scene.session,
                                        startMs: scene.startMs,
                                        endMs: scene.endMs,
                                        angles: scene.angles,
                                        live: isLive,
                                        sessions: [scene.session]))
            }
        }
        let titles = mac?.titles ?? [:]
        for index in merged.indices {
            merged[index].title = merged[index].sessions.compactMap { titles[$0] }.first { !$0.isEmpty }
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
        pulls += 1
        Task {
            guard let folder = try? await indexFolderId() else {
                return
            }
            await pullExtras(folder: folder)
            generatePhoneThumbs()
            resolveDurations()
            generatePhoneSprite()
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

    private func pullExtras(folder: String) async {
        if !seeded {
            seeded = true
            var own = UserDefaults.standard.string(forKey: daysIndexPhoneFileKey)
            if own == nil {
                own = try? await api.findFile(name: "iphone.json", folderId: folder)
            }
            if let own, let data = try? await api.downloadMedia(fileId: own), let remote = DaysRawIndex(data: data) {
                seedHistory(remote)
            }
        }
        guard pulls % 10 == 1 else {
            return
        }
        if let id = try? await api.findFile(name: "thumbs-phone.json", folderId: folder),
           let data = try? await api.downloadMedia(fileId: id),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        {
            thumbsMap = map
            rebuildPhone()
        }
    }

    private func localRecordings() -> [(url: URL, ms: Int64)] {
        let dir = URL.documentsDirectory.appending(component: "Recordings")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Makassar")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> (URL, Int64)? in
            guard name.hasPrefix("Recording_"), name.hasSuffix(".mp4"),
                  let date = formatter.date(from: String(name.dropFirst(10).dropLast(4)))
            else {
                return nil
            }
            return (dir.appending(component: name), Int64(date.timeIntervalSince1970 * 1000))
        }
    }

    private func localFile(for scene: DaysRawScene, in files: [(url: URL, ms: Int64)]) -> URL? {
        files.first { abs($0.ms - scene.startMs) < 90000 }?.url
    }

    private func resolveDurations() {
        guard !fixtures, !resolving, driveAuth.isSignedIn else {
            return
        }
        let ends = UserDefaults.standard.dictionary(forKey: daysIndexEndsKey) as? [String: Int64] ?? [:]
        let durations = UserDefaults.standard.dictionary(forKey: daysIndexDurationsKey) as? [String: Double] ?? [:]
        var tries = UserDefaults.standard.dictionary(forKey: daysIndexDurTriesKey) as? [String: Int] ?? [:]
        let files = localRecordings()
        let candidate = phone.scenes.reversed().first { scene in
            guard let angle = scene.angles.first else {
                return false
            }
            let local = localFile(for: scene, in: files) != nil
            let remote = angle.driveId != nil && angle.bytes > 0 && angle.uploaded >= angle.bytes
            return scene.endMs != nil && scene.endEst && ends[scene.session] == nil
                && durations[scene.session] == nil && (local || remote) && (tries[scene.session] ?? 0) < 3
        }
        guard let candidate else {
            return
        }
        let local = localFile(for: candidate, in: files)
        let driveId = candidate.angles.first?.driveId
        resolving = true
        tries[candidate.session] = (tries[candidate.session] ?? 0) + 1
        UserDefaults.standard.set(tries, forKey: daysIndexDurTriesKey)
        Task {
            defer { resolving = false }
            guard let asset = await daysAsset(local: local, driveId: driveId),
                  let seconds = await daysAssetDuration(asset)
            else {
                return
            }
            var all = UserDefaults.standard.dictionary(forKey: daysIndexDurationsKey) as? [String: Double] ?? [:]
            all[candidate.session] = seconds
            UserDefaults.standard.set(all, forKey: daysIndexDurationsKey)
            daysLog("duration \(candidate.session) \(seconds)s local=\(local != nil)")
            rebuildPhone()
            push()
            resolveDurations()
        }
    }

    private func generatePhoneThumbs() {
        guard !fixtures, !generating, driveAuth.isSignedIn else {
            return
        }
        var tries = UserDefaults.standard.dictionary(forKey: daysThumbTriesKey) as? [String: Int] ?? [:]
        let files = localRecordings()
        let candidate = phone.scenes.reversed().first { scene in
            guard let angle = scene.angles.first else {
                return false
            }
            let local = localFile(for: scene, in: files) != nil
            let remote = angle.driveId != nil && angle.bytes > 0 && angle.uploaded >= angle.bytes
            return scene.endMs != nil && angle.thumbs.isEmpty && (local || remote)
                && (tries[scene.session] ?? 0) < 3 && thumbsMap[angle.driveId ?? ""] == nil
        }
        guard let candidate else {
            return
        }
        let local = localFile(for: candidate, in: files)
        let driveId = candidate.angles.first?.driveId
        generating = true
        tries[candidate.session] = (tries[candidate.session] ?? 0) + 1
        UserDefaults.standard.set(tries, forKey: daysThumbTriesKey)
        Task {
            defer { generating = false }
            guard let folder = try? await thumbFolderId(), let asset = await daysAsset(local: local, driveId: driveId) else {
                daysLog("thumbs \(candidate.session): no asset or folder")
                return
            }
            let frames = await daysAssetFrames(asset)
            var ids: [String] = []
            for (number, frame) in frames.enumerated() {
                if let id = try? await api.createFile(name: "\(candidate.session)_phone_\(number + 1).jpg",
                                                      folderId: folder,
                                                      content: frame,
                                                      mimeType: "image/jpeg")
                {
                    ids.append(id)
                }
            }
            daysLog("thumbs \(candidate.session): frames=\(frames.count) uploaded=\(ids.count) local=\(local != nil)")
            guard !ids.isEmpty else {
                return
            }
            var all = UserDefaults.standard.dictionary(forKey: daysIndexThumbsKey) as? [String: [String]] ?? [:]
            all[candidate.session] = ids
            UserDefaults.standard.set(all, forKey: daysIndexThumbsKey)
            rebuildPhone()
            push()
            generatePhoneThumbs()
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
                daysLog("index pushed")
            } catch DriveError.sessionGone {
                UserDefaults.standard.removeObject(forKey: daysIndexPhoneFileKey)
            } catch {
                daysLog("index push failed \(error)")
            }
        }
    }

    private func collectFrame() {
        guard !fixtures, let model else {
            return
        }
        model.media.takeSnapshot(age: 0) { [weak self] image, _, _ in
            guard let self else {
                return
            }
            let scale = 320 / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            self.liveFrames.append(small)
        }
    }

    private func uploadLiveSprite() {
        guard !fixtures, driveAuth.isSignedIn, let session = daysQueue.items.first?.name, !liveFrames.isEmpty,
              let sheet = daysComposeSprite(frames: liveFrames)
        else {
            return
        }
        uploadSprite(sheet, session: session, spanMs: Int64(liveFrames.count) * 30000)
    }

    private func finalizeSprite() {
        guard !fixtures, driveAuth.isSignedIn, let session = daysQueue.items.first?.name else {
            return
        }
        let frames = liveFrames
        let start = recordingStartMs
        Task {
            for attempt in 0 ..< 4 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 4 : 6))
                let files = localRecordings()
                if let local = files.first(where: { abs($0.ms - start) < 90000 })?.url,
                   let result = await daysAssetSpriteFrames(AVURLAsset(url: local), count: 48),
                   let sheet = daysComposeSprite(frames: result.frames)
                {
                    daysLog("sprite final \(session) from file")
                    uploadSprite(sheet, session: session, spanMs: result.spanMs)
                    return
                }
            }
            if let sheet = daysComposeSprite(frames: frames) {
                daysLog("sprite final \(session) from live frames")
                uploadSprite(sheet, session: session, spanMs: Int64(frames.count) * 30000)
            }
        }
    }

    private func uploadSprite(_ sheet: DaysSpriteSheet, session: String, spanMs: Int64) {
        Task {
            guard let folder = try? await thumbFolderId() else {
                return
            }
            var all = UserDefaults.standard.dictionary(forKey: daysIndexSpritesKey) as? [String: [String: Any]] ?? [:]
            var fileId = all[session]?["id"] as? String
            do {
                if let id = fileId {
                    try await api.updateMedia(fileId: id, content: sheet.data, mimeType: "image/jpeg")
                } else {
                    fileId = try await api.createFile(name: "\(session)_phone_sprite.jpg",
                                                      folderId: folder,
                                                      content: sheet.data,
                                                      mimeType: "image/jpeg")
                }
            } catch {
                daysLog("sprite upload failed \(session) \(error)")
                return
            }
            guard let fileId else {
                return
            }
            let sprite = DaysSprite(id: fileId, n: sheet.n, cols: sheet.cols, w: sheet.w, h: sheet.h, spanMs: spanMs)
            all[session] = sprite.dict
            UserDefaults.standard.set(all, forKey: daysIndexSpritesKey)
            if let dir = DaysSprites.shared.cacheDirectory {
                try? sheet.data.write(to: dir.appendingPathComponent("\(fileId).jpg"))
            }
            daysLog("sprite \(session) \(sheet.data.count) bytes n=\(sheet.n)")
            _ = await DaysSprites.shared.sheet(fileId, refresh: true)
            rebuildPhone()
            push()
        }
    }

    private func generatePhoneSprite() {
        guard !fixtures, !spriteBusy, driveAuth.isSignedIn else {
            return
        }
        var tries = UserDefaults.standard.dictionary(forKey: daysSpriteTriesKey) as? [String: Int] ?? [:]
        let files = localRecordings()
        let candidate = phone.scenes.reversed().first { scene in
            guard let angle = scene.angles.first else {
                return false
            }
            let local = localFile(for: scene, in: files) != nil
            let remote = angle.driveId != nil && angle.bytes > 0 && angle.uploaded >= angle.bytes
            return scene.endMs != nil && angle.sprite == nil && (local || remote) && (tries[scene.session] ?? 0) < 3
        }
        guard let candidate else {
            return
        }
        let local = localFile(for: candidate, in: files)
        let driveId = candidate.angles.first?.driveId
        spriteBusy = true
        tries[candidate.session] = (tries[candidate.session] ?? 0) + 1
        UserDefaults.standard.set(tries, forKey: daysSpriteTriesKey)
        Task {
            defer { spriteBusy = false }
            guard let asset = await daysAsset(local: local, driveId: driveId),
                  let result = await daysAssetSpriteFrames(asset, count: local != nil ? 48 : 24),
                  let sheet = daysComposeSprite(frames: result.frames)
            else {
                daysLog("sprite \(candidate.session): no frames local=\(local != nil)")
                return
            }
            uploadSprite(sheet, session: candidate.session, spanMs: result.spanMs)
            try? await Task.sleep(for: .seconds(2))
            generatePhoneSprite()
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
        excludeFromBackup(url)
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

func daysAsset(local: URL?, driveId: String?) async -> AVURLAsset? {
    if let local {
        return AVURLAsset(url: local)
    }
    guard let driveId, let token = try? await driveAuth.accessToken(),
          let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(driveId)?alt=media")
    else {
        return nil
    }
    return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
}

func daysAssetDuration(_ asset: AVURLAsset) async -> Double? {
    guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 1 else {
        return nil
    }
    return duration.seconds
}

func daysAssetFrames(_ asset: AVURLAsset) async -> [Data] {
    guard let seconds = await daysAssetDuration(asset) else {
        return []
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 480)
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    var frames: [Data] = []
    for fraction in [0.05, 0.5, 0.95] {
        let time = CMTime(seconds: seconds * fraction, preferredTimescale: 600)
        if let (image, _) = try? await generator.image(at: time),
           let jpeg = await daysThumbJpeg(UIImage(cgImage: image))
        {
            frames.append(jpeg)
        }
    }
    return frames
}
