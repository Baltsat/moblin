import AVFoundation
import Foundation
import SwiftUI

private let daysQuickButtons: Set<SettingsQuickButtonType> = [
    .record, .mute, .torch, .blackScreen, .lockScreen, .live,
]

extension Model {
    func applyDaysDefaults() {
        database.portrait = false
        database.mirrorFrontCameraOnStream = false
        database.showAllSettings = false
        database.tapToFocus = true
        for button in database.quickButtons {
            button.enabled = daysQuickButtons.contains(button.type)
        }
        for stream in database.streams {
            stream.recording.uploadToDrive = true
            stream.recording.autoStartRecording = false
            stream.recording.autoStopRecording = false
        }
        let lowLightKey = "daysLowLightBoost1"
        if !UserDefaults.standard.bool(forKey: lowLightKey) {
            for stream in database.streams {
                stream.lowLightBoost = true
            }
            UserDefaults.standard.set(true, forKey: lowLightKey)
        }
        DaysBackgroundUploader.shared.start()
        if !UserDefaults.standard.bool(forKey: "daysWidestLens1"), !widestBackCameraId.isEmpty {
            for scene in database.scenes where scene.videoSource.cameraPosition == .back {
                scene.videoSource.backCameraId = widestBackCameraId
            }
            UserDefaults.standard.set(true, forKey: "daysWidestLens1")
        }
        applyDaysCaptureMigration()
        applyDaysBitrateMigration()
        applyDaysFocusMigration()
        daysObserveSubjectArea()
        daysPickStereoMic()
        applyDaysPendingPreset()
        daysAutoPreset()
    }

    func applyDaysPendingPreset() {
        guard DaysPreset.pending else {
            return
        }
        DaysPreset.pending = false
        DaysQuality.shared.applied = nil
        daysAutoPreset()
    }

    func daysApplyPreset(_ preset: DaysPreset, reload: Bool = true) {
        let values = preset.values
        for stream in database.streams {
            stream.resolution = values.resolution
            stream.fps = values.fps
            stream.codec = .h264avc
            stream.bitrate = values.streamBitrate
            stream.rtmp.adaptiveBitrateEnabled = true
            stream.maxKeyFrameInterval = 2
            stream.audioCodec = .aac
            stream.audioBitrate = 192_000
            stream.recording.overrideStream = false
            stream.recording.videoCodec = values.recordingCodec
            stream.recording.videoBitrate = values.recordingBitrate
            stream.recording.maxKeyFrameInterval = 2
            stream.recording.audioBitrate = 256_000
        }
        database.videoStabilizationMode = .standard
        database.audio.preferStereoMic = true
        storeSettings()
        if reload, !isRecording, !isLive {
            reloadStreamIfEnabled(stream: stream)
            attachCamera()
        }
    }

    func daysPickStereoMic() {
        let want: SettingsMic = getSelectedScene()?.videoSource.cameraPosition == .front ? .front : .back
        guard let target = database.mics.mics.first(where: {
            $0.isAudioSession() && $0.builtInOrientation == want
        }) else {
            return
        }
        if database.mics.defaultMic != target.id {
            database.mics.defaultMic = target.id
        }
        if mic.current != noMic, mic.current != target, mic.current.builtInOrientation != nil {
            manualSelectMicById(id: target.id)
        }
    }

    func choosePreset(_ preset: DaysPreset) {
        DaysPreset.set(preset)
        if isRecording || isLive {
            DaysPreset.pending = true
        } else {
            DaysQuality.shared.applied = nil
            daysAutoPreset()
        }
    }

    func cycleQuality() {
        choosePreset(DaysPreset.current.next)
    }

