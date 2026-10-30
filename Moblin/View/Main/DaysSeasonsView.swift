import AVFoundation
import AVKit
import SwiftUI
import Vision

private let seasonsBg = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x1A / 255)
private let seasonsLine = Color(red: 0x24 / 255, green: 0x24 / 255, blue: 0x28 / 255)

private func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

private func daysLength(_ ms: Int64) -> String {
    let minutes = Int((Double(ms) / 60000).rounded())
    return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
}

struct DaysKeyFrame {
    let image: UIImage
    let faceY: CGFloat?
}

/// science-ref: the Mac Seasons "punch" score (capped luminance mean + contrast + saturation, big bonus for a confident
/// face scaled by area; face centre drives the crop) plus 64×64 gradient energy so motion-blurred frames lose.
@MainActor
final class DaysKeyArt {
    static let shared = DaysKeyArt()
    private var best: [String: DaysKeyFrame] = [:]
    private var scores: [String: (Double, CGFloat?)] = [:]

    func frame(_ ids: [String]) async -> DaysKeyFrame? {
        let key = ids.joined(separator: ",")
        if let found = best[key] {
            return found
        }
        var winner: (Double, UIImage, CGFloat?)?
        for id in ids {
            guard let image = await DaysThumbs.shared.image(id) else {
                continue
            }
            let (score, faceY) = score(id, image)
            if winner == nil || score > winner!.0 {
                winner = (score, image, faceY)
            }
        }
        guard let winner else {
            return nil
        }
        let frame = DaysKeyFrame(image: winner.1, faceY: winner.2)
        best[key] = frame
        return frame
    }

    private func sharpness(_ cg: CGImage) -> Double {
        let side = 64
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else {
            return 0
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }
        var total = 0.0
        for y in 0 ..< side - 1 {
            for x in 0 ..< side - 1 {
                let here = Double(data[y * side + x])
                total += abs(here - Double(data[y * side + x + 1])) + abs(here - Double(data[(y + 1) * side + x]))
            }
        }
        return total / Double((side - 1) * (side - 1))
    }

    private func score(_ id: String, _ image: UIImage) -> (Double, CGFloat?) {
        if let cached = scores[id] {
            return cached
        }
        guard let cg = image.cgImage,
              let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return (0, nil)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        var lums: [Double] = []
        var sat = 0.0
        if let data = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            for k in 0 ..< 256 {
                let r = Double(data[k * 4]), g = Double(data[k * 4 + 1]), b = Double(data[k * 4 + 2])
                lums.append(0.299 * r + 0.587 * g + 0.114 * b)
                sat += max(r, g, b) - min(r, g, b)
            }
        }
        let mean = lums.reduce(0, +) / 256
        let sd = sqrt(lums.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 256)
        var value = min(mean, 150) + sd + sat / 256 + 8 * sharpness(cg)
        var faceY: CGFloat?
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        if let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }), face.confidence > 0.6 {
            value += 400 + 600 * min(0.25, face.boundingBox.width * face.boundingBox.height)
            faceY = 1 - face.boundingBox.midY
        }
        scores[id] = (value, faceY)
        return (value, faceY)
    }
}

private struct DaysArt: View {
    let ids: [String]
    var trailing = false
    @State private var frame: DaysKeyFrame?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: trailing ? .trailing : .center) {
                LinearGradient(colors: [Color(red: 0x2A / 255, green: 0x12 / 255, blue: 0x15 / 255),
                                        Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let frame {
                    let size = frame.image.size
                    if size.height > size.width, !trailing {
                        let height = geometry.size.width * size.height / size.width
                        let faceY = frame.faceY ?? 0.38
                        let slack = (height - geometry.size.height) / 2
                        Image(uiImage: frame.image).resizable()
                            .frame(width: geometry.size.width, height: height)
                            .offset(y: min(max(slack - (faceY * height - geometry.size.height * 0.45), -slack), slack))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else if size.height > size.width {
                        Image(uiImage: frame.image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: 18).opacity(0.55).clipped()
                        Image(uiImage: frame.image).resizable().scaledToFit()
                            .frame(height: geometry.size.height)
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                                                 startPoint: .leading, endPoint: .trailing))
                    } else {
                        Image(uiImage: frame.image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }
            }
        }
        .clipped()
        .task(id: ids) {
            frame = await DaysKeyArt.shared.frame(ids)
        }
    }
}

