import NaturalLanguage
import SwiftUI

func daysPrompterParagraphs(_ text: String) -> [String] {
    var result: [String] = []
    let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\n[ \t]*\n", with: "\u{0}", options: .regularExpression)
        .components(separatedBy: "\u{0}")
    for block in blocks {
        let flat = block.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else {
            continue
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = flat
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: flat.startIndex ..< flat.endIndex) { range, _ in
            let sentence = flat[range].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        var current: [String] = []
        var words = 0
        for sentence in sentences {
            let count = sentence.split(separator: " ").count
            if !current.isEmpty, current.count >= 3 || words + count > 40 {
                result.append(current.joined(separator: " "))
                current = []
                words = 0
            }
            current.append(sentence)
            words += count
        }
        if !current.isEmpty {
            result.append(current.joined(separator: " "))
        }
    }
    return result
}

private let daysPrompterCard = Color(red: 0x2A / 255, green: 0x2F / 255, blue: 0x35 / 255)
private let daysPrompterEditorBg = Color(red: 0x1C / 255, green: 0x1F / 255, blue: 0x23 / 255)

@MainActor
final class DaysPrompter: ObservableObject {
    static let shared = DaysPrompter()
    private let defaults = UserDefaults.standard

    @Published var shown: Bool { didSet { defaults.set(shown, forKey: "daysPrompterShown") } }
    @Published var script: String {
        didSet {
            defaults.set(script, forKey: "daysPrompterScript")
            paragraphs = daysPrompterParagraphs(script)
        }
    }

    @Published private(set) var paragraphs: [String] = []
    @Published var speed: Double { didSet { reanchor(); defaults.set(speed, forKey: "daysPrompterPts") } }
    @Published var size: Double { didSet { defaults.set(size, forKey: "daysPrompterTextSize") } }
    @Published var alpha: Double { didSet { defaults.set(alpha, forKey: "daysPrompterAlpha") } }
    @Published var countdownOn: Bool { didSet { defaults.set(countdownOn, forKey: "daysPrompterCountdown") } }
    @Published var autoStart: Bool { didSet { defaults.set(autoStart, forKey: "daysPrompterAutoStart") } }
    @Published var position: CGSize {
        didSet { defaults.set([position.width, position.height], forKey: "daysPrompterPosition") }
    }

    @Published var cardSize: CGSize {
        didSet { defaults.set([cardSize.width, cardSize.height], forKey: "daysPrompterCard") }
    }

    @Published var tune = false
    @Published private(set) var generation = 0
    @Published private(set) var playing = false
    @Published private(set) var countdown: Int?
    private var anchorOffset: CGFloat = 0
    private var anchorDate = Date()
    var maxOffset: CGFloat = .greatestFiniteMagnitude
    private var countdownTask: Task<Void, Never>?

    private init() {
        shown = defaults.bool(forKey: "daysPrompterShown")
        script = defaults.string(forKey: "daysPrompterScript") ?? ""
        speed = defaults.object(forKey: "daysPrompterPts") as? Double ?? 30
        size = defaults.object(forKey: "daysPrompterTextSize") as? Double ?? 22
        alpha = defaults.object(forKey: "daysPrompterAlpha") as? Double ?? 0.72
        countdownOn = defaults.object(forKey: "daysPrompterCountdown") as? Bool ?? true
        autoStart = defaults.object(forKey: "daysPrompterAutoStart") as? Bool ?? true
        let saved = defaults.array(forKey: "daysPrompterPosition") as? [Double] ?? [0, 0]
        position = CGSize(width: saved.first ?? 0, height: saved.last ?? 0)
        let card = defaults.array(forKey: "daysPrompterCard") as? [Double] ?? [560, 200]
        cardSize = CGSize(width: card.first ?? 560, height: card.last ?? 200)
        paragraphs = daysPrompterParagraphs(script)
        #if DEBUG
            tune = defaults.bool(forKey: "DaysPrompterTune")
        #endif
    }

    func offset(at date: Date) -> CGFloat {
        guard playing else {
            return anchorOffset
        }
        return min(anchorOffset + CGFloat(date.timeIntervalSince(anchorDate) * speed), maxOffset)
    }

    private func reanchor() {
        anchorOffset = offset(at: Date())
        anchorDate = Date()
    }

    func play() {
        guard !playing, !paragraphs.isEmpty else {
            return
        }
        if anchorOffset >= maxOffset {
            anchorOffset = 0
        }
        anchorDate = Date()
        playing = true
    }

    func pause() {
        countdownTask?.cancel()
        countdown = nil
        reanchor()
        playing = false
    }

    var running: Bool {
        playing || countdown != nil
    }

    func toggle() {
        if running {
            pause()
        } else {
            start()
        }
    }

    func start() {
        guard countdownOn else {
            play()
            return
        }
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for value in [3, 2, 1] {
                countdown = value
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled {
                    return
                }
            }
            countdown = nil
            play()
        }
    }

    func reset() {
        pause()
        guard anchorOffset != 0 else {
            return
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            anchorOffset = 0
            generation += 1
        }
    }

    func takeStopped() {
        if running {
            pause()
        }
    }

    func close() {
        reset()
        tune = false
        shown = false
    }

    func takeStarted() {
        guard shown, autoStart, !running else {
            return
        }
        reset()
        start()
    }

    func reachedEnd(_ date: Date) -> Bool {
        playing && offset(at: date) >= maxOffset
    }
}

