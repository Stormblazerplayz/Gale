import Foundation
import GaleCore
import GaleFormat
import SwiftUI

/// Does what the canvas and the panels ask: adds strokes, fills, moves selections, hair, stash and loops.
@MainActor
final class EditorController: ObservableObject {
    let document: ProjectDocument
    let model: EditorModel
    let store: LibraryStore
    @Published var toast: String?
    private var stashTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(document: ProjectDocument, model: EditorModel, store: LibraryStore) {
        self.document = document
        self.model = model
        self.store = store
    }

    var actions: CanvasActions {
        CanvasActions(
            commitStroke: { [weak self] s in self?.commit(s) },
            fill: { [weak self] p in self?.fill(at: p) },
            select: { [weak self] ids in self?.model.selection = ids },
            moveSelection: { [weak self] d in self?.moveSelection(by: d) },
            addHair: { [weak self] poly in self?.addHair(poly) },
            dropStash: { [weak self] id, p in self?.placeStash(id: id, at: p) },
            undo: { [weak self] in self?.document.undo() },
            redo: { [weak self] in self?.document.redo() },
            toggleEraser: { [weak self] in
                guard let self else { return }
                self.model.tool = self.model.tool == .eraser ? .brush : .eraser
            },
            pencilSeen: { [weak self] in
                guard let self, !self.model.pencilSeen else { return }
                self.model.pencilSeen = true
                self.model.fingerDraws = false
                self.say("Apple Pencil found. Fingers now zoom and move, the Pencil draws. Change it in Settings.")
            },
            blocked: { [weak self] msg in self?.say(msg) }
        )
    }

    func say(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Drawing

    private func commit(_ stroke: Stroke) {
        document.addStroke(stroke)
        if stroke.brush.kind != .eraser, model.tool == .brush { model.useColor(stroke.brush.color) }
        scheduleAutoStash()
    }

    /// A couple of seconds after you stop drawing, the drawings on this layer are saved to the stash by themselves.
    private func scheduleAutoStash() {
        stashTask?.cancel()
        let frameID = document.frame.id
        let layerID = document.currentLayerID
        let projectID = document.project.id
        stashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let fi = self.document.project.frameIndex(frameID) else { return }
            let cel = self.document.project.frames[fi].cel(layerID)
            self.store.autoStash(cel: cel, projectID: projectID, frameID: frameID, layerID: layerID)
        }
    }

    private func fill(at p: Vec2) {
        let cel = document.frame.cel(document.currentLayerID)
        let canvas = document.project.canvas
        let gap = model.fillGapClose
        let color = model.color.with(alpha: model.color.a * model.opacity)
        Task {
            let path = await Task.detached(priority: .userInitiated) {
                PaintBucket.fill(cel: cel, canvasWidth: canvas.width, canvasHeight: canvas.height, seed: p, gapClose: gap)
            }.value
            guard let path else {
                self.say("Tap inside a shape to fill it.")
                return
            }
            self.document.addFill(Fill(color: color, path: path))
        }
    }

    // MARK: Selection

    func moveSelection(by d: Vec2) {
        let ids = model.selection
        document.updateCurrentCel { cel in
            cel.strokes = cel.strokes.map { s in
                ids.contains(s.id) ? StrokeTransform.translate([s], dx: d.x, dy: d.y)[0] : s
            }
        }
    }

    private func selectedStrokes() -> [Stroke] {
        document.frame.cel(document.currentLayerID).strokes.filter { model.selection.contains($0.id) }
    }

    func deleteSelection() {
        let ids = model.selection
        document.updateCurrentCel { $0.strokes.removeAll { ids.contains($0.id) } }
        model.selection = []
    }

    func duplicateSelection() {
        let copies = StrokeTransform.freshIDs(StrokeTransform.translate(selectedStrokes(), dx: 24, dy: 24))
        var newIDs: Set<String> = []
        document.updateCurrentCel { cel in
            for s in copies {
                cel.append(s)
                newIDs.insert(s.id)
            }
        }
        model.selection = newIDs
    }

    func scaleSelection(_ k: Double) {
        let ids = model.selection
        let center = Geometry.bounds(of: selectedStrokes()).center
        document.updateCurrentCel { cel in
            cel.strokes = cel.strokes.map { s in
                ids.contains(s.id) ? StrokeTransform.scale([s], by: k, around: center)[0] : s
            }
        }
    }

    func flipSelection() {
        let ids = model.selection
        let axis = Geometry.bounds(of: selectedStrokes()).center.x
        document.updateCurrentCel { cel in
            cel.strokes = cel.strokes.map { s in
                ids.contains(s.id) ? StrokeTransform.flipHorizontally([s], axis: axis)[0] : s
            }
        }
    }

