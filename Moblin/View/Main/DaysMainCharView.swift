import SwiftUI

private let daysSeenAchKey = "daysSeenAchievements"

struct DaysHead: View {
    let life: DaysLife?
    let season: Int
    let episode: Int
    let weekday: String
    let tz: TimeZone
    @AppStorage(daysSeenAchKey) private var seen = ""
    @State private var pressed: Int?

    private var past: [DaysLifeDay] {
        Array((life?.days ?? []).dropLast().suffix(29).drop { $0.rec == 0 })
    }

    private func dayName(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = tz
        guard let date = parser.date(from: iso) else {
            return iso
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = tz
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    private func subtitle(_ past: [DaysLifeDay], _ fresh: [DaysAchievement]) -> Text {
        let episodeText = "Season \(season) \u{00B7} Episode \(episode)"
        if let i = pressed, past.indices.contains(i) {
            let day = past[i]
            return Text("\(dayName(day.d)) \u{00B7} ").foregroundColor(DaysUI.muted)
                + Text("\(Int(day.pct.rounded()))%").foregroundColor(.white).bold()
                + Text(" of the waking day \u{00B7} \(daysDuration(Int64(day.rec) * 60000))").foregroundColor(DaysUI.muted)
        }
        if let latest = fresh.last {
            return Text("\(episodeText)  ").foregroundColor(DaysUI.muted)
                + Text("\u{2605} \(latest.t)").foregroundColor(DaysUI.amber)
        }
        return Text(episodeText).foregroundColor(DaysUI.muted)
    }

    private func bars(_ past: [DaysLifeDay]) -> some View {
        let top = max(30, past.map(\.pct).max() ?? 0)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(past.indices, id: \.self) { i in
                let pct = past[i].pct
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(pressed == i ? DaysUI.red : Color.white.opacity(pct >= 25 ? 0.82 : 0.2 + 0.4 * pct / 25))
                    .frame(width: 4, height: max(2, 30 * CGFloat(pct / top)))
            }
        }
        .frame(height: 30, alignment: .bottom)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                pressed = min(max(Int(drag.location.x / 6), 0), past.count - 1)
            }
            .onEnded { _ in
                pressed = nil
            })
        .animation(.easeOut(duration: 0.12), value: pressed)
    }

    var body: some View {
        let past = past
        let ids = Set(seen.split(separator: ",").map(String.init))
        let fresh = (life?.ach ?? []).filter { !ids.contains($0.id) }
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                subtitle(past, fresh)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .lineLimit(1)
                    .animation(.easeOut(duration: 0.12), value: pressed)
                    .onTapGesture {
                        if !fresh.isEmpty {
                            seen = ids.union((life?.ach ?? []).map(\.id)).sorted().joined(separator: ",")
                        }
                    }
                Text(weekday)
                    .font(.system(size: 40, weight: .semibold))
                    .tracking(-1.2)
            }
            Spacer(minLength: 12)
            if !past.isEmpty {
                bars(past)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 8 }
            }
        }
        .onAppear {
            if seen.isEmpty, let life {
                seen = life.ach.dropLast().map(\.id).joined(separator: ",")
            }
            #if DEBUG
                if let i = UserDefaults.standard.object(forKey: "DaysLifePressed") as? Int {
                    pressed = i
                }
            #endif
        }
    }
}
