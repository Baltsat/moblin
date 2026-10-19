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
        applyDaysCaptureMigration()
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
            stream.maxKeyFrameInterval = 2
            stream.audioCodec = .aac
            stream.audioBitrate = 128_000
            stream.recording.overrideStream = false
            stream.recording.videoCodec = values.recordingCodec
            stream.recording.videoBitrate = values.recordingBitrate
            stream.recording.maxKeyFrameInterval = 2
            stream.recording.audioBitrate = 128_000
        }
        database.videoStabilizationMode = .standard
        database.audio.preferStereoMic = true
        if reload, !isRecording, !isLive {
            reloadStreamIfEnabled(stream: stream)
            attachCamera()
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
        if hot {
            disableScreenPreview()
        } else if !daysDim.dimmed {
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
            Values(resolution: .r1920x1080, fps: 30, streamBitrate: 6_000_000,
                   recordingCodec: .h264avc, recordingBitrate: 6_000_000)
        case .smooth:
            Values(resolution: .r1920x1080, fps: 60, streamBitrate: 8_000_000,
                   recordingCodec: .h264avc, recordingBitrate: 8_000_000)
        case .max:
            Values(resolution: .r3840x2160, fps: 30, streamBitrate: 35_000_000,
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
}
