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

private struct DaysPillView: View {
    @ObservedObject var recording: RecordingProvider
    @ObservedObject var drive: DriveStatus
    let isRecording: Bool
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

    private var statusPill: some View {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 30)
                    .fill(.red)
                    .frame(width: isRecording ? 32 : 60, height: isRecording ? 32 : 60)
            }
            .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
        .buttonStyle(.plain)
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

struct DaysOverlayView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var orientation: Orientation
    @ObservedObject var recording: RecordingProvider
    @ObservedObject var drive: DriveStatus
    let isRecording: Bool

    private var pill: some View {
        DaysPillView(recording: recording, drive: drive, isRecording: isRecording) {
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
        DaysRecordButton(isRecording: isRecording) {
            model.toggleRecording()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            content(portrait: geometry.size.height >= geometry.size.width)
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
