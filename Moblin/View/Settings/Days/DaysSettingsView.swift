import AVFoundation
import SwiftUI

private let daysResolutions: [SettingsStreamResolution] = [.r3840x2160, .r2560x1440, .r1920x1080, .r1280x720]
private let daysFpss = [60, 30, 25]
private let daysDimOptions: [Int] = [0, 10, 15, 30, 60, 120]

private func daysDimLabel(_ seconds: Int) -> String {
    seconds == 0 ? String(localized: "Never") : seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
}

private struct DaysAccountsSection: View {
    @ObservedObject var drive: DriveStatus
    @ObservedObject var github: GitHubStatus
    let model: Model

    private func check(_ ok: Bool, _ title: LocalizedStringKey) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
        .font(.subheadline)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(drive.signedIn ? (drive.email.isEmpty ? "Signed in" : drive.email) : "Google",
                      systemImage: "person.crop.circle")
                if drive.signedIn {
                    check(driveAuth.hasScope(driveScopes[0]), "Drive")
                    check(drive.hasYouTube, "YouTube")
                }
            }
            if drive.signedIn {
                Button("Reconnect Google") {
                    model.driveSignIn()
                }
                Button("Sign out of Google", role: .destructive) {
                    model.driveSignOut()
                }
            } else {
                Button("Sign in to Google") {
                    model.driveSignIn()
                }
            }
        } header: {
            Text("Google")
        }
        .task(id: drive.signedIn) {
            await drive.refreshEmail()
        }
        Section {
            if github.signedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Label(github.login.isEmpty ? "Connected" : github.login, systemImage: "person.crop.circle")
                    check(true, "Signed in")
                    check(github.repoOk, "balkonsta/days-archive")
                }
                Button("Disconnect GitHub", role: .destructive) {
                    githubDisconnect()
                }
            } else if let code = github.userCode {
                VStack(spacing: 12) {
                    Text("Enter this code on GitHub")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = code
                        if let url = URL(string: github.verificationUri) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open github.com/login/device", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    ProgressView()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                Button("Cancel", role: .cancel) {
                    githubCancelConnect()
                }
            } else {
                Button {
                    githubConnect()
                } label: {
                    Label("Connect GitHub", systemImage: "link")
                }
            }
            if !github.text.isEmpty {
                Text(github.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("GitHub")
        } footer: {
            Text("Authorize as balkonsta. Recordings are archived to a private repository.")
        }
        .task(id: github.signedIn) {
            await githubRefreshLogin()
        }
    }
}

private struct DaysStatusSection: View {
    let model: Model
    @ObservedObject var net: DaysNetStatus
    @ObservedObject var github: GitHubStatus
    @ObservedObject var drive: DriveStatus
    @ObservedObject var overlay: StreamOverlay

    private var networkIcon: String {
        switch net.kind {
        case .wifi:
            "wifi"
        case .cellular:
            "antenna.radiowaves.left.and.right"
        case .offline:
            "wifi.slash"
        }
    }

    private var liveText: LocalizedStringKey {
        if model.isLive {
            "Live"
        } else if model.isRecording, DaysPrefs.bool(DaysPrefs.youTubeEnabled, true) {
            "Waiting"
        } else {
            "Off"
        }
    }

