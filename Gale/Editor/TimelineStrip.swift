import GaleCore
import GaleFormat
import SwiftUI
import UniformTypeIdentifiers

/// Small pictures of frames, made in the background and kept until the frame changes.
@MainActor
final class ThumbnailCache: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var keys: [String: Int] = [:]
    private var pending: Set<String> = []

    func image(for frame: Frame, project: GaleProject, index: Int) -> CGImage? {
        var h = Hasher()
        h.combine(frame)
        h.combine(project.layers)
        h.combine(project.canvas.background)
        let key = h.finalize()
        if keys[frame.id] != key, !pending.contains(frame.id) {
            pending.insert(frame.id)
            let p = project
            let id = frame.id
            let scale = CGFloat(120 / max(p.canvas.width, p.canvas.height))
            Task.detached(priority: .utility) {
                let img = FrameRenderer.image(p, frameIndex: index, scale: scale)
                await MainActor.run {
                    self.pending.remove(id)
                    self.keys[id] = key
                    self.images[id] = img
                }
            }
        }
        return images[frame.id]
    }
}

/// The row of frames under the canvas: tap a frame to draw on it, long press for more.
struct TimelineStrip: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var model: EditorModel
    @ObservedObject var controller: EditorController
    @ObservedObject var player: AnimationPlayer
    @StateObject private var thumbs = ThumbnailCache()

    var body: some View {
        let p = document.project
        let aspect = CGFloat(p.canvas.width / max(1, p.canvas.height))
        HStack(spacing: 8) {
            VStack(spacing: 6) {
                Button { document.addFrame() } label: {
                    Image(systemName: "plus").frame(width: 34, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("New frame")
                Button { document.addFrame(copyCurrent: true) } label: {
                    Image(systemName: "plus.square.on.square").frame(width: 34, height: 22)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Copy this frame")
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(Array(p.frames.enumerated()), id: \.element.id) { i, frame in
                            FrameCell(index: i, frame: frame, image: thumbs.image(for: frame, project: p, index: i),
                                      aspect: aspect,
                                      selected: i == document.currentFrame,
                                      playing: player.isPlaying && i == player.frameIndex)
                                .id(frame.id)
                                .onTapGesture { document.currentFrame = i }
                                .contextMenu { menu(for: i, frame: frame) }
                                .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                    dropStash(providers, on: i)
                                }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .onChange(of: document.currentFrame) { _, i in
                    guard p.frames.indices.contains(i) else { return }
                    withAnimation { proxy.scrollTo(p.frames[i].id, anchor: .center) }
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(min(document.currentFrame, p.frames.count - 1) + 1) / \(p.frames.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text("\(p.fps) fps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1fs", p.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52)
        }
        .padding(.horizontal, 10)
        .frame(height: 96)
        .background(.bar)
    }

    @ViewBuilder
    private func menu(for i: Int, frame: Frame) -> some View {
        Button { document.currentFrame = i; document.addFrame(copyCurrent: true) } label: {
            Label("Copy frame", systemImage: "plus.square.on.square")
        }
        Menu {
            ForEach([1, 2, 3, 4, 6, 8], id: \.self) { h in
                Button("\(h == 1 ? "On ones" : "Hold for \(h)")\(frame.hold == h ? " ✓" : "")") {
                    document.edit { p in
                        guard let fi = p.frameIndex(frame.id) else { return }
                        p.frames[fi].hold = h
                    }
                }
            }
        } label: {
            Label("Hold (\(frame.hold))", systemImage: "timer")
        }
        Button { move(frame, by: -1) } label: { Label("Move left", systemImage: "arrow.left") }
            .disabled(i == 0)
        Button { move(frame, by: 1) } label: { Label("Move right", systemImage: "arrow.right") }
            .disabled(i == document.project.frames.count - 1)
        Button {
            document.edit { p in
                guard let fi = p.frameIndex(frame.id) else { return }
                p.frames[fi].cels = [:]
            }
        } label: { Label("Clear frame", systemImage: "eraser") }
        Button(role: .destructive) { document.deleteFrame(at: i) } label: {
            Label("Delete frame", systemImage: "trash")
        }
    }

    private func move(_ frame: Frame, by d: Int) {
        guard let from = document.project.frameIndex(frame.id) else { return }
        let to = max(0, min(document.project.frames.count - 1, from + d))
        document.edit { p in p.moveFrame(from: from, to: to) }
        document.currentFrame = to
    }

    private func dropStash(_ providers: [NSItemProvider], on index: Int) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let text = item as? String, text.hasPrefix(StashDrag.prefix) else { return }
            let id = String(text.dropFirst(StashDrag.prefix.count))
            DispatchQueue.main.async { controller.placeStash(id: id, onFrame: index) }
        }
        return true
    }
}

struct FrameCell: View {
    var index: Int
    var frame: Frame
    var image: CGImage?
    var aspect: CGFloat
    var selected: Bool
    var playing: Bool

    var body: some View {
        let h: CGFloat = 60
        let w = min(140, max(40, h * aspect))
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Theme.accent : (playing ? Color.orange : Color.secondary.opacity(0.3)), lineWidth: selected || playing ? 3 : 1)
            )
            HStack(spacing: 2) {
                Text("\(index + 1)").font(.caption2.monospacedDigit())
                if frame.hold > 1 {
                    Text("×\(frame.hold)").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(selected ? Theme.accent : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Frame \(index + 1)")
    }
}
