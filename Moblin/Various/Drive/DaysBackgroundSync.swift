import BackgroundTasks
import Foundation
import UIKit

private let daysSyncIdentifier = "com.baltsat.moblin-dais.sync"
private let daysRefreshIdentifier = "com.baltsat.moblin-dais.refresh"

enum DaysBackgroundSync {
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: daysSyncIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: daysRefreshIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleRefresh(task)
        }
    }

    /// The cloud recap job runs at 07:30 Bali, so the next refresh aims at 07:45 Bali, but never later than 3 h away.
    static func scheduleRefresh() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Makassar")!
        let morning = calendar.nextDate(after: Date(), matching: DateComponents(hour: 7, minute: 45),
                                        matchingPolicy: .nextTime) ?? Date()
        let request = BGAppRefreshTaskRequest(identifier: daysRefreshIdentifier)
        request.earliestBeginDate = min(morning, Date(timeIntervalSinceNow: 3 * 3600))
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        daysLog("BGAppRefreshTask started")
        scheduleRefresh()
        nonisolated(unsafe) let task = task
        let work = Task { @MainActor in
            await DaysIndex.shared.pullNow()
            DaysRecaps.shared.expire()
            await DaysRecaps.shared.refresh(download: DaysNet.shared.unmeteredWifi)
            daysLog("BGAppRefreshTask done recaps=\(DaysRecaps.shared.recaps.keys.sorted())")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
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
            await DaysIndex.shared.pullNow()
            await MainActor.run { DaysRecaps.shared.expire() }
            await DaysRecaps.shared.refresh(download: DaysNet.shared.unmeteredWifi)
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
