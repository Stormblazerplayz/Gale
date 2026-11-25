import SwiftUI
import GaleFormat
import GaleLearn

/// What the learner animated in Gale for each "animate it" step of a lesson, in lesson units.
@MainActor
final class LearnStudioBook: ObservableObject {
    @Published private(set) var answers: [String: [[[LearnPoint]]]] = [:]

    func answer(for step: LearnStep) -> [[[LearnPoint]]] { answers[step.id] ?? [] }
    func drawnCount(for step: LearnStep) -> Int { LearnStudio.drawnFrameCount(answer(for: step)) }
    func set(_ frames: [[[LearnPoint]]], for step: LearnStep) { answers[step.id] = frames }
}

/// Animate it for real: opens a Gale project with the lesson's drawings on a locked guide layer,
/// lets the learner animate in the full editor, then shows what they drew, ready to check.
struct LearnAnimateStepView: View {
    let lesson: LearnLesson
    let step: LearnStep
    @ObservedObject var store: LearnStore
    @ObservedObject var studio: LearnStudioBook
    @ObservedObject var narrator: LearnNarrator

    @EnvironmentObject private var library: ProjectLibrary
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var sync: SyncManager

    @State private var document: ProjectDocument?
    @State private var showEditor = false
    @State private var error: String?
    @State private var confirmRestart = false
    @State private var showGuide = true

    private var guide: LearnGuide? { step.guide }
    private var drawn: Int { studio.drawnCount(for: step) }
    private var total: Int { guide?.frames.count ?? 0 }
    private var hasProject: Bool { existingURL != nil }
    private var existingURL: URL? {
        guard let id = store.studioProjectID(lesson: lesson, step: step) else { return nil }
        return library.url(forProjectID: id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LearnStepHeader(step: step, compact: true)
                if let guide {
                    preview(guide)
                    frameStrip(guide)
                    Text(drawn == 0 ? "\(total) frames to animate" : "You've drawn \(drawn) of \(total) frames")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(drawn >= total ? Color.green : Color.secondary)
                        .accessibilityIdentifier("learnAnimateCount")
                    Button { open() } label: {
                        Label(drawn > 0 || hasProject ? "Keep animating in Gale" : "Animate it in Gale",
                              systemImage: "pencil.and.scribble")
                            .font(.headline)
                            .frame(maxWidth: 420)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("learnOpenInGale")
                    if hasProject {
                        Button("Start over with a fresh project") { confirmRestart = true }
                            .font(.footnote)
                    }
                    tips
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .task { loadExisting() }
        .fullScreenCover(isPresented: $showEditor, onDismiss: editorClosed) {
            if let document {
                NavigationStack {
                    EditorView(document: document, store: libraryStore)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { showEditor = false } label: {
                                    Label("Back to lesson", systemImage: "graduationcap")
                                        .labelStyle(.titleAndIcon)
                                }
                                .accessibilityIdentifier("learnBackToLesson")
                            }
                        }
                }
                .environmentObject(library)
                .environmentObject(libraryStore)
                .environmentObject(sync)
                .tint(Theme.accent)
            }
        }
        .confirmationDialog("Start over?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Start over") { restart() }
            Button("Keep my animation", role: .cancel) {}
        } message: {
            Text("You'll get a fresh project for this step. Your old one stays in your projects.")
        }
    }

    // MARK: Pieces

