import GaleFormat
import GalePixel
import SwiftUI

/// All scenes of a pixel story as a film strip, plus everything about the chosen scene:
/// its words, speech bubbles, speed, loops, background and how it starts.
struct StoryboardView: View {
    @ObservedObject var document: ProjectDocument
    @Binding var selection: Int
    /// Close the storyboard and draw the chosen scene.
    var onDraw: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var dragging: String?

    private var story: PixelStory { document.project.pixel ?? PixelStory(width: 16, height: 16) }
    private var sel: Int { min(max(0, selection), max(0, story.scenes.count - 1)) }

    var body: some View {
        NavigationStack {
            ZStack {
                Retro.screen.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            PixelLabel(text: "STORYBOARD", color: Retro.yellow, dot: 3)
                            Spacer()
                            Text(lengthText).font(Retro.font(13, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        }
                        filmStrip
                        sceneButtons
                        SceneEditor(document: document, sceneID: story.scenes[sel].id, dragging: $dragging)
                    }
                    .padding(18)
                }
                Scanlines().ignoresSafeArea()
            }
            .environment(\.colorScheme, .dark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Retro.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("closeStoryboard")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onDraw() } label: { Label("Draw this scene", systemImage: "pencil.tip") }
                        .accessibilityIdentifier("drawScene")
                }
            }
            .onAppear {
                if reduceMotion { appeared = true } else { withAnimation { appeared = true } }
            }
        }
    }

    private var lengthText: String {
        let total = StoryTiming(story).total
        let n = story.scenes.count
        return "\(n) scene\(n == 1 ? "" : "s") · \(String(format: "%.1f", total)) s"
    }

    private var filmStrip: some View {
        let s = story
        let timing = StoryTiming(s)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(s.scenes.enumerated()), id: \.element.id) { i, sc in
                        if i > 0 {
                            TransitionChip(transition: sc.transition)
                        }
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selection = i }
                        } label: {
                            SceneCard(number: i + 1, scene: sc, image: s.thumbnail(scene: i),
                                      seconds: timing.spans.indices.contains(i) ? timing.spans[i].duration : 0,
                                      selected: i == sel)
                        }
                        .buttonStyle(.plain)
                        .id(sc.id)
                        .offset(y: appeared ? 0 : 60)
                        .opacity(appeared ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72).delay(Double(min(i, 10)) * 0.07), value: appeared)
                        .accessibilityLabel("Scene \(i + 1), \(sc.name)")
                        .accessibilityIdentifier("sceneCard-\(i + 1)")
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 4)
            }
            .onChange(of: sel) { _, i in
                if s.scenes.indices.contains(i) { withAnimation { proxy.scrollTo(s.scenes[i].id, anchor: .center) } }
            }
        }
        .background(
            // A dark film base behind the cards.
            Rectangle().fill(Color.black.opacity(0.45))
                .overlay(alignment: .top) { Sprockets() }
                .overlay(alignment: .bottom) { Sprockets() }
        )
    }

    private var sceneButtons: some View {
        HStack(spacing: 12) {
            Button { addScene() } label: { Label("New scene", systemImage: "plus") }
                .buttonStyle(RetroButtonStyle(color: Retro.purple))
                .accessibilityIdentifier("addScene")
            Button { duplicateScene() } label: { Label("Copy", systemImage: "plus.square.on.square") }
                .buttonStyle(RetroButtonStyle(color: Retro.panel))
            Button { moveScene(-1) } label: { Image(systemName: "arrow.left") }
                .buttonStyle(RetroButtonStyle(color: Retro.panel))
                .disabled(sel == 0)
                .accessibilityLabel("Move scene earlier")
            Button { moveScene(1) } label: { Image(systemName: "arrow.right") }
                .buttonStyle(RetroButtonStyle(color: Retro.panel))
                .disabled(sel >= story.scenes.count - 1)
                .accessibilityLabel("Move scene later")
            Spacer()
            Button(role: .destructive) { deleteScene() } label: { Image(systemName: "trash") }
                .buttonStyle(RetroButtonStyle(color: Retro.pink))
                .disabled(story.scenes.count <= 1)
                .accessibilityLabel("Delete scene")
        }
    }

    private func editStory(_ change: (inout PixelStory) -> Void) {
        document.edit { p in
            guard var st = p.pixel else { return }
            change(&st)
            p.pixel = st
        }
    }

    private func addScene() {
        let i = sel
        var newIndex = i + 1
        editStory { st in
            let fps = st.scenes.indices.contains(i) ? st.scenes[i].fps : 8
            let scene = PixelScene(name: "Scene \(st.scenes.count + 1)", fps: fps,
                                   frames: [PixelFrame.blank(width: st.width, height: st.height)])
            newIndex = st.insertScene(scene, after: i)
        }
        withAnimation { selection = newIndex }
    }

    private func duplicateScene() {
        let i = sel
        var newIndex = i + 1
        editStory { st in
            guard st.scenes.indices.contains(i) else { return }
            var copy = st.scenes[i]
            copy.id = GaleID.make()
            copy.name += " copy"
            copy.frames = copy.frames.map { f in
                var n = f
                n.id = GaleID.make()
                return n
            }
            copy.bubbles = copy.bubbles.map { b in
                var n = b
                n.id = GaleID.make()
                return n
            }
            newIndex = st.insertScene(copy, after: i)
        }
        withAnimation { selection = newIndex }
    }

    private func moveScene(_ d: Int) {
        let i = sel
        guard i + d >= 0, i + d < story.scenes.count else { return }
        editStory { st in st.moveScene(from: i, to: i + d) }
        withAnimation { selection = i + d }
    }

    private func deleteScene() {
        let i = sel
        editStory { st in
            guard st.scenes.count > 1, st.scenes.indices.contains(i) else { return }
            st.scenes.remove(at: i)
        }
        selection = max(0, i - 1)
    }
}

