import CoreGraphics
import GaleCore
import GaleFormat
import PhotosUI
import SwiftUI
import UIKit

// BODY SCAN → CHARACTER CONCEPTS
// Scan your body (3D camera, selfie camera or a photo), then get character ideas in your own
// proportions and pose. Everything happens on this device. The scan is only kept in memory
// until you leave this screen, unless you save a concept.

/// Which camera screen is open.
enum ScanMode: String, Identifiable {
    case ar, front, back
    var id: String { rawValue }
}

/// Lets CGImages cross into background tasks (they never change after they're made).
struct ScanImages: @unchecked Sendable {
    var images: [String: CGImage] = [:]
}

struct ScanImageBox: @unchecked Sendable {
    let image: CGImage?
}

struct ScanView: View {
    let onOpenProject: (URL) -> Void

    @EnvironmentObject var library: ProjectLibrary
    @EnvironmentObject var store: LibraryStore

    @State private var scanned: ScanBody?
    @State private var concepts: [ScanConcept] = []
    @State private var thumbs = ScanImages()
    @State private var filter: ScanStyle?
    @State private var seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    @State private var generation = 0
    @State private var making = false
    @State private var working = false
    @State private var problem: String?
    @State private var mode: ScanMode?
    @State private var permission = ScanCameraPermission.current
    @State private var photoItem: PhotosPickerItem?
    @State private var selected: ScanConcept?
    @State private var openAfterSheet: URL?

    init(onOpenProject: @escaping (URL) -> Void) {
        self.onOpenProject = onOpenProject
    }

