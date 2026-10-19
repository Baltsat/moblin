import AVFoundation
import Foundation

private let daysQuickButtons: Set<SettingsQuickButtonType> = [
    .record, .mute, .torch, .blackScreen, .lockScreen, .live,
]

extension Model {
    func applyDaysDefaults() {
        database.portrait = false
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
        let key = "daysCaptureMigration3"
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
        for stream in database.streams {
            stream.resolution = .r1920x1080
            stream.fps = 60
            stream.codec = .h264avc
            stream.bitrate = 8_000_000
            stream.maxKeyFrameInterval = 2
            stream.audioCodec = .aac
            stream.audioBitrate = 128_000
            stream.recording.overrideStream = false
            stream.recording.videoCodec = .h264avc
            stream.recording.videoBitrate = 8_000_000
            stream.recording.maxKeyFrameInterval = 2
            stream.recording.audioBitrate = 128_000
        }
        database.videoStabilizationMode = .standard
        database.audio.preferStereoMic = true
        UserDefaults.standard.set(true, forKey: key)
    }
}
