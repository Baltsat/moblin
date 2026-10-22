import AVFoundation
import SwiftUI

struct DaysSprite: Equatable {
    var id: String
    var n: Int
    var cols: Int
    var w: Int
    var h: Int
    var spanMs: Int64

    init(id: String, n: Int, cols: Int, w: Int, h: Int, spanMs: Int64) {
        self.id = id
        self.n = n
        self.cols = cols
        self.w = w
        self.h = h
        self.spanMs = spanMs
    }

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let n = (dict["n"] as? NSNumber)?.intValue,
              let cols = (dict["cols"] as? NSNumber)?.intValue,
              let w = (dict["w"] as? NSNumber)?.intValue,
              let h = (dict["h"] as? NSNumber)?.intValue,
              n > 0, cols > 0, w > 0, h > 0
        else {
            return nil
        }
        self.init(id: id, n: n, cols: cols, w: w, h: h, spanMs: (dict["span_ms"] as? NSNumber)?.int64Value ?? 0)
    }

    var dict: [String: Any] {
        ["id": id, "n": n, "cols": cols, "w": w, "h": h, "span_ms": spanMs]
    }

    func seconds(at fraction: Double) -> Int {
        Int(Double(spanMs) / 1000 * min(max(fraction, 0), 0.9999))
    }

    func index(at fraction: Double) -> Int {
        min(max(Int(fraction * Double(n)), 0), n - 1)
    }
}

struct DaysSpriteSheet {
    var data: Data
    var cols: Int
    var w: Int
    var h: Int
    var n: Int
}

func daysComposeSprite(frames: [UIImage], count: Int = 48, cols: Int = 8) -> DaysSpriteSheet? {
    guard let first = frames.first, !frames.isEmpty else {
        return nil
    }
    let picked: [UIImage]
    if frames.count > count {
        picked = (0 ..< count).map { frames[$0 * frames.count / count] }
    } else {
        picked = frames
    }
    let portrait = first.size.height > first.size.width
    let w = portrait ? 90 : 160
    let h = portrait ? 160 : 90
    let rows = (picked.count + cols - 1) / cols
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: cols * w, height: rows * h)
    let sheet = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.black.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        for (index, frame) in picked.enumerated() {
            let cell = CGRect(x: (index % cols) * w, y: (index / cols) * h, width: w, height: h)
            let scale = max(cell.width / max(frame.size.width, 1), cell.height / max(frame.size.height, 1))
            let drawSize = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
            context.cgContext.saveGState()
            context.cgContext.clip(to: cell)
            frame.draw(in: CGRect(x: cell.midX - drawSize.width / 2,
                                  y: cell.midY - drawSize.height / 2,
                                  width: drawSize.width,
                                  height: drawSize.height))
            context.cgContext.restoreGState()
        }
    }
    for quality in [0.6, 0.5, 0.4, 0.3] {
        if let data = sheet.jpegData(compressionQuality: quality), data.count <= 200_000 || quality == 0.3 {
            return DaysSpriteSheet(data: data, cols: cols, w: w, h: h, n: picked.count)
        }
    }
    return nil
}

func daysAssetSpriteFrames(_ asset: AVURLAsset, count: Int) async -> (frames: [UIImage], spanMs: Int64)? {
    guard let seconds = await daysAssetDuration(asset) else {
        return nil
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 320, height: 320)
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    var frames: [UIImage] = []
    for index in 0 ..< count {
        let time = CMTime(seconds: seconds * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
        if let (image, _) = try? await generator.image(at: time) {
            frames.append(UIImage(cgImage: image))
        } else if let last = frames.last {
            frames.append(last)
        }
    }
    guard frames.count == count else {
        return nil
    }
    return (frames, Int64(seconds * 1000))
}

@MainActor
final class DaysSprites {
    static let shared = DaysSprites()
    var localDir: URL?
    var cacheDirectory: URL? {
        dir
    }
    private let api = DriveApi()
    private var sheets: [String: CGImage] = [:]
    private var frames: [String: UIImage] = [:]
    private var loading: Set<String> = []
    private let dir: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DaysSprites")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func sheet(_ id: String, refresh: Bool = false) async -> CGImage? {
        if !refresh, let sheet = sheets[id] {
            return sheet
        }
        let file = (localDir ?? dir).appendingPathComponent("\(id).jpg")
        if !refresh, let image = UIImage(contentsOfFile: file.path)?.cgImage {
            sheets[id] = image
            return image
        }
        guard localDir == nil, driveAuth.isSignedIn, !loading.contains(id) else {
            return sheets[id]
        }
        loading.insert(id)
        defer { loading.remove(id) }
        guard let data = try? await api.downloadMedia(fileId: id), let image = UIImage(data: data)?.cgImage else {
            return sheets[id]
        }
        try? data.write(to: file)
        sheets[id] = image
        frames = frames.filter { !$0.key.hasPrefix("\(id)#") }
        return image
    }

    func frame(_ sprite: DaysSprite, index: Int) -> UIImage? {
        let key = "\(sprite.id)#\(index)"
        if let image = frames[key] {
            return image
        }
        guard let sheet = sheets[sprite.id] else {
            return nil
        }
        let rect = CGRect(x: (index % sprite.cols) * sprite.w, y: (index / sprite.cols) * sprite.h,
                          width: sprite.w, height: sprite.h)
        guard let cropped = sheet.cropping(to: rect) else {
            return nil
        }
        let image = UIImage(cgImage: cropped)
        frames[key] = image
        return image
    }
}
