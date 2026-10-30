import Foundation

private let daysTitleFuseKey = "daysTitleFuse"
private let daysTitleCap = 30

private let daysTitlePrompt = """
You name one episode of the TV series "My Life", one person's video diary. Match HIS own naming style.
Episode: {day} {part}, {when} ({dur}). Recorded by: iPhone camera.
Earlier episode titles (newest last): {prev}
The attached image is a contact sheet of this episode (left to right, top to bottom, in time order). Look where he is and what he does.

His style (from 214 days he named himself): English, 1-4 words (max 6), no quotes, no emoji, no period, no explanation.
Name the ONE anchor activity or image, never a list. Dry, self-ironic, deadpan. Allowed shapes:
"<Mood> <Weekday>" (Hustling Tuesday, Healing Sunday), "<Event> @<Place>" (Fablab @Skoltech), a sequel/ordinal joke when an
earlier title is similar (Jazz X2, My Second Stand-Up, not so lazy day after party), one concrete image (Early morning matcha),
mock-epic for turning points (Monk Mode start). A hard or dull stretch stays short and flat (Tiring). No motivational lines,
no therapy words, no names of people, health, sex or money. Never mention Claude, Days, Terminal or the recording.
Use the weekday shape at most once per day: if an earlier title today already names the weekday, pick another shape.
Use "Again" or a sequel joke only when this episode clearly repeats one specific earlier activity, never twice in one title and never if one of the last 3 titles already uses it. Base the title on the whole episode (all frames and the screen log), not on its first minutes.
Reply with the title only.
"""

struct DaysTitleSecrets: Decodable {
    let key: String
    let workspace: String

    static let shared: DaysTitleSecrets? = Bundle.main.url(forResource: "days-secrets", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(DaysTitleSecrets.self, from: $0) }
        .flatMap { $0.key.isEmpty ? nil : $0 }
}

enum DaysTitleError: Error {
    case fuse
    case http(Int)
    case rejected(String)
}

private func daysTitleFuse() throws {
    let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
    let stored = UserDefaults.standard.dictionary(forKey: daysTitleFuseKey) ?? [:]
    let used = stored["day"] as? String == day ? stored["n"] as? Int ?? 0 : 0
    guard used < daysTitleCap else {
        throw DaysTitleError.fuse
    }
    UserDefaults.standard.set(["day": day, "n": used + 1], forKey: daysTitleFuseKey)
}

func daysAskTitle(startMs: Int64, endMs: Int64, tz: TimeZone, prev: [String], sprite: Data?) async throws -> String {
    guard let secrets = DaysTitleSecrets.shared else {
        throw DaysTitleError.http(0)
    }
    try daysTitleFuse()
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let start = Date(timeIntervalSince1970: Double(startMs) / 1000)
    let end = Date(timeIntervalSince1970: Double(endMs) / 1000)
    let hour = cal.component(.hour, from: start)
    let part = 5 ..< 11 ~= hour ? "morning" : 11 ..< 17 ~= hour ? "afternoon" : 17 ..< 23 ~= hour ? "evening" : "night"
    let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    let clock = DateFormatter()
    clock.timeZone = tz
    clock.dateFormat = "HH:mm"
    let mins = (endMs - startMs) / 60000
    let prompt = daysTitlePrompt
        .replacingOccurrences(of: "{day}", with: days[cal.component(.weekday, from: start) - 1])
        .replacingOccurrences(of: "{part}", with: part)
        .replacingOccurrences(of: "{when}", with: "\(clock.string(from: start))–\(clock.string(from: end))")
        .replacingOccurrences(of: "{dur}", with: mins >= 60 ? "\(mins / 60) h \(mins % 60) min" : "\(mins) min")
        .replacingOccurrences(of: "{prev}", with: prev.isEmpty ? "(none yet)" : prev.joined(separator: ", "))
    var content: [[String: Any]] = []
    if let sprite {
        content.append(["type": "image",
                        "source": ["type": "base64", "media_type": "image/jpeg", "data": sprite.base64EncodedString()]])
    }
    content.append(["type": "text", "text": prompt])
    let body: [String: Any] = [
        "model": "claude-sonnet-5-5",
        "max_tokens": 2000,
        "output_config": ["effort": "low"],
        "messages": [["role": "user", "content": content]],
    ]
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue(secrets.key, forHTTPHeaderField: "x-api-key")
    request.setValue(secrets.workspace, forHTTPHeaderField: "anthropic-workspace-id")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let blocks = root["content"] as? [[String: Any]]
    else {
        throw DaysTitleError.http(status)
    }
    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    let last = text.split(separator: "\n").last.map(String.init) ?? ""
    let title = last
        .replacingOccurrences(of: "[\"'«»“”„.!*#_]|[\\x{1F000}-\\x{1FFFF}\\x{2600}-\\x{27BF}]", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    let words = title.split(separator: " ").count
    guard 1 ... 6 ~= words,
          title.range(of: "claude|клод|days|terminal|iterm|терминал", options: [.regularExpression, .caseInsensitive]) == nil
    else {
        throw DaysTitleError.rejected(title)
    }
    return title
}
