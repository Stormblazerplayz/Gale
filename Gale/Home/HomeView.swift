import SwiftUI
import GaleFormat
import GaleSync

struct HomeView: View {
    @EnvironmentObject var library: ProjectLibrary
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var libraryStore: LibraryStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showLearn = false
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
                VStack(alignment: .leading, spacing: 22) {
                    shortcuts

                    VStack(alignment: .leading, spacing: 12) {
                        HomeSectionHeader(title: "Your projects", symbol: "square.grid.2x2.fill", detail: projectCount)
                        LazyVGrid(columns: columns, spacing: 16) {
                            Button { showNew = true } label: { NewCard() }
                                .buttonStyle(HomeCardButtonStyle())
                                .accessibilityLabel("New project")
                                .accessibilityIdentifier("newProject")
                            Button { showPixel = true } label: { PixelHomeCard() }
                                .buttonStyle(HomeCardButtonStyle())
                                .accessibilityLabel("New pixel story")
                                .accessibilityIdentifier("newPixelStory")
                            ForEach(library.entries) { entry in
                                Button { path.append(entry.url) } label: { ProjectCard(entry: entry) }
                                    .buttonStyle(HomeCardButtonStyle())
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
                        if library.entries.isEmpty {
                            Label("Tap New to start drawing.", systemImage: "hand.point.up.left")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }

                    if !computerOnly.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HomeSectionHeader(title: "On your computer", symbol: "desktopcomputer",
                                              detail: computerOnly.count == 1 ? "1 to download" : "\(computerOnly.count) to download")
                            ForEach(computerOnly) { item in
                                Button {
                                    downloading = item.id
                                    Task {
                                        if let url = await sync.download(item) { path.append(url) }
                                        downloading = nil
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "icloud.and.arrow.down")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Theme.accent)
                                            .frame(width: 34, height: 34)
                                            .background(Theme.accent.opacity(0.12), in: Circle())
                                        Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                                        Spacer()
                                        if downloading == item.id { ProgressView() }
                                    }
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(alignment: .top) {
                // A soft wash of the Gale colors behind the top of the screen.
                LinearGradient(colors: [Theme.accent.opacity(0.14), Theme.sky.opacity(0.06), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 320)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .navigationTitle("Gale")
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

    /// Learn and Computer as two big tiles at the top, side by side on iPad and stacked on a phone.
    @ViewBuilder
    private var shortcuts: some View {
        let learn = HomeShortcut(title: "Learn", subtitle: "Drawing and animation lessons",
                                 symbol: "graduationcap.fill", filled: true, dot: nil,
                                 identifier: "homeLearn") { showLearn = true }
        let computer = HomeShortcut(title: "Computer", subtitle: computerStatus.text,
                                    symbol: sync.status == .connected ? "desktopcomputer.and.arrow.down" : "desktopcomputer",
                                    filled: false, dot: computerStatus.color,
                                    identifier: "homeComputer") { showComputer = true }
        if sizeClass == .compact {
            VStack(spacing: 12) { learn; computer }
        } else {
            HStack(spacing: 16) { learn; computer }
        }
    }

    private var computerStatus: (text: String, color: Color) {
        switch sync.status {
        case .notPaired: return ("Not connected", Color.secondary)
        case .connecting: return ("Connecting…", .orange)
        case .connected: return ("Connected to \(sync.hub?.serverName ?? "your computer")", .green)
        case .offline: return ("Offline", .red)
        }
    }

    private var projectCount: String {
        let n = library.entries.count
        return n == 1 ? "1 project" : "\(n) projects"
    }

    /// Projects on the paired computer that aren't on this device yet.
    private var computerOnly: [HubProject] {
        let here = Set(library.entries.map(\.id))
        return sync.hubProjects.filter { !here.contains($0.id) }
    }
}

/// A big tappable tile at the top of the home screen.
private struct HomeShortcut: View {
    let title: String
    let subtitle: String
    let symbol: String
    /// The main tile is filled with the Gale gradient; the other one is a plain card.
    let filled: Bool
    /// A small status light next to the subtitle (nil hides it).
    let dot: Color?
    /// The name UI tests use to find the tile.
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(filled ? Theme.accent : Color.white)
                    .frame(width: 50, height: 50)
                    .background {
                        if filled {
                            Circle().fill(Color.white)
                        } else {
                            Circle().fill(Theme.gradient)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(filled ? Color.white : Color.primary)
                    HStack(spacing: 6) {
                        if let dot {
                            Circle().fill(dot).frame(width: 8, height: 8)
                        }
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(filled ? Color.white.opacity(0.85) : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(filled ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(filled ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color(.secondarySystemBackground)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(filled ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: filled ? Theme.accent.opacity(0.25) : Color.black.opacity(0.06), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityIdentifier(identifier)
    }
}

/// A section title with an icon and a small grey count on the right.
private struct HomeSectionHeader: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.bold))
                .labelStyle(HomeHeaderLabelStyle())
            Spacer()
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HomeHeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.accent)
            configuration.title
        }
    }
}

/// Cards shrink a little while pressed, so a tap feels like pushing a real button.
private struct HomeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Both home cards share this shape: a picture on top and a name underneath, inside one rounded card.
private struct HomeCardFrame<Picture: View>: View {
    let title: String
    let caption: Text
    @ViewBuilder let picture: Picture

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picture
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                caption.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 2)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct NewCard: View {
    var body: some View {
        HomeCardFrame(title: "New", caption: Text("Start drawing")) {
            ZStack {
                Theme.gradient
                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct PixelHomeCard: View {
    var body: some View {
        HomeCardFrame(title: "Pixel Storytime", caption: Text("Pixel art stories")) {
            PixelStoryArt()
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Retro.purple, lineWidth: 3))
        }
    }
}

private struct ProjectCard: View {
    let entry: ProjectLibrary.Entry

    var body: some View {
        HomeCardFrame(title: entry.name, caption: Text(entry.modified, style: .relative)) {
            ZStack {
                Color(.tertiarySystemBackground)
                if let image = UIImage(contentsOfFile: entry.coverURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(entry.isPixel ? .none : .high)
                        .scaledToFit()
                        .padding(4)
                } else {
                    Image(systemName: "scribble.variable")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if entry.isPixel {
                    PixelLabel(text: "PIXEL", color: .white, dot: 1.5)
                        .padding(5)
                        .background(Retro.purple, in: Rectangle())
                        .padding(8)
                }
            }
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
