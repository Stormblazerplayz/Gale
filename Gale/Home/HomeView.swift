import SwiftUI
import GaleFormat
import GaleSync

struct HomeView: View {
    @EnvironmentObject var library: ProjectLibrary
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var libraryStore: LibraryStore
    @State private var showLearn = false
    @State private var showScan = false
    @State private var showComputer = false
    @State private var downloading: String?
    @State private var path: [URL] = []
    @State private var showNew = false
    @State private var showPixel = false
    @State private var renaming: ProjectLibrary.Entry?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    Button { showNew = true } label: { NewCard() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New project")
                        .accessibilityIdentifier("newProject")
                    Button { showPixel = true } label: { PixelStoryCard() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New pixel story")
                        .accessibilityIdentifier("newPixelStory")
                    ForEach(library.entries) { entry in
                        Button { path.append(entry.url) } label: { ProjectCard(entry: entry) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    newName = entry.name
                                    renaming = entry
                                }
                                Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(entry) }
                                Button("Delete", systemImage: "trash", role: .destructive) { library.delete(entry) }
                            }
                    }
                }
                .padding(16)
                if !computerOnly.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("On your computer", systemImage: "desktopcomputer").font(.headline)
                        ForEach(computerOnly) { item in
                            Button {
                                downloading = item.id
                                Task {
                                    if let url = await sync.download(item) { path.append(url) }
                                    downloading = nil
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "icloud.and.arrow.down")
                                    Text(item.name)
                                    Spacer()
                                    if downloading == item.id { ProgressView() }
                                }
                                .padding(12)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if library.entries.isEmpty {
                    Text("Tap New to start drawing.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Gale")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showLearn = true } label: { Label("Learn", systemImage: "graduationcap") }
                    Button { showScan = true } label: { Label("Body scan", systemImage: "figure.stand") }
                    Button { showComputer = true } label: {
                        Label("Computer", systemImage: sync.status == .connected ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
                    }
                }
            }
            .fullScreenCover(isPresented: $showLearn) {
                NavigationStack {
                    LearnHomeView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Close") { showLearn = false } }
                        }
                }
                .environmentObject(library)
                .environmentObject(libraryStore)
                .environmentObject(sync)
            }
            .fullScreenCover(isPresented: $showScan) {
                NavigationStack {
                    ScanView(onOpenProject: { url in
                        showScan = false
                        library.reload()
                        path.append(url)
                    })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { showScan = false } }
                    }
                }
            }
            .sheet(isPresented: $showComputer) {
                ComputerView()
            }
            .navigationDestination(for: URL.self) { url in
                EditorHost(url: url)
            }
            .fullScreenCover(isPresented: $showPixel) {
                PixelEntryView { url in
                    showPixel = false
                    path.append(url)
                }
                .environmentObject(library)
            }
            .sheet(isPresented: $showNew) {
                NewProjectSheet { url in
                    showNew = false
                    path.append(url)
                }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let entry = renaming { library.rename(entry, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .onAppear { library.reload() }
        }
    }

    /// Projects on the paired computer that aren't on this device yet.
    private var computerOnly: [HubProject] {
        let here = Set(library.entries.map(\.id))
        return sync.hubProjects.filter { !here.contains($0.id) }
    }
}

private struct NewCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
            Text("New").font(.headline)
            Text(" ").font(.caption)
        }
    }
}

private struct ProjectCard: View {
    let entry: ProjectLibrary.Entry

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground))
                if let image = UIImage(contentsOfFile: entry.coverURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(entry.isPixel ? .none : .high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(6)
                } else {
                    Image(systemName: "scribble.variable")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110)
            .overlay(alignment: .topTrailing) {
                if entry.isPixel {
                    PixelLabel(text: "PIXEL", color: .white, dot: 1.5)
                        .padding(5)
                        .background(Retro.purple, in: Rectangle())
                        .padding(8)
                }
            }
            Text(entry.name).font(.headline).lineLimit(1)
            Text(entry.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NewProjectSheet: View {
    @EnvironmentObject var library: ProjectLibrary
    @Environment(\.dismiss) private var dismiss
    var onCreate: (URL) -> Void

    struct Preset: Hashable {
        let name: String
        let width: Double
        let height: Double
    }

    static let presets = [
        Preset(name: "Wide video (1920 × 1080)", width: 1920, height: 1080),
        Preset(name: "YouTube Shorts (1080 × 1920)", width: 1080, height: 1920),
        Preset(name: "Square (1080 × 1080)", width: 1080, height: 1080),
        Preset(name: "Big drawing (2732 × 2048)", width: 2732, height: 2048),
        Preset(name: "Small and fast (1280 × 720)", width: 1280, height: 720)
    ]

    @State private var name = "My animation"
    @State private var preset = NewProjectSheet.presets[0]
    @State private var fps = 12
    @State private var background = Color.white
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Size", selection: $preset) {
                    ForEach(Self.presets, id: \.self) { Text($0.name).tag($0) }
                }
                Picker("Frames per second", selection: $fps) {
                    Text("8 (choppy, easy)").tag(8)
                    Text("12 (classic cartoon)").tag(12)
                    Text("24 (smooth)").tag(24)
                    Text("30 (video)").tag(30)
                }
                ColorPicker("Paper color", selection: $background, supportsOpacity: true)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        do {
                            let canvas = GaleCanvas(width: preset.width, height: preset.height, background: RGBA(background))
                            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            let url = try library.create(name: clean.isEmpty ? "My animation" : clean, canvas: canvas, fps: fps)
                            onCreate(url)
                        } catch {
                            self.error = "Couldn't make the project: \(error.localizedDescription)"
                        }
                    }
                    .accessibilityIdentifier("createProject")
                }
            }
        }
    }
}
