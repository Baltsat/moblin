import SwiftUI

private let daysSeenAchKey = "daysSeenAchievements"

struct DaysMainCharView: View {
    let life: DaysLife
    @AppStorage(daysSeenAchKey) private var seen = ""

    private func hours(_ minutes: Int) -> String {
        daysDuration(Int64(minutes) * 60000)
    }

    private var banner: some View {
        let ids = Set(seen.split(separator: ",").map(String.init))
        let fresh = life.ach.filter { !ids.contains($0.id) }
        return Group {
            if let latest = fresh.last {
                Button {
                    seen = ids.union(life.ach.map(\.id)).sorted().joined(separator: ",")
                } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: "\u{2605}").font(.system(size: 22, weight: .bold)).foregroundStyle(DaysUI.amber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NEW \u{00B7} \(latest.t.uppercased())")
                                .font(.system(size: 12, weight: .heavy))
                                .tracking(1.2)
                                .foregroundStyle(.white)
                            Text(fresh.count > 1 ? "\(latest.sub) \u{00B7} +\(fresh.count - 1) more" : latest.sub)
                                .font(.system(size: 12))
                                .foregroundStyle(DaysUI.muted)
                        }
                        Spacer()
                        Text(verbatim: "\u{2715}").font(.system(size: 12)).foregroundStyle(DaysUI.dim)
                    }
                    .padding(12)
                    .background(Color(red: 0x2A / 255, green: 0x22 / 255, blue: 0x10 / 255),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    var body: some View {
        let last = Array(life.days.suffix(30))
        let top = max(25, last.map(\.pct).max() ?? 0)
        let today = life.days.last
        let up = life.avg7 >= life.prev7
        VStack(alignment: .leading, spacing: 12) {
            banner
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(life.today.rounded()))%")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                VStack(alignment: .leading, spacing: 2) {
                    Text("MAIN CHARACTER TODAY")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.4)
                        .foregroundStyle(DaysUI.red)
                    Text("\(hours(today?.rec ?? 0)) of \(hours(today?.awake ?? 0)) awake on record")
                        .font(.system(size: 12))
                        .foregroundStyle(DaysUI.muted)
                }
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(last.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == last.count - 1 ? DaysUI.red
                            : last[i].pct >= 25 ? Color.white.opacity(0.8) : Color.white.opacity(0.25))
                        .frame(height: max(2, 44 * CGFloat(last[i].pct / top)))
                }
            }
            .frame(height: 44, alignment: .bottom)
            HStack(spacing: 12) {
                Text("7-day \(Int(life.avg7.rounded()))% \(up ? "\u{25B2}" : "\u{25BC}") \(Int(abs(life.avg7 - life.prev7).rounded()))")
                    .foregroundStyle(up ? DaysUI.green : DaysUI.red)
                Text("\u{1F525} \(life.streak)-day streak")
                Text("Best \(Int(life.best.rounded()))%")
                Text("\(life.total_h) h total")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DaysUI.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x23 / 255), in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            if seen.isEmpty {
                seen = life.ach.dropLast().map(\.id).joined(separator: ",")
            }
        }
    }
}