private struct DaysParagraphFrames: PreferenceKey {
    static let defaultValue: [Int: ClosedRange<CGFloat>] = [:]

    static func reduce(value: inout [Int: ClosedRange<CGFloat>], nextValue: () -> [Int: ClosedRange<CGFloat>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct DaysFatSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 26
            let width = geometry.size.width - knob - 8
            let x = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.13))
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white)
                    .frame(width: knob, height: knob)
                    .offset(x: 4 + x)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let t = Double(min(max(0, (drag.location.x - 4 - knob / 2) / width), 1))
                value = range.lowerBound + t * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 34)
    }
}

private struct DaysPrompterKnobs: View {
    @ObservedObject var prompter = DaysPrompter.shared

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Teleprompter speed")
            DaysFatSlider(value: $prompter.speed, range: 8 ... 120)
            label("Text size").padding(.top, 4)
            DaysFatSlider(value: $prompter.size, range: 14 ... 48)
        }
        .padding(14)
        .frame(width: 230, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private struct DaysPrompterText: View {
    @ObservedObject var prompter = DaysPrompter.shared
    let size: CGSize
    @State private var frames: [Int: ClosedRange<CGFloat>] = [:]

    private var readLine: CGFloat {
        size.height * 0.55
    }

    private func current(_ offset: CGFloat) -> Int {
        let line = offset + readLine + 4
        return frames.sorted { $0.key < $1.key }.last(where: { $0.value.lowerBound <= line })?.key ?? 0
    }

    private func band(_ edges: Bool) -> some View {
        LinearGradient(stops: [.init(color: edges ? .black : .clear, location: 0),
                               .init(color: edges ? .clear : .black, location: 0.22),
                               .init(color: edges ? .clear : .black, location: 0.84),
                               .init(color: edges ? .black : .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        ZStack(alignment: .top) {
            column.blur(radius: 4).mask(band(true))
            column.mask(band(false))
        }
        .onPreferenceChange(DaysParagraphFrames.self) { value in
            frames = value
            prompter.maxOffset = max((value.values.map(\.upperBound).max() ?? 0) - readLine, 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.02),
                                     .init(color: .black, location: 0.22),
                                     .init(color: .black, location: 0.8),
                                     .init(color: .clear, location: 0.98)],
                             startPoint: .top, endPoint: .bottom))
    }

    private var column: some View {
        TimelineView(.animation(paused: !prompter.playing)) { context in
            let offset = prompter.offset(at: context.date)
            let active = current(offset)
            VStack(alignment: .leading, spacing: prompter.size * 0.75) {
                ForEach(Array(prompter.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .font(.system(size: prompter.size, weight: .semibold))
                        .lineSpacing(prompter.size * 0.18)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white.opacity(index == active ? 1 : 0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { proxy in
                            let frame = proxy.frame(in: .named("daysPrompter"))
                            Color.clear.preference(key: DaysParagraphFrames.self,
                                                   value: [index: frame.minY ... frame.maxY])
                        })
                }
                if prompter.paragraphs.isEmpty {
                    Text("Add your script here…")
                        .font(.system(size: prompter.size, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: active)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18)
            .padding(.trailing, 40)
            .padding(.top, readLine)
            .coordinateSpace(name: "daysPrompter")
            .offset(y: -offset)
            .onChange(of: prompter.reachedEnd(context.date)) { ended in
                if ended {
                    prompter.pause()
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

private func daysRubber(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
    let stretch = { (excess: CGFloat) in 60 * (1 - 1 / (excess / 110 + 1)) }
    if value < range.lowerBound {
        return range.lowerBound - stretch(range.lowerBound - value)
    }
    if value > range.upperBound {
        return range.upperBound + stretch(value - range.upperBound)
    }
    return value
}

private func daysNearest(_ value: CGFloat, _ stops: [CGFloat]) -> CGFloat {
    stops.min { abs($0 - value) < abs($1 - value) } ?? value
}

struct DaysPrompterOverlay: View {
    @ObservedObject var prompter = DaysPrompter.shared
    let screen: CGSize
    let recording: Bool
    @State private var moving: CGSize = .zero
    @State private var resizing: CGSize = .zero
    @State private var dragging = false
    @State private var showEditor = false

    private var portrait: Bool {
        screen.height >= screen.width
    }

    private func fit(_ wanted: CGSize) -> CGSize {
        CGSize(width: min(max(wanted.width, 240), screen.width - (portrait ? 16 : 340)),
               height: min(max(wanted.height, 110), screen.height - insets.bottom - top))
    }

    private var committed: CGSize {
        fit(prompter.cardSize)
    }

    private var size: CGSize {
        fit(CGSize(width: prompter.cardSize.width + resizing.width,
                   height: prompter.cardSize.height + resizing.height))
    }

    private var top: CGFloat {
        portrait ? 8 : 100
    }

    private var insets: (left: CGFloat, right: CGFloat, bottom: CGFloat) {
        portrait ? (8, 8, 210) : (16, 130, 72)
    }

    private func xRange(_ width: CGFloat) -> ClosedRange<CGFloat> {
        let low = insets.left - (screen.width - width) / 2
        let high = (screen.width - width) / 2 - insets.right
        return low <= high ? low ... high : (low + high) / 2 ... (low + high) / 2
    }

    private func yRange(_ height: CGFloat) -> ClosedRange<CGFloat> {
        0 ... max(screen.height - insets.bottom - height - top, 0)
    }

    private func clamp(_ offset: CGSize, _ card: CGSize) -> CGSize {
        let x = xRange(card.width), y = yRange(card.height)
        return CGSize(width: min(max(offset.width, x.lowerBound), x.upperBound),
                      height: min(max(offset.height, y.lowerBound), y.upperBound))
    }

    private var liveOffset: CGSize {
        let width = prompter.position.width + moving.width + (size.width - committed.width) / 2
        let height = prompter.position.height + moving.height
        if resizing != .zero {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: daysRubber(width, xRange(size.width)), height: daysRubber(height, yRange(size.height)))
    }

    private func snap(_ predicted: CGSize) -> CGSize {
        let x = xRange(committed.width), y = yRange(committed.height)
        let middle = (y.lowerBound + y.upperBound) / 2
        return CGSize(width: daysNearest(predicted.width, [x.lowerBound, min(max(0, x.lowerBound), x.upperBound), x.upperBound]),
                      height: daysNearest(predicted.height, [y.lowerBound, middle, y.upperBound]))
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("daysPrompterStage"))
            .onChanged { value in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragging = true
                    moving = value.translation
                }
            }
            .onEnded { value in
                let projected = CGSize(
                    width: prompter.position.width + value.translation.width
                        + (value.predictedEndTranslation.width - value.translation.width) * 0.6,
                    height: prompter.position.height + value.translation.height
                        + (value.predictedEndTranslation.height - value.translation.height) * 0.6
                )
                let target = snap(projected)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.interpolatingSpring(stiffness: 260, damping: 26)) {
                    prompter.position = target
                    moving = .zero
                    dragging = false
                }
            }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("daysPrompterStage"))
            .onChanged { value in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragging = true
                    resizing = value.translation
                }
            }
            .onEnded { _ in
                let final = size
                var position = prompter.position
                position.width += (final.width - committed.width) / 2
                var widthSnap = final.width
                let full = fit(CGSize(width: CGFloat.infinity, height: 0)).width
                if full - final.width < 28 {
                    widthSnap = full
                }
                let snapped = CGSize(width: widthSnap, height: final.height)
                position.width += (snapped.width - final.width) / 2
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.interpolatingSpring(stiffness: 260, damping: 26)) {
                    prompter.cardSize = snapped
                    resizing = .zero
                    prompter.position = clamp(position, fit(snapped))
                    dragging = false
                }
            }
    }

    private var corner: some View {
        Path { path in
            path.move(to: CGPoint(x: 14, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: 14), control: CGPoint(x: 14, y: 14))
        }
        .stroke(.white.opacity(dragging && resizing != .zero ? 0.9 : 0.45),
                style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .frame(width: 14, height: 14)
        .padding(10)
        .frame(width: 60, height: 60, alignment: .bottomTrailing)
        .contentShape(Rectangle())
        .highPriorityGesture(resize)
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            DaysPrompterText(size: resizing == .zero ? size : committed)
                .id(prompter.generation)
                .transition(.opacity)
            if let countdown = prompter.countdown {
                Text("\(countdown)")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !prompter.playing, !prompter.paragraphs.isEmpty, recording {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 15)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(daysPrompterCard.opacity(prompter.alpha)))
        .scaleEffect(dragging && resizing == .zero ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: dragging)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            if prompter.paragraphs.isEmpty || (!recording && !prompter.running) {
                showEditor = true
            } else {
                prompter.toggle()
            }
        }
        .highPriorityGesture(move)
        .overlay(alignment: .topTrailing) {
            Button {
                prompter.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .bottomLeading) {
            Button {
                prompter.tune.toggle()
            } label: {
                Image(systemName: "switch.2")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(prompter.tune ? 1 : 0.85))
                    .padding(.leading, 14)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .bottomTrailing) {
            corner
        }
    }

    var body: some View {
        if prompter.shown {
            let offset = liveOffset
            let below = top + offset.height + size.height + 148 <= screen.height
            card
                .overlay(alignment: .bottomLeading) {
                    if prompter.tune, !dragging {
                        DaysPrompterKnobs()
                            .frame(height: 140)
                            .offset(y: below ? 148 : -44)
                    }
                }
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, top)
                .coordinateSpace(name: "daysPrompterStage")
                .fullScreenCover(isPresented: $showEditor) {
                    DaysPrompterEditor()
                }
        }
    }
}

struct DaysPrompterEditor: View {
    @ObservedObject var prompter = DaysPrompter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DaysPrompter.shared.script
    @State private var more = false
    @FocusState private var focused: Bool

    private func capsule(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var extras: some View {
        let words = draft.split(whereSeparator: \.isWhitespace).count
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(daysPrompterParagraphs(draft).count) paragraphs · \(words) words · "
                + "~\(max(1, (words + 75) / 150)) min aloud")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Toggle("3-2-1 countdown", isOn: $prompter.countdownOn)
            Toggle("Start scrolling with the take", isOn: $prompter.autoStart)
            VStack(alignment: .leading, spacing: 6) {
                Text("Card opacity").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                DaysFatSlider(value: $prompter.alpha, range: 0.2 ... 1)
            }
            HStack {
                capsule("Back to top") {
                    prompter.reset()
                }
                capsule("Reset card") {
                    prompter.position = .zero
                    prompter.cardSize = CGSize(width: 560, height: 200)
                }
                Spacer()
                capsule("Paste") {
                    if let text = UIPasteboard.general.string {
                        draft = text
                    }
                }
            }
        }
        .font(.system(size: 15))
        .tint(.white.opacity(0.5))
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                capsule("More") {
                    focused = more
                    more.toggle()
                }
                Spacer()
                capsule("Done") {
                    if draft != prompter.script {
                        prompter.script = draft
                        prompter.reset()
                    }
                    dismiss()
                }
            }
            if more {
                extras
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                if draft.isEmpty {
                    Text("Add your script here…")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(daysPrompterEditorBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            focused = true
        }
    }
}