    var body: some View {
        Section("Status") {
            LabeledContent {
                Text(net.queueCount == 0 ? "Empty" : "\(net.queueCount) · \(UInt64(net.queueBytes).formatBytes())")
            } label: {
                Label("Upload queue", systemImage: "arrow.up.circle")
            }
            if github.signedIn {
                LabeledContent {
                    Text(net.githubPending == 0 ? "Empty" : "\(net.githubPending)")
                } label: {
                    Label("GitHub queue", systemImage: "archivebox")
                }
            }
            LabeledContent {
                if let date = net.lastSync {
                    Text(date, style: .relative) + Text(" ago")
                } else {
                    Text("Never")
                }
            } label: {
                Label("Last sync", systemImage: "clock.arrow.circlepath")
            }
            LabeledContent {
                Text(LocalizedStringKey(net.kind.rawValue))
            } label: {
                Label("Network", systemImage: networkIcon)
            }
            LabeledContent {
                Text(liveText)
            } label: {
                Label("YouTube live", systemImage: "dot.radiowaves.left.and.right")
            }
            LabeledContent {
                let free = (try? URL(fileURLWithPath: NSHomeDirectory())
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage) ?? 0
                Text(UInt64(max(free, 0)).formatBytes())
            } label: {
                Label("Free storage", systemImage: "internaldrive")
            }
            LabeledContent {
                let level = model.battery.level
                Text((level >= 0 ? "\(Int(level * 100))%" : "–")
                    + (model.battery.state == .charging || model.battery.state == .full ? ", charging" : ""))
            } label: {
                Label("Battery", systemImage: "battery.100")
            }
            LabeledContent {
                Text(model.statusOther.thermalState.string())
            } label: {
                Label("Temperature", systemImage: "thermometer.medium")
            }
            if !drive.text.isEmpty {
                Text(drive.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DaysRecordingSection: View {
    let model: Model
    @ObservedObject var database: Database
    @ObservedObject var stream: SettingsStream
    @ObservedObject var recording: SettingsStreamRecording
    @State private var preset = DaysPreset.current
    @AppStorage(DaysPrefs.torchDefault) private var torchDefault = false
    @AppStorage(DaysPrefs.dimDelay) private var dimDelay = 15
    @AppStorage(DaysPrefs.autoStart) private var autoStart = false

    private var locked: Bool {
        model.isLive || model.isRecording
    }

    var body: some View {
        Section {
            Picker(selection: Binding(get: { preset }, set: {
                preset = $0
                model.choosePreset($0)
            })) {
                ForEach(DaysPreset.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            } label: {
                Label("Quality", systemImage: "sparkles.tv")
            }
            Picker(selection: $stream.resolution) {
                ForEach(daysResolutions, id: \.self) {
                    Text($0.shortString())
                }
            } label: {
                Label("Resolution", systemImage: "rectangle.on.rectangle")
            }
            .onChange(of: stream.resolution) { _ in
                model.reloadStreamIfEnabled(stream: stream)
            }
            .disabled(locked)
            Picker(selection: $stream.fps) {
                ForEach(daysFpss, id: \.self) {
                    Text("\($0) fps")
                }
            } label: {
                Label("Frame rate", systemImage: "speedometer")
            }
            .onChange(of: stream.fps) { _ in
                model.reloadStreamIfEnabled(stream: stream)
            }
            .disabled(locked)
            Picker(selection: Binding(get: { database.videoStabilizationMode }, set: {
                database.videoStabilizationMode = $0
                model.attachCamera()
            })) {
                ForEach(videoStabilizationModes, id: \.self) {
                    Text($0.toString())
                }
            } label: {
                Label("Stabilization", systemImage: "camera.metering.matrix")
            }
            .disabled(locked)
            NavigationLink {
                QuickButtonMicView(model: model, mics: database.mics, modelMic: model.mic)
            } label: {
                Label("Microphone", systemImage: "mic")
            }
            Toggle(isOn: $torchDefault) {
                Label("Torch on when recording starts", systemImage: "bolt.fill")
            }
            Picker(selection: $dimDelay) {
                ForEach(daysDimOptions, id: \.self) {
                    Text(daysDimLabel($0)).tag($0)
                }
            } label: {
                Label("Auto-dim", systemImage: "moon")
            }
            Toggle(isOn: $autoStart) {
                Label("Start recording on launch", systemImage: "record.circle")
            }
        } header: {
            Text("Recording")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(effectiveLine)
                if preset == .max {
                    Text("Short scenes. Runs hot. ~13 GB/hour.")
                }
            }
        }
    }

    private var effectiveLine: String {
        let codec = recording.videoCodec == .h264avc ? "H.264" : "HEVC"
        let mbps = Double(recording.videoBitrate) / 1_000_000
        let gb = (Double(recording.videoBitrate) + Double(recording.audioBitrate)) / 8 * 3600 / 1e9
        return String(format: "%@ · %@ %.0f Mbps · ~%.1f GB/hour",
                      "\(stream.resolution.shortString())\(stream.fps)", codec, mbps, gb)
    }
}

private struct DaysUploadSection: View {
    let model: Model
    @ObservedObject var recording: SettingsStreamRecording
    @ObservedObject var github: GitHubStatus
    @AppStorage(DaysPrefs.wifiOnly) private var wifiOnly = true
    @AppStorage(DaysPrefs.youTubeEnabled) private var youTube = true
    @AppStorage(DaysPrefs.youTubeCellular) private var youTubeCellular = false
    @AppStorage(DaysPrefs.githubArchive) private var githubArchiveOn = true

    var body: some View {
        Section {
            Toggle(isOn: $recording.uploadToDrive) {
                Label("Upload to Google Drive", systemImage: "externaldrive")
            }
            Toggle(isOn: $wifiOnly) {
                Label("Upload on Wi-Fi only", systemImage: "wifi")
            }
            .onChange(of: wifiOnly) { _ in
                driveUploader.resume()
                githubArchive.resume()
            }
            Toggle(isOn: $youTube) {
                Label("Stream to YouTube", systemImage: "play.rectangle")
            }
            Toggle(isOn: $youTubeCellular) {
                Label("YouTube over cellular", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(!youTube)
            Toggle(isOn: $githubArchiveOn) {
                Label("GitHub archive", systemImage: "archivebox")
            }
            .onChange(of: githubArchiveOn) { _ in
                githubArchive.resume()
            }
        } header: {
            Text("Upload")
        } footer: {
            Text("""
            Recordings upload to Drive first. The local file is deleted once Drive and, when connected, \
            the GitHub archive have both finished.

            Charger tips: Low Power Mode is fine. Use a wired charger, not MagSafe or wireless; it heats. \
            Take the case off. Keep the phone out of the sun.
            """)
        }
    }
}

private func daysMb(_ bytes: Int64) -> String {
    String(format: "%.0f", Double(bytes) / 1_048_576)
}

private struct DaysLinkRow: View {
    let title: LocalizedStringKey
    let icon: String
    let detail: String
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                row
            }
        } else {
            row.foregroundStyle(.secondary)
        }
    }

    private var row: some View {
        LabeledContent {
            Text(detail)
                .font(.footnote)
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

private func daysDriveDetail(_ item: DaysQueueItem) -> String {
    if item.driveDone {
        return "\(daysMb(item.driveTotal)) MB"
    }
    return "\(daysMb(item.driveAcked)) / \(daysMb(item.driveTotal)) MB"
}

private func daysGitHubDetail(_ item: DaysQueueItem) -> String {
    if item.githubFinished {
        return "\(item.githubTotal) / \(item.githubTotal) parts"
    }
    return item.githubTotal == 0 ? "queued" : "\(item.githubDone) / \(item.githubTotal) parts"
}

private struct DaysNowRecordingSection: View {
    let model: Model
    @ObservedObject var queue: DaysQueue

    var body: some View {
        if model.isRecording {
            let item = queue.items.first
            let youTube = model.youTubeLiveState()
            Section("Now recording") {
                if let youTube {
                    DaysLinkRow(title: "YouTube",
                                icon: "play.rectangle",
                                detail: youTube.state,
                                url: youTube.id.flatMap { daysYouTubeUrl($0) })
                }
                if let item {
                    let fileUrl = item.driveFileId.flatMap { daysDriveFileUrl($0) }
                        ?? queue.phoneFolderId.flatMap { daysDriveFolderUrl($0) }
                    DaysLinkRow(title: "Google Drive",
                                icon: "externaldrive",
                                detail: daysDriveDetail(item),
                                url: fileUrl)
                    if item.githubQueued {
                        DaysLinkRow(title: "GitHub",
                                    icon: "archivebox",
                                    detail: daysGitHubDetail(item),
                                    url: item.githubReady ? daysGitHubReleaseUrl(item.name) : nil)
                    }
                }
            }
        }
    }
}

private struct DaysQueueSection: View {
    @ObservedObject var queue: DaysQueue

    private func timeText(_ item: DaysQueueItem) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(item.startMs) / 1000))
    }

    var body: some View {
        Section("Queue") {
            ForEach(queue.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(timeText(item))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: item.finished ? "checkmark.circle.fill" : "arrow.up.circle")
                            .foregroundStyle(item.finished ? .green : .secondary)
                    }
                    DaysLinkRow(title: "Drive",
                                icon: "externaldrive",
                                detail: daysDriveDetail(item),
                                url: item.driveFileId.flatMap { daysDriveFileUrl($0) }
                                    ?? queue.phoneFolderId.flatMap { daysDriveFolderUrl($0) })
                    if item.githubQueued {
                        DaysLinkRow(title: "GitHub",
                                    icon: "archivebox",
                                    detail: daysGitHubDetail(item),
                                    url: item.githubReady ? daysGitHubReleaseUrl(item.name) : nil)
                    }
                    if let id = item.youTubeId {
                        DaysLinkRow(title: "YouTube",
                                    icon: "play.rectangle",
                                    detail: id,
                                    url: daysYouTubeUrl(id))
                    }
                }
                .padding(.vertical, 2)
            }
            if queue.items.isEmpty {
                Text("Nothing in the queue")
                    .foregroundStyle(.secondary)
            }
            Button {
                daysOpenDriveFolder()
            } label: {
                Label("Open Days folder in Drive", systemImage: "folder")
            }
            Button {
                daysOpenPlaylist()
            } label: {
                Label("Open YouTube playlist", systemImage: "list.and.film")
            }
            Link(destination: daysGitHubArchiveUrl) {
                Label("Open GitHub archive", systemImage: "archivebox")
            }
        }
    }
}

private struct DaysEffectiveSection: View {
    @ObservedObject var stream: SettingsStream
    @ObservedObject var database: Database