/// One scene in the film strip: its first frame on a little screen, its number and length.
private struct SceneCard: View {
    let number: Int
    let scene: PixelScene
    let image: RGBAImage
    let seconds: Double
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Checkerboard(square: 5)
                PixelImageView(image: image)
            }
            .frame(width: 168, height: 120)
            .overlay(Scanlines(spacing: 3, opacity: 0.12))
            .overlay(Rectangle().strokeBorder(.black, lineWidth: 2))
            HStack {
                PixelLabel(text: String(format: "SCENE %02d", number), color: selected ? .black : Retro.yellow, dot: 2)
                Spacer()
                Text(String(format: "%.1fs", seconds)).font(Retro.font(11, weight: .bold))
            }
            Text(scene.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? scene.name : scene.caption)
                .font(Retro.font(11, weight: .semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            HStack(spacing: 10) {
                Label("\(scene.frames.count)", systemImage: "square.stack")
                Label("\(scene.fps)", systemImage: "speedometer")
                if !scene.bubbles.isEmpty { Label("\(scene.bubbles.count)", systemImage: "bubble.left.fill") }
            }
            .font(Retro.font(10, weight: .bold))
            .opacity(0.8)
        }
        .foregroundStyle(selected ? .black : .white)
        .padding(10)
        .frame(width: 188)
        .background(selected ? Retro.yellow : Retro.panel, in: Rectangle())
        .overlay(Rectangle().strokeBorder(selected ? .white : Retro.line, lineWidth: selected ? 3 : 2))
        .background(Rectangle().fill(.black.opacity(0.6)).offset(x: 5, y: 5))
        .offset(y: selected ? -6 : 0)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }
}

/// The little arrow between two scenes that says how the next one starts.
private struct TransitionChip: View {
    let transition: PixelTransition

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 16, weight: .black))
            Text(transition.title.uppercased()).font(Retro.font(9, weight: .heavy))
        }
        .foregroundStyle(Retro.sky)
        .frame(width: 52)
        .accessibilityLabel("Then \(transition.title)")
    }

    private var icon: String {
        switch transition {
        case .cut: return "arrow.right"
        case .fade: return "circle.lefthalf.filled"
        case .wipe: return "rectangle.righthalf.filled"
        case .iris: return "smallcircle.filled.circle"
        }
    }
}

/// The holes along the edges of film.
private struct Sprockets: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = 6
            while x < size.width {
                path.addRect(CGRect(x: x, y: 2, width: 8, height: 5))
                x += 18
            }
            ctx.fill(path, with: .color(.white.opacity(0.22)))
        }
        .frame(height: 9)
        .allowsHitTesting(false)
    }
}

