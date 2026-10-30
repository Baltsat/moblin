import Foundation

/// Season recaps and teasers from Drive _recaps/S<n>/; the cloud editor replaces them in place, so a changed
/// md5/modifiedTime means a new cut and the cached copy is replaced.
@MainActor
final class DaysRecaps: ObservableObject {
    static let shared = DaysRecaps()
    @Published private(set) var recaps: [Int: URL] = [:]
    @Published private(set) var teasers: [Int: URL] = [:]
    private let dir = URL.applicationSupportDirectory.appending(path: "Recaps")
    private let stampsKey = "daysRecapStamps"
    private var busy = false
    private var checkedAt = Date.distantPast

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for season in 1 ... 60 {
            try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "recap-S\(season).mp4"))
        }
        scan()
    }

    private func scan() {
        var recaps: [Int: URL] = [:]
        var teasers: [Int: URL] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard let (kind, season) = Self.parse(name) else {
                continue
            }
            if kind == "recap" {
                recaps[season] = dir.appending(path: name)
            } else {
                teasers[season] = dir.appending(path: name)
            }
        }
        if recaps != self.recaps {
            self.recaps = recaps
        }
        if teasers != self.teasers {
            self.teasers = teasers
        }
    }

    private static func parse(_ name: String) -> (String, Int)? {
        for kind in ["recap", "teaser"] where name.hasPrefix("\(kind)-S") && name.hasSuffix(".mp4") {
            if let season = Int(name.dropFirst(kind.count + 2).dropLast(4)) {
                return (kind, season)
            }
        }
        return nil
    }

    func expire() {
        checkedAt = .distantPast
    }

    func refresh(download: Bool) async {
        guard !busy, driveAuth.isSignedIn, Date().timeIntervalSince(checkedAt) > 300 else {
            return
        }
        checkedAt = Date()
        busy = true
        defer { busy = false }
        let api = DriveApi()
        let query = "(name contains 'recap-S' or name contains 'teaser-S') and trashed=false"
        guard let files = try? await api.search(query, fields: "id,name,md5Checksum,modifiedTime,version") else {
            return
        }
        var stamps = UserDefaults.standard.dictionary(forKey: stampsKey) as? [String: String] ?? [:]
        var seen = Set<String>()
        for file in files {
            guard let id = file["id"] as? String, let name = file["name"] as? String, Self.parse(name) != nil,
                  seen.insert(name).inserted
            else {
                continue
            }
            let stamp = (file["md5Checksum"] as? String) ?? "\(file["modifiedTime"] ?? "")-\(file["version"] ?? "")"
            let local = dir.appending(path: name)
            guard stamps[name] != stamp || !FileManager.default.fileExists(atPath: local.path) else {
                continue
            }
            guard download else {
                continue
            }
            guard let data = try? await api.downloadMedia(fileId: id),
                  (try? data.write(to: local, options: .atomic)) != nil
            else {
                daysLog("recap \(name) download failed")
                continue
            }
            stamps[name] = stamp
            UserDefaults.standard.set(stamps, forKey: stampsKey)
            daysLog("recap \(name) updated \(data.count) bytes \(stamp)")
            scan()
        }
    }
}
