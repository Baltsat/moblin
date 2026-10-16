import CoreLocation
import Foundation
import UIKit

extension Model {
    func makeDriveSessionInfo() -> DriveSessionInfo {
        let recording = stream.recording
        let resolution = recording.overrideStream ? recording.resolution : stream.resolution
        let fps = recording.overrideStream ? recording.fps : stream.fps
        var size = resolution.rawValue.split(separator: "x").compactMap { Int($0) }
        if stream.portrait {
            size.reverse()
        }
        let bitrate = recording.videoBitrate != 0 ? recording.videoBitrate : stream.bitrate
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return DriveSessionInfo(
            device: "\(UIDevice.current.model) \(machine)",
            codec: recording.videoCodec == .h265hevc ? "hevc" : "h264",
            width: size.first ?? 0,
            height: size.last ?? 0,
            fps: fps,
            bitrateKbps: Int(bitrate / 1000)
        )
    }

    func startDriveSessionIfNeeded() {
        if stream.recording.uploadToDrive, driveAuth.isSignedIn {
            driveUploader.arm(info: makeDriveSessionInfo())
        } else {
            driveUploader.disarm()
            if stream.recording.uploadToDrive {
                makeErrorToast(title: String(localized: "Not signed in to Google Drive"))
            }
        }
    }

    func stopDriveSession() {
        driveUploader.disarm()
    }

    private func isDriveRecording() -> Bool {
        isRecording && stream.recording.uploadToDrive
    }

    private func driveDetail(_ values: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    func driveRecordLocation(location: CLLocation) {
        guard isDriveRecording() else {
            return
        }
        var values: [String: Any] = [
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "alt": location.altitude,
            "hacc": location.horizontalAccuracy,
            "vacc": location.verticalAccuracy,
            "fix_ms": Int64(location.timestamp.timeIntervalSince1970 * 1000),
        ]
        if location.speed >= 0 {
            values["speed"] = location.speed
        }
        if location.course >= 0 {
            values["course"] = location.course
        }
        driveUploader.event(type: "location", detail: driveDetail(values))
    }

    func driveRecordDeviceSample() {
        guard isDriveRecording() else {
            return
        }
        let device = UIDevice.current
        let battery: String
        switch device.batteryState {
        case .charging:
            battery = "charging"
        case .full:
            battery = "full"
        case .unplugged:
            battery = "unplugged"
        default:
            battery = "unknown"
        }
        driveUploader.event(type: "device", detail: driveDetail([
            "battery": Int(device.batteryLevel * 100),
            "battery_state": battery,
            "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "brightness": Double(UIScreen.main.brightness),
            "free_bytes": freeDiskBytes(),
        ]))
    }

    func driveRecordOrientation() {
        guard isDriveRecording() else {
            return
        }
        let value: String
        switch UIDevice.current.orientation {
        case .portrait:
            value = "portrait"
        case .portraitUpsideDown:
            value = "portrait_upside_down"
        case .landscapeLeft:
            value = "landscape_left"
        case .landscapeRight:
            value = "landscape_right"
        case .faceUp:
            value = "face_up"
        case .faceDown:
            value = "face_down"
        default:
            return
        }
        driveUploader.event(type: "orientation", detail: value)
    }

    private func freeDiskBytes() -> Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
