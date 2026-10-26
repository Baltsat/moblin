import BackgroundTasks
import Foundation
import UIKit

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
        daysLog("BGProcessingTask started")
        DispatchQueue.main.async { daysLogBackgroundSettings() }
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

@MainActor
func daysLogBackgroundSettings() {
    let refresh = switch UIApplication.shared.backgroundRefreshStatus {
    case .available: "on"
    case .denied: "OFF"
    case .restricted: "restricted"
    @unknown default: "unknown"
    }
    UIDevice.current.isBatteryMonitoringEnabled = true
    let battery = switch UIDevice.current.batteryState {
    case .charging: "charging"
    case .full: "full"
    case .unplugged: "unplugged"
    default: "unknown"
    }
    daysLog("settings backgroundRefresh=\(refresh) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) battery=\(battery) \(Int(UIDevice.current.batteryLevel * 100))%")
}
