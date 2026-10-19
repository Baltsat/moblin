import SwiftUI

private func daysUploadText(_ status: String, signedIn: Bool) -> String? {
    let text = status.lowercased()
    if text.isEmpty {
        return signedIn ? "Synced" : nil
    } else if text.contains("sign in") {
        return "Sign in to Drive"
    } else if text.contains("waiting for network") {
        return "Waiting for Wi-Fi"
    } else if text.contains("queued") {
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

    var statusPill: some View {
        let upload = daysUploadText(drive.text, signedIn: drive.signedIn)
        return HStack(spacing: 8) {
            if isRecording {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(timer)
                    .font(.system(.subheadline, design: .default).monospacedDigit().weight(.semibold))
            }
            if isRecording, upload != nil {
                Text(verbatim: "\u{00B7}").foregroundStyle(.secondary)
            }
            if let upload {
                Text(upload).font(.subheadline)
            } else if !isRecording {
                Text("Ready").font(.subheadline)
            }
            if isLive {
                Text("LIVE").font(.caption.weight(.bold)).foregroundStyle(.red)
            }
            if isRecording {
                Image(systemName: battery.state == .charging ? "battery.100.bolt" : "battery.50")
                    .font(.subheadline)
                Text("\(Int(battery.level * 100))%").font(.caption).monospacedDigit()
                if status.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    Image(systemName: "thermometer.high").foregroundStyle(.orange)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
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
                Text("Hold to stop")
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

struct DaysOverlayView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var orientation: Orientation
    @ObservedObject var recording: RecordingProvider
    @ObservedObject var drive: DriveStatus
    let isRecording: Bool

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

    private var record: some View {
        DaysRecordButton(isRecording: isRecording,
                         onStart: { model.startRecording() },
                         onStop: { model.stopRecording() })
    }

    var body: some View {
        GeometryReader { geometry in
            content(portrait: geometry.size.height >= geometry.size.width)
        }
        .onAppear {
            model.completePendingYouTube()
            guard UserDefaults.standard.bool(forKey: "daysAutoStartRecording"), !daysAutoStartDone else {
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
                    ZStack {
                        pill
                        HStack {
                            Spacer()
                            gear
                        }
                    }
                    Spacer()
                    DaysZoomPillView(model: model, zoom: model.zoom)
                        .padding(.bottom, 14)
                    ZStack {
                        record
                        HStack {
                            black
                            Spacer()
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
                    gear
                    Spacer()
                    DaysZoomPillView(model: model, zoom: model.zoom)
                    record
                    Spacer()
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
        } else if !dimmed, Date().timeIntervalSince(lastTouch) > 15 {
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            dim.tick(active: model.isRecording && model.showingPanel == .none && !model.showStealthMode)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            dim.wake()
        }
    }
}
