import Foundation
import UIKit

extension Model {
    func makeDriveSessionInfo() -> DriveSessionInfo {
        let recording = stream.recording
        let resolution = recording.overrideStream ? recording.resolution : stream.resolution
        let fps = recording.overrideStream ? recording.fps : stream.fps
        let size = resolution.rawValue.split(separator: "x").compactMap { Int($0) }
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
}
