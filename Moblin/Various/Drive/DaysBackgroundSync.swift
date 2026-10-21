import BackgroundTasks
import Foundation

private let daysSyncIdentifier = "com.baltsat.moblin-dais.sync"

enum DaysBackgroundSync {
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: daysSyncIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: daysSyncIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule()
        nonisolated(unsafe) let task = task
        let work = Task {
            driveUploader.setBackground(true)
            driveUploader.resume()
            await MainActor.run { DaysIndex.shared.refreshAndPush() }
            try? await Task.sleep(for: .seconds(60))
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
