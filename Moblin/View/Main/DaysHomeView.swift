import AVKit
import SwiftUI

enum DaysUI {
    static let bg = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0F / 255)
    static let surface = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x1A / 255)
    static let line = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)
    static let muted = Color(red: 0x8C / 255, green: 0x8C / 255, blue: 0x8C / 255)
    static let dim = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x6E / 255)
    static let red = Color(red: 0xE5 / 255, green: 0x09 / 255, blue: 0x14 / 255)
    static let green = Color(red: 0x46 / 255, green: 0xD3 / 255, blue: 0x69 / 255)
    static let amber = Color(red: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255)
    static let liveCard = Color(red: 0x1A / 255, green: 0x12 / 255, blue: 0x14 / 255)
}

private enum DaysRoute: Hashable {
    case day(String)
    case scene(String)
    case uploads
}

func daysDuration(_ ms: Int64) -> String {
    let minutes = Int((Double(ms) / 60000).rounded())
    if minutes < 60 {
        return "\(minutes) min"
    }
    return String(format: "%dh %02dm", minutes / 60, minutes % 60)
}

func daysClock(_ ms: Int64, tz: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = tz
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

func daysWeekday(_ date: Date, tz: TimeZone, short: Bool = false) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = tz
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = short ? "EEEEE" : "EEEE"
    return formatter.string(from: date)
}

func daysNow() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

private struct DaysCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(DaysUI.muted)
    }
}

