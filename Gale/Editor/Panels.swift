import GaleCore
import GaleFormat
import SwiftUI

/// The side panel with Layers, Stash, Loops and Hair.
struct PanelHost: View {
    @Binding var panel: EditorPanel
    @ObservedObject var document: ProjectDocument
    @ObservedObject var model: EditorModel
    @ObservedObject var controller: EditorController

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $panel) {
                ForEach(EditorPanel.allCases) { p in
                    Image(systemName: p.icon).tag(p).accessibilityLabel(p.title)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            Text(panel.title).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            switch panel {
            case .layers: LayersPanel(document: document)
            case .stash: StashPanel(controller: controller)
            case .loops: LoopsPanel(document: document, controller: controller)
            case .hair: HairPanel(document: document, model: model, controller: controller)
            }
        }
    }
}

// MARK: Layers

struct LayersPanel: View {
    @ObservedObject var document: ProjectDocument
    @State private var renaming: Layer?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                Button {
                    let above = document.project.layerIndex(document.currentLayerID)
                    var made: Layer?
                    document.edit { p in made = p.addLayer(name: "Layer \(p.layers.count + 1)", above: above) }
                    if let made { document.currentLayerID = made.id }
                } label: {
                    Label("New layer", systemImage: "plus")
                }
            }
            Section {
                // Top layer first, like a stack of paper seen from above.
                ForEach(Array(document.project.layers.reversed())) { layer in
                    LayerRow(layer: layer, selected: layer.id == document.currentLayerID, document: document) {
                        newName = layer.name
                        renaming = layer
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { document.currentLayerID = layer.id }
                }
            } footer: {
                Text("Tap a layer to draw on it. Layers higher in the list are in front.")
            }
        }
        .alert("Rename layer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let l = renaming {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    document.edit { p in
                        if let i = p.layerIndex(l.id), !name.isEmpty { p.layers[i].name = name }
                    }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct LayerRow: View {
    var layer: Layer
    var selected: Bool
    @ObservedObject var document: ProjectDocument
    var rename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { change { $0.visible.toggle() } } label: {
                    Image(systemName: layer.visible ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                Text(layer.name).fontWeight(selected ? .bold : .regular)
                    .foregroundStyle(selected ? Theme.accent : .primary)
                Spacer()
                Button { change { $0.locked.toggle() } } label: {
                    Image(systemName: layer.locked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(.borderless)
                Menu {
                    Button("Rename", action: rename)
                    Button("Move up") { move(1) }
                    Button("Move down") { move(-1) }
                    Button("Copy layer") { duplicate() }
                    Button("Delete", role: .destructive) { delete() }
                        .disabled(document.project.layers.count < 2)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if selected {
                HStack {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { layer.opacity }, set: { v in
                        document.edit(undoable: false) { p in
                            if let i = p.layerIndex(layer.id) { p.layers[i].opacity = v }
                        }
                    }), in: 0...1, onEditingChanged: { editing in
                        if editing { document.checkpoint() }
                    })
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(selected ? Theme.accent.opacity(0.08) : nil)
    }

    private func change(_ f: @escaping (inout Layer) -> Void) {
        document.edit { p in
            if let i = p.layerIndex(layer.id) { f(&p.layers[i]) }
        }
    }

    private func move(_ d: Int) {
        guard let i = document.project.layerIndex(layer.id) else { return }
        let to = max(0, min(document.project.layers.count - 1, i + d))
        document.edit { p in p.moveLayer(from: i, to: to) }
    }

    private func duplicate() {
        guard let i = document.project.layerIndex(layer.id) else { return }
        var made: Layer?
        document.edit { p in
            let copy = p.addLayer(name: "\(layer.name) copy", above: i)
            made = copy
            for fi in p.frames.indices {
                let cel = p.frames[fi].cel(layer.id)
                if !cel.isEmpty {
                    p.frames[fi].cels[copy.id] = Cel(strokes: StrokeTransform.freshIDs(cel.strokes), fills: StrokeTransform.freshIDs(cel.fills))
                }
            }
            if let ci = p.layerIndex(copy.id) {
                p.layers[ci].opacity = layer.opacity
            }
        }
        if let made { document.currentLayerID = made.id }
    }

    private func delete() {
        guard document.project.layers.count > 1 else { return }
        document.edit { p in
            p.layers.removeAll { $0.id == layer.id }
            for fi in p.frames.indices { p.frames[fi].cels[layer.id] = nil }
            p.hair.removeAll { $0.layer == layer.id }
        }
    }
}

// MARK: Stash

struct StashPanel: View {
    @ObservedObject var controller: EditorController
    @EnvironmentObject var store: LibraryStore
    @State private var renaming: StashItem?
    @State private var newName = ""
    @State private var onlyPinned = false

    var body: some View {
        let items = store.stash.filter { !onlyPinned || $0.pinned || !$0.auto }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Things you draw are saved here by themselves. Drag one onto the canvas or onto a frame to use it again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Only saved and pinned", isOn: $onlyPinned).font(.footnote)
                if items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "tray",
                                           description: Text("Draw something and it will show up here in a moment."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        ForEach(items) { item in
                            StashCard(item: item)
                                .onDrag { NSItemProvider(object: (StashDrag.prefix + item.id) as NSString) }
                                .contextMenu {
                                    Button { controller.placeStash(id: item.id, onFrame: controller.document.currentFrame) } label: {
                                        Label("Add to this frame", systemImage: "plus")
                                    }
                                    Button { store.togglePin(item) } label: {
                                        Label(item.pinned ? "Unpin" : "Pin (keep forever)", systemImage: item.pinned ? "pin.slash" : "pin")
                                    }
                                    Button { newName = item.name; renaming = item } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { store.delete(stash: item) } label: { Label("Delete", systemImage: "trash") }
                                }
                                .onTapGesture { controller.placeStash(id: item.id, onFrame: controller.document.currentFrame) }
                        }
                    }
                }
            }
            .padding()
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let r = renaming { store.rename(stash: r, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct StashCard: View {
    var item: StashItem
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
                }
                if item.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange).padding(6)
                }
            }
            .frame(height: 100)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
            Text(item.name).font(.caption).lineLimit(1)
        }
        .task(id: item.updated) {
            let s = item.strokes, f = item.fills
            image = await Task.detached(priority: .utility) { FrameRenderer.thumbnail(strokes: s, fills: f, side: 200) }.value
        }
    }
}

