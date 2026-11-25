import GaleFormat
import GalePixel
import SwiftUI

/// The pixel art editor: draw on a grid, one frame at a time, with a palette and a frame strip.
struct PixelEditorView: View {
    @ObservedObject var document: ProjectDocument

    @State private var sceneIndex = 0
    @State private var frameIndex = 0
    @State private var tool: PixelTool = .pencil
    @State private var color: UInt8 = 1
    @State private var brush = 1
    @State private var mirrorX = false
    @State private var mirrorY = false
    @State private var filled = false
    @State private var showGrid = true
    @State private var onion = PixelOnion(on: true, before: 1, after: 0, opacity: 0.35)
    @State private var playing = false
    @State private var playStart = Date()
    @State private var stroke = StrokeState()
    @State private var showStoryboard = false
    @State private var showPlayer = false
    @State private var showExport = false
    @State private var showSettings = false

    /// The drawing in progress: shown live, saved once when the finger lifts.
    struct StrokeState {
        var base: PixelGrid?
        var working: PixelGrid?
        var start: GridPoint?
        var last: GridPoint?
    }

    private var story: PixelStory { document.project.pixel ?? PixelStory(width: 16, height: 16) }
    private var scene: Int { min(max(0, sceneIndex), max(0, story.scenes.count - 1)) }
    private var frame: Int { min(max(0, frameIndex), max(0, story.scenes[scene].frames.count - 1)) }

    var body: some View {
        VStack(spacing: 0) {
            sceneBar
            HStack(spacing: 0) {
                toolColumn
                canvasArea
            }
            paletteBar
            framesStrip
        }
        .background(Retro.screen.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle(document.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Retro.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showStoryboard) {
            StoryboardView(document: document, selection: $sceneIndex) {
                frameIndex = 0
                showStoryboard = false
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            StoryPlayerView(story: story)
        }
        .sheet(isPresented: $showExport) {
            PixelExportSheet(story: story, name: document.project.name, scene: scene, frame: frame)
        }
        .sheet(isPresented: $showSettings) {
            PixelSettingsView(document: document)
        }
        .onChange(of: sceneIndex) { _, _ in
            playing = false
            frameIndex = 0
        }
        .onDisappear { document.saveNow() }
    }

    // MARK: Top

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { document.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!document.canUndo)
                .accessibilityIdentifier("pixelUndo")
            Button { document.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!document.canRedo)
            Button { showStoryboard = true } label: { Label("Storyboard", systemImage: "rectangle.split.3x1") }
                .accessibilityIdentifier("openStoryboard")
            Button { showPlayer = true } label: { Label("Play story", systemImage: "play.tv") }
                .accessibilityIdentifier("playStory")
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("pixelExport")
            Button { showSettings = true } label: { Label("Grid and colors", systemImage: "slider.horizontal.3") }
        }
    }

