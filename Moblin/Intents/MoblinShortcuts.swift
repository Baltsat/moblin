import AppIntents
import IntentsUI

final class MoblinShortcuts: AppShortcutsProvider {
    static let shortcutTileColor = ShortcutTileColor.navy

    nonisolated(unsafe) static let appShortcuts: [AppShortcut] = [
        AppShortcut(intent: StartRecordingIntent(), phrases: [
            "\(.applicationName), start recording",
        ],
        shortTitle: "Start recording",
        systemImageName: "record.circle"),
        AppShortcut(intent: StopRecordingIntent(), phrases: [
            "\(.applicationName), stop recording",
        ],
        shortTitle: "Stop recording",
        systemImageName: "stop.circle"),
        AppShortcut(intent: MuteIntent(), phrases: [
            "\(.applicationName), mute",
        ],
        shortTitle: "Mute",
        systemImageName: "microphone.slash"),
        AppShortcut(intent: UnmuteIntent(), phrases: [
            "\(.applicationName), unmute",
        ],
        shortTitle: "Unmute",
        systemImageName: "microphone"),
        AppShortcut(intent: SnapshotIntent(), phrases: [
            "\(.applicationName), take snapshot",
        ],
        shortTitle: "Take snapshot",
        systemImageName: "microphone"),
    ]
}
