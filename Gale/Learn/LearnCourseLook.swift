import SwiftUI
import GaleLearn

extension LearnCourseLook {
    /// The course's main colour.
    var color: Color { Color(hue: hue, saturation: 0.62, brightness: 0.88) }
    /// A deeper second colour, for gradients and badges.
    var color2: Color { Color(hue: hue2, saturation: 0.72, brightness: 0.74) }
    var gradient: LinearGradient {
        LinearGradient(colors: [color, color2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A little window onto a course: its own demo playing on a loop, framed in the course's colours.
/// Holds still on the first drawing when Reduce Motion is on.
struct LearnCoursePreview: View {
    let course: LearnCourse
    private let guide: LearnGuide?
    private let look: LearnCourseLook

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(course: LearnCourse) {
        self.course = course
        guide = LearnCourseStyle.previewGuide(for: course)
        look = LearnCourseStyle.look(for: course.id)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(look.gradient)
            if let guide {
                ZStack {
                    LearnPalette.paper
                    playing(guide)
                }
                .aspectRatio(CGFloat(max(0.5, guide.aspect)), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: course.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Image(systemName: course.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(look.color2, in: Circle())
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .offset(x: 6, y: 6)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func playing(_ guide: LearnGuide) -> some View {
        if reduceMotion || guide.frames.count < 2 {
            LearnGuideCanvas(guide: guide, frame: 0, style: .demo, showNotes: false)
        } else {
            let fps = Double(max(1, min(guide.fps, 24)))
            TimelineView(.animation(minimumInterval: 1.0 / fps)) { context in
                let frame = LearnCourseStyle.previewFrame(guide, at: context.date.timeIntervalSinceReferenceDate)
                LearnGuideCanvas(guide: guide, frame: frame, style: .demo, showNotes: false)
            }
        }
    }
}

/// A vertical line through the middle of its frame.
struct LearnRailLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

/// One stop on a course's path of lessons: a node on the rail (done, next, or later) and the lesson's card.
struct LearnLessonPathRow: View {
    enum Rail { case hidden, done, todo }

    let number: Int
    let lesson: LearnLesson
    let state: LearnPathState
    let stars: Int
    let look: LearnCourseLook
    let above: Rail
    let below: Rail

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        card
            .padding(.leading, 62)
            .padding(.vertical, 6)
            .overlay(alignment: .leading) {
                VStack(spacing: 0) {
                    segment(above)
                    node
                    segment(below)
                }
                .frame(width: 48)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Starts the lesson")
    }

    // MARK: Rail

    @ViewBuilder
    private func segment(_ rail: Rail) -> some View {
        switch rail {
        case .hidden:
            Color.clear.frame(width: 4)
        case .done:
            Rectangle().fill(look.color).frame(width: 4)
        case .todo:
            LearnRailLine()
                .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 7]))
                .frame(width: 4)
        }
    }

    private var node: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(look.gradient)
                Image(systemName: "checkmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
            case .next:
                Circle()
                    .stroke(look.color.opacity(pulse ? 0 : 0.55), lineWidth: 3)
                    .scaleEffect(pulse ? 1.55 : 1)
                Circle().fill(Color(.secondarySystemGroupedBackground))
                Circle().stroke(look.color, lineWidth: 3)
                Text("\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(look.color2)
            case .later:
                Circle().fill(Color(.secondarySystemGroupedBackground))
                Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                Text("\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .onAppear {
            guard state == .next, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    // MARK: Card

    private var card: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(lesson.title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    if state == .next {
                        Text("UP NEXT")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(look.gradient, in: Capsule())
                    }
                }
                Text(lesson.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label("\(lesson.minutes) min", systemImage: "clock")
                    Label("\(lesson.steps.count) steps", systemImage: "list.bullet")
                    if lesson.steps.contains(where: { $0.kind == .animate }) {
                        Label("Animate", systemImage: "pencil.and.scribble")
                    }
                    if state == .done { LearnStarsView(count: stars, size: 11) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: state == .next ? "play.circle.fill" : "chevron.right")
                .font(state == .next ? Font.title2 : Font.footnote.weight(.semibold))
                .foregroundStyle(state == .next ? AnyShapeStyle(look.color) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(look.color.opacity(state == .next ? 0.7 : 0), lineWidth: 2)
        )
    }

    private var accessibilityText: String {
        let where_: String
        switch state {
        case .done: where_ = "done, \(stars) of 3 stars"
        case .next: where_ = "up next"
        case .later: where_ = "not started"
        }
        return "Lesson \(number), \(lesson.title), \(where_). \(lesson.summary)"
    }
}
