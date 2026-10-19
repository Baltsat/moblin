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
        let key = "daysDefaultsApplied2"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        for stream in database.streams {
            stream.resolution = .r1920x1080
            stream.fps = 30
            stream.codec = .h264avc
            stream.bitrate = 5_000_000
            stream.maxKeyFrameInterval = 2
            stream.recording.overrideStream = false
            stream.recording.videoCodec = .h264avc
            stream.recording.videoBitrate = 5_000_000
            stream.recording.maxKeyFrameInterval = 2
        }
        database.videoStabilizationMode = .standard
        database.audio.preferStereoMic = true
        UserDefaults.standard.set(true, forKey: key)
    }
}