struct DaysHomeView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var index: DaysIndex
    @Environment(\.dismiss) private var dismiss
    @State private var path: [DaysRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topBar
                    DaysSeasonsSection(index: index, header: AnyView(controls)) { path.append(.day($0)) }
                    settingsRow
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(DaysUI.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(for: DaysRoute.self) { route in
                switch route {
                case let .day(id):
                    DaysDayView(index: index, episodeId: id) { path.append(.scene($0)) }
                case let .scene(id):
                    DaysSceneView(index: index, sceneId: id)
                case .uploads:
                    DaysUploadsView(index: index, drive: driveStatus, queue: daysQueue)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            #if DEBUG
                if let day = UserDefaults.standard.string(forKey: "DaysOpenDay"), path.isEmpty {
                    path = [.day(day)]
                }
                if UserDefaults.standard.bool(forKey: "DaysOpenUploads"), path.isEmpty {
                    path = [.uploads]
                }
                if let id = UserDefaults.standard.string(forKey: "DaysOpenScene"), path.isEmpty {
                    let scene = id == "today" ? index.today.scenes.first?.id : id
                    if let scene {
                        path = [.scene(scene)]
                    }
                }
            #endif
        }
    }

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: "DAYS")
                .font(.system(size: 18, weight: .heavy))
                .tracking(5)
                .foregroundStyle(DaysUI.red)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DaysUI.muted)
                    .frame(width: 36, height: 28, alignment: .trailing)
            }
        }
    }

    private var controls: some View {
        let verdict = index.verdict(index.today)
        return VStack(alignment: .leading, spacing: 12) {
            if index.recordingNow {
                DaysLiveStrip(index: index, isRecording: model.isRecording)
            }
            rollButton
            if !verdict.text.isEmpty {
                Button {
                    path.append(.uploads)
                } label: {
                    Text(verdict.text)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(verdict.color)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var rollButton: some View {
        Button {
            if model.isRecording {
                dismiss()
            } else {
                model.startRecording()
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(DaysUI.red).frame(width: 12, height: 12)
                Text(model.isRecording ? "Back to camera" : "Roll on iPhone")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var settingsRow: some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                model.toggleShowingPanel(type: nil, panel: .settings)
            }
        } label: {
            HStack {
                Text("Settings").font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(DaysUI.muted)
            .frame(height: 52)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle().fill(DaysUI.line).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct DaysThumb: View {
    let id: String?
    let label: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            DaysUI.surface
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(DaysUI.dim.opacity(0.7))
            }
        }
        .clipped()
        .task(id: id) {
            image = nil
            if let id {
                image = await DaysThumbs.shared.image(id)
            }
        }
    }
}

struct DaysScrubThumb: View {
    let angle: DaysAngle
    @State private var fraction: Double?
    @State private var sheetReady = false
    @State private var axisLocked = false

    private func clock(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func open(at fraction: Double?) {
        guard let id = angle.youtube else {
            if let url = angle.driveId.flatMap({ daysDriveFileUrl($0) }) {
                UIApplication.shared.open(url)
            }
            return
        }
        var text = "https://youtu.be/\(id)"
        if let fraction, let sprite = angle.sprite {
            text += "?t=\(sprite.seconds(at: fraction))"
        }
        if let url = URL(string: text) {
            UIApplication.shared.open(url)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack {
                DaysThumb(id: angle.thumbs.last, label: angle.label)
                if let fraction, let sprite = angle.sprite, sheetReady,
                   let frame = DaysSprites.shared.frame(sprite, index: sprite.index(at: fraction))
                {
                    Color.black
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: geometry.size.height)
                        .clipped()
                }
                if let fraction, let sprite = angle.sprite {
                    VStack(spacing: 0) {
                        Spacer()
                        HStack {
                            Text(clock(sprite.seconds(at: fraction)))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule())
                            Spacer()
                        }
                        .padding(8)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle().fill(.white).frame(width: width * fraction)
                        }
                        .frame(height: 2)
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard angle.sprite != nil else {
                            return
                        }
                        if fraction == nil, abs(value.translation.height) > abs(value.translation.width) {
                            return
                        }
                        DaysScrubState.shared.active = true
                        fraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { _ in
                        fraction = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            DaysScrubState.shared.active = false
                        }
                    }
            )
            .gesture(
                SpatialTapGesture().onEnded { value in
                    open(at: angle.sprite == nil ? nil : min(max(value.location.x / width, 0), 1))
                }
            )
        }
        .task(id: angle.sprite?.id) {
            sheetReady = false
            if let sprite = angle.sprite {
                sheetReady = await DaysSprites.shared.sheet(sprite.id) != nil
            }
            #if DEBUG
                let demo = UserDefaults.standard.double(forKey: "DaysScrubDemo")
                if demo > 0, angle.sprite != nil {
                    fraction = demo
                }
            #endif
        }
    }
}

func daysWatchUrl(youtube: String?, drive: String?) -> URL? {
    youtube.flatMap { daysYouTubeUrl($0) } ?? drive.flatMap { daysDriveFileUrl($0) }
}

struct DaysAngleLink<Content: View>: View {
    let youtube: String?
    var drive: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let url = daysWatchUrl(youtube: youtube, drive: drive) {
            Link(destination: url, label: content)
        } else {
            content()
        }
    }
}

struct DaysSceneCard: View {
    let scene: DaysScene
    let tz: TimeZone
    var height: CGFloat = 150
    let open: () -> Void

    var body: some View {
        let ms = scene.durationMs(now: daysNow())
        let present = scene.present
        let main = present.first { !$0.thumbs.isEmpty } ?? present.first
        let others = present.filter { $0.angle != main?.angle }
        let second = others.first { !$0.thumbs.isEmpty } ?? others.first
        let labels = present.map(\.label).joined(separator: " + ")
        return VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let main {
                        DaysScrubThumb(angle: main)
                    } else {
                        DaysThumb(id: nil, label: "Scene")
                    }
                }
                .frame(height: height)
                .frame(maxWidth: .infinity)
                if let second {
                    DaysAngleLink(youtube: second.youtube, drive: second.driveId) {
                        DaysThumb(id: second.thumbs.last, label: second.label)
                            .frame(width: 84, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black, lineWidth: 2))
                            .padding(10)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SCENE \(scene.number)")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(DaysUI.dim)
                    Text(scene.title ?? "Scene \(scene.number)")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text("\(daysClock(scene.startMs, tz: tz)) \u{00B7} \(daysDuration(ms)) \u{00B7} \(labels)")
                        .font(.system(size: 13))
                        .foregroundStyle(DaysUI.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct DaysSceneList: View {
    let scenes: [DaysScene]
    let tz: TimeZone
    let open: (String) -> Void
    @State private var shortExpanded = false

    var body: some View {
        let now = daysNow()
        let full = scenes.filter { !$0.isShort(now: now) }.reversed() as [DaysScene]
        let short = scenes.filter { $0.isShort(now: now) }.reversed() as [DaysScene]
        return VStack(alignment: .leading, spacing: 14) {
            if full.count > 3 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(full) { scene in
                            DaysSceneCard(scene: scene, tz: tz, height: 172) { open(scene.id) }
                                .frame(width: 300)
                        }
                    }
                }
            } else {
                ForEach(full) { scene in
                    DaysSceneCard(scene: scene, tz: tz) { open(scene.id) }
                }
            }
            if !short.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shortExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text("\(short.count) short clip\(short.count == 1 ? "" : "s")")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: shortExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(DaysUI.muted)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        Rectangle().fill(DaysUI.line).frame(height: 1)
                    }
                }
                .buttonStyle(.plain)
                if shortExpanded {
                    ForEach(short) { scene in
                        Button {
                            open(scene.id)
                        } label: {
                            HStack {
                                Text("\(daysClock(scene.startMs, tz: tz)) \u{00B7} \(scene.durationMs(now: now) / 1000) s")
                                    .font(.system(size: 13).monospacedDigit())
                                Spacer()
                                Text(scene.present.map(\.label).joined(separator: " + "))
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(DaysUI.dim)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

@MainActor
final class DaysScrubState {
    static let shared = DaysScrubState()
    var active = false
}

struct DaysBackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(DaysUI.muted)
            .frame(minWidth: 88, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DaysSwipeBack: UIViewControllerRepresentable {
    final class Holder: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }

    func makeUIViewController(context _: Context) -> Holder {
        Holder()
    }

    func updateUIViewController(_: Holder, context _: Context) {}
}

struct DaysDayView: View {
    @ObservedObject var index: DaysIndex
    @State var episodeId: String
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var withFootage: [DaysEpisode] {
        index.seasons.flatMap(\.episodes).filter { !$0.scenes.isEmpty }
    }

    private func move(_ offset: Int) {
        let list = withFootage
        guard let position = list.firstIndex(where: { $0.id == episodeId }) else {
            return
        }
        let target = position + offset
        guard list.indices.contains(target) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            episodeId = list[target].id
        }
    }

    var body: some View {
        let episode = index.episode(episodeId)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DaysBackButton(title: "Season \(episode?.season ?? 1)") {
                    dismiss()
                }
                if let episode {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(daysWeekday(episode.day, tz: index.tz))
                            .font(.system(size: 40, weight: .semibold))
                            .tracking(-1.2)
                        Text("Season \(episode.season) \u{00B7} Episode \(episode.number) \u{00B7} \(daysDuration(episode.durationMs(now: daysNow())))")
                            .font(.system(size: 14))
                            .foregroundStyle(DaysUI.muted)
                    }
                    DaysSceneList(scenes: episode.scenes, tz: index.tz, open: open)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 40)
            .id(episodeId)
        }
        .background(DaysUI.bg.ignoresSafeArea())
        .background(DaysSwipeBack())
        .navigationBarHidden(true)
        .simultaneousGesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                guard value.startLocation.x > 24, !DaysScrubState.shared.active,
                      abs(value.translation.width) > 80,
                      abs(value.translation.width) > abs(value.translation.height) * 1.5
                else {
                    return
                }
                move(value.translation.width > 0 ? 1 : -1)
            }
        )
    }
}

private struct DaysLivePreview: View {
    let label: String
    let live: DaysLiveAngle

    var body: some View {
        DaysAngleLink(youtube: live.youtube) {
            DaysThumb(id: live.thumbs.last, label: label)
                .frame(width: 104, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Circle().fill(Color(red: 1, green: 0.35, blue: 0.37)).frame(width: 5, height: 5)
                        Text(label).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 3)
                    .padding(6)
                }
        }
    }
}

private struct DaysLiveStrip: View {
    @ObservedObject var index: DaysIndex
    let isRecording: Bool

    private var startMs: Int64 {
        [index.macLive?.startMs, index.phone.live?.startMs].compactMap { $0 }.min() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(DaysUI.red).frame(width: 9, height: 9)
                    Text("Recording now \u{00B7} Scene \(max(index.today.scenes.count, 1))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.37))
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(Int(context.date.timeIntervalSince1970 - Double(startMs) / 1000), 0)
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 26, weight: .light))
                        .monospacedDigit()
                }
            }
            if let live = index.macLive {
                row("MacBook", previews: live.angles.map {
                    DaysLivePreview(label: $0.angle == "face" ? "Face" : "Screen", live: $0)
                })
            }
            if isRecording {
                row("iPhone", previews: [DaysLivePreview(
                    label: "iPhone",
                    live: index.phone.live?.angles.first ?? DaysLiveAngle(angle: "phone")
                )])
            }
        }
        .padding(16)
        .background(DaysUI.liveCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private func row(_ name: String, previews: [DaysLivePreview]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(name).font(.system(size: 13)).foregroundStyle(Color(white: 0.7)).frame(width: 64, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(0 ..< previews.count, id: \.self) { previews[$0] }
            }
            Spacer()
        }
    }
}
