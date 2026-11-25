import GaleCore
import GaleFormat
import SwiftUI
import UIKit

enum EditorPanel: String, CaseIterable, Identifiable {
    case layers, stash, loops, hair
    var id: String { rawValue }
    var title: String {
        switch self {
        case .layers: return "Layers"
        case .stash: return "Stash"
        case .loops: return "Loops"
        case .hair: return "Hair"
        }
    }
    var icon: String {
        switch self {
        case .layers: return "square.3.layers.3d"
        case .stash: return "tray.full"
        case .loops: return "repeat"
        case .hair: return "wind"
        }
    }
}

/// The main drawing and animating screen.
struct EditorView: View {
    @ObservedObject var document: ProjectDocument
    @StateObject private var model: EditorModel
    @StateObject private var controller: EditorController
    @StateObject private var player = AnimationPlayer()
    @EnvironmentObject var store: LibraryStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var panel: EditorPanel = .layers
    @State private var showPanel = false
    @State private var showStudio = false
    @State private var showExport = false
    @State private var showSettings = false
    @State private var showBrush = false
    @State private var zoomFit: (() -> Void)?

    init(document: ProjectDocument, store: LibraryStore) {
        self.document = document
        let m = EditorModel()
        _model = StateObject(wrappedValue: m)
        _controller = StateObject(wrappedValue: EditorController(document: document, model: m, store: store))
    }

    private var canvasState: CanvasState {
        CanvasState(project: document.project, frameIndex: min(document.currentFrame, document.project.frames.count - 1),
                    layerID: document.currentLayerID, onion: model.onion, tool: model.tool, brush: model.brush,
                    smoothing: model.smoothing, sharpCorners: model.sharpCorners, fingerDraws: model.fingerDraws,
                    selection: model.selection,
                    hairSide: model.hairSide, fillGap: model.fillGapClose)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DrawingCanvas(state: canvasState, actions: controller.actions, registerZoom: { fit in
                    DispatchQueue.main.async { zoomFit = fit }
                })
                .ignoresSafeArea(edges: .horizontal)

                if player.isPlaying {
                    PlayerOverlay(player: player, background: document.project.canvas.background.color) {
                        player.stop()
                    }
                }

                if UITestMode.on && !player.isPlaying {
                    // Only in UI tests: draws a shaky zigzag through the real drawing steps.
                    VStack {
                        HStack {
                            Button("Test scribble") { NotificationCenter.default.post(name: UITestMode.scribble, object: nil) }
                                .font(.caption2)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("testScribble")
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                }

                VStack {
                    if let toast = controller.toast {
                        Text(toast)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if model.tool == .select && !model.selection.isEmpty && !player.isPlaying {
                        SelectionBar(controller: controller)
                            .padding(.bottom, 8)
                    }
                    if !player.isPlaying {
                        ToolBar(model: model, showBrush: $showBrush)
                            .padding(.bottom, 10)
                    }
                }
                .padding(.horizontal, 12)
                .animation(.spring(duration: 0.3), value: controller.toast)
            }
            TimelineStrip(document: document, model: model, controller: controller, player: player)
        }
        .navigationTitle(document.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { topBar }
        .inspector(isPresented: $showPanel) {
            PanelHost(panel: $panel, document: document, model: model, controller: controller)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(document: document)
        }
        .sheet(isPresented: $model.showStabilizerTest) {
            StabilizerCalibrationView(model: model)
                .presentationDetents([.large])
        }
        .onChange(of: model.stabilizerTestRequested) { _, asked in
            // Close brush settings first, then open the test once the popup has gone.
            guard asked else { return }
            model.stabilizerTestRequested = false
            showBrush = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showStabilizerTest = true }
        }
        .sheet(isPresented: $showSettings) {
            EditorSettingsSheet(document: document, model: model)
        }
        .fullScreenCover(isPresented: $showStudio) {
            NavigationStack {
                StudioView(document: document)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showStudio = false }
                        }
                    }
            }
        }
        .onChange(of: model.tool) { _, tool in
            if tool != .select { model.selection = [] }
            if tool == .hair {
                panel = .hair
                showPanel = true
            }
        }
        .onChange(of: document.currentFrame) { _, _ in model.selection = [] }
        .onChange(of: document.currentLayerID) { _, _ in model.selection = [] }
        .onDisappear {
            player.stop()
            document.saveNow()
        }
    }

    @ToolbarContentBuilder
    private var topBar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!document.canUndo)
                .accessibilityLabel("Undo")
            Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!document.canRedo)
                .accessibilityLabel("Redo")
            Button {
                if player.isPlaying { player.stop() } else {
                    player.play(document.project, from: document.currentFrame, maxSide: 1600)
                }
            } label: {
                Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
            }
            .accessibilityLabel(player.isPlaying ? "Stop" : "Play")
            .accessibilityIdentifier("play")
            Menu {
                Toggle("Onion skin", isOn: $model.onion.on)
                Toggle("Frosted glass", isOn: $model.onion.frosted)
                Toggle("Loop around the ends", isOn: $model.onion.wrap)
                Stepper("Frames before: \(model.onion.before)", value: $model.onion.before, in: 0...5)
                Stepper("Frames after: \(model.onion.after)", value: $model.onion.after, in: 0...5)
                Picker("Strength", selection: $model.onion.opacity) {
                    Text("Light").tag(0.3)
                    Text("Medium").tag(0.5)
                    Text("Strong").tag(0.75)
                }
            } label: {
                Image(systemName: model.onion.on ? "circle.dashed.inset.filled" : "circle.dashed")
            }
            .accessibilityLabel("Onion skin options")
            .accessibilityValue(model.onion.on ? "on" : "off")
            .accessibilityIdentifier("onion")
            // One tap opens or closes the side panel. The panel has its own tabs for
            // Layers, Stash, Loops and Hair, so this does not need a menu.
            Button { showPanel.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .symbolVariant(showPanel ? .fill : .none)
            }
            .accessibilityLabel("Panels")
            .accessibilityValue(showPanel ? "open" : "closed")
            .accessibilityIdentifier("panels")
            Menu {
                Button { showStudio = true } label: { Label("Video and audio", systemImage: "film.stack") }
                Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button { zoomFit?() } label: { Label("Fit to screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("more")
        }
    }
}