    var body: some View {
        let info = DaysCaptureInfo.shared.summary
        Section {
            LabeledContent("Camera format", value: info.format)
            LabeledContent("Stabilization", value: info.stabilization)
            LabeledContent("Video") {
                Text("\(stream.codec == .h264avc ? "H.264" : "HEVC") \(stream.bitrate / 1_000_000) Mbps, "
                    + "\(stream.maxKeyFrameInterval) s keyframes")
            }
            LabeledContent("Audio") {
                Text("AAC \(stream.audioBitrate / 1000) kbps, "
                    + "\(Int(AVAudioSession.sharedInstance().sampleRate / 1000)) kHz"
                    + (database.audio.preferStereoMic ? ", stereo" : ""))
            }
        } header: {
            Text("Effective capture")
        } footer: {
            if info.fellBack {
                Text("The camera has no matching format; the default format is used.")
            }
        }
    }
}

struct DaysSettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var database: Database

    var body: some View {
        Form {
            if model.isRecording {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    DaysNowRecordingSection(model: model, queue: daysQueue)
                }
            }
            DaysQueueSection(queue: daysQueue)
            DaysAccountsSection(drive: driveStatus, github: githubStatus, model: model)
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                DaysStatusSection(model: model,
                                  net: daysNetStatus,
                                  github: githubStatus,
                                  drive: driveStatus,
                                  overlay: model.streamOverlay)
            }
            DaysRecordingSection(model: model, database: database, stream: model.stream,
                                 recording: model.stream.recording)
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                DaysEffectiveSection(stream: model.stream, database: database)
            }
            DaysUploadSection(model: model, recording: model.stream.recording, github: githubStatus)
            Section {
                NavigationLink {
                    RecordingsSettingsView(model: model)
                } label: {
                    Label("Recordings on this phone", systemImage: "film.stack")
                }
                NavigationLink {
                    SettingsView(database: database)
                } label: {
                    Label("Advanced", systemImage: "gearshape.2")
                }
            }
        }
        .navigationTitle("Days")
    }
}
