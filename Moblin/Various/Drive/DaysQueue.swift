import Foundation
import SwiftUI

struct DaysQueueItem: Codable, Identifiable, Sendable {
    var name: String
    var startMs: Int64
    var driveAcked: Int64 = 0
    var driveTotal: Int64 = 0
    var driveFileId: String?
    var driveDone = false
    var githubQueued = false
    var githubReady = false
    var githubDone = 0
    var githubTotal = 0
    var githubFinished = false
    var youTubeId: String?

    var id: String {
        name
    }

    var finished: Bool {
        driveDone && (!githubQueued || githubFinished)
    }
}

private let daysQueueKey = "daysQueueItems"
private let daysRootFolderKey = "daysDriveRootFolderId"
private let daysPhoneFolderKey = "daysDrivePhoneFolderId"
let daysPlaylistKey = "daysYouTubePlaylistId"

@MainActor
final class DaysQueue: ObservableObject {
    @Published var items: [DaysQueueItem] = []
    private var pendingYouTube: (id: String, at: Date)?

    init() {
        if let data = UserDefaults.standard.data(forKey: daysQueueKey),
           let loaded = try? JSONDecoder().decode([DaysQueueItem].self, from: data)
        {
            items = loaded
        }
    }

    var rootFolderId: String? {
        UserDefaults.standard.string(forKey: daysRootFolderKey)
    }

    var phoneFolderId: String? {
        UserDefaults.standard.string(forKey: daysPhoneFolderKey)
    }

    func apply(_ name: String, startMs: Int64?, _ change: (inout DaysQueueItem) -> Void) {
        if let index = items.firstIndex(where: { $0.name == name }) {
            change(&items[index])
        } else {
            var item = DaysQueueItem(name: name, startMs: startMs ?? Int64(Date().timeIntervalSince1970 * 1000))
            if let pending = pendingYouTube, Date().timeIntervalSince(pending.at) < 600 {
                item.youTubeId = pending.id
                pendingYouTube = nil
            }
            change(&item)
            items.append(item)
        }
        items.sort { $0.startMs > $1.startMs }
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 3 * 86_400_000
        items.removeAll { $0.finished && $0.startMs < cutoff }
        while items.count > 15, let index = items.lastIndex(where: { $0.finished }) {
            items.remove(at: index)
        }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: daysQueueKey)
        }
    }

    func attachYouTube(_ id: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let index = items.firstIndex(where: { $0.youTubeId == nil && now - $0.startMs < 1_800_000 }) {
            apply(items[index].name, startMs: nil) { $0.youTubeId = id }
        } else {
            pendingYouTube = (id, Date())
        }
    }
}

@MainActor
let daysQueue = DaysQueue()

func daysQueueUpdate(_ name: String, startMs: Int64? = nil, _ change: @escaping @Sendable (inout DaysQueueItem) -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            daysQueue.apply(name, startMs: startMs, change)
        }
    }
}

func daysSaveFolderIds(root: String, phone: String) {
    UserDefaults.standard.set(root, forKey: daysRootFolderKey)
    UserDefaults.standard.set(phone, forKey: daysPhoneFolderKey)
}

func daysDriveFileUrl(_ id: String) -> URL? {
    URL(string: "https://drive.google.com/file/d/\(id)/view")
}

func daysDriveFolderUrl(_ id: String) -> URL? {
    URL(string: "https://drive.google.com/drive/folders/\(id)")
}

func daysYouTubeUrl(_ id: String) -> URL? {
    URL(string: "https://youtu.be/\(id)")
}

func daysGitHubReleaseUrl(_ tag: String) -> URL? {
    URL(string: "https://github.com/balkonsta/days-archive/releases/tag/\(tag)")
}

let daysGitHubArchiveUrl = URL(string: "https://github.com/balkonsta/days-archive")!

@MainActor
func daysOpenDriveFolder() {
    Task {
        var id = daysQueue.rootFolderId
        if id == nil {
            id = try? await DriveApi().findOrCreateFolder(name: "Days", parentId: "root")
            if let id {
                UserDefaults.standard.set(id, forKey: daysRootFolderKey)
            }
        }
        if let id, let url = daysDriveFolderUrl(id) {
            await UIApplication.shared.open(url)
        }
    }
}

@MainActor
func daysOpenPlaylist() {
    Task {
        let id = await youTubeResolvePlaylistId()
        if let id, let url = URL(string: "https://www.youtube.com/playlist?list=\(id)") {
            await UIApplication.shared.open(url)
        }
    }
}