    func recolorSelection() {
        let ids = model.selection
        let color = model.color
        document.updateCurrentCel { cel in
            for i in cel.strokes.indices where ids.contains(cel.strokes[i].id) {
                cel.strokes[i].brush.color = color
            }
        }
    }

    func stashSelection() {
        let strokes = selectedStrokes()
        guard !strokes.isEmpty else { return }
        let item = SmartStash.makeItem(group: strokes, cel: document.frame.cel(document.currentLayerID),
                                       projectID: document.project.id, frameID: document.frame.id,
                                       layerID: document.currentLayerID, name: "Saved drawing", auto: false)
        store.save(item)
        store.reload()
        say("Saved to your stash.")
    }

    func copySelectionToNextFrame() {
        let strokes = StrokeTransform.freshIDs(selectedStrokes())
        guard !strokes.isEmpty else { return }
        let layer = document.currentLayerID
        let next = document.currentFrame + 1
        document.edit { p in
            if next >= p.frames.count { _ = p.insertFrame(Frame(), after: p.frames.count - 1) }
            var cel = p.frames[next].cel(layer)
            for s in strokes { cel.append(s) }
            p.frames[next].cels[layer] = cel
        }
        document.currentFrame = next
        model.selection = []
    }

    // MARK: Stash

    func placeStash(id: String, at p: Vec2) {
        guard let item = store.stash.first(where: { $0.id == id }) else { return }
        guard document.currentLayer?.locked != true else { say("This layer is locked."); return }
        document.updateCurrentCel { cel in _ = SmartStash.place(item, at: p, into: &cel) }
    }

    func placeStash(id: String, onFrame index: Int) {
        guard let item = store.stash.first(where: { $0.id == id }), document.project.frames.indices.contains(index) else { return }
        let layer = document.currentLayerID
        let center = Vec2(document.project.canvas.width / 2, document.project.canvas.height / 2)
        document.edit { p in
            var cel = p.frames[index].cel(layer)
            _ = SmartStash.place(item, at: center, into: &cel)
            p.frames[index].cels[layer] = cel
        }
        document.currentFrame = index
    }

    // MARK: Hair

    private func addHair(_ polygon: [Double]) {
        let region = HairRegion(layer: document.currentLayerID, polygon: polygon,
                                root: HairSway.root(for: polygon, side: model.hairSide))
        document.edit { p in p.hair.append(region) }
        say("Hair sway added. Press play to see it move.")
    }

    /// Turns the sway into real frames, so you can fix them by hand.
    func bakeHair(_ region: HairRegion) {
        let fi = document.currentFrame
        let source = document.project.frames[fi]
        let baked = HairSway.bake(source.cel(region.layer), region: region, fps: document.project.fps)
        guard baked.count > 1 else { return }
        document.edit { p in
            var at = fi
            p.frames[fi].cels[region.layer] = baked[0]
            for cel in baked.dropFirst() {
                var f = Frame(hold: source.hold)
                for (lid, c) in source.cels where lid != region.layer {
                    f.cels[lid] = Cel(strokes: StrokeTransform.freshIDs(c.strokes), fills: StrokeTransform.freshIDs(c.fills))
                }
                f.cels[region.layer] = Cel(strokes: StrokeTransform.freshIDs(cel.strokes), fills: StrokeTransform.freshIDs(cel.fills))
                at = p.insertFrame(f, after: at)
            }
            if let i = p.hair.firstIndex(where: { $0.id == region.id }) { p.hair[i].on = false }
        }
        say("Made \(baked.count) frames of hair sway.")
    }

    // MARK: Loops

    func saveLoop(name: String, kind: LoopKind, range: ClosedRange<Int>, stride: Double, allLayers: Bool) {
        let layers = allLayers ? document.project.layers.map(\.id) : [document.currentLayerID]
        guard let loop = LoopTools.makeLoop(from: document.project, layerIDs: layers, range: range,
                                            name: name.isEmpty ? kind.title : name, kind: kind, stride: stride) else {
            say("Those frames are empty, so there's nothing to save.")
            return
        }
        store.save(loop)
        say("Saved \"\(loop.name)\" to your loops.")
    }

    func insertLoop(_ loop: LoopItem, cycles: Int, direction: Double, mirrored: Bool) {
        guard document.currentLayer?.locked != true else { say("This layer is locked."); return }
        let layer = document.currentLayerID
        let start = document.currentFrame
        document.edit { p in
            _ = LoopTools.insert(loop, into: &p, layerID: layer, at: start,
                             placement: .init(cycles: cycles, direction: direction, mirrored: mirrored))
        }
    }
}