final class DaysLoopView: UIView {
    private var looper: AVPlayerLooper?

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    func play(_ url: URL?) {
        playerLayer.videoGravity = .resizeAspectFill
        guard let url else {
            playerLayer.player?.pause()
            playerLayer.player = nil
            looper = nil
            return
        }
        if (playerLayer.player?.currentItem?.asset as? AVURLAsset)?.url == url {
            return
        }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        looper = AVPlayerLooper(player: player, templateItem: item,
                                timeRange: CMTimeRange(start: CMTime(seconds: 4, preferredTimescale: 600),
                                                       duration: .positiveInfinity))
        playerLayer.player = player
        player.play()
    }
}

private struct DaysLoop: UIViewRepresentable {
    let url: URL?

    func makeUIView(context _: Context) -> DaysLoopView {
        DaysLoopView()
    }

    func updateUIView(_ view: DaysLoopView, context _: Context) {
        view.play(url)
    }

    static func dismantleUIView(_ view: DaysLoopView, coordinator _: ()) {
        view.play(nil)
    }
}

private extension DaysEpisode {
    var lead: DaysScene? {
        scenes.max { $0.durationMs(now: daysNow()) < $1.durationMs(now: daysNow()) }
    }

    var artIds: [String] {
        guard let lead else {
            return []
        }
        for name in ["phone", "face", "screen"] {
            if let thumbs = lead.angles.first(where: { $0.angle == name })?.thumbs, !thumbs.isEmpty {
                return thumbs
            }
        }
        return lead.angles.flatMap(\.thumbs)
    }

    var leadTitle: String {
        lead?.title ?? scenes.compactMap(\.title).first { !$0.isEmpty } ?? ""
    }

    var moreTitles: [String] {
        var seen = Set<String>()
        return scenes.sorted { $0.startMs < $1.startMs }.compactMap(\.title)
            .filter { !$0.isEmpty && $0 != leadTitle && seen.insert($0).inserted }
    }
}

private struct DaysSeasonInfo {
    let season: DaysSeason
    let lived: [DaysEpisode]
    let totalMs: Int64
    let artIds: [String]

    init(_ season: DaysSeason) {
        self.season = season
        lived = season.episodes.filter { !$0.scenes.isEmpty }
        totalMs = season.totalMs(now: daysNow())
        artIds = Array(lived.flatMap { Array($0.artIds.prefix(4)) }.prefix(24))
    }
}

private struct DaysWatch: Identifiable {
    let url: URL
    var id: URL {
        url
    }
}

struct DaysSeasonsSection: View {
    @ObservedObject var index: DaysIndex
    @ObservedObject private var recaps = DaysRecaps.shared
    let header: AnyView
    let onDay: (String) -> Void
    @State private var selected: Int?
    @State private var choosing = false
    @State private var watching: DaysWatch?

    private var current: Int {
        index.seasons.first?.n ?? 1
    }

    private var season: DaysSeason? {
        index.seasons.first { $0.n == (selected ?? current) } ?? index.seasons.first
    }

