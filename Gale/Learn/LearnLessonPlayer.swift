import SwiftUI
import UIKit
import GaleLearn

/// Plays a lesson full screen. "Next lesson" and "Try again" swap in a fresh session.
struct LearnLessonPlayer: View {
    @ObservedObject var store: LearnStore
    let onClose: () -> Void

    @State private var current: LearnLesson
    @State private var attempt = 0

    init(store: LearnStore, lesson: LearnLesson, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _current = State(initialValue: lesson)
    }

    var body: some View {
        LearnLessonSession(store: store, lesson: current, onClose: onClose,
                           onNext: { next in
                               attempt = 0
                               current = next
                           },
                           onReplay: { attempt += 1 })
            .id("\(current.id)#\(attempt)")
    }
}

enum LearnFramesMode: Hashable {
    case watch, draw
}

/// One go through a lesson.
struct LearnLessonSession: View {
    @ObservedObject var store: LearnStore
    let lesson: LearnLesson
    let onClose: () -> Void
    let onNext: (LearnLesson) -> Void
    let onReplay: () -> Void

    @State private var run: LearnLessonRun
    @StateObject private var book = LearnInkBook()
    @State private var feedback: LearnFeedback?
    @State private var quizChoice: Int?
    @State private var wrongChoices: Set<Int> = []
    @State private var framesMode: LearnFramesMode = .watch
    @State private var confirmLeave = false
    @State private var result: LearnLessonResult?

