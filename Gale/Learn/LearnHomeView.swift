import SwiftUI
import GaleLearn

/// Gale's free built-in courses: tracks → courses → lessons.
/// Show it inside a NavigationStack (courses open with a push, lessons open full screen).
struct LearnHomeView: View {
    @StateObject private var store = LearnStore()
    @State private var playing: LearnLesson?
    // Passed into the full-screen lesson so "animate it" steps can open the real editor.
    @EnvironmentObject private var projects: ProjectLibrary
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var sync: SyncManager

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
                .environmentObject(projects)
                .environmentObject(libraryStore)
                .environmentObject(sync)
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
                                        tip: store.missingCourses(for: course))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("learnCourse-\(course.id)")
                }
            }
        }
    }
}

struct LearnCourseCard: View {
    let course: LearnCourse
    let done: Int
    let stars: Int
    /// Courses that make this one easier, if they aren't done yet (a tip only: every course is open).
    let tip: [String]

    private var total: Int { course.lessons.count }
    private var finished: Bool { total > 0 && done >= total }
    private var look: LearnCourseLook { LearnCourseStyle.look(for: course.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LearnCoursePreview(course: course)
                .frame(width: 112, height: 86)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(course.title)
                        .font(.headline)
                    Spacer(minLength: 4)
                    if finished {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
                Text(course.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: Double(min(done, total)), total: Double(max(1, total)))
                    .tint(look.color)
                HStack {
                    Text("\(done) of \(total) lessons")
                    Spacer()
                    Label("\(stars)", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(stars > 0 ? LearnStarsView.gold : Color.secondary)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                if !tip.isEmpty && done == 0 {
                    Label("Easier after \(LearnWords.list(tip))", systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [look.color.opacity(0.16), look.color.opacity(0.02)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(look.color.opacity(0.25), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the course")
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
    @EnvironmentObject private var projects: ProjectLibrary
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var sync: SyncManager

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
                .environmentObject(projects)
                .environmentObject(libraryStore)
                .environmentObject(sync)
        }
    }

    private func content(_ course: LearnCourse) -> some View {
        let missing = store.missingCourses(for: course)
        let look = LearnCourseStyle.look(for: course.id)
        let states = LearnCourseStyle.pathStates(lessonIDs: course.lessons.map(\.id)) { store.progress.isCompleted($0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    LearnCoursePreview(course: course)
                        .frame(width: 150, height: 114)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(course.title)
                            .font(.title.weight(.bold))
                            .fontDesign(.rounded)
                        Text(course.subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        let done = store.progress.completedCount(in: course)
                        ProgressView(value: Double(min(done, course.lessons.count)), total: Double(max(1, course.lessons.count)))
                            .tint(look.color)
                            .padding(.top, 4)
                        Text("\(done) of \(course.lessons.count) lessons done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !missing.isEmpty && store.progress.completedCount(in: course) == 0 {
                    Label("Tip: this course is easier after \(LearnWords.list(missing)), but you can start right away.",
                          systemImage: "lightbulb")
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(look.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                // The lessons as a path: done ones joined by a solid line, the next one pulsing.
                VStack(spacing: 0) {
                    ForEach(Array(course.lessons.enumerated()), id: \.element.id) { i, lesson in
                        Button {
                            playing = lesson
                        } label: {
                            LearnLessonPathRow(
                                number: i + 1, lesson: lesson, state: states[i], stars: store.stars(for: lesson),
                                look: look,
                                above: i == 0 ? .hidden : (states[i - 1] == .done ? .done : .todo),
                                below: i == course.lessons.count - 1 ? .hidden : (states[i] == .done ? .done : .todo))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("learnLesson-\(lesson.id)")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }
}
