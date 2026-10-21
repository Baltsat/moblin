import AlertToast
import SwiftUI

func daysToastStyle(titleColor: Color = .white, titleFont: Font? = nil) -> AlertToast.AlertStyle {
    .style(backgroundColor: DaysUI.surface,
           titleColor: titleColor,
           subTitleColor: DaysUI.muted,
           titleFont: titleFont ?? .system(size: 15, weight: .semibold),
           subTitleFont: .system(size: 13))
}

private var daysFakeRecording: Bool {
    #if DEBUG
        UserDefaults.standard.bool(forKey: "DaysFakeRecording")
    #else
        false
    #endif
}

@MainActor private func daysUploadText(_ drive: DriveStatus) -> String? {
    if let reason = daysUploadReason(drive: drive) {
        return reason
    }
    let text = drive.text.lowercased()
    if text.contains("queued") {
        if let percent = drive.percent {
            return "\u{2191} \(percent)%"
        }
        return "\u{2191} Uploading"
    }
    return nil
}

private struct DaysGlass: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color.black.opacity(0.5), in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

private extension View {
    func daysGlass() -> some View {
        modifier(DaysGlass())
    }
}

@MainActor private func daysSceneLabel(_ index: DaysIndex, recording: Bool) -> String {
    let today = index.today
    let count = today.scenes.count
    let number = recording ? max(count, 1) : count + 1
    return "S\(today.season):E\(today.number) \u{00B7} Scene \(number)"
}

struct DaysPillView: View {
    @ObservedObject var recording: RecordingProvider
    @ObservedObject var drive: DriveStatus
    @ObservedObject var battery: Battery
    @ObservedObject var status: StatusOther
    @ObservedObject private var index = DaysIndex.shared
    let isRecording: Bool
    let isLive: Bool
    let onReconnect: () -> Void

    private var rec: Bool {
        isRecording || daysFakeRecording
    }

    private var timer: String {
        if daysFakeRecording, !isRecording {
            return "12:33"
        }
        return recording.length.split(separator: " ").first.map(String.init) ?? "0:00"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rec {
                HStack(spacing: 10) {
                    Circle().fill(DaysUI.red).frame(width: 10, height: 10)
                    Text(timer)
                        .font(.system(size: 24, weight: .light))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 42)
                .daysGlass()
                Text(daysSceneLabel(index, recording: true))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .padding(.leading, 14)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(index.verdict(index.today).color).frame(width: 7, height: 7)
                    Text(daysSceneLabel(index, recording: false))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .daysGlass()
                if drive.signedIn, !drive.hasYouTube {
                    Button(action: onReconnect) {
                        Text("Reconnect Google")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DaysUI.amber)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .daysGlass()
                    }
                    .buttonStyle(.plain)
                } else if let text = daysUploadText(drive) {
                    Text(text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.leading, 14)
                }
            }
        }
    }
}

struct DaysStatusPill: View {
    @ObservedObject var drive: DriveStatus
    @ObservedObject var battery: Battery
    @ObservedObject var status: StatusOther
    let isLive: Bool

    private var lowBattery: Bool {
        battery.level >= 0 && battery.level < 0.2 && battery.state != .charging && battery.state != .full
    }

    private var hot: Bool {
        status.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    var body: some View {
        HStack(spacing: 8) {
            if isLive || daysFakeRecording {
                Text("LIVE")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DaysUI.red, in: RoundedRectangle(cornerRadius: 6))
            }
            Text(daysUploadReason(drive: drive).map { "\u{2191} \($0)" } ?? "\u{2191} after Cut")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if lowBattery {
                Image(systemName: "battery.25").foregroundStyle(DaysUI.amber)
                Text("\(Int(battery.level * 100))%").font(.system(size: 12)).monospacedDigit()
            }
            if hot {
                Image(systemName: "thermometer.high")
                    .foregroundStyle(status.thermalState == .critical ? DaysUI.red : DaysUI.amber)
                Text(status.thermalState == .critical ? "Critical" : "Hot").font(.system(size: 12))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .daysGlass()
    }
}

private struct DaysRoundButton: View {
    let systemName: String
    var size: CGFloat = 44
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct DaysTorchButton: View {
    let model: Model
    @ObservedObject var overlay: StreamOverlay

    var body: some View {
        DaysRoundButton(systemName: overlay.isTorchOn ? "bolt.fill" : "bolt.slash.fill",
                        tint: overlay.isTorchOn ? .yellow : .white)
        {
            model.toggleTorch()
        }
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
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .daysGlass()
        }
    }
}

private struct DaysRecordButton: View {
    let isRecording: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.9), lineWidth: 3).frame(width: 76, height: 76)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(DaysUI.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 30)
                    .fill(DaysUI.red)
                    .frame(width: isRecording ? 28 : 60, height: isRecording ? 28 : 60)
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.2), value: isRecording)
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
            Text(isRecording ? "Hold to cut" : "Roll")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? .white : .white.opacity(0.6))
                .frame(width: 36, height: 36)
                .background(active ? Color.white.opacity(0.18) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 0) {
            button(1, "1\u{00D7}")
            button(2, "2\u{00D7}")
        }
        .padding(4)
        .daysGlass()
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

    private var rec: Bool {
        isRecording || daysFakeRecording
    }

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

    private var statusPill: some View {
        DaysStatusPill(drive: drive, battery: model.battery, status: model.statusOther, isLive: model.isLive)
    }

    private var pair: some View {
        HStack(spacing: 10) {
            DaysRoundButton(systemName: "film.stack", size: rec ? 40 : 44) {
                showHome = true
            }
            DaysRoundButton(systemName: "gearshape", size: rec ? 40 : 44) {
                model.toggleShowingPanel(type: nil, panel: .settings)
            }
        }
    }

    private var topRight: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if rec {
                statusPill
            }
            pair
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            DaysRoundButton(systemName: "moon") {
                model.setStealthMode(on: true)
            }
            DaysFlipButton(model: model)
            DaysTorchButton(model: model, overlay: model.streamOverlay)
            DaysZoomIfBack(model: model, overlay: model.streamOverlay)
        }
    }

    private var record: some View {
        DaysRecordButton(isRecording: rec,
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
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    pill
                    Spacer()
                    topRight
                }
                Spacer()
                DaysLockBadge(camera: model.camera)
                    .padding(.bottom, 10)
                controls
                    .padding(.bottom, 22)
                record
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 10)
        } else {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    pill
                    Spacer()
                    HStack {
                        controls
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    topRight
                    Spacer()
                    DaysLockBadge(camera: model.camera)
                    record
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
                    HStack(alignment: .top) {
                        DaysPillView(recording: recording,
                                     drive: drive,
                                     battery: model.battery,
                                     status: model.statusOther,
                                     isRecording: true,
                                     isLive: model.isLive) {}
                        Spacer()
                        DaysStatusPill(drive: drive,
                                       battery: model.battery,
                                       status: model.statusOther,
                                       isLive: model.isLive)
                    }
                    .opacity(0.9)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
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
