import AppIntents

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start recording"
    static let description: IntentDescription? = IntentDescription("Starts recording.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if !model.isRecording {
            model.startRecording()
        }
        return .result()
    }

    @Dependency
    private var model: Model
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop recording"
    static let description: IntentDescription? = IntentDescription("Stops recording.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        model.stopRecording()
        return .result()
    }

    @Dependency
    private var model: Model
}
