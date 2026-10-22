import SwiftUI

struct DaysSceneView: View {
    @ObservedObject var index: DaysIndex
    let sceneId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let found = index.scene(sceneId)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    dismiss()
                } label: {
                    Text(verbatim: "\u{2039} \(found.map { daysWeekday($0.1.day, tz: index.tz) } ?? "Days")")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DaysUI.muted)
                }
                if let (scene, episode) = found {
                    header(scene)
                    VStack(spacing: 0) {
                        ForEach(["screen", "face", "phone"], id: \.self) { name in
                            angleSection(name: name, angle: scene.angle(name))
                        }
                    }
                    Text("Originals in Drive: Days/\(episode.id.replacingOccurrences(of: "-", with: "/"))")
                        .font(.system(size: 12))
                        .foregroundStyle(DaysUI.dim)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 26)
        }
        .background(DaysUI.bg.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private func header(_ scene: DaysScene) -> some View {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let range = scene.endMs.map { "\(daysClock(scene.startMs, tz: index.tz)) \u{2013} \(daysClock($0, tz: index.tz))" }
            ?? "\(daysClock(scene.startMs, tz: index.tz)) \u{2013} now"
        let state: (String, Color) = scene.endMs == nil
            ? ("recording", DaysUI.red)
            : scene.safe ? ("safe", DaysUI.green) : ("uploading", DaysUI.amber)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Scene \(scene.number)")
                .font(.system(size: 40, weight: .semibold))
                .tracking(-1.2)
            HStack(spacing: 0) {
                Text("\(range) \u{00B7} \(daysDuration(scene.durationMs(now: now))) \u{00B7} ")
                    .foregroundStyle(DaysUI.muted)
                Text(state.0).fontWeight(.bold).foregroundStyle(state.1)
            }
            .font(.system(size: 14))
        }
    }

    private func detail(_ angle: DaysAngle) -> String {
        var parts: [String] = []
        if angle.youtube != nil {
            parts.append("YouTube")
        }
        if angle.bytes > 0 {
            if angle.uploaded >= angle.bytes {
                parts.append("Drive \(daysSize(angle.bytes)) \u{2713}")
            } else {
                parts.append("Drive \u{2191} \(Int(100 * Double(angle.uploaded) / Double(angle.bytes)))%")
            }
        }
        return parts.isEmpty ? "Recording" : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func angleSection(name: String, angle: DaysAngle?) -> some View {
        let label = DaysAngle(angle: name, bytes: 0, uploaded: 0).label
        if let angle {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(label).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(detail(angle)).font(.system(size: 13)).foregroundStyle(Color(white: 0.7))
                }
                DaysScrubThumb(angle: angle)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if angle.thumbs.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(angle.thumbs, id: \.self) { id in
                                DaysAngleLink(youtube: angle.youtube) {
                                    DaysThumb(id: id, label: label)
                                        .frame(width: 96, height: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                }
                if let id = angle.youtube, let url = daysYouTubeUrl(id) {
                    Link(destination: url) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 11))
                            Text("Watch on YouTube").font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(.vertical, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(DaysUI.line).frame(height: 1)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 16, weight: .semibold))
                Text("Not recording in this scene").font(.system(size: 13)).foregroundStyle(DaysUI.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .opacity(0.5)
            .overlay(alignment: .top) {
                Rectangle().fill(DaysUI.line).frame(height: 1)
            }
        }
    }
}