    private func pct(_ episode: DaysEpisode) -> Double? {
        let formatter = DateFormatter()
        formatter.timeZone = index.tz
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: episode.day)
        return index.mac?.life?.days.first { $0.d == day }?.pct
    }

    var body: some View {
        if let season {
            let info = DaysSeasonInfo(season)
            VStack(alignment: .leading, spacing: 0) {
                hero(info)
                header
                    .padding(.top, 16)
                episodesHeader(season.n)
                ForEach(season.episodes) { episode in
                    DaysEpisodeRow(episode: episode,
                                   isToday: episode.id == index.today.id,
                                   live: index.recordingNow,
                                   pct: pct(episode),
                                   tz: index.tz) {
                        onDay(episode.id)
                    }
                    if episode.id != season.episodes.last?.id {
                        Rectangle().fill(seasonsLine).frame(height: 1).padding(.leading, 34)
                    }
                }
            }
            .fullScreenCover(isPresented: $choosing) {
                DaysSeasonPicker(seasons: index.seasons, current: current, selected: season.n, tz: index.tz) { picked in
                    if let picked {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            selected = picked
                        }
                    }
                    choosing = false
                }
            }
            .fullScreenCover(item: $watching) { watch in
                DaysFullPlayer(url: watch.url) {
                    watching = nil
                }
            }
        }
    }

    private func hero(_ info: DaysSeasonInfo) -> some View {
        let n = info.season.n
        let recap = recaps.recaps[n]
        let teaser = recaps.teasers[n]
        let past = info.lived.filter { $0.id != index.today.id }.compactMap { pct($0) }
        let average = past.isEmpty ? nil : past.reduce(0, +) / Double(past.count)
        let heroEpisode = info.lived.max { $0.durationMs(now: daysNow()) < $1.durationMs(now: daysNow()) }
        let year = Calendar(identifier: .gregorian).component(.year, from: info.season.start)
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let url = recap ?? teaser {
                    DaysLoop(url: url)
                } else {
                    DaysArt(ids: info.artIds, trailing: true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.25),
                                   .init(color: seasonsBg.opacity(0.7), location: 0.62),
                                   .init(color: seasonsBg, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [seasonsBg.opacity(0.55), .clear], startPoint: .leading, endPoint: .center)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(verbatim: "D").font(.system(size: 15, weight: .black)).foregroundStyle(DaysUI.red)
                    Text(verbatim: "S E R I E S").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(white: 0.82))
                }
                Text(verbatim: "MY LIFE")
                    .font(.system(size: 46, weight: .black))
                    .tracking(-1.5)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
                HStack(spacing: 8) {
                    if let average {
                        Text("\(Int(average.rounded()))% on camera").foregroundStyle(DaysUI.green).bold()
                    }
                    Text(verbatim: "\(year)")
                    Text(verbatim: "S\(n)")
                        .padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(DaysUI.muted, lineWidth: 1))
                    Text("\(info.lived.count) episode\(info.lived.count == 1 ? "" : "s")")
                    Text(daysLength(info.totalMs))
                }
                .font(rounded(13, .medium))
                .foregroundStyle(Color(white: 0.82))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                HStack(spacing: 10) {
                    Button {
                        if let recap {
                            watching = DaysWatch(url: recap)
                        } else if let latest = info.lived.first {
                            onDay(latest.id)
                        }
                    } label: {
                        Label(recap != nil ? "Play" : info.lived.first.map { "Episode \($0.number)" } ?? "Play",
                              systemImage: "play.fill")
                            .font(rounded(15, .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(recap == nil && info.lived.isEmpty)
                    if let teaser {
                        Button {
                            watching = DaysWatch(url: teaser)
                        } label: {
                            Label("Trailer", systemImage: "film")
                                .font(rounded(15, .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.22)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
                if let heroEpisode, !heroEpisode.leadTitle.isEmpty {
                    Text(([heroEpisode.leadTitle] + heroEpisode.moreTitles).prefix(4).joined(separator: ". ") + ".")
                        .font(rounded(13))
                        .foregroundStyle(Color(white: 0.74))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .frame(height: heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var heroHeight: CGFloat {
        max(UIScreen.main.bounds.height * 0.6, 340)
    }

    private func episodesHeader(_ n: Int) -> some View {
        HStack {
            Text("Episodes").font(rounded(20, .bold))
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                choosing = true
            } label: {
                HStack(spacing: 6) {
                    Text("Season \(n)").font(rounded(14, .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.17)))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 22)
        .padding(.bottom, 6)
    }
}

private struct DaysEpisodeRow: View {
    let episode: DaysEpisode
    let isToday: Bool
    let live: Bool
    let pct: Double?
    let tz: TimeZone
    let action: () -> Void

    var body: some View {
        let empty = episode.scenes.isEmpty
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: "\(episode.number)")
                    .font(rounded(22, .medium))
                    .foregroundStyle(DaysUI.dim)
                    .frame(width: 22)
                ZStack(alignment: .bottom) {
                    DaysArt(ids: Array(episode.artIds.prefix(6)))
                    if let pct, pct > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(DaysUI.red).frame(width: geometry.size.width * CGFloat(min(1, pct / 100)))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .frame(width: 124, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(daysWeekday(episode.day, tz: tz)).font(rounded(15, .semibold)).lineLimit(1)
                        if isToday {
                            Text(verbatim: live ? "LIVE" : "NEW")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(0.8)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(DaysUI.red))
                        }
                        Spacer(minLength: 4)
                        Text(empty ? "" : daysLength(episode.durationMs(now: daysNow())))
                            .font(rounded(12))
                            .monospacedDigit()
                            .foregroundStyle(Color(white: 0.64))
                    }
                    Text(empty ? "Nothing on camera." : episode.leadTitle.isEmpty
                        ? "\(episode.scenes.count) scene\(episode.scenes.count == 1 ? "" : "s")" : episode.leadTitle)
                        .font(rounded(13, .medium))
                        .foregroundStyle(Color(white: 0.82))
                        .lineLimit(1)
                    if !episode.moreTitles.isEmpty {
                        Text(episode.moreTitles.joined(separator: " \u{00B7} "))
                            .font(rounded(12))
                            .foregroundStyle(DaysUI.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(.vertical, 12)
            .opacity(empty ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(empty)
    }
}

private struct DaysSeasonPicker: View {
    let seasons: [DaysSeason]
    let current: Int
    let selected: Int
    let tz: TimeZone
    let done: (Int?) -> Void
    @State private var highlighted: Int?

    private func dates(_ start: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMM"
        let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: start) ?? start
        return "\(formatter.string(from: start)) \u{2013} \(formatter.string(from: end))"
    }

    var body: some View {
        let focus = seasons.first { $0.n == (highlighted ?? selected) }.map(DaysSeasonInfo.init)
        ZStack {
            seasonsBg.ignoresSafeArea()
            DaysArt(ids: focus?.artIds ?? [])
                .blur(radius: 40)
                .opacity(0.45)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.3), value: highlighted)
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Text(verbatim: "SEASONS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(DaysUI.muted)
                    .padding(.bottom, 18)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(seasons) { season in
                            let info = DaysSeasonInfo(season)
                            let on = season.n == selected
                            Button {
                                highlighted = season.n
                                done(season.n)
                            } label: {
                                HStack(spacing: 14) {
                                    DaysArt(ids: info.artIds)
                                        .frame(width: 112, height: 63)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(on ? Color.white : .clear, lineWidth: 2))
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text("Season \(season.n)")
                                                .font(rounded(on ? 22 : 19, on ? .bold : .semibold))
                                                .foregroundStyle(on ? .white : Color(white: 0.7))
                                            if season.n == current {
                                                Text(verbatim: "NOW")
                                                    .font(.system(size: 9, weight: .heavy))
                                                    .tracking(0.8)
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(RoundedRectangle(cornerRadius: 3).fill(DaysUI.red))
                                            }
                                        }
                                        Text("\(dates(season.start)) \u{00B7} \(info.lived.count) episode\(info.lived.count == 1 ? "" : "s") \u{00B7} \(daysLength(info.totalMs))")
                                            .font(rounded(12))
                                            .monospacedDigit()
                                            .foregroundStyle(DaysUI.muted)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: CGFloat(seasons.count) * 89)
                Spacer(minLength: 12)
                Button {
                    done(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white))
                }
                .buttonStyle(.plain)
                .padding(.vertical, 22)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct DaysFullPlayer: View {
    let url: URL
    let close: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            Button {
                player?.pause()
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .padding(.leading, 8)
        }
        .onAppear {
            player = AVPlayer(url: url)
            player?.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}
