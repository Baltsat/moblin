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

struct DaysPrompterOverlay: View {
    @ObservedObject var prompter = DaysPrompter.shared
    let screen: CGSize
    let recording: Bool
    @State private var frames: [Int: ClosedRange<CGFloat>] = [:]
    @State private var moving: CGSize = .zero
    @State private var resizing: CGSize = .zero
    @State private var showEditor = false

    private var portrait: Bool {
        screen.height >= screen.width
    }

    private var size: CGSize {
        let width = min(max(prompter.cardSize.width + resizing.width, 240), screen.width - (portrait ? 16 : 340))
        let height = min(max(prompter.cardSize.height + resizing.height, 110), screen.height * 0.7)
        return CGSize(width: width, height: height)
    }

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

    private var text: some View {
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

    private var corner: some View {
        Path { path in
            path.move(to: CGPoint(x: 10, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: 10), control: CGPoint(x: 10, y: 10))
        }
        .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .frame(width: 10, height: 10)
        .padding(9)
        .frame(width: 40, height: 40, alignment: .bottomTrailing)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { resizing = $0.translation }
            .onEnded { _ in
                prompter.cardSize = size
                resizing = .zero
            })
    }

    private var card: some View {
        ZStack(alignment: .top) {
            text
                .id(prompter.generation)
                .transition(.opacity)
            if let countdown = prompter.countdown {
                Text("\(countdown)")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxHeight: .infinity)
            } else if !prompter.playing, !prompter.paragraphs.isEmpty, recording {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 15)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(daysPrompterCard.opacity(prompter.alpha)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            if prompter.paragraphs.isEmpty || (!recording && !prompter.running) {
                showEditor = true
            } else {
                prompter.toggle()
            }
        }
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { moving = $0.translation }
            .onEnded { _ in
                prompter.position = clamp(CGSize(width: prompter.position.width + moving.width,
                                                 height: prompter.position.height + moving.height))
                moving = .zero
            })
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

    private func clamp(_ offset: CGSize) -> CGSize {
        let maxX = max((screen.width - size.width) / 2, 0)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -top), max(screen.height - size.height - top, 0)))
    }

    private var top: CGFloat {
        portrait ? 8 : 100
    }

    var body: some View {
        if prompter.shown {
            let offset = clamp(CGSize(width: prompter.position.width + moving.width,
                                      height: prompter.position.height + moving.height))
            let below = top + offset.height + size.height + 148 <= screen.height
            card
                .overlay(alignment: .bottomLeading) {
                    if prompter.tune {
                        DaysPrompterKnobs()
                            .frame(height: 140)
                            .offset(y: below ? 148 : -44)
                    }
                }
                .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, top)
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
