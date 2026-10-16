import SwiftUI

let settingsHalfWidth = 350.0

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var database: Database

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    StreamsSettingsView(createStreamWizard: model.createStreamWizard, database: database)
                } label: {
                    Label("Streams", systemImage: "dot.radiowaves.left.and.right")
                }
                NavigationLink {
                    ScenesSettingsView(database: database)
                } label: {
                    Label("Scenes", systemImage: "photo.on.rectangle")
                }
                NavigationLink {
                    CameraSettingsView(database: database, stream: model.stream, color: database.color)
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                NavigationLink {
                    AudioSettingsView(database: database,
                                      stream: model.stream,
                                      mic: model.mic,
                                      debug: database.debug,
                                      audio: database.audio)
                } label: {
                    Label("Audio", systemImage: "waveform")
                }
                NavigationLink {
                    DisplaySettingsView(database: database)
                } label: {
                    Label("Display", systemImage: "rectangle.inset.topright.fill")
                }
                NavigationLink {
                    LocationSettingsView(
                        database: database,
                        location: database.location,
                        locationManager: model.locationManager,
                        stream: $model.stream
                    )
                } label: {
                    Label("Location", systemImage: "location")
                }
            }
            Section {
                NavigationLink {
                    RecordingsSettingsView(model: model)
                } label: {
                    Label("Recordings", systemImage: "photo.on.rectangle.angled")
                }
                NavigationLink {
                    DebugSettingsView(model: model, debug: database.debug)
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
            }
            Section {
                SettingsSaveView(model: model)
            }
            Section {
                SettingsResetView(model: model)
            }
        }
        .navigationTitle("Settings")
    }
}