    func daysFlipCamera() {
        guard let scene = getSelectedScene() else {
            return
        }
        if scene.videoSource.cameraPosition == .front {
            scene.videoSource.cameraPosition = .back
        } else {
            scene.videoSource.cameraPosition = .front
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sceneUpdated(attachCamera: true, updateRemoteScene: false)
        daysPickStereoMic()
        storeSettings()
    }

    /// user-req: one button, best quality the hardware can hold without dropped frames. Auto decides before each take,
    /// never mid-take: 4K30 HEVC while cool, 1080p60 when warm, 1080p30 when hot or short on space.
    func daysAutoPreset() {
        guard !isRecording else {
            return
        }
        let chosen = DaysPreset.current
        var target = chosen
        if chosen == .auto {
            let heat = statusOther.thermalState
            let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
            if heat.rawValue >= ProcessInfo.ThermalState.serious.rawValue || free < 60_000_000_000 {
                target = .allDay
            } else if heat == .fair || free < 120_000_000_000 {
                target = .smooth
            } else {
                target = .max
            }
        }
        guard DaysQuality.shared.applied != target else {
            return
        }
        DaysQuality.shared.applied = target
        daysLog("quality \(chosen.rawValue) -> \(target.short)")
        daysApplyPreset(target)
    }

    func daysThermalChanged() {
        let state = statusOther.thermalState
        let hot = state.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if hot, !daysThermalReduced {
            daysThermalReduced = true
            media.setVideoStreamBitrate(bitrate: UInt32(Double(stream.bitrate) * 0.7))
        } else if !hot, daysThermalReduced {
            daysThermalReduced = false
            media.setVideoStreamBitrate(bitrate: stream.bitrate)
        }
        if daysDim.dimmed {
            disableScreenPreview()
        } else {
            maybeEnableScreenPreview()
        }
        youTubeThermalChanged(state)
        daysAutoPreset()
    }
}

@MainActor private var daysThermalReduced = false

@MainActor
final class DaysQuality: ObservableObject {
    static let shared = DaysQuality()
    @Published var chosen = DaysPreset.current
    @Published var applied: DaysPreset?

    var label: String {
        guard let applied else {
            return chosen.short
        }
        return chosen == .auto ? "Auto · \(applied.short)" : applied.short
    }
}

enum DaysPreset: String, CaseIterable {
    case auto, allDay, smooth, max

    struct Values {
        let resolution: SettingsStreamResolution
        let fps: Int
        let streamBitrate: UInt32
        let recordingCodec: SettingsStreamCodec
        let recordingBitrate: UInt32
    }

    var values: Values {
        switch self {
        case .auto, .allDay:
            Values(resolution: .r1920x1080, fps: 30, streamBitrate: 4_000_000,
                   recordingCodec: .h265hevc, recordingBitrate: 10_000_000)
        case .smooth:
            Values(resolution: .r1920x1080, fps: 60, streamBitrate: 12_000_000,
                   recordingCodec: .h265hevc, recordingBitrate: 16_000_000)
        case .max:
            Values(resolution: .r3840x2160, fps: 30, streamBitrate: 12_000_000,
                   recordingCodec: .h265hevc, recordingBitrate: 35_000_000)
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .auto: "Auto"
        case .allDay: "All-day"
        case .smooth: "Smooth"
        case .max: "Max quality"
        }
    }

    var short: String {
        switch self {
        case .auto: "Auto"
        case .allDay: "1080p30"
        case .smooth: "1080p60"
        case .max: "4K30"
        }
    }

    var next: DaysPreset {
        let all = DaysPreset.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    private static let key = "daysPreset"
    private static let pendingKey = "daysPresetPending"

    static var current: DaysPreset {
        DaysPreset(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }

    @MainActor
    static func set(_ preset: DaysPreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: key)
        DaysQuality.shared.chosen = preset
    }

    static var pending: Bool {
        get { UserDefaults.standard.bool(forKey: pendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: pendingKey) }
    }
}

final class DaysCaptureInfo: @unchecked Sendable {
    static let shared = DaysCaptureInfo()
    private let lock = NSLock()
    private var width = 0
    private var height = 0
    private var fps = 0
    private var fallback = false
    private weak var connection: AVCaptureConnection?

    func formatApplied(width: Int, height: Int, fps: Int) {
        lock.withLock {
            self.width = width
            self.height = height
            self.fps = fps
            fallback = false
        }
    }

    func formatMissing() {
        lock.withLock { fallback = true }
    }

    func attached(_ connection: AVCaptureConnection) {
        lock.withLock { self.connection = connection }
    }

