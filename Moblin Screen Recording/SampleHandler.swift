import AVFoundation
import ReplayKit

private let segmentSeconds = 600.0
private let screenNotification = "com.baltsat.days.screen"

private let nameFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Makassar")
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    return formatter
}()

private final class Segment {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let app: AVAssetWriterInput
    let mic: AVAssetWriterInput
    let open: URL
    let done: URL
    let start: CMTime

    init?(dir: URL, width: Int32, height: Int32, start: CMTime) {
        let stamp = nameFormatter.string(from: Date())
        let take = UserDefaults(suiteName: moblinAppGroup)?.string(forKey: "daysTake")
        let name = take.map { "\($0)-screen-\(stamp.suffix(6))" } ?? "\(stamp)_screen"
        open = dir.appending(component: "open").appending(component: "\(name).mov")
        done = dir.appending(component: "\(name).mov")
        guard let writer = try? AVAssetWriter(outputURL: open, fileType: .mov) else {
            return nil
        }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        let audio: (Int) -> AVAssetWriterInput = { channels in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels * 64000,
            ])
        }
        app = audio(2)
        mic = audio(1)
        for input in [video, app, mic] {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }
        guard writer.startWriting() else {
            return nil
        }
        writer.startSession(atSourceTime: start)
        self.writer = writer
        self.start = start
    }

    func finish(_ completion: @escaping () -> Void) {
        for input in [video, app, mic] {
            input.markAsFinished()
        }
        writer.finishWriting { [open, done] in
            try? FileManager.default.moveItem(at: open, to: done)
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(screenNotification as CFString), nil, nil, true)
            completion()
        }
    }
}

class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private var dir: URL?
    private var segment: Segment?

    override func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: moblinAppGroup) else {
            return
        }
        let dir = root.appending(component: "Screen")
        let open = dir.appending(component: "open")
        try? FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: open.path)) ?? [] {
            try? FileManager.default.moveItem(at: open.appending(component: name), to: dir.appending(component: name))
        }
        lock.withLock { self.dir = dir }
    }

    override func broadcastFinished() {
        guard let segment = lock.withLock({ () -> Segment? in
            defer { self.segment = nil }
            return self.segment
        }) else {
            return
        }
        let done = DispatchSemaphore(value: 0)
        segment.finish { done.signal() }
        done.wait()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        lock.withLock {
            autoreleasepool {
                append(sampleBuffer, type)
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, _ type: RPSampleBufferType) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if type == .video {
            if let current = segment, (time - current.start).seconds >= segmentSeconds {
                current.finish {}
                segment = nil
            }
            if segment == nil, let dir, let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
                segment = Segment(dir: dir,
                                  width: Int32(CVPixelBufferGetWidth(image)),
                                  height: Int32(CVPixelBufferGetHeight(image)),
                                  start: time)
            }
        }
        guard let segment, time >= segment.start else {
            return
        }
        let input = switch type {
        case .video: segment.video
        case .audioApp: segment.app
        case .audioMic: segment.mic
        @unknown default: segment.mic
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
