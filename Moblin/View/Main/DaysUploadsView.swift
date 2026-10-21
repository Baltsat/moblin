import SwiftUI

@MainActor func daysUploadReason(drive: DriveStatus) -> String? {
    let text = drive.text.lowercased()
    if !drive.signedIn || text.contains("sign in") {
        return "Sign in to Google"
    }
    if text.contains("in background") {
        return daysNetStatus.kind == .wifi ? "Uploading in background on Wi-Fi" : "Waiting for Wi-Fi"
    }
    if text.contains("storage is full") {
        return "Drive storage is full"
    }
    if text.contains("waiting for network") {
        return "Waiting for Wi-Fi"
    }
    if DaysPace.live {
        return "Paced while live"
    }
    if text.contains("failed") || text.contains("lost") {
        return "Retrying"
    }
    return nil
}

private struct DaysUploadRow: Identifiable {
    var scene: DaysScene
    var angle: DaysAngle

    var id: String {
        "\(scene.id)-\(angle.angle)"
    }
}

struct DaysUploadsView: View {
    @ObservedObject var index: DaysIndex
    @ObservedObject var drive: DriveStatus
    @ObservedObject var queue: DaysQueue
    @Environment(\.dismiss) private var dismiss

    private var rows: [DaysUploadRow] {
        index.seasons.flatMap(\.episodes).flatMap(\.scenes).reversed().flatMap { scene in
            scene.present.filter { $0.bytes > $0.uploaded || (scene.endMs == nil) }.map {
                DaysUploadRow(scene: scene, angle: $0)
            }
        }
    }

    private var safeToday: Int {
        index.today.scenes.reduce(0) { total, scene in
            total + scene.present.filter { $0.bytes > 0 && $0.uploaded >= $0.bytes }.count
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            content
        }
        .background(DaysUI.bg.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private var content: some View {
        let rows = rows
        let left = rows.reduce(Int64(0)) { $0 + max($1.angle.bytes - $1.angle.uploaded, 0) }
        let speed = queue.live.values.filter { Date().timeIntervalSince($0.at) < 4 }.map(\.speed).max() ?? 0
        let eta: String? = speed > 0 && left > 0 ? "~\(max(Int((Double(left) / speed / 60).rounded(.up)), 1)) min" : index.leftEta
        let reason = daysUploadReason(drive: drive)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    dismiss()
                } label: {
                    Text(verbatim: "\u{2039} Days")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DaysUI.muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if rows.isEmpty {
                        Text("All safe")
                            .font(.system(size: 40, weight: .semibold))
                            .tracking(-1.2)
                        Text(verbatim: "\u{2713} Everything is in Drive")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DaysUI.green)
                    } else {
                        Text(left > 0 ? daysSize(left) : "Recording")
                            .font(.system(size: 40, weight: .semibold))
                            .tracking(-1.2)
                        Text(verbatim: "\(left > 0 ? "\u{2191} left" : "\u{25CF} Safe after Cut")\(eta.map { " \u{00B7} \($0)" } ?? "")\(reason.map { " \u{00B7} \($0)" } ?? "")")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(left > 0 ? DaysUI.amber : DaysUI.red)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        uploadRow(row, reason: reason)
                    }
                }
                if safeToday > 0 {
                    HStack(spacing: 8) {
                        Text(verbatim: "\u{2713}").foregroundStyle(DaysUI.green)
                        Text("\(safeToday) safe today").foregroundStyle(DaysUI.muted)
                        Spacer()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.vertical, 14)
                    .overlay(alignment: .top) {
                        Rectangle().fill(DaysUI.line).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    private func uploadRow(_ row: DaysUploadRow, reason: String?) -> some View {
        let angle = row.angle
        let live = queue.live[row.scene.id].flatMap { Date().timeIntervalSince($0.at) < 4 ? $0 : nil }
        let recording = row.scene.endMs == nil
        let fraction = angle.bytes > 0 ? min(Double(angle.uploaded) / Double(angle.bytes), 1) : 0
        let detail: String
        if recording {
            detail = "Safe after Cut"
        } else if let reason {
            detail = reason
        } else if let live, live.speed > 0 {
            let left = Double(max(angle.bytes - angle.uploaded, 0))
            detail = String(format: "%.1f MB/s \u{00B7} ~%d min", live.speed / 1_000_000,
                            max(Int((left / live.speed / 60).rounded(.up)), 1))
        } else if angle.angle == "phone" {
            detail = "Queued"
        } else {
            detail = "Uploading from MacBook"
        }
        return HStack(spacing: 14) {
            DaysThumb(id: angle.thumbs.last, label: angle.label)
                .frame(width: 72, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Scene \(row.scene.number) \u{00B7} \(angle.label)")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(daysSize(angle.uploaded)) / \(daysSize(angle.bytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(DaysUI.muted)
                        .monospacedDigit()
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(DaysUI.line)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(recording ? DaysUI.red : DaysUI.amber)
                            .frame(width: geometry.size.width * (recording ? 0.04 : fraction))
                    }
                }
                .frame(height: 3)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DaysUI.muted)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(DaysUI.line).frame(height: 1)
        }
    }
}