    init(store: LearnStore, lesson: LearnLesson, onClose: @escaping () -> Void,
         onNext: @escaping (LearnLesson) -> Void, onReplay: @escaping () -> Void) {
        self.store = store
        self.lesson = lesson
        self.onClose = onClose
        self.onNext = onNext
        self.onReplay = onReplay
        _run = State(initialValue: LearnLessonRun(lesson: lesson))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if !lesson.steps.isEmpty {
                stepContent
                    .id(run.step.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                Spacer()
            }
            if let fb = feedback {
                LearnFeedbackBanner(feedback: fb) {
                    withAnimation(.easeOut(duration: 0.2)) { feedback = nil }
                }
            }
            actionBar
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay {
            if let result {
                LearnCelebration(result: result, saveError: store.saveError,
                                 onNext: onNext, onReplay: onReplay, onDone: onClose)
                    .transition(.opacity)
            }
        }
        .confirmationDialog("Leave this lesson?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { onClose() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("This lesson isn't finished, so it won't be saved yet.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                if run.progress > 0 && !run.isFinished { confirmLeave = true } else { onClose() }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close lesson")

            VStack(alignment: .leading, spacing: 5) {
                Text(lesson.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                ProgressView(value: run.progress)
                    .tint(Theme.accent)
                    .animation(.easeInOut(duration: 0.3), value: run.progress)
            }
            Text("\(min(run.index + 1, max(1, run.stepCount))) / \(max(1, run.stepCount))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Step \(min(run.index + 1, max(1, run.stepCount))) of \(max(1, run.stepCount))")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        let step = run.step
        switch step.kind {
        case .read:
            LearnReadStepView(step: step)
        case .quiz:
            LearnQuizStepView(step: step, choice: $quizChoice, wrongChoices: wrongChoices, solved: run.record.passed)
        case .tool:
            LearnToolStepView(step: step)
        case .trace:
            VStack(spacing: 12) {
                LearnStepHeader(step: step, compact: true)
                if let guide = step.guide {
                    LearnTracePad(guide: guide, ink: book.ink(for: step))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        case .frames:
            VStack(spacing: 10) {
                LearnStepHeader(step: step, compact: true)
                Picker("Mode", selection: $framesMode) {
                    Text("Watch").tag(LearnFramesMode.watch)
                    Text("Draw").tag(LearnFramesMode.draw)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                if let guide = step.guide {
                    if framesMode == .watch {
                        LearnGuidePlayer(guide: guide)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { framesMode = .draw }
                        } label: {
                            Label("Start drawing \(guide.frames.count) frames", systemImage: "pencil.tip.crop.circle")
                                .font(.headline)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                    } else {
                        LearnFramesPad(guide: guide, ink: book.ink(for: step))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: Buttons

    private var needsCheck: Bool {
        run.step.kind.isScored && !run.record.passed
    }

    private var hasAnswer: Bool {
        let step = run.step
        switch step.kind {
        case .trace: return !book.ink(for: step).isEmpty
        case .frames: return book.ink(for: step).drawnFrameCount > 0
        case .quiz:
            guard let c = quizChoice else { return false }
            return !wrongChoices.contains(c)
        case .read, .tool: return true
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if run.canGoBack {
                Button { goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Spacer(minLength: 0)
            if run.canSkip {
                Button("Skip") { skip() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityHint("Moves on without stars for this step")
            }
            if needsCheck {
                Button { check() } label: {
                    Label("Check", systemImage: "checkmark")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accent)
                .disabled(!hasAnswer)
            } else {
                Button { next() } label: {
                    Label(run.isLastStep ? "Finish" : "Next", systemImage: run.isLastStep ? "flag.checkered" : "chevron.right")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accent)
                .disabled(!run.canAdvance)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Actions

    private func check() {
        let step = run.step
        let answer: LearnAnswer
        switch step.kind {
        case .trace: answer = .strokes(book.ink(for: step).answerFrames.first ?? [])
        case .frames: answer = .frames(book.ink(for: step).answerFrames)
        case .quiz: answer = .choice(quizChoice ?? -1)
        case .read, .tool: answer = .done
        }
        let fb = run.submit(answer)
        if step.kind == .quiz, !fb.passed, let c = quizChoice {
            wrongChoices.insert(c)
            quizChoice = nil
        }
        UINotificationFeedbackGenerator().notificationOccurred(fb.passed ? .success : .warning)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { feedback = fb }
    }

    private func next() {
        guard run.canAdvance else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            run.advance()
            resetStepState()
        }
        if run.isFinished { finish() }
    }

    private func goBack() {
        withAnimation(.easeInOut(duration: 0.2)) {
            run.back()
            resetStepState()
        }
    }

    private func skip() {
        withAnimation(.easeInOut(duration: 0.2)) {
            run.skip()
            resetStepState()
        }
        if run.isFinished { finish() }
    }

    private func resetStepState() {
        feedback = nil
        quizChoice = nil
        wrongChoices = []
        if !lesson.steps.isEmpty, run.step.kind == .frames {
            framesMode = book.ink(for: run.step).isEmpty ? .watch : .draw
        } else {
            framesMode = .watch
        }
    }

    private func finish() {
        let stars = run.stars
        let opened = store.finish(lesson, stars: stars)
        let next = store.lesson(after: lesson)
        withAnimation(.easeInOut(duration: 0.25)) {
            result = LearnLessonResult(lesson: lesson, stars: stars, opened: opened, next: next)
        }
    }
}

/// How a finished lesson went.
struct LearnLessonResult {
    let lesson: LearnLesson
    let stars: Int
    let opened: [LearnCourse]
    let next: LearnLesson?
}

// MARK: - Feedback

struct LearnStarsView: View {
    let count: Int
    var total = 3
    var size: CGFloat = 14

    static let gold = Color(red: 1.0, green: 0.74, blue: 0.1)

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(0..<max(0, total), id: \.self) { i in
                Image(systemName: i < count ? "star.fill" : "star")
                    .foregroundStyle(i < count ? LearnStarsView.gold : Color.secondary.opacity(0.45))
            }
        }
        .font(.system(size: size, weight: .semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) of \(total) stars")
    }
}

/// What the check said, plus a hint after a miss.
struct LearnFeedbackBanner: View {
    let feedback: LearnFeedback
    let onClose: () -> Void

    var body: some View {
        let tone: Color = feedback.passed ? .green : .orange
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feedback.passed ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(feedback.title).font(.headline)
                    if feedback.passed && feedback.stars > 0 {
                        LearnStarsView(count: feedback.stars, size: 14)
                    }
                }
                if !feedback.message.isEmpty {
                    Text(feedback.message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !feedback.passed, let hint = feedback.hint, !hint.isEmpty {
                    Label {
                        Text(hint).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    }
                    .font(.subheadline)
                }
                if feedback.canSkip {
                    Text("Stuck? You can skip this step and come back to it later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Hide message")
        }
        .padding(14)
        .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tone.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Celebration

/// The end of a lesson: stars pop in one by one. Simple and calm, no confetti.
struct LearnCelebration: View {
    let result: LearnLessonResult
    let saveError: String?
    let onNext: (LearnLesson) -> Void
    let onReplay: () -> Void
    let onDone: () -> Void

    @State private var shown = 0
    @State private var appeared = false

    private var cheer: String {
        switch result.stars {
        case 3: return "All three stars. Amazing work!"
        case 2: return "Two stars. Really nice!"
        default: return "Lesson done. Try again any time for more stars."
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.gradient)
                        .scaleEffect(appeared ? 1 : 0.6)
                    VStack(spacing: 4) {
                        Text("Lesson done!")
                            .font(.title.weight(.bold))
                            .fontDesign(.rounded)
                        Text(result.lesson.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { i in
                            let earned = i < result.stars
                            Image(systemName: earned ? "star.fill" : "star")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(earned ? LearnStarsView.gold : Color.secondary.opacity(0.35))
                                .scaleEffect(earned ? (shown > i ? 1 : 0.2) : 1)
                                .opacity(earned ? (shown > i ? 1 : 0) : 1)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(result.stars) of 3 stars")
                    Text(cheer)
                        .font(.body)
                        .multilineTextAlignment(.center)

                    if !result.opened.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(result.opened.count == 1 ? "A new course is open" : "New courses are open")
                                .font(.subheadline.weight(.semibold))
                            ForEach(result.opened) { course in
                                Label(course.title, systemImage: course.symbol)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    VStack(spacing: 10) {
                        if let next = result.next {
                            Button { onNext(next) } label: {
                                VStack(spacing: 2) {
                                    Text("Next lesson").font(.headline)
                                    Text(next.title).font(.footnote).opacity(0.85)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(Theme.accent)
                        }
                        HStack(spacing: 10) {
                            if result.stars < 3 {
                                Button { onReplay() } label: {
                                    Label("Try again", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                            Button { onDone() } label: {
                                Text(result.next == nil ? "Done" : "Back to lessons").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 440)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
        .task {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { appeared = true }
            for i in 0..<max(0, result.stars) {
                try? await Task.sleep(nanoseconds: 280_000_000)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { shown = i + 1 }
            }
        }
    }
}
