import SwiftUI
import WidgetKit

private struct IconAndTextView: View {
    let image: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: image)
                .frame(width: 20)
            Text(text)
        }
        .foregroundColor(.white)
    }
}

private struct MoblinLiveActivityStatusLabel: View {
    let state: LiveActivityAttributes.ContentState

    var body: some View {
        ForEach(state.functions, id: \.image) { function in
            IconAndTextView(image: function.image, text: function.text)
        }
        if state.showEllipsis {
            HStack {
                Image(systemName: "record.circle")
                    .frame(width: 20)
                    .foregroundColor(.clear)
                Text(String("..."))
                    .foregroundColor(.white)
            }
        }
    }
}

private let daysRed = Color(red: 0xE5 / 255, green: 0x09 / 255, blue: 0x14 / 255)

private struct DaysMark: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(daysRed).frame(width: 9, height: 9)
            Text(verbatim: "DAYS")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3)
                .foregroundColor(daysRed)
        }
    }
}

private struct DaysTimer: View {
    let since: Date?
    var size: CGFloat = 17

    var body: some View {
        if let since {
            Text(timerInterval: since ... Date.distantFuture, countsDown: false)
                .font(.system(size: size, weight: .light).monospacedDigit())
                .foregroundColor(.white)
                .multilineTextAlignment(.trailing)
        }
    }
}

@main
struct MoblinLiveActivityApp: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    DaysMark()
                    Spacer()
                    DaysTimer(since: context.state.since, size: 20)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
                Text(context.state.line ?? "Days is running in background")
                    .font(.system(size: 17, weight: .semibold))
                    .italic(context.state.line != nil)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundColor(.white)
                if !context.state.functions.isEmpty || context.state.showEllipsis {
                    MoblinLiveActivityStatusLabel(state: context.state)
                        .font(.system(size: 13))
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DaysMark()
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DaysTimer(since: context.state.since)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.line ?? "Days is running in background")
                        .font(.system(size: 15, weight: .semibold))
                        .italic(context.state.line != nil)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundColor(.white)
                }
            } compactLeading: {
                Circle().fill(daysRed).frame(width: 9, height: 9)
            } compactTrailing: {
                DaysTimer(since: context.state.since, size: 14)
                    .frame(maxWidth: 52)
            } minimal: {
                Circle().fill(daysRed).frame(width: 9, height: 9)
            }
        }
    }
}