/// Shows the playing animation over the canvas. Tap to stop.
struct PlayerOverlay: View {
    @ObservedObject var player: AnimationPlayer
    var background: Color
    var stop: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let img = player.image {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            } else {
                ProgressView("Getting ready…")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playing")
        .accessibilityValue(player.image == nil ? "getting ready" : "frame \(player.frameIndex + 1)")
        .accessibilityIdentifier("player")
        .accessibilityAddTraits(.isButton)
    }
}

/// Tools, color and size, floating at the bottom of the canvas.
struct ToolBar: View {
    @ObservedObject var model: EditorModel
    @Binding var showBrush: Bool
    @State private var showColor = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 6) {
            ForEach(EditorTool.allCases) { t in
                Button {
                    if model.tool == t && (t == .brush || t == .eraser) { showBrush = true } else { model.tool = t }
                } label: {
                    Image(systemName: t == .brush ? brushIcon : t.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(model.tool == t ? Theme.accent.opacity(0.2) : .clear, in: Circle())
                        .foregroundStyle(model.tool == t ? Theme.accent : .primary)
                }
                .accessibilityLabel(t.title)
                .accessibilityValue(model.tool == t ? "selected" : "")
                .accessibilityIdentifier("tool-\(t.rawValue)")
            }
            Divider().frame(height: 28)
            Button { showColor = true } label: {
                Circle()
                    .fill(model.color.color)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                    .frame(width: 30, height: 30)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Color")
            .accessibilityValue(showColor ? "picker open" : "picker closed")
            .accessibilityIdentifier("color")
            .popover(isPresented: $showColor) {
                SystemColorPicker(color: Binding(get: { model.color.color }, set: { model.color = RGBA($0) }))
                    .frame(minWidth: 320, idealWidth: 360, minHeight: 480, idealHeight: 600)
                    .presentationDetents([.medium, .large])
                    .presentationCompactAdaptation(.sheet)
            }
            Button { showBrush = true } label: {
                Circle()
                    .fill(model.tool == .eraser ? Color.gray : model.color.color)
                    .frame(width: max(6, min(28, (model.tool == .eraser ? model.eraserSize : model.size) / 2)),
                           height: max(6, min(28, (model.tool == .eraser ? model.eraserSize : model.size) / 2)))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Brush size")
            .accessibilityIdentifier("brushSize")
            .popover(isPresented: $showBrush) {
                // A Form has no natural height, so a popover would shrink it to one row.
                // Give it a real size so every setting shows.
                BrushPanel(model: model)
                    .frame(minWidth: 340, idealWidth: 380, minHeight: model.tool == .eraser ? 460 : 560, idealHeight: model.tool == .eraser ? 560 : 760)
                    .presentationDetents([.medium, .large])
                    .presentationCompactAdaptation(.sheet)
            }
            // Smoothing right on the toolbar on iPad, so it's easy to turn down for faces and details.
            // On a narrow screen it lives in the brush settings instead.
            if sizeClass != .compact && (model.tool == .brush || model.tool == .eraser) {
                Divider().frame(height: 28)
                SmoothingControl(value: $model.smoothing, compact: true)
                    .frame(width: 190)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private var brushIcon: String {
        switch model.brushKind {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .brush: return "paintbrush.pointed.fill"
        case .airbrush: return "aqi.medium"
        case .eraser: return "eraser.fill"
        }
    }
}

/// Brush kind, size, opacity, smoothing and recent colors.
struct BrushPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Form {
            if model.tool == .eraser {
                Section("Eraser") {
                    LabeledSlider(title: "Size", value: $model.eraserSize, range: 2...200, format: "%.0f")
                }
            } else {
                Section("Brush") {
                    Picker("Brush", selection: $model.brushKind) {
                        ForEach(BrushKind.allCases.filter { $0 != .eraser }, id: \.self) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledSlider(title: "Size", value: $model.size, range: 1...200, format: "%.0f")
                    LabeledSlider(title: "See-through", value: $model.opacity, range: 0.05...1, format: "%.2f")
                }
                if !model.recentColors.isEmpty {
                    Section("Recent colors") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                            ForEach(model.recentColors, id: \.self) { c in
                                Button { model.color = c } label: {
                                    Circle().fill(c.color)
                                        .overlay(Circle().stroke(.secondary.opacity(0.4)))
                                        .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            StabilizerSection(model: model)
        }
    }
}

/// The smoothing strength slider: 0 is Off, with the amount shown as a percentage.
struct SmoothingControl: View {
    @Binding var value: Double
    var compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { value = 0 } label: {
                Image(systemName: value < 0.005 ? "scribble" : "scribble.variable")
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    .foregroundStyle(value < 0.005 ? Color.secondary : Theme.accent)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn smoothing off")
            .accessibilityIdentifier("smoothingOff")
            Slider(value: Binding(get: { value }, set: { value = $0 < 0.02 ? 0 : $0 }), in: 0...1)
                .tint(Theme.accent)
                .accessibilityLabel("Smoothing strength")
                .accessibilityValue(StrokeSmoothing.label(value))
                .accessibilityIdentifier("smoothing")
            Text(StrokeSmoothing.label(value))
                .font((compact ? Font.caption : Font.subheadline).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: compact ? 36 : 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// Buttons for the strokes you picked with the lasso.
struct SelectionBar: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                bar("Delete", "trash") { controller.deleteSelection() }
                bar("Copy", "plus.square.on.square") { controller.duplicateSelection() }
                bar("Bigger", "plus.magnifyingglass") { controller.scaleSelection(1.1) }
                bar("Smaller", "minus.magnifyingglass") { controller.scaleSelection(1 / 1.1) }
                bar("Flip", "arrow.left.and.right.righttriangle.left.righttriangle.right") { controller.flipSelection() }
                bar("Color", "paintpalette") { controller.recolorSelection() }
                bar("To next frame", "arrow.right.square") { controller.copySelectionToNextFrame() }
                bar("Stash", "tray.and.arrow.down") { controller.stashSelection() }
                bar("Done", "checkmark") { controller.model.selection = [] }
            }
            .padding(6)
        }
        .background(.regularMaterial, in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bar(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

struct EditorSettingsSheet: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Animation") {
                    Stepper("Speed: \(document.project.fps) frames per second",
                            value: Binding(get: { document.project.fps }, set: { v in document.edit { $0.fps = v } }), in: 1...60)
                    Toggle("Motion blur", isOn: Binding(get: { document.project.motionBlur.on },
                                                        set: { v in document.edit { $0.motionBlur.on = v } }))
                    if document.project.motionBlur.on {
                        LabeledSlider(title: "Blur amount", value: Binding(get: { document.project.motionBlur.amount },
                                                                            set: { v in document.edit(undoable: false) { $0.motionBlur.amount = v } }),
                                      range: 0.1...1, format: "%.2f")
                    }
                    ColorPicker("Paper color", selection: Binding(get: { document.project.canvas.background.color },
                                                                   set: { c in document.edit { $0.canvas.background = RGBA(c) } }))
                }
                Section {
                    Toggle("Fingers draw too", isOn: $model.fingerDraws)
                } header: {
                    Text("Apple Pencil")
                } footer: {
                    Text("Turn this off so your hand resting on the screen never draws. Two fingers always zoom and move.")
                }
                Section("Fill") {
                    LabeledSlider(title: "Close small gaps", value: $model.fillGapClose, range: 0...16, format: "%.0f")
                }
                Section("Gestures") {
                    Label("Tap with two fingers to undo", systemImage: "hand.tap")
                    Label("Tap with three fingers to redo", systemImage: "hand.tap")
                    Label("Double tap the Apple Pencil to switch to the eraser", systemImage: "applepencil")
                    Label("Pinch to zoom, drag with two fingers to move", systemImage: "hand.draw")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Apple's full color picker (grid, spectrum, sliders and eyedropper), shown in a popover we control,
/// so the color button always opens it and its open or closed state is known.
struct SystemColorPicker: UIViewControllerRepresentable {
    @Binding var color: Color

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = UIColor(color)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: SystemColorPicker
        init(_ parent: SystemColorPicker) { self.parent = parent }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            parent.color = Color(uiColor: color)
        }
    }
}
