import SwiftUI

private func daysUploadText(_ status: String, signedIn: Bool, percent: Int?) -> String? {
    let text = status.lowercased()
    if text.isEmpty {
        return signedIn ? "Synced" : nil
    } else if text.contains("sign in") {
        return "Sign in to Drive"
    } else if text.contains("waiting for network") {
        return "Waiting for Wi-Fi"
    } else if text.contains("queued") {
        if let percent {
            return "\u{2191} \(percent)%"
        }
        let size = status.replacingOccurrences(of: "Google Drive: ", with: "")
            .replacingOccurrences(of: "recording, ", with: "")
            .replacingOccurrences(of: " queued", with: "")
        return "\u{2191} \(size) queued"
    } else if text.contains("uploaded") {
        return "Synced"
    } else if text.contains("failed") || text.contains("lost") {
        return "Upload issue"
    }
    return status
}

struct DaysPillView: View {
    @ObservedObject var recording: RecordingProvider
    @ObservedObject var drive: DriveStatus
    @ObservedObject var battery: Battery
    @ObservedObject var status: StatusOther
    let isRecording: Bool
    let isLive: Bool
    let onReconnect: () -> Void

    private var timer: String {
        recording.length.split(separator: " ").first.map(String.init) ?? ""
    }

    var body: some View {
        if drive.signedIn, !drive.hasYouTube {
            Button(action: onReconnect) {
                Label("Tap to reconnect Google", systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
            }
            .buttonStyle(.plain)
        } else {
            statusPill
        }
    }

    private var problem: Bool {
        let low = battery.level >= 0 && battery.level < 0.2 && battery.state != .charging && battery.state != .full
        return low || status.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    var statusPill: some View {
        let upload = daysUploadText(drive.text, signedIn: drive.signedIn, percent: drive.percent)
        return HStack(spacing: 8) {
            if isRecording {
                Circle().fill(DaysUI.red).frame(width: 10, height: 10)
                Text(timer)
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                if isLive {
                    Text("LIVE")
                        .font(.system(size: 11, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DaysUI.red, in: RoundedRectangle(cornerRadius: 6))
                }
                Text(verbatim: "\u{00B7}").foregroundStyle(.secondary)
                Text("\u{2191} after Cut")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            } else if let upload {
                Text(upload).font(.subheadline)
            } else {
                Text("Ready").font(.subheadline)
            }
            if problem {
                if battery.level < 0.2, battery.state != .charging {
                    Image(systemName: "battery.25").foregroundStyle(.orange)
                    Text("\(Int(battery.level * 100))%").font(.caption).monospacedDigit()
                }
                if status.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    Image(systemName: "thermometer.high")
                        .foregroundStyle(status.thermalState == .critical ? .red : .orange)
                    Text(status.thermalState == .critical ? "Critical" : "Hot")
                        .font(.caption)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.black.opacity(0.6), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

private struct DaysRoundButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct DaysTorchButton: View {
    let model: Model
    @ObservedObject var overlay: StreamOverlay

    var body: some View {
        Button {
            model.toggleTorch()
        } label: {
            Image(systemName: overlay.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(overlay.isTorchOn ? .yellow : .white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct DaysFlipButton: View {
    let model: Model

    var body: some View {
        DaysRoundButton(systemName: "arrow.triangle.2.circlepath.camera") {
            model.daysFlipCamera()
        }
    }
}

private struct DaysZoomIfBack: View {
    let model: Model
    @ObservedObject var overlay: StreamOverlay

    var body: some View {
        if !overlay.isFrontCameraSelected {
            DaysZoomPillView(model: model, zoom: model.zoom)
        }
    }
}

private struct DaysLockBadge: View {
    @ObservedObject var camera: CameraState

    var body: some View {
        if camera.aeAfLocked {
            Label("AE/AF LOCK", systemImage: "lock.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
        }
    }
}

private struct DaysRecordButton: View {
    let isRecording: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 76, height: 76)
            RoundedRectangle(cornerRadius: isRecording ? 8 : 30)
                .fill(.red)
                .frame(width: isRecording ? 32 : 60, height: isRecording ? 32 : 60)
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .overlay(alignment: .bottom) {
            if isRecording {
                Text("Hold to cut")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .offset(y: 16)
            }
        }
        .onTapGesture {
            if !isRecording {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onStart()
            }
        }
        .onLongPressGesture(minimumDuration: 1.5, maximumDistance: 60) {
            if isRecording {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                progress = 0
                onStop()
            }
        } onPressingChanged: { pressing in
            if pressing, isRecording {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.linear(duration: 1.5)) {
                    progress = 1
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    progress = 0
                }
            }
        }
    }
}

private struct DaysZoomPillView: View {
    let model: Model
    @ObservedObject var zoom: Zoom

    private func button(_ x: Float, _ label: String) -> some View {
        let active = abs(zoom.x - x) < 0.25
        return Button {
            model.setZoomX(x: x)
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? .yellow : .white)
                .frame(width: 36, height: 36)
                .background(active ? Color.black.opacity(0.5) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 2) {
            button(1, "1\u{00D7}")
            button(2, "2\u{00D7}")
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

struct DaysBlackView: View {
    let model: Model
    @State private var hint = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if hint {
                Text("Double-tap to wake")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.setStealthMode(on: false)
        }
        .onAppear {
            model.disableScreenPreview()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                hint = false
            }
        }
        .onDisappear {
            model.maybeEnableScreenPreview()
        }
    }
}

@MainActor private var daysAutoStartDone = false
@MainActor private var daysHomeShownAtLaunch = false

struct DaysOverlayView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var orientation: Orientation
    @ObservedObject var recording: RecordingProvider
    @ObservedObject var drive: DriveStatus
    let isRecording: Bool
    @ObservedObject private var daysIndex = DaysIndex.shared
    @State private var showHome = false

    private var pill: some View {
        DaysPillView(recording: recording,
                     drive: drive,
                     battery: model.battery,
                     status: model.statusOther,
                     isRecording: isRecording,
                     isLive: model.isLive) {
            model.driveSignIn()
        }
    }

    private var home: some View {
        DaysRoundButton(systemName: "film.stack") {
            showHome = true
        }
    }

    private var sceneLabel: String {
        let today = daysIndex.today
        return "S\(today.season):E\(today.number) \u{00B7} Scene \(max(today.scenes.count, 1))"
    }

    private var gear: some View {
        DaysRoundButton(systemName: "gearshape.fill") {
            model.toggleShowingPanel(type: nil, panel: .settings)
        }
    }

    private var black: some View {
        DaysRoundButton(systemName: "moon.fill") {
            model.setStealthMode(on: true)
        }
    }

    private var torch: some View {
        DaysTorchButton(model: model, overlay: model.streamOverlay)
    }

    private var record: some View {
        DaysRecordButton(isRecording: isRecording,
                         onStart: { model.startRecording() },
                         onStop: { model.stopRecording() })
    }

    var body: some View {
        GeometryReader { geometry in
            content(portrait: geometry.size.height >= geometry.size.width)
        }
        .fullScreenCover(isPresented: $showHome) {
            DaysHomeView(index: daysIndex).environmentObject(model)
        }
        .onAppear {
            daysIndex.attach(model: model)
            #if DEBUG
                if UserDefaults.standard.bool(forKey: "DaysOpenHome") {
                    showHome = true
                }
            #endif
            model.completePendingYouTube()
            guard UserDefaults.standard.bool(forKey: DaysPrefs.autoStart), !daysAutoStartDone else {
                if !daysHomeShownAtLaunch, !isRecording {
                    daysHomeShownAtLaunch = true
                    showHome = true
                }
                return
            }
            daysAutoStartDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if !model.isRecording {
                    model.startRecording()
                }
            }
        }
    }

    @ViewBuilder
    private func content(portrait: Bool) -> some View {
        if portrait {
            ZStack {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            pill
                            if isRecording {
                                Text(sceneLabel)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                                    .padding(.leading, 12)
                            }
                        }
                        Spacer()
                        home
                        gear
                    }
                    Spacer()
                    DaysLockBadge(camera: model.camera)
                    DaysZoomIfBack(model: model, overlay: model.streamOverlay)
                        .padding(.bottom, 14)
                    ZStack {
                        record
                        HStack {
                            black
                            Spacer()
                            DaysFlipButton(model: model)
                            torch
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        } else {
            HStack {
                VStack {
                    pill
                    Spacer()
                }
                Spacer()
                VStack {
                    home
                    gear
                    Spacer()
                    DaysLockBadge(camera: model.camera)
                    DaysZoomIfBack(model: model, overlay: model.streamOverlay)
                    record
                    Spacer()
                    torch
                    DaysFlipButton(model: model)
                    black
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

@MainActor
final class DaysDim: ObservableObject {
    @Published var dimmed = false
    private var lastTouch = Date()
    private var savedBrightness: CGFloat?

    func touch() {
        lastTouch = Date()
    }

    func tick(active: Bool) {
        if !active {
            if dimmed {
                wake()
            }
        } else if !dimmed, DaysPrefs.dimSeconds > 0,
                  Date().timeIntervalSince(lastTouch) > Double(DaysPrefs.dimSeconds)
        {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.02
            dimmed = true
        }
    }

    func wake() {
        if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
        }
        savedBrightness = nil
        dimmed = false
        lastTouch = Date()
    }
}

@MainActor
let daysDim = DaysDim()

private final class DaysTouchObserver: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        MainActor.assumeIsolated { daysDim.touch() }
        state = .failed
    }
}

private final class DaysTouchDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool
    {
        true
    }
}

@MainActor private let daysTouchDelegate = DaysTouchDelegate()

@MainActor
func daysInstallTouchObserver() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        for window in scene.windows
            where !(window.gestureRecognizers ?? []).contains(where: { $0 is DaysTouchObserver })
        {
            let observer = DaysTouchObserver(target: nil, action: nil)
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            observer.delegate = daysTouchDelegate
            window.addGestureRecognizer(observer)
        }
    }
}

struct DaysDimView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var dim: DaysDim
    @ObservedObject var recording: RecordingProvider
    @ObservedObject var drive: DriveStatus

    var body: some View {
        ZStack {
            if dim.dimmed {
                Color.black.opacity(0.8)
                    .ignoresSafeArea()
                VStack {
                    DaysPillView(recording: recording,
                                 drive: drive,
                                 battery: model.battery,
                                 status: model.statusOther,
                                 isRecording: true,
                                 isLive: model.isLive) {}
                        .opacity(0.9)
                    Spacer()
                }
                .padding(.top, 12)
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        dim.wake()
                    }
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in
                        dim.wake()
                    })
            }
        }
        .onChange(of: dim.dimmed) { dimmed in
            if dimmed {
                model.disableScreenPreview()
            } else if model.statusOther.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue {
                model.maybeEnableScreenPreview()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            dim.tick(active: model.isRecording && model.showingPanel == .none && !model.showStealthMode)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            dim.wake()
        }
    }
}
