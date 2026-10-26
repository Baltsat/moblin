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
        applyDaysCaptureMigration()
        applyDaysBitrateMigration()
        applyDaysFocusMigration()
        daysObserveSubjectArea()
        daysPickStereoMic()
        applyDaysPendingPreset()
    }

    func applyDaysPendingPreset() {
        guard DaysPreset.pending else {
            return
        }
        DaysPreset.pending = false
        daysApplyPreset(DaysPreset.current)
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
            stream.recording.audioBitrate = 192_000
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
            daysApplyPreset(preset)
        }
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
    }
}

@MainActor private var daysThermalReduced = false

enum DaysPreset: String, CaseIterable {
    case allDay, smooth, max

    struct Values {
        let resolution: SettingsStreamResolution
        let fps: Int
        let streamBitrate: UInt32
        let recordingCodec: SettingsStreamCodec
        let recordingBitrate: UInt32
    }

    var values: Values {
        switch self {
        case .allDay:
            Values(resolution: .r1920x1080, fps: 30, streamBitrate: 4_000_000,
                   recordingCodec: .h265hevc, recordingBitrate: 8_000_000)
        case .smooth:
            Values(resolution: .r1920x1080, fps: 60, streamBitrate: 12_000_000,
                   recordingCodec: .h264avc, recordingBitrate: 14_000_000)
        case .max:
            Values(resolution: .r3840x2160, fps: 30, streamBitrate: 12_000_000,
                   recordingCodec: .h265hevc, recordingBitrate: 30_000_000)
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .allDay: "All-day"
        case .smooth: "Smooth"
        case .max: "Max quality"
        }
    }

    private static let key = "daysPreset"
    private static let pendingKey = "daysPresetPending"

    static var current: DaysPreset {
        DaysPreset(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .allDay
    }

    static func set(_ preset: DaysPreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: key)
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
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?.uniqueID
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
        let key = "daysBitrateMigration11"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        daysApplyPreset(DaysPreset.current, reload: false)
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