/// Settings for one scene, and a preview where bubbles can be dragged into place.
private struct SceneEditor: View {
    @ObservedObject var document: ProjectDocument
    let sceneID: String
    @Binding var dragging: String?

    private var story: PixelStory { document.project.pixel ?? PixelStory(width: 16, height: 16) }
    private var index: Int { story.sceneIndex(sceneID) ?? 0 }
    private var scene: PixelScene { story.scenes[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("NAME") {
                TextField("Scene name", text: field(\.name))
                    .font(Retro.font(16, weight: .bold))
                    .retroField()
            }
            row("WORDS") {
                TextField("What happens in this scene? (typed out like an old game)", text: field(\.caption), axis: .vertical)
                    .lineLimit(2...5)
                    .font(Retro.font(15, weight: .semibold))
                    .retroField()
                    .accessibilityIdentifier("sceneCaption")
            }
            row("PREVIEW") {
                BubblePlacer(story: story, sceneIndex: index, dragging: $dragging) { id, x, y, tail in
                    moveBubble(id, x: x, y: y, tail: tail)
                }
            }
            row("SPEECH BUBBLES") {
                VStack(spacing: 10) {
                    ForEach(scene.bubbles) { b in
                        BubbleRow(text: bubbleField(b.id, \.text), style: bubbleField(b.id, \.style)) {
                            editScene { sc in sc.bubbles.removeAll { $0.id == b.id } }
                        }
                    }
                    Button {
                        editScene { sc in
                            let n = sc.bubbles.count
                            sc.bubbles.append(SpeechBubble(text: "Hi!", x: 0.3 + 0.2 * Double(n % 3), y: 0.22, tailX: 0.45, tailY: 0.6))
                        }
                    } label: {
                        Label("Add bubble", systemImage: "bubble.left.fill")
                    }
                    .buttonStyle(RetroButtonStyle(color: Retro.sky, text: .black))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("addBubble")
                }
            }
            row("HOW IT STARTS") {
                Picker("How it starts", selection: field(\.transition)) {
                    ForEach(PixelTransition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            row("TIMING") {
                VStack(spacing: 8) {
                    Stepper(value: field(\.fps), in: 1...30) {
                        Text("Speed: \(scene.fps) frames a second").font(Retro.font(14, weight: .semibold))
                    }
                    Stepper(value: field(\.loops), in: 1...20) {
                        Text("Plays \(scene.loops) time\(scene.loops == 1 ? "" : "s")").font(Retro.font(14, weight: .semibold))
                    }
                    Text("The scene stays on screen until its words are read, even after the loops end.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Retro.panel, in: Rectangle())
            }
            row("BACKGROUND") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<story.palette.count, id: \.self) { i in
                            Button {
                                editScene { $0.background = i }
                            } label: {
                                PaletteChip(color: i == 0 ? story.paper : story.palette[i], isClear: false,
                                            selected: scene.background == i, size: 28)
                                    .overlay {
                                        if i == 0 { Text("P").font(Retro.font(11)).foregroundStyle(.black.opacity(0.6)) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(i == 0 ? "Paper color" : "Color \(i)")
                        }
                    }
                    .padding(6)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PixelLabel(text: label, color: Retro.sky, dot: 2)
            content()
        }
    }

    private func editScene(undoable: Bool = true, _ change: (inout PixelScene) -> Void) {
        let id = sceneID
        document.edit(undoable: undoable) { p in
            guard var st = p.pixel, let i = st.sceneIndex(id) else { return }
            change(&st.scenes[i])
            p.pixel = st
        }
    }

    private func field<T>(_ kp: WritableKeyPath<PixelScene, T>) -> Binding<T> {
        let id = sceneID
        let fallback = scene[keyPath: kp]
        return Binding(
            get: { document.project.pixel?.scenes.first(where: { $0.id == id })?[keyPath: kp] ?? fallback },
            set: { v in editScene { $0[keyPath: kp] = v } })
    }

    private func bubbleField<T>(_ bubbleID: String, _ kp: WritableKeyPath<SpeechBubble, T>) -> Binding<T>? {
        guard let b = scene.bubbles.first(where: { $0.id == bubbleID }) else { return nil }
        let id = sceneID
        let fallback = b[keyPath: kp]
        return Binding(
            get: {
                document.project.pixel?.scenes.first(where: { $0.id == id })?.bubbles.first(where: { $0.id == bubbleID })?[keyPath: kp] ?? fallback
            },
            set: { v in
                editScene { sc in
                    if let i = sc.bubbles.firstIndex(where: { $0.id == bubbleID }) { sc.bubbles[i][keyPath: kp] = v }
                }
            })
    }

    private func moveBubble(_ id: String, x: Double, y: Double, tail: Bool) {
        if dragging != id {
            dragging = id
            document.checkpoint()
        }
        editScene(undoable: false) { sc in
            guard let i = sc.bubbles.firstIndex(where: { $0.id == id }) else { return }
            if tail {
                sc.bubbles[i].tailX = x
                sc.bubbles[i].tailY = y
            } else {
                sc.bubbles[i].x = x
                sc.bubbles[i].y = y
            }
        }
    }
}

/// One bubble's words, its kind and a delete button.
private struct BubbleRow: View {
    let text: Binding<String>?
    let style: Binding<BubbleStyle>?
    let onDelete: () -> Void

    var body: some View {
        if let text, let style {
            HStack(spacing: 8) {
                TextField("Bubble words", text: text)
                    .font(Retro.font(14, weight: .semibold))
                    .retroField()
                Picker("Kind", selection: style) {
                    ForEach(BubbleStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Retro.yellow)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(RetroButtonStyle(color: Retro.pink))
                    .accessibilityLabel("Delete bubble")
            }
        }
    }
}

/// The scene as it will play (all words shown), with handles to drag each bubble and its tail.
private struct BubblePlacer: View {
    let story: PixelStory
    let sceneIndex: Int
    @Binding var dragging: String?
    let onMove: (String, Double, Double, Bool) -> Void

    var body: some View {
        let r = StoryRenderer(story: story, maxSide: 320)
        // Late in the scene, so every letter has been typed and any fade is over.
        let img = r.image(scene: sceneIndex, local: StoryTiming.maxSceneSeconds)
        let bubbles = story.scenes.indices.contains(sceneIndex) ? story.scenes[sceneIndex].bubbles : []
        return PixelImageView(image: img)
            .overlay {
                GeometryReader { geo in
                    let artW = geo.size.width * CGFloat(r.layout.artWidth) / CGFloat(max(1, r.layout.width))
                    let artH = geo.size.height * CGFloat(r.layout.artHeight) / CGFloat(max(1, r.layout.height))
                    ForEach(bubbles) { b in
                        if b.style != .sign {
                            handle(color: Retro.sky, size: 18)
                                .position(x: b.tailX * artW, y: b.tailY * artH)
                                .gesture(drag(b.id, artW: artW, artH: artH, tail: true))
                                .accessibilityLabel("Bubble tail")
                        }
                        handle(color: Retro.yellow, size: 26)
                            .position(x: b.x * artW, y: b.y * artH)
                            .gesture(drag(b.id, artW: artW, artH: artH, tail: false))
                            .accessibilityLabel("Bubble \(b.text)")
                    }
                }
                .coordinateSpace(NamedCoordinateSpace.named("placer"))
            }
            .overlay(Rectangle().strokeBorder(.black, lineWidth: 2))
            .frame(maxWidth: 520)
    }

    private func handle(color: Color, size: CGFloat) -> some View {
        Rectangle()
            .fill(color.opacity(0.85))
            .frame(width: size, height: size)
            .overlay(Rectangle().strokeBorder(.black, lineWidth: 2))
            .overlay(Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: size * 0.45, weight: .black)).foregroundStyle(.black))
            .contentShape(Rectangle().inset(by: -10))
    }

    private func drag(_ id: String, artW: CGFloat, artH: CGFloat, tail: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: NamedCoordinateSpace.named("placer"))
            .onChanged { v in
                let x = min(1, max(0, Double(v.location.x / max(1, artW))))
                let y = min(1, max(0, Double(v.location.y / max(1, artH))))
                onMove(id, x, y, tail)
            }
            .onEnded { _ in dragging = nil }
    }
}

extension View {
    /// A dark boxed text field in the arcade style.
    func retroField() -> some View {
        self
            .foregroundStyle(.white)
            .padding(10)
            .background(Retro.panel, in: Rectangle())
            .overlay(Rectangle().strokeBorder(Retro.line, lineWidth: 2))
    }
}
