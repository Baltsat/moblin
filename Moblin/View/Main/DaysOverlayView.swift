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

    private var timer: String {
        recording.length.split(separator: " ").first.map(String.init) ?? ""
    }

    var body: some View {
        let upload = daysUploadText(drive.text, signedIn: drive.signedIn)
        HStack(spacing: 8) {
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

struct DaysOverlayView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var orientation: Orientation
    @ObservedObject var recording: RecordingProvider
    @ObservedObject var drive: DriveStatus
    let isRecording: Bool

    private var pill: some View {
        DaysPillView(recording: recording, drive: drive, isRecording: isRecording)
    }

    private var gear: some View {
        DaysRoundButton(systemName: "gearshape.fill") {
            model.toggleShowingPanel(type: nil, panel: .settings)
        }
    }

    private var black: some View {
        DaysRoundButton(systemName: "moon.fill") {
            model.toggleStealthMode()
        }
    }

    private var record: some View {
        DaysRecordButton(isRecording: isRecording) {
            model.toggleRecording()
        }
    }

    private var insets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets ?? .zero
    }

    var body: some View {
        content
            .padding(.top, insets.top)
            .padding(.bottom, insets.bottom)
            .padding(.leading, insets.left)
            .padding(.trailing, insets.right)
    }

    @ViewBuilder
    private var content: some View {
        if orientation.isPortrait {
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