// MARK: Loops

struct LoopsPanel: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var controller: EditorController
    @EnvironmentObject var store: LibraryStore

    @State private var name = ""
    @State private var kind: LoopKind = .walk
    @State private var from = 1
    @State private var to = 1
    @State private var stride = 0.0
    @State private var allLayers = false
    @State private var cycles = 2
    @State private var direction = 0
    @State private var mirrored = false

    var body: some View {
        let count = document.project.frames.count
        Form {
            Section {
                TextField("Name (like Bouncy walk)", text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(LoopKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Stepper("From frame \(from)", value: $from, in: 1...max(1, count))
                Stepper("To frame \(to)", value: $to, in: 1...max(1, count))
                Toggle("All layers (not just this one)", isOn: $allLayers)
                if kind == .walk || kind == .run {
                    LabeledSlider(title: "Steps forward per cycle (px)", value: $stride, range: 0...800, format: "%.0f")
                }
                Button {
                    controller.saveLoop(name: name, kind: kind, range: min(from, to) - 1...max(from, to) - 1,
                                        stride: stride, allLayers: allLayers)
                } label: {
                    Label("Save these frames as a loop", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Save a loop")
            } footer: {
                Text("Walk cycles, runs, blinks, flames... save them once and drop them into any project.")
            }
            Section {
                Stepper("Play it \(cycles) times", value: $cycles, in: 1...20)
                Picker("Move", selection: $direction) {
                    Text("Stay").tag(0)
                    Text("Right").tag(1)
                    Text("Left").tag(-1)
                }
                .pickerStyle(.segmented)
                Toggle("Mirror", isOn: $mirrored)
                if store.loops.isEmpty {
                    Text("No loops yet. Save one above.").foregroundStyle(.secondary)
                }
                ForEach(store.loops) { loop in
                    HStack {
                        LoopThumb(loop: loop)
                        VStack(alignment: .leading) {
                            Text(loop.name)
                            Text("\(loop.kind.title) · \(loop.frames.count) frames").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") {
                            controller.insertLoop(loop, cycles: cycles, direction: Double(direction), mirrored: mirrored)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.delete(loop: loop) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } header: {
                Text("Your loops")
            } footer: {
                Text("Adds the loop on this layer, starting at this frame. New frames are made if needed.")
            }
        }
        .onAppear {
            from = 1
            to = max(1, count)
        }
    }
}

struct LoopThumb: View {
    var loop: LoopItem
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white)
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(3) }
        }
        .frame(width: 48, height: 48)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        .task(id: loop.id) {
            guard let first = loop.frames.first(where: { !$0.strokes.isEmpty }) else { return }
            let s = first.strokes, f = first.fills
            image = await Task.detached(priority: .utility) { FrameRenderer.thumbnail(strokes: s, fills: f, side: 96) }.value
        }
    }
}

// MARK: Hair

struct HairPanel: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var model: EditorModel
    @ObservedObject var controller: EditorController

    var body: some View {
        let regions = document.project.hair.filter { $0.layer == document.currentLayerID }
        Form {
            Section {
                Button { model.tool = .hair } label: {
                    Label("Draw around some hair", systemImage: "lasso")
                }
                Picker("Hair grows from the", selection: $model.hairSide) {
                    Text("Top").tag(HairSway.AttachSide.top)
                    Text("Left").tag(HairSway.AttachSide.left)
                    Text("Right").tag(HairSway.AttachSide.right)
                    Text("Bottom").tag(HairSway.AttachSide.bottom)
                }
            } footer: {
                Text("Pick the Hair tool and draw a loop around hair, a cape or a tail. It sways by itself when you press play. The side it grows from stays still.")
            }
            if regions.isEmpty {
                Text("No swaying hair on this layer yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(regions.enumerated()), id: \.element.id) { n, region in
                Section("Hair \(n + 1)") {
                    Toggle("Sway", isOn: binding(region, \.on))
                    LabeledSlider(title: "Stiff", value: binding(region, \.stiffness), range: 0...1, format: "%.2f")
                    LabeledSlider(title: "Wind", value: binding(region, \.wind), range: -1...1, format: "%.2f")
                    LabeledSlider(title: "Gusts", value: binding(region, \.gust), range: 0...1, format: "%.2f")
                    LabeledSlider(title: "Speed", value: binding(region, \.speed), range: 0.2...3, format: "%.1f")
                    Button { controller.bakeHair(region) } label: {
                        Label("Turn into frames", systemImage: "film")
                    }
                    Button(role: .destructive) {
                        document.edit { p in p.hair.removeAll { $0.id == region.id } }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func binding<T>(_ region: HairRegion, _ key: WritableKeyPath<HairRegion, T>) -> Binding<T> {
        Binding(
            get: { document.project.hair.first { $0.id == region.id }?[keyPath: key] ?? region[keyPath: key] },
            set: { v in
                document.edit(undoable: false) { p in
                    if let i = p.hair.firstIndex(where: { $0.id == region.id }) { p.hair[i][keyPath: key] = v }
                }
            }
        )
    }
}
