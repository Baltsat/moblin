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
    @Published var speed: Double { didSet { reanchor(); defaults.set(speed, forKey: "daysPrompterSpeed") } }
    @Published var size: Double { didSet { defaults.set(size, forKey: "daysPrompterSize") } }
    @Published var width: Double { didSet { defaults.set(width, forKey: "daysPrompterWidth") } }
    @Published var backdrop: Double { didSet { defaults.set(backdrop, forKey: "daysPrompterBackdrop") } }
    @Published var countdownOn: Bool { didSet { defaults.set(countdownOn, forKey: "daysPrompterCountdown") } }
    @Published var autoStart: Bool { didSet { defaults.set(autoStart, forKey: "daysPrompterAutoStart") } }
    @Published var position: CGSize {
        didSet {
            defaults.set([position.width, position.height], forKey: "daysPrompterPosition")
        }
    }

    @Published private(set) var playing = false
    @Published private(set) var countdown: Int?
    private var anchorOffset: CGFloat = 0
    private var anchorDate = Date()
    var maxOffset: CGFloat = .greatestFiniteMagnitude
    private var countdownTask: Task<Void, Never>?

    private init() {
        shown = defaults.bool(forKey: "daysPrompterShown")
        script = defaults.string(forKey: "daysPrompterScript") ?? ""
        speed = defaults.object(forKey: "daysPrompterSpeed") as? Double ?? 4
        size = defaults.object(forKey: "daysPrompterSize") as? Double ?? 26
        width = defaults.object(forKey: "daysPrompterWidth") as? Double ?? 0.9
        backdrop = defaults.object(forKey: "daysPrompterBackdrop") as? Double ?? 0.55
        countdownOn = defaults.object(forKey: "daysPrompterCountdown") as? Bool ?? true
        autoStart = defaults.object(forKey: "daysPrompterAutoStart") as? Bool ?? true
        let saved = defaults.array(forKey: "daysPrompterPosition") as? [Double] ?? [0, 0]
        position = CGSize(width: saved.first ?? 0, height: saved.last ?? 0)
        paragraphs = daysPrompterParagraphs(script)
    }

    private var pointsPerSecond: CGFloat {
        CGFloat(6 + speed * 7) * CGFloat(size / 26)
    }

    func offset(at date: Date) -> CGFloat {
        guard playing else {
            return anchorOffset
        }
        return min(anchorOffset + CGFloat(date.timeIntervalSince(anchorDate)) * pointsPerSecond, maxOffset)
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

    func toggle() {
        if playing || countdown != nil {
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

    func scrub(to value: CGFloat) {
        anchorOffset = min(max(value, 0), maxOffset)
        anchorDate = Date()
    }

    func reset() {
        pause()
        anchorOffset = 0
    }

    func takeStarted() {
        guard shown, autoStart, !playing, countdown == nil else {
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

struct DaysPrompterOverlay: View {
    @ObservedObject var prompter = DaysPrompter.shared
    let screen: CGSize
    @State private var frames: [Int: ClosedRange<CGFloat>] = [:]
    @State private var scrubStart: CGFloat?
    @State private var dragStart: CGSize?
    @State private var moving: CGSize = .zero
    @State private var showEditor = false

    private var boxWidth: CGFloat {
        min(max(160, (screen.width - 24) * prompter.width), 600)
    }

    private var boxHeight: CGFloat {
        min(max(screen.height * 0.3, 150), 320)
    }

    private var readLine: CGFloat {
        boxHeight * 0.22
    }

    private func current(_ offset: CGFloat) -> Int {
        let line = offset + readLine + 4
        let ordered = frames.sorted { $0.key < $1.key }
        return ordered.last(where: { $0.value.lowerBound <= line })?.key ?? 0
    }

    private var text: some View {
        TimelineView(.animation(paused: !prompter.playing)) { context in
            let offset = prompter.offset(at: context.date)
            let active = current(offset)
            VStack(alignment: .leading, spacing: prompter.size * 0.7) {
                ForEach(Array(prompter.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .font(.system(size: prompter.size, weight: .semibold))
                        .lineSpacing(prompter.size * 0.18)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white.opacity(index == active ? 1 : 0.38))
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { proxy in
                            let frame = proxy.frame(in: .named("daysPrompter"))
                            Color.clear.preference(key: DaysParagraphFrames.self,
                                                   value: [index: frame.minY ... frame.maxY])
                        })
                        .animation(.easeOut(duration: 0.25), value: active)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, readLine)
            .padding(.bottom, boxHeight)
            .coordinateSpace(name: "daysPrompter")
            .offset(y: -offset)
            .onChange(of: prompter.reachedEnd(context.date)) { ended in
                if ended {
                    prompter.pause()
                }
            }
        }
        .onPreferenceChange(DaysParagraphFrames.self) { value in
            frames = value
            prompter.maxOffset = max((value.values.map(\.upperBound).max() ?? 0) - readLine - 20, 0)
        }
        .frame(width: boxWidth, height: boxHeight, alignment: .top)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.78),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    private var empty: some View {
        Button {
            showEditor = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "text.badge.plus").font(.system(size: 24))
                Text("Tap to add a script").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: boxWidth, height: boxHeight)
        }
        .buttonStyle(.plain)
    }

    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [.black.opacity(prompter.backdrop),
                                              .black.opacity(prompter.backdrop * 0.55)],
                                     startPoint: .top, endPoint: .bottom))
            if prompter.paragraphs.isEmpty {
                empty
            } else {
                text
            }
            if let countdown = prompter.countdown {
                Text("\(countdown)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
                    .transition(.scale.combined(with: .opacity))
                    .id(countdown)
            }
        }
        .frame(width: boxWidth, height: boxHeight)
        .overlay(RoundedRectangle(cornerRadius: 18)
            .stroke(.white.opacity(dragStart == nil ? 0 : 0.8), lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .highPriorityGesture(move)
        .gesture(scrub)
        .simultaneousGesture(TapGesture().onEnded {
            if !prompter.paragraphs.isEmpty {
                prompter.toggle()
            }
        })
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if scrubStart == nil {
                    prompter.pause()
                    scrubStart = prompter.offset(at: Date())
                }
                prompter.scrub(to: (scrubStart ?? 0) - value.translation.height)
            }
            .onEnded { _ in
                scrubStart = nil
            }
    }

    private var move: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case let .second(true, drag) = value {
                    if dragStart == nil {
                        dragStart = prompter.position
                    }
                    moving = drag?.translation ?? .zero
                }
            }
            .onEnded { _ in
                if let start = dragStart {
                    prompter.position = clamp(CGSize(width: start.width + moving.width,
                                                     height: start.height + moving.height))
                }
                dragStart = nil
                moving = .zero
            }
    }

    private func clamp(_ size: CGSize) -> CGSize {
        let maxX = max((screen.width - boxWidth) / 2, 0)
        return CGSize(width: min(max(size.width, -maxX), maxX),
                      height: min(max(size.height, -40), max(screen.height - boxHeight - 120, 0)))
    }

    var body: some View {
        if prompter.shown {
            let base = dragStart ?? prompter.position
            box
                .offset(clamp(CGSize(width: base.width + moving.width, height: base.height + moving.height)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 76)
                .sheet(isPresented: $showEditor) {
                    DaysPrompterEditor()
                }
        }
    }
}

