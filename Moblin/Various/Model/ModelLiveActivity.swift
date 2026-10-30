import ActivityKit
import Foundation

#if !targetEnvironment(macCatalyst)

extension Model {
    func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        guard liveActivity == nil else {
            return
        }
        do {
            liveActivity = try Activity.request(
                attributes: LiveActivityAttributes(),
                content: .init(state: makeState(), staleDate: nil)
            )
            logger.info("live-activity: Started")
        } catch {
            logger.info("live-activity: Start failed with error: \(error)")
        }
    }

    func stopLiveActivity() {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Task {
                for activity in Activity<LiveActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
        liveActivity = nil
    }

    func updateLiveActivity() {
        let state = makeState()
        Task {
            await liveActivity?.update(.init(state: state, staleDate: nil))
        }
    }

    private func makeState() -> LiveActivityAttributes.ContentState {
        var functions: [LiveActionFunction] = []
        if isLive {
            functions.append(LiveActionFunction(image: "livephoto",
                                                text: String(localized: "Live")))
        }

        if database.chat.background {
            functions.append(LiveActionFunction(image: "bubble.left",
                                                text: String(localized: "Background chat")))
        }
        if database.moblink.relay.enabled {
            functions.append(LiveActionFunction(
                image: "app.connected.to.app.below.fill",
                text: String(localized: "Moblink relay")
            ))
        }
        if database.catPrinters.backgroundPrinting {
            functions.append(LiveActionFunction(image: "pawprint",
                                                text: String(localized: "Background printing")))
        }
        let line = isRecording ? DaysTake.shared.line ?? "main character energy \u{00B7} capturing" : nil
        let since = isRecording ? DaysTake.shared.since : nil
        if functions.count <= 3 {
            return LiveActivityAttributes.ContentState(functions: functions, showEllipsis: false, line: line, since: since)
        } else {
            return LiveActivityAttributes.ContentState(functions: Array(functions.prefix(2)),
                                                       showEllipsis: true, line: line, since: since)
        }
    }
}

#else

extension Model {
    func startLiveActivity() {}

    func stopLiveActivity() {}

    func updateLiveActivity() {}
}

#endif