    private var sceneBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Array(story.scenes.enumerated()), id: \.element.id) { i, sc in
                    Button {
                        sceneIndex = i
                    } label: {
                        if i == scene { Label("\(i + 1). \(sc.name)", systemImage: "checkmark") } else { Text("\(i + 1). \(sc.name)") }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    PixelLabel(text: String(format: "SCENE %02d", scene + 1), color: Retro.yellow, dot: 2)
                    Text(story.scenes[scene].name).font(Retro.font(14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.bold()).foregroundStyle(.white.opacity(0.7))
                }
            }
            .accessibilityLabel("Scene \(scene + 1) of \(story.scenes.count)")
            Spacer()
            PixelLabel(text: "FRAME \(frame + 1)/\(story.scenes[scene].frames.count)", color: Retro.sky, dot: 2)
                .accessibilityIdentifier("pixelFrameCounter")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Retro.panel)
    }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            let s = story
            let availW = max(10, geo.size.width - 24), availH = max(10, geo.size.height - 24)
            let fit = min(availW / CGFloat(s.width), availH / CGFloat(s.height))
            // Whole points per cell keep the pixels crisp when there's room.
            let cell = fit >= 2 ? fit.rounded(.down) : fit
            let w = cell * CGFloat(s.width), h = cell * CGFloat(s.height)
            ZStack {
                Checkerboard(square: max(4, cell))
                if playing {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                        let local = tl.date.timeIntervalSince(playStart)
                        let fi = StoryTiming.frameIndex(s.scenes[scene], local: local)
                        PixelImageView(image: PixelRender.editorFrame(s, scene: scene, frame: fi, onion: PixelOnion(on: false)))
                    }
                } else {
                    PixelImageView(image: displayImage)
                }
                if showGrid && cell >= 6 && !playing {
                    GridLines(columns: s.width, rows: s.height)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(drawGesture(cell: cell), including: playing ? .none : .all)
            .overlay(Rectangle().strokeBorder(Retro.line, lineWidth: 2).padding(-3))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .accessibilityElement()
            .accessibilityLabel("Drawing grid, \(s.width) by \(s.height)")
            .accessibilityValue(canvasDescription)
            .accessibilityIdentifier("pixelCanvas")
        }
    }

    /// What the canvas says to VoiceOver (and the UI tests): ink on this frame, frames and scenes.
    private var canvasDescription: String {
        let s = story
        let ink = s.scenes[scene].frames[frame].cells.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        return "ink \(ink), frames \(s.scenes[scene].frames.count), scenes \(s.scenes.count), frame \(frame + 1)"
    }

    private var displayImage: RGBAImage {
        var s = story
        if let w = stroke.working, s.scenes.indices.contains(scene), s.scenes[scene].frames.indices.contains(frame),
           w.cells.count == s.cellCount {
            s.scenes[scene].frames[frame].cells = w.cells
        }
        return PixelRender.editorFrame(s, scene: scene, frame: frame, onion: onion)
    }

    private func cellAt(_ p: CGPoint, cell: CGFloat) -> GridPoint {
        GridPoint(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)))
    }

    private func drawGesture(cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                drag(to: cellAt(v.location, cell: cell), start: cellAt(v.startLocation, cell: cell))
            }
            .onEnded { v in
                finish(at: cellAt(v.location, cell: cell), start: cellAt(v.startLocation, cell: cell))
            }
    }

    private func currentGrid() -> PixelGrid {
        let s = story
        return PixelGrid(width: s.width, height: s.height, cells: s.scenes[scene].frames[frame].cells)
    }

    private func drag(to p: GridPoint, start: GridPoint) {
        guard tool != .fill && tool != .picker else { return }
        if stroke.base == nil {
            let g = currentGrid()
            stroke = StrokeState(base: g, working: g, start: start, last: nil)
        }
        guard let base = stroke.base, var w = stroke.working else { return }
        let ink: UInt8 = tool == .eraser ? 0 : color
        switch tool {
        case .pencil, .eraser:
            if let last = stroke.last {
                w.drawLine(last, p, color: ink, size: brush, mirrorX: mirrorX, mirrorY: mirrorY)
            } else {
                w.stamp(p, color: ink, size: brush, mirrorX: mirrorX, mirrorY: mirrorY)
            }
        case .line:
            w = base
            w.drawLine(start, p, color: color, size: brush, mirrorX: mirrorX, mirrorY: mirrorY)
        case .rect:
            w = base
            w.drawRect(start, p, color: color, filled: filled)
        case .circle:
            w = base
            w.drawEllipse(start, p, color: color, filled: filled)
        case .move:
            w = base.shifted(dx: p.x - start.x, dy: p.y - start.y)
        case .fill, .picker:
            break
        }
        stroke.last = p
        stroke.working = w
    }

    private func finish(at p: GridPoint, start: GridPoint) {
        defer { stroke = StrokeState() }
        switch tool {
        case .fill:
            var g = currentGrid()
            if g.floodFill(p, color: color) > 0 { commit(g) }
        case .picker:
            let g = currentGrid()
            guard g.contains(p) else { return }
            let v = g[p]
            if v == 0 {
                tool = .eraser
            } else {
                color = v
                tool = .pencil
            }
        default:
            drag(to: p, start: start)
            if let w = stroke.working, w != stroke.base { commit(w) }
        }
    }

    /// Saves a new picture for the current frame (one undo step, one sync message).
    private func commit(_ g: PixelGrid) {
        let s = story
        let sceneID = s.scenes[scene].id, frameID = s.scenes[scene].frames[frame].id
        editStory { st in
            guard let si = st.sceneIndex(sceneID),
                  let fi = st.scenes[si].frames.firstIndex(where: { $0.id == frameID }),
                  g.cells.count == st.cellCount else { return }
            st.scenes[si].frames[fi].cells = g.cells
        }
    }

    private func editStory(undoable: Bool = true, _ change: (inout PixelStory) -> Void) {
        document.edit(undoable: undoable) { p in
            guard var st = p.pixel else { return }
            change(&st)
            p.pixel = st
        }
    }

    // MARK: Tools

    private var toolColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(PixelTool.allCases, id: \.self) { t in
                    ToolButton(icon: Self.icon(t), label: t.title, on: tool == t) { tool = t }
                        .accessibilityIdentifier("pixelTool-\(t.rawValue)")
                }
                Divider().background(Retro.line).padding(.vertical, 4)
                ToolButton(icon: "\(brush).square", label: "Brush size \(brush)", on: false) { brush = brush % 4 + 1 }
                ToolButton(icon: "arrow.left.and.right", label: "Mirror left and right", on: mirrorX) { mirrorX.toggle() }
                ToolButton(icon: "arrow.up.and.down", label: "Mirror up and down", on: mirrorY) { mirrorY.toggle() }
                ToolButton(icon: filled ? "square.fill" : "square.dashed", label: filled ? "Filled shapes" : "Outline shapes", on: filled) { filled.toggle() }
                ToolButton(icon: "grid", label: "Grid lines", on: showGrid) { showGrid.toggle() }
                Divider().background(Retro.line).padding(.vertical, 4)
                ToolButton(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip frame sideways", on: false) {
                    commit(currentGrid().flippedHorizontally())
                }
                ToolButton(icon: "arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Flip frame upside down", on: false) {
                    commit(currentGrid().flippedVertically())
                }
                ToolButton(icon: "trash", label: "Clear frame", on: false) {
                    commit(PixelGrid(width: story.width, height: story.height))
                }
            }
            .padding(8)
        }
        .frame(width: 62)
        .background(Retro.panel)
    }

    static func icon(_ t: PixelTool) -> String {
        switch t {
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        case .line: return "line.diagonal"
        case .rect: return "square"
        case .circle: return "circle"
        case .picker: return "eyedropper"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    // MARK: Palette

    private var paletteBar: some View {
        let s = story
        return HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<s.palette.count, id: \.self) { i in
                        Button {
                            color = UInt8(i)
                            if i == 0 {
                                tool = .eraser
                            } else if tool == .eraser || tool == .picker {
                                tool = .pencil
                            }
                        } label: {
                            PaletteChip(color: s.palette[i], isClear: i == 0, selected: Int(color) == i || (i == 0 && tool == .eraser))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i == 0 ? "See-through" : "Color \(i)")
                        .accessibilityIdentifier("pixelColor-\(i)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            if Int(color) > 0 && Int(color) < s.palette.count {
                ColorPicker("Change this color", selection: paletteColorBinding, supportsOpacity: false)
                    .labelsHidden()
            }
            Button {
                addColor()
            } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .black))
            }
            .buttonStyle(RetroButtonStyle(color: Retro.panel))
            .disabled(s.palette.count >= PixelStory.maxColors)
            .accessibilityLabel("Add a color")
            .padding(.trailing, 10)
        }
        .background(Retro.panel.opacity(0.7))
    }

    /// Editing a palette color changes it everywhere it's used, like real pixel art tools.
    private var paletteColorBinding: Binding<Color> {
        let i = Int(color)
        return Binding(
            get: { (document.project.pixel?.palette[safe: i] ?? .black).color },
            set: { c in
                editStory(undoable: false) { st in
                    if i > 0 && i < st.palette.count {
                        st.palette[i] = RGBA(c)
                        st.paletteName = "" // no longer the built-in palette
                    }
                }
            })
    }

    private func addColor() {
        let s = story
        let base = Int(color) > 0 && Int(color) < s.palette.count ? s.palette[Int(color)] : RGBA(0.5, 0.5, 0.5)
        var newIndex = Int(color)
        editStory { st in
            guard st.palette.count < PixelStory.maxColors else { return }
            st.palette.append(base)
            st.paletteName = ""
            newIndex = st.palette.count - 1
        }
        color = UInt8(newIndex)
    }

    // MARK: Frames

    private var framesStrip: some View {
        let s = story
        let sc = s.scenes[scene]
        return HStack(spacing: 10) {
            Button {
                playStart = Date()
                playing.toggle()
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 16, weight: .black)).frame(width: 22)
            }
            .buttonStyle(RetroButtonStyle(color: playing ? Retro.pink : Retro.mint, text: .black))
            .accessibilityLabel(playing ? "Stop" : "Play this scene")
            .accessibilityIdentifier("playScene")
            Menu {
                Toggle("Onion skin", isOn: $onion.on)
                Stepper("Frames before: \(onion.before)", value: $onion.before, in: 0...3)
                Stepper("Frames after: \(onion.after)", value: $onion.after, in: 0...3)
            } label: {
                Image(systemName: onion.on ? "circle.circle.fill" : "circle.circle")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(onion.on ? Retro.yellow : .white)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Onion skin")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(sc.frames.enumerated()), id: \.element.id) { i, f in
                            Button {
                                playing = false
                                frameIndex = i
                            } label: {
                                FrameThumb(image: s.thumbnail(scene: scene, frame: i), number: i + 1, hold: f.hold, selected: i == frame)
                            }
                            .buttonStyle(.plain)
                            .id(f.id)
                            .accessibilityLabel("Frame \(i + 1)")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: frame) { _, f in
                    if sc.frames.indices.contains(f) { withAnimation { proxy.scrollTo(sc.frames[f].id) } }
                }
            }
            Button {
                addFrame(copy: false)
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .black))
            }
            .buttonStyle(RetroButtonStyle(color: Retro.purple))
            .accessibilityLabel("Add frame")
            .accessibilityIdentifier("addPixelFrame")
            Menu {
                Button("Copy this frame", systemImage: "plus.square.on.square") { addFrame(copy: true) }
                Button("Show longer", systemImage: "plus.circle") { changeHold(1) }
                Button("Show shorter", systemImage: "minus.circle") { changeHold(-1) }
                    .disabled(sc.frames[frame].hold <= 1)
                Button("Move left", systemImage: "arrow.left") { moveFrame(-1) }
                    .disabled(frame == 0)
                Button("Move right", systemImage: "arrow.right") { moveFrame(1) }
                    .disabled(frame >= sc.frames.count - 1)
                Button("Delete frame", systemImage: "trash", role: .destructive) { deleteFrame() }
                    .disabled(sc.frames.count <= 1)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 22, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40)
            }
            .accessibilityLabel("Frame options")
            .padding(.trailing, 10)
        }
        .padding(.leading, 10)
        .frame(height: 92)
        .background(Retro.panel)
    }

    private func addFrame(copy: Bool) {
        let s = scene, f = frame
        var newIndex = f + 1
        editStory { st in
            guard st.scenes.indices.contains(s), st.scenes[s].frames.indices.contains(f) else { return }
            let old = st.scenes[s].frames[f]
            let frame = copy ? PixelFrame(hold: old.hold, cells: old.cells) : PixelFrame.blank(width: st.width, height: st.height)
            newIndex = st.insertFrame(frame, scene: s, after: f)
        }
        playing = false
        frameIndex = newIndex
    }

    private func changeHold(_ d: Int) {
        let s = scene, f = frame
        editStory { st in
            guard st.scenes.indices.contains(s), st.scenes[s].frames.indices.contains(f) else { return }
            st.scenes[s].frames[f].hold = min(24, max(1, st.scenes[s].frames[f].hold + d))
        }
    }

    private func moveFrame(_ d: Int) {
        let s = scene, f = frame
        editStory { st in st.moveFrame(scene: s, from: f, to: f + d) }
        frameIndex = f + d
    }

    private func deleteFrame() {
        let s = scene, f = frame
        editStory { st in
            guard st.scenes.indices.contains(s), st.scenes[s].frames.count > 1, st.scenes[s].frames.indices.contains(f) else { return }
            st.scenes[s].frames.remove(at: f)
        }
        frameIndex = max(0, f - 1)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// A square tool button that lights up yellow when it's the one in use.
private struct ToolButton: View {
    let icon: String
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 44, height: 44)
                .background(on ? Retro.yellow : Retro.screen, in: Rectangle())
                .overlay(Rectangle().strokeBorder(on ? .black.opacity(0.4) : Retro.line, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Lines between the cells of the grid.
private struct GridLines: View {
    let columns: Int
    let rows: Int

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            let cw = size.width / CGFloat(columns), ch = size.height / CGFloat(rows)
            for c in 1..<max(2, columns) {
                let x = (CGFloat(c) * cw).rounded()
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for r in 1..<max(2, rows) {
                let y = (CGFloat(r) * ch).rounded()
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(path, with: .color(.black.opacity(0.18)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One frame in the strip at the bottom.
private struct FrameThumb: View {
    let image: RGBAImage
    let number: Int
    let hold: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            PixelImageView(image: image)
                .frame(width: 54, height: 54)
                .background(Checkerboard(square: 4))
                .overlay(Rectangle().strokeBorder(selected ? Retro.yellow : Retro.line, lineWidth: selected ? 3 : 1))
            HStack(spacing: 3) {
                Text("\(number)").font(Retro.font(10, weight: .bold))
                if hold > 1 { Text("×\(hold)").font(Retro.font(10, weight: .bold)).foregroundStyle(Retro.yellow) }
            }
            .foregroundStyle(.white)
        }
    }
}