    static let panel = Color(uiColor: .secondarySystemBackground)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let problem {
                    problemCard(problem)
                }
                if working {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for you in the picture…").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(ScanView.panel, in: RoundedRectangle(cornerRadius: 18))
                }
                if let scanned {
                    resultHeader(scanned)
                    styleChips
                    conceptGrid
                } else if !working {
                    intro
                }
            }
            .padding()
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Body scan")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $mode) { m in
            switch m {
            case .ar:
                ScanARScreen(onSkeleton: { skeleton in
                    mode = nil
                    use(skeleton)
                }, onCancel: { mode = nil })
            case .front, .back:
                ScanCameraScreen(front: m == .front, onPhoto: { image in
                    mode = nil
                    process(ScanImageBox(image: image))
                }, onCancel: { mode = nil })
            }
        }
        .sheet(item: $selected, onDismiss: {
            if let url = openAfterSheet {
                openAfterSheet = nil
                onOpenProject(url)
            }
        }) { concept in
            if let scanned {
                ScanConceptDetail(concept: concept, scan: scanned) { url in
                    openAfterSheet = url
                    selected = nil
                }
                .environmentObject(library)
                .environmentObject(store)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            loadPhoto(item)
        }
        .onChange(of: filter) { _, _ in makeConcepts() }
    }

    // MARK: Before a scan

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "figure.arms.open")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.gradient)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turn yourself into a character!")
                        .font(.title2.bold())
                    Text("Scan your body and I'll draw character ideas with your real shape and pose: chibi, hero, robot, creature and more.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Find a spot with good light and room to step back.")
                step(2, "Stand so your whole body fits, from head to toes.")
                step(3, "Strike a pose and hold still for 3 seconds.")
                step(4, "Pick a character you like and start drawing!")
            }
            .padding()
            .background(ScanView.panel, in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 12) {
                if ScanAR.isSupported {
                    scanButton("3D scan", detail: "Best! Someone holds the device and points the back camera at you.",
                               symbol: "figure.stand", prominent: true) { openCamera(.ar) }
                }
                if ScanCameraPermission.hasFrontCamera {
                    scanButton("Selfie scan", detail: "Lean the device on something, step back and pose.",
                               symbol: "person.crop.square", prominent: !ScanAR.isSupported) { openCamera(.front) }
                }
                if !ScanAR.isSupported && ScanCameraPermission.hasBackCamera {
                    scanButton("Back camera photo", detail: "Someone takes a photo of your whole body.",
                               symbol: "camera", prominent: false) { openCamera(.back) }
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    scanLabel("Pick a photo", detail: "Use a photo where you can see a whole person.", symbol: "photo")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            if permission == .blocked {
                cameraBlockedCard
            }

            Label("Private: your photo never leaves this device and is never saved. I only keep a stick figure until you close this screen.",
                  systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.accent, in: Circle())
            Text(text)
        }
    }

    private func scanLabel(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).opacity(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func scanButton(_ title: String, detail: String, symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) { scanLabel(title, detail: detail, symbol: symbol) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        } else {
            Button(action: action) { scanLabel(title, detail: detail, symbol: symbol) }
                .buttonStyle(.bordered)
        }
    }

    private var cameraBlockedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The camera is turned off for Gale", systemImage: "video.slash.fill")
                .font(.headline)
            Text("To scan, turn on Camera for Gale in Settings. You can also pick a photo instead.")
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private func problemCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(text)
            Spacer(minLength: 0)
            Button {
                problem = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: After a scan

    private func resultHeader(_ b: ScanBody) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your body scan").font(.title2.bold())
                Spacer()
                Text(b.source.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
            }
            Text("Pose: " + b.pose.summary)
                .font(.subheadline)
            let facts = b.proportions.facts
            if !facts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(facts, id: \.self) { fact in
                        Label(fact, systemImage: "ruler")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(b.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    forget()
                } label: {
                    Label("Scan again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    forget()
                } label: {
                    Label("Forget scan", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    seed = UInt64.random(in: 1...UInt64.max)
                    makeConcepts()
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(making)
            }
        }
        .padding()
        .background(ScanView.panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private var styleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", symbol: "square.grid.2x2", on: filter == nil) { filter = nil }
                ForEach(ScanStyle.allCases) { style in
                    chip(title: style.title, symbol: style.symbol, on: filter == style) { filter = style }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(ScanView.panel), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var conceptGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let filter {
                Text(filter.blurb).font(.subheadline).foregroundStyle(.secondary)
            }
            if making && concepts.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Drawing your characters…")
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(concepts) { concept in
                    Button {
                        selected = concept
                    } label: {
                        conceptCard(concept)
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(making && !concepts.isEmpty ? 0.5 : 1)
            Text("Tap a character to see it big, save it, or start a project with it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func conceptCard(_ concept: ScanConcept) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.white)
                if let image = thumbs.images[concept.id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(6)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(0.8, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
            Text(concept.name)
                .font(.headline)
                .lineLimit(1)
            Label(concept.style.title, systemImage: concept.style.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func openCamera(_ m: ScanMode) {
        problem = nil
        permission = ScanCameraPermission.current
        switch permission {
        case .allowed:
            mode = m
        case .ask:
            Task { @MainActor in
                let ok = await ScanCameraPermission.request()
                permission = ok ? .allowed : .blocked
                if ok { mode = m }
            }
        case .blocked:
            problem = "I need the camera to scan you. You can turn it on in Settings, or pick a photo instead."
        }
    }

    private func use(_ skeleton: ScanSkeleton) {
        if let b = ScanBody(scan: skeleton) {
            show(b)
        } else {
            problem = skeleton.problems.first ?? ScanVision.noPerson
        }
    }

    private func show(_ b: ScanBody) {
        problem = nil
        scanned = b
        concepts = []
        thumbs = ScanImages()
        seed = UInt64.random(in: 1...UInt64.max)
        makeConcepts()
    }

    private func process(_ box: ScanImageBox) {
        guard box.image != nil else {
            problem = "That photo didn't work. Please try again."
            return
        }
        working = true
        problem = nil
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { () -> ScanFound in
                guard let image = box.image else { return .problem(ScanVision.noPerson) }
                return ScanVision.findBody(in: image)
            }.value
            working = false
            switch found {
            case .body(let b): show(b)
            case .problem(let text): problem = text
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        working = true
        problem = nil
        Task { @MainActor in
            let data = try? await item.loadTransferable(type: Data.self)
            guard let data else {
                working = false
                problem = "I couldn't open that photo. Try a different one."
                return
            }
            let found = await Task.detached(priority: .userInitiated) { () -> ScanFound in
                guard let ui = UIImage(data: data), let image = ScanVision.upright(ui) else {
                    return .problem("I couldn't open that photo. Try a different one.")
                }
                return ScanVision.findBody(in: image)
            }.value
            working = false
            switch found {
            case .body(let b): show(b)
            case .problem(let text): problem = text
            }
        }
    }

    private func makeConcepts() {
        guard let b = scanned else { return }
        generation += 1
        let token = generation
        let styles = filter.map { [$0] } ?? ScanStyle.allCases
        let perStyle = filter == nil ? 2 : 8
        let seed = self.seed
        making = true
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> ([ScanConcept], ScanImages) in
                let list = ScanConceptMaker.concepts(body: b, styles: styles, perStyle: perStyle, seed: seed)
                var pics = ScanImages()
                for c in list {
                    if let image = FrameRenderer.thumbnail(strokes: c.drawing.strokes, fills: c.drawing.fills, side: 360) {
                        pics.images[c.id] = image
                    }
                }
                return (list, pics)
            }.value
            guard token == generation, scanned != nil else { return }
            concepts = result.0
            thumbs = result.1
            making = false
        }
    }

    private func forget() {
        generation += 1
        scanned = nil
        concepts = []
        thumbs = ScanImages()
        selected = nil
        making = false
        problem = nil
    }
}

// MARK: - One concept, big

struct ScanConceptDetail: View {
    let concept: ScanConcept
    let scan: ScanBody
    let onMade: (URL) -> Void

    @EnvironmentObject var library: ProjectLibrary
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var turnaround = false
    @State private var poseImage: ScanImageBox?
    @State private var sheetImage: ScanImageBox?
    @State private var sheet: ScanTurnaround?
    @State private var saved = false
    @State private var busy = false
    @State private var message: String?

    init(concept: ScanConcept, scan: ScanBody, onMade: @escaping (URL) -> Void) {
        self.concept = concept
        self.scan = scan
        self.onMade = onMade
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("View", selection: $turnaround) {
                        Text("Pose").tag(false)
                        Text("Turnaround").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)

                    ZStack {
                        RoundedRectangle(cornerRadius: 18).fill(Color.white)
                        if let image = (turnaround ? sheetImage : poseImage)?.image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .padding(10)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(minHeight: 280)
                    .frame(maxHeight: 560)
                    .aspectRatio(turnaround ? 1.9 : 0.75, contentMode: .fit)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.1)))

                    if turnaround {
                        HStack {
                            ForEach(ScanTurnaround.titles, id: \.self) { title in
                                Text(title).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            }
                        }
                        Text("Front, 3/4, side and back of the same character. The blue lines help you keep the sizes the same.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Text(concept.look.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let message {
                        Text(message)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 10) {
                        Button {
                            makeProject()
                        } label: {
                            Label(turnaround ? "Make a turnaround project" : "Make a project", systemImage: "plus.square.on.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)

                        Button {
                            saveToStash()
                        } label: {
                            Label(saved ? "Saved to your stash!" : "Save to stash", systemImage: saved ? "checkmark.circle.fill" : "tray.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(saved)
                    }
                    .controlSize(.large)
                    .disabled(busy)
                    .frame(maxWidth: 420)

                    Text(turnaround
                         ? "The project gets 4 frames (one for each side), a guide layer, and a \"Draw here\" layer for your own lines."
                         : "The project gets this character on a \"Concept\" layer and an empty \"Draw here\" layer on top. Trace it, change it, make it yours!")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(concept.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await renderPose() }
        .onChange(of: turnaround) { _, on in
            saved = false
            message = nil
            if on && sheetImage == nil {
                Task { @MainActor in await renderSheet() }
            }
        }
    }

    private func renderPose() async {
        let drawing = concept.drawing
        let box = await Task.detached(priority: .userInitiated) {
            ScanImageBox(image: ScanRender.image(drawing, maxSide: 1100))
        }.value
        poseImage = box
    }

    private func renderSheet() async {
        let b = scan
        let look = concept.look
        let result = await Task.detached(priority: .userInitiated) { () -> (ScanTurnaround, ScanImageBox) in
            let t = ScanConceptMaker.turnaround(body: b, look: look)
            return (t, ScanImageBox(image: ScanRender.image(t.sheet, maxSide: 1800)))
        }.value
        sheet = result.0
        sheetImage = result.1
    }

    private func saveToStash() {
        let drawing: ScanDrawing
        let name: String
        if turnaround {
            guard let sheet else { return }
            drawing = sheet.sheet
            name = concept.name + " turnaround"
        } else {
            drawing = concept.drawing
            name = concept.name
        }
        // Stash items are pasted onto a canvas, so keep them a handy size.
        let small = drawing.fitted(into: Box(minX: 0, minY: 0, maxX: 700, maxY: 700))
        guard let item = ScanConceptMaker.stashItem(name: name, drawing: small) else {
            message = "Hmm, that one couldn't be saved. Try another."
            return
        }
        store.save(item)
        store.reload()
        saved = true
    }

    private func makeProject() {
        busy = true
        message = nil
        defer { busy = false }
        let canvas = turnaround ? ScanConceptMaker.turnaroundCanvas : ScanConceptMaker.poseCanvas
        let name = turnaround ? concept.name + " turnaround" : concept.name
        do {
            let url = try library.create(name: name, canvas: canvas, fps: 12)
            do {
                var project = try GaleIO.readProject(at: url)
                ScanConceptMaker.fill(&project, concept: concept, body: scan, turnaround: turnaround)
                try GaleIO.writeProject(project, to: url)
            } catch {
                // Don't leave an empty project behind if filling it failed.
                try? FileManager.default.removeItem(at: url)
                library.reload()
                throw error
            }
            library.reload()
            onMade(url)
        } catch {
            message = "I couldn't make the project. Is your device full?"
        }
    }
}