    /// The guide with the learner's frames over it, playing at the lesson's speed.
    private func preview(_ guide: LearnGuide) -> some View {
        VStack(spacing: 6) {
            LearnPaper(aspect: guide.aspect) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let cycle = guide.loop ? guide.duration : guide.duration + 1.0
                    let local = t.truncatingRemainder(dividingBy: max(0.1, cycle))
                    let i = guide.frameIndex(atTime: min(local, max(0, guide.duration - 0.0001)))
                    LearnStudioFrame(guide: guide, frame: i, ink: frameInk(i), showGuide: showGuide || drawn == 0)
                }
            }
            .frame(maxWidth: 640)
            if drawn > 0 {
                Toggle("Show the guide", isOn: $showGuide)
                    .font(.footnote)
                    .frame(maxWidth: 240)
            }
        }
    }

    private func frameStrip(_ guide: LearnGuide) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(guide.frames.indices, id: \.self) { i in
                    let done = !frameInk(i).isEmpty
                    VStack(spacing: 3) {
                        LearnPaper(aspect: guide.aspect) {
                            LearnStudioFrame(guide: guide, frame: i, ink: frameInk(i), showGuide: true, small: true)
                        }
                        .frame(height: 54)
                        HStack(spacing: 3) {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done ? Color.green : Color.secondary)
                            Text("\(i + 1)").monospacedDigit()
                        }
                        .font(.caption2)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Frame \(i + 1), \(done ? "drawn" : "not drawn yet")")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            tip("square.3.layers.3d", "The faint drawings are on a locked layer called Lesson guide. Draw on Your animation.")
            tip("circle.dashed", "Turn on onion skin to see the frame before while you draw.")
            tip("play.fill", "Press play in Gale to watch your animation move.")
            tip("checkmark.circle", "Tap Back to lesson when you're done, then Check.")
        }
        .font(.footnote)
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
    }

    private func frameInk(_ i: Int) -> [[LearnPoint]] {
        let a = studio.answer(for: step)
        return a.indices.contains(i) ? a[i] : []
    }

    // MARK: Projects

    /// Reads back a project made for this step before (so work isn't lost between lessons).
    private func loadExisting() {
        guard studio.answers[step.id] == nil else { return }
        guard let id = store.studioProjectID(lesson: lesson, step: step) else { return }
        guard let url = library.url(forProjectID: id) else {
            // The project was deleted from the home screen: start fresh next time.
            store.setStudioProject(nil, lesson: lesson, step: step)
            return
        }
        if let project = try? GaleIO.readProject(at: url) {
            studio.set(LearnStudio.answerFrames(from: project), for: step)
        }
    }

    private func open() {
        narrator.stop()
        error = nil
        do {
            let url: URL
            if let existing = existingURL {
                url = existing
            } else {
                guard let project = LearnStudio.makeProject(for: step, lessonTitle: lesson.title) else {
                    error = "This step has nothing to animate."
                    return
                }
                url = library.freshFolder(for: project.name)
                try GaleIO.writeProject(project, to: url)
                library.reload()
                store.setStudioProject(project.id, lesson: lesson, step: step)
            }
            let doc = try ProjectDocument(folder: url)
            // Start on the learner's layer and the first frame.
            if let draw = LearnStudio.layerIDs(in: doc.project).draw { doc.currentLayerID = draw }
            doc.currentFrame = 0
            sync.attach(doc)
            document = doc
            showEditor = true
        } catch {
            self.error = "Gale couldn't open the project. (\(error.localizedDescription))"
        }
    }

    private func editorClosed() {
        guard let doc = document else { return }
        doc.saveNow()
        studio.set(LearnStudio.answerFrames(from: doc.project), for: step)
        sync.detach(doc)
        document = nil
        library.reload()
    }

    private func restart() {
        store.setStudioProject(nil, lesson: lesson, step: step)
        studio.set([], for: step)
        open()
    }
}

/// One frame: the guide faintly, and the learner's lines on top.
struct LearnStudioFrame: View {
    let guide: LearnGuide
    let frame: Int
    let ink: [[LearnPoint]]
    var showGuide = true
    var small = false

    var body: some View {
        Canvas { ctx, size in
            let space = LearnSpace(size: size, aspect: guide.aspect)
            if showGuide {
                LearnDraw.guidePaths(guide.background, in: &ctx, space: space, style: .scenery)
                if guide.frames.indices.contains(frame) {
                    LearnDraw.guidePaths(guide.frames[frame].paths, in: &ctx, space: space, style: small ? .scenery : .ghost)
                }
            }
            let width = max(small ? 0.8 : 1.5, space.scale * 0.009)
            for line in ink where !line.isEmpty {
                if line.count == 1 {
                    let c = space.point(line[0])
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - width / 2, y: c.y - width / 2, width: width, height: width)),
                             with: .color(LearnPalette.ink))
                } else {
                    ctx.stroke(LearnDraw.path(line, closed: false, space: space), with: .color(LearnPalette.ink),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