    var summary: (format: String, stabilization: String, fellBack: Bool) {
        lock.withLock {
            let stab: String = switch connection?.activeVideoStabilizationMode {
            case .off: "Off"
            case .standard: "Standard"
            case .cinematic, .cinematicExtended, .cinematicExtendedEnhanced: "Cinematic"
            case .auto: "Auto"
            case .previewOptimized: "Preview"
            case nil: "–"
            @unknown default: "–"
            }
            let format = width == 0 ? "–" : "\(height)p\(fps)"
            return (format, stab, fallback)
        }
    }
}

extension Model {
    fileprivate func applyDaysCaptureMigration() {
        if !UserDefaults.standard.bool(forKey: "daysBackgroundMigration1") {
            for stream in database.streams {
                stream.backgroundStreaming = true
            }
            UserDefaults.standard.set(true, forKey: "daysBackgroundMigration1")
        }
        let key = "daysCaptureMigration4"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        let wide = widestBackCameraId.isEmpty ? nil : widestBackCameraId
        let backPositions: Set<SettingsSceneCameraPosition> = [
            .back, .backDualLowEnergy, .backTripleLowEnergy, .backWideDualLowEnergy,
        ]
        if let wide {
            for scene in database.scenes where backPositions.contains(scene.videoSource.cameraPosition) {
                scene.videoSource.cameraPosition = .back
                scene.videoSource.backCameraId = wide
            }
        }
        DaysPreset.set(.allDay)
        daysApplyPreset(.allDay, reload: false)
        UserDefaults.standard.set(true, forKey: key)
    }

    fileprivate func applyDaysFocusMigration() {
        let key = "daysFocusMigration1"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        database.tapToFocus = true
        camera.lockedFocuses.removeAll()
        camera.isFocusesLocked.removeAll()
        camera.isFocusLocked = false
        camera.aeAfLocked = false
        storeSettings()
        UserDefaults.standard.set(true, forKey: key)
    }

    fileprivate func applyDaysBitrateMigration() {
        if !UserDefaults.standard.bool(forKey: "daysGitHubOffMigration1") {
            UserDefaults.standard.set(false, forKey: DaysPrefs.githubArchive)
            UserDefaults.standard.set(true, forKey: "daysGitHubOffMigration1")
        }
        let key = "daysBitrateMigration14"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        DaysPreset.set(.auto)
        UserDefaults.standard.set(false, forKey: "daysYouTubeEnabled")
        storeSettings()
        UserDefaults.standard.set(true, forKey: key)
    }
}

extension Model {
    func daysObserveSubjectArea() {
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let model = MoblinApp.globalModel,
                      model.camera.manualFocusPoint != nil, !model.camera.aeAfLocked
                else {
                    return
                }
                model.setAutoFocus()
            }
        }
    }

    func daysLogRecordingStart() {
        let recording = stream.recording
        let resolution = recording.overrideStream ? recording.resolution : stream.resolution
        let fps = recording.overrideStream ? recording.fps : stream.fps
        let info = DaysCaptureInfo.shared.summary
        let channels = media.getNumberOfAudioChannels()
        logger.info("""
        days: recording start \(resolution.shortString())\(fps) \
        codec \(recording.videoCodec == .h265hevc ? "hevc" : "h264") \
        recording \(recording.videoBitrate / 1000) kbps stream \(stream.bitrate / 1000) kbps \
        override \(recording.overrideStream) audio \(recording.audioBitrate / 1000) kbps \(channels) ch \
        camera \(info.format) stab \(info.stabilization)
        """)
    }
}

extension AVCaptureDevice {
    func daysConfigureContinuousFocus() {
        if isFocusModeSupported(.continuousAutoFocus) {
            focusMode = .continuousAutoFocus
        }
        if isExposureModeSupported(.continuousAutoExposure) {
            exposureMode = .continuousAutoExposure
        }
        if isFocusPointOfInterestSupported {
            focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if isExposurePointOfInterestSupported {
            exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if isAutoFocusRangeRestrictionSupported {
            autoFocusRangeRestriction = .none
        }
        if isSmoothAutoFocusSupported {
            isSmoothAutoFocusEnabled = false
        }
        if isFocusModeSupported(.continuousAutoFocus) {
            automaticallyAdjustsFaceDrivenAutoFocusEnabled = true
        }
        if isExposureModeSupported(.continuousAutoExposure) {
            automaticallyAdjustsFaceDrivenAutoExposureEnabled = true
        }
        isSubjectAreaChangeMonitoringEnabled = true
    }
}
