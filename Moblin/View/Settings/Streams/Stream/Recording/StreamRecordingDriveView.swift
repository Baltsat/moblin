import SwiftUI

struct StreamRecordingDriveView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var recording: SettingsStreamRecording
    @ObservedObject private var status = driveStatus

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
