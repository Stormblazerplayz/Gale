import SwiftUI
import GaleLearn

/// Gale's free built-in courses: tracks → courses → lessons.
/// Show it inside a NavigationStack (courses open with a push, lessons open full screen).
struct LearnHomeView: View {
    @StateObject private var store = LearnStore()
    @State private var playing: LearnLesson?

    var body: some View {
        Group {
            if let library = store.library {
                home(library)
            } else if let error = store.loadError {
                ContentUnavailableView("The lessons didn't load", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView("Getting your lessons ready…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Learn")
        .task { await store.load() }
        .fullScreenCover(item: $playing) { lesson in
            LearnLessonPlayer(store: store, lesson: lesson) { playing = nil }
        }
    }

    private func home(_ library: LearnCourseLibrary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                LearnStatsRow(streak: store.streak, stars: store.totalStars,
                              done: store.progress.completedCount, total: library.lessons.count)
                if let saveError = store.saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                LearnUpNextCard(store: store) { lesson in playing = lesson }
                ForEach(library.tracks) { track in
                    LearnTrackSection(store: store, track: track)
                }
                Text("Everything here is free and works offline. Your stars are saved only on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Home pieces

struct LearnStatsRow: View {
    let streak: Int
    let stars: Int
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            LearnStatPill(symbol: "flame.fill", color: .orange,
                          value: "\(streak)", label: "day streak")
            LearnStatPill(symbol: "star.fill", color: LearnStarsView.gold, value: "\(stars)", label: stars == 1 ? "star" : "stars")
            LearnStatPill(symbol: "checkmark.circle.fill", color: Theme.accent, value: "\(done)/\(total)", label: "lessons")
        }
    }
}

struct LearnStatPill: View {
    let symbol: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.headline.monospacedDigit())
                    .fontDesign(.rounded)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The next lesson to do, with a big Start button.
struct LearnUpNextCard: View {
    @ObservedObject var store: LearnStore
    let start: (LearnLesson) -> Void

    var body: some View {
        if let next = store.nextUp {
            let started = store.progress.completedCount > 0
            VStack(alignment: .leading, spacing: 12) {
                Text(started ? "UP NEXT" : "START HERE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                VStack(alignment: .leading, spacing: 4) {
                    Text(next.lesson.title)
                        .font(.title2.weight(.bold))
                        .fontDesign(.rounded)
                    Text("\(next.course.title) · \(next.lesson.minutes) min")
                        .font(.subheadline.weight(.medium))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                Text(next.lesson.summary)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Button { start(next.lesson) } label: {
                    Label(started ? "Keep going" : "Start your first lesson", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(Theme.accent)
                .controlSize(.large)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else if store.library != nil {
            HStack(spacing: 14) {
                Image(systemName: "trophy.fill")
                    .font(.largeTitle)
                    .foregroundStyle(LearnStarsView.gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text("You finished every open lesson!")
                        .font(.headline)
                    Text("Go back to any lesson to earn more stars, or make something of your own.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

struct LearnTrackSection: View {
    @ObservedObject var store: LearnStore
    let track: LearnTrack

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: track.symbol)
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.title2.weight(.bold))
                        .fontDesign(.rounded)
                    Text(track.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(track.courses) { course in
                    NavigationLink {
                        LearnCourseView(store: store, courseID: course.id)
                    } label: {
                        LearnCourseCard(course: course,
                                        done: store.progress.completedCount(in: course),
                                        stars: course.lessons.reduce(0) { $0 + store.stars(for: $1) },
                                        locked: !store.isUnlocked(course),
                                        missing: store.missingCourses(for: course))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct LearnCourseCard: View {
    let course: LearnCourse
    let done: Int
    let stars: Int
    let locked: Bool
    let missing: [String]

    private var total: Int { course.lessons.count }
    private var finished: Bool { total > 0 && done >= total }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(locked ? Color.secondary.opacity(0.12) : Theme.accent.opacity(0.14))
                Image(systemName: course.symbol)
                    .font(.title2)
                    .foregroundStyle(locked ? Color.secondary : Theme.accent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(course.title)
                        .font(.headline)
                    Spacer(minLength: 4)
                    if locked {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    } else if finished {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
                Text(course.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if locked && !missing.isEmpty {
                    Text("Finish \(LearnWords.list(missing)) first. You can still peek.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: Double(min(done, total)), total: Double(max(1, total)))
                        .tint(Theme.accent)
                    HStack {
                        Text("\(done) of \(total) lessons")
                        Spacer()
                        Label("\(stars)", systemImage: "star.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(stars > 0 ? LearnStarsView.gold : Color.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint(locked ? "Locked. Opens a preview." : "Opens the course")
    }
}

enum LearnWords {
    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

// MARK: - Course

/// One course: its lessons in order.
struct LearnCourseView: View {
    @ObservedObject var store: LearnStore
    let courseID: String

    @State private var playing: LearnLesson?
    @State private var askEarly: LearnLesson?

    var body: some View {
        Group {
            if let course = store.library?.course(id: courseID) {
                content(course)
                    .navigationTitle(course.title)
            } else {
                ContentUnavailableView("Course not found", systemImage: "questionmark.folder")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .fullScreenCover(item: $playing) { lesson in
            LearnLessonPlayer(store: store, lesson: lesson) { playing = nil }
        }
        .confirmationDialog("Open this lesson early?",
                            isPresented: Binding(get: { askEarly != nil }, set: { if !$0 { askEarly = nil } }),
                            titleVisibility: .visible, presenting: askEarly) { lesson in
            Button("Open anyway") { openLater(lesson) }
            Button("Not now", role: .cancel) {}
        } message: { _ in
            Text("This lesson uses things from the lessons before it. It's easier if you do those first.")
        }
    }

    private func content(_ course: LearnCourse) -> some View {
        let unlocked = store.isUnlocked(course)
        let missing = store.missingCourses(for: course)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: course.symbol)
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 60, height: 60)
                        .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(course.title)
                            .font(.title.weight(.bold))
                            .fontDesign(.rounded)
                        Text(course.subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        let done = store.progress.completedCount(in: course)
                        ProgressView(value: Double(min(done, course.lessons.count)), total: Double(max(1, course.lessons.count)))
                            .tint(Theme.accent)
                            .padding(.top, 4)
                        Text("\(done) of \(course.lessons.count) lessons done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !unlocked && !missing.isEmpty {
                    Label("This course builds on \(LearnWords.list(missing)). You can look around, but it's easier after that.",
                          systemImage: "lock.fill")
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                VStack(spacing: 10) {
                    ForEach(Array(course.lessons.enumerated()), id: \.element.id) { i, lesson in
                        let open = store.isUnlocked(lesson, in: course)
                        Button {
                            if open { playing = lesson } else { askEarly = lesson }
                        } label: {
                            LearnLessonRow(number: i + 1, lesson: lesson, done: store.isDone(lesson),
                                           stars: store.stars(for: lesson), locked: !open)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    /// Waits for the question to close before opening the lesson full screen.
    private func openLater(_ lesson: LearnLesson) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            playing = lesson
        }
    }
}

struct LearnLessonRow: View {
    let number: Int
    let lesson: LearnLesson
    let done: Bool
    let stars: Int
    let locked: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.16) : (locked ? Color.secondary.opacity(0.12) : Theme.accent.opacity(0.14)))
                if done {
                    Image(systemName: "checkmark").font(.headline).foregroundStyle(.green)
                } else if locked {
                    Image(systemName: "lock.fill").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("\(number)").font(.headline.monospacedDigit()).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title)
                    .font(.headline)
                    .foregroundStyle(locked ? Color.secondary : Color.primary)
                Text(lesson.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label("\(lesson.minutes) min", systemImage: "clock")
                    Label("\(lesson.steps.count) steps", systemImage: "list.bullet")
                    if done { LearnStarsView(count: stars, size: 11) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint(locked ? "Locked. You can still open it." : "Starts the lesson")
    }
}
