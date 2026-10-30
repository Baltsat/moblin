import Foundation

private let daysTaglines = [
    "main character energy · capturing",
    "plot development in progress",
    "this is canon",
    "director's cut, live",
    "episode loading…",
    "no retakes in real life",
    "previously on your life",
    "the season finale is not today",
    "cold open",
    "unscripted, as always",
    "roll camera, live life",
    "the b-roll is the story",
    "every scene counts",
    "filmed on location: here",
    "slow burn, good arc",
    "character development detected",
    "the montage starts now",
    "based on a true story",
    "no stunt double available",
    "you are the pilot episode",
    "renewed for another day",
    "behind the scenes, in front of you",
    "the quiet scene before the twist",
    "this one makes the recap",
    "lead role, no audition",
    "today's episode, unwritten",
    "an origin story in progress",
    "binge-worthy, probably",
    "the soundtrack is ambient",
    "next episode: whatever you do now",
]

func daysNextTagline() -> String {
    let key = "daysRecentTaglines"
    let recent = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
    let pick = daysTaglines.indices.filter { !recent.contains($0) }.randomElement() ?? 0
    UserDefaults.standard.set(Array((recent + [pick]).suffix(8)), forKey: key)
    return daysTaglines[pick]
}

/// user-req: the lock screen / Dynamic Island shows one series-tone line per take instead of "Recording".
@MainActor
final class DaysTake {
    static let shared = DaysTake()
    private(set) var line: String?
    private(set) var since: Date?

    func begin() {
        line = daysNextTagline()
        since = Date()
    }

    func end() {
        line = nil
        since = nil
    }
}