struct DaysPrompterControls: View {
    @ObservedObject var prompter = DaysPrompter.shared
    @State private var showEditor = false

    private func slider(_ icon: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)
            Slider(value: value, in: range)
                .frame(width: 120)
                .tint(.white)
        }
    }

    var body: some View {
        if prompter.shown {
            HStack(spacing: 10) {
                Button {
                    prompter.toggle()
                } label: {
                    Image(systemName: prompter.playing || prompter.countdown != nil ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.15), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    slider("hare", $prompter.speed, 1 ... 10)
                    slider("textformat.size", $prompter.size, 16 ... 48)
                }
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.15), in: Circle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 22))
            .environment(\.colorScheme, .dark)
            .sheet(isPresented: $showEditor) {
                DaysPrompterEditor()
            }
        }
    }
}

struct DaysPrompterEditor: View {
    @ObservedObject var prompter = DaysPrompter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DaysPrompter.shared.script

    private var preview: [String] {
        daysPrompterParagraphs(draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 220)
                    HStack {
                        Button("Paste") {
                            if let text = UIPasteboard.general.string {
                                draft = text
                            }
                        }
                        Spacer()
                        Button("Clear", role: .destructive) {
                            draft = ""
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Script")
                } footer: {
                    Text("\(preview.count) paragraphs, \(draft.split(whereSeparator: \.isWhitespace).count) words. "
                        + "Paste any text: it is split into short paragraphs. A blank line always starts a new one.")
                }
                Section("Scroll") {
                    LabeledContent("Speed") {
                        Slider(value: $prompter.speed, in: 1 ... 10)
                    }
                    LabeledContent("Text size") {
                        Slider(value: $prompter.size, in: 16 ... 48)
                    }
                    LabeledContent("Width") {
                        Slider(value: $prompter.width, in: 0.5 ... 1)
                    }
                    LabeledContent("Backdrop") {
                        Slider(value: $prompter.backdrop, in: 0 ... 0.9)
                    }
                    Toggle("3-2-1 countdown", isOn: $prompter.countdownOn)
                    Toggle("Start scrolling with the take", isOn: $prompter.autoStart)
                    Button("Back to the top") {
                        prompter.reset()
                    }
                    Button("Reset position") {
                        prompter.position = .zero
                    }
                }
                if !preview.isEmpty {
                    Section("Paragraphs") {
                        ForEach(Array(preview.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph).font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Teleprompter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if draft != prompter.script {
                            prompter.script = draft
                            prompter.reset()
                        }
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
