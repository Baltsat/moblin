import SwiftUI

struct StreamRecordingDriveView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var recording: SettingsStreamRecording
    @ObservedObject private var status = driveStatus
    @AppStorage("daysAutoStartRecording") private var autoStart = false
    @AppStorage("daysYouTubeEnabled") private var youTubeEnabled = true
    @AppStorage("daysYouTubeCellular") private var youTubeCellular = false

    var body: some View {
        Section {
            Toggle("Upload to Google Drive", isOn: $recording.uploadToDrive)
            if status.signedIn {
                TextButtonView("Sign out of Google") {
                    model.driveSignOut()
                }
                .tint(.red)
            } else {
                TextButtonView("Sign in to Google") {
                    model.driveSignIn()
                }
            }
            Toggle("Start recording when the app opens", isOn: $autoStart)
            Toggle("Stream to YouTube while recording", isOn: $youTubeEnabled)
            Toggle("Stream to YouTube over cellular", isOn: $youTubeCellular)
            if status.signedIn, !status.hasYouTube {
                Text("Sign in to Google again to allow YouTube.")
            }
            if !status.text.isEmpty {
                Text(status.text)
            }
        } header: {
            Text("Google Drive")
        } footer: {
            Text("""
            Uploads every recording while it is recorded, as one video file with a JSON file next to it, \
            to Days/phone in your Google Drive.
            """)
        }
    }
}
