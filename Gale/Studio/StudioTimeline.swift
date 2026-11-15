import AVFoundation
import GaleFormat
import SwiftUI

/// The drawing as it was when the studio last looked, for thumbnails.
/// A class, so SwiftUI compares it by identity instead of comparing every stroke.
final class StudioDrawingSnapshot {
    let project: GaleProject
    let version: Int

    init(project: GaleProject) {
        self.project = project
        var hasher = Hasher()
        hasher.combine(project.frames)
        hasher.combine(project.layers)
        hasher.combine(project.canvas)
        version = hasher.finalize()
    }
}

/// Where one clip sits on screen right now.
private struct StudioClipLayout: Identifiable {
    let clip: Clip
    let track: Track
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    /// The part of the clip that is on screen (clips can be much wider than the screen).
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    var id: String { clip.id }
}

/// Tracks and clips over time. The playhead stays in the middle; slide the timeline to move through the movie.
struct StudioTimeline: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var playback: StudioPlayback
    @Binding var selectedClipID: String?
    @Binding var pixelsPerSecond: Double
    let drawing: StudioDrawingSnapshot
    let onTrackTap: (String) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var scrollY: CGFloat = 0
    @State private var pan: PanState?
    @State private var zoomStart: Double?
    @State private var drag: ClipDrag?

    private struct PanState {
        let start: CGPoint
        let startTime: Double
        let startY: CGFloat
        var axis: Axis?
    }

    private struct ClipDrag {
        let key: String
        let origin: Clip
    }

    static let space = "studioTimeline"
    private let rowHeight: CGFloat = 64
    private let rulerHeight: CGFloat = 28
    private var headerWidth: CGFloat { sizeClass == .compact ? 78 : 124 }

    var body: some View {
        GeometryReader { geo in
            let tracks = StudioMath.displayTracks(document.project.movie)
            let laneWidth = max(1, geo.size.width - headerWidth)
            let height = geo.size.height
            let maxScroll = max(0, rulerHeight + CGFloat(tracks.count) * rowHeight + 24 - height)
            HStack(spacing: 0) {
                headers(tracks: tracks, maxScroll: maxScroll)
                    .frame(width: headerWidth, height: height)
                lane(tracks: tracks, width: laneWidth, height: height, maxScroll: maxScroll)
                    .frame(width: laneWidth, height: height)
            }
            .onChange(of: maxScroll) { _, newValue in
                if scrollY > newValue { scrollY = newValue }
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func rowY(_ index: Int) -> CGFloat {
        rulerHeight + CGFloat(index) * rowHeight - scrollY
    }

    // MARK: Track headers

    private func headers(tracks: [Track], maxScroll: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                StudioTrackHeader(track: track,
                                  onTap: { onTrackTap(track.id) },
                                  onMute: {
                                      StudioActions.updateTrack(document, track.id) { $0.muted.toggle() }
                                  })
                    .frame(width: headerWidth - 6, height: rowHeight - 6)
                    .offset(x: 3, y: rowY(index) + 3)
            }
            Color(.systemBackground)
                .frame(width: headerWidth, height: rulerHeight)
                .overlay(alignment: .leading) {
                    Text("Tracks")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { v in
                    if pan?.start != v.startLocation {
                        pan = PanState(start: v.startLocation, startTime: playback.time, startY: scrollY, axis: .vertical)
                    }
                    guard let p = pan else { return }
                    scrollY = min(max(0, p.startY - v.translation.height), maxScroll)
                }
                .onEnded { _ in pan = nil }
        )
    }

    // MARK: Lane (ruler, rows, clips, playhead)

    private func layouts(tracks: [Track], width: CGFloat, height: CGFloat) -> [StudioClipLayout] {
        let rowOf = Dictionary(tracks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let trackOf = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let playheadX = Double(width / 2)
        var out: [StudioClipLayout] = []
        for clip in document.project.movie.clips {
            guard let row = rowOf[clip.track], let track = trackOf[clip.track] else { continue }
            let y = rowY(row) + 4
            if y + rowHeight < rulerHeight || y > height { continue }
            let x = CGFloat(StudioMath.x(forTime: clip.start, playheadTime: playback.time, playheadX: playheadX, pixelsPerSecond: pixelsPerSecond))
            let w = max(2, CGFloat(clip.length * pixelsPerSecond))
            guard x.isFinite, w.isFinite, x + w > -40, x < width + 40 else { continue }
            let vx0 = max(x, -40)
            let vx1 = min(x + w, width + 40)
            out.append(StudioClipLayout(clip: clip, track: track, x: x, y: y, width: w,
                                        visibleX: vx0, visibleWidth: max(2, vx1 - vx0)))
        }
        // Selected clip on top.
        out.sort { a, b in (a.clip.id == selectedClipID ? 1 : 0, a.clip.start) < (b.clip.id == selectedClipID ? 1 : 0, b.clip.start) }
        return out
    }

    private func lane(tracks: [Track], width: CGFloat, height: CGFloat, maxScroll: CGFloat) -> some View {
        let playheadX = width / 2
        let items = layouts(tracks: tracks, width: width, height: height)
        let zeroX = CGFloat(StudioMath.x(forTime: 0, playheadTime: playback.time, playheadX: Double(playheadX), pixelsPerSecond: pixelsPerSecond))
        let endX = CGFloat(StudioMath.x(forTime: playback.duration, playheadTime: playback.time, playheadX: Double(playheadX), pixelsPerSecond: pixelsPerSecond))
        let selected = items.first { $0.clip.id == selectedClipID }
        return ZStack(alignment: .topLeading) {
            Color(.secondarySystemBackground)
                .onTapGesture { selectedClipID = nil }

            // Before the movie starts.
            if zeroX > 0 {
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: min(width, zeroX), height: height)
                    .allowsHitTesting(false)
            }

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Rectangle()
                    .fill(Color.primary.opacity(track.kind == .video ? 0.05 : 0.03))
                    .frame(width: width, height: rowHeight - 2)
                    .offset(y: rowY(index) + 1)
                    .allowsHitTesting(false)
            }

            // End of the movie.
            if endX > 0, endX < width {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 1, height: height)
                    .offset(x: endX)
                    .allowsHitTesting(false)
            }

            ForEach(items) { item in
                clipView(item, tracks: tracks)
            }

            if let selected {
                trimHandles(selected, width: width)
            }

            ruler(width: width, playheadX: playheadX)

            if document.project.movie.clips.isEmpty {
                VStack(spacing: 6) {
                    Text(tracks.isEmpty ? "Tap + to add a video, music or your voice." : "Tap + to put something on a track.")
                        .font(.callout.weight(.semibold))
                    Text("Until then your drawing plays on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(12)
                .frame(width: width, height: max(0, height - rulerHeight))
                .offset(y: rulerHeight)
                .allowsHitTesting(false)
            }

            // Playhead.
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2, height: height)
                .offset(x: playheadX - 1)
                .allowsHitTesting(false)
            StudioPlayheadCap()
                .fill(Theme.accent)
                .frame(width: 14, height: 10)
                .offset(x: playheadX - 7, y: rulerHeight - 10)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .coordinateSpace(NamedCoordinateSpace.named(Self.space))
        .gesture(panGesture(maxScroll: maxScroll))
        .simultaneousGesture(zoomGesture)
    }

    // MARK: Ruler

    private func ruler(width: CGFloat, playheadX: CGFloat) -> some View {
        let time = playback.time
        let pps = pixelsPerSecond
        return Canvas { ctx, size in
            let step = StudioMath.rulerStep(pixelsPerSecond: pps, minSpacing: 70)
            let t0 = time - Double(playheadX) / pps
            let t1 = time + Double(size.width - playheadX) / pps
            func xOf(_ t: Double) -> CGFloat { CGFloat(Double(playheadX) + (t - time) * pps) }
            var minor = Path()
            for m in StudioMath.rulerMarks(from: t0, to: t1, step: step / 5) {
                let x = xOf(m)
                minor.move(to: CGPoint(x: x, y: size.height - 5))
                minor.addLine(to: CGPoint(x: x, y: size.height))
            }
            ctx.stroke(minor, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            var major = Path()
            for m in StudioMath.rulerMarks(from: t0 - step, to: t1, step: step) {
                let x = xOf(m)
                major.move(to: CGPoint(x: x, y: size.height - 11))
                major.addLine(to: CGPoint(x: x, y: size.height))
                ctx.draw(Text(StudioMath.timeLabel(m, tenths: step < 1)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
            }
            ctx.stroke(major, with: .color(.secondary), lineWidth: 1)
        }
        .frame(width: width, height: rulerHeight)
        .background(Color(.systemBackground).opacity(0.96))
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture()
                .onEnded { v in
                    playback.pause()
                    playback.seek(to: StudioMath.time(forX: Double(v.location.x), playheadTime: playback.time,
                                                      playheadX: Double(playheadX), pixelsPerSecond: pixelsPerSecond))
                }
        )
    }

    // MARK: Gestures

    private func panGesture(maxScroll: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                if pan?.start != v.startLocation {
                    pan = PanState(start: v.startLocation, startTime: playback.time, startY: scrollY, axis: nil)
                    playback.pause()
                }
                guard var p = pan else { return }
                if p.axis == nil {
                    p.axis = abs(v.translation.width) >= abs(v.translation.height) ? .horizontal : .vertical
                    pan = p
                }
                if p.axis == .horizontal {
                    playback.seek(to: p.startTime - Double(v.translation.width) / pixelsPerSecond)
                } else {
                    scrollY = min(max(0, p.startY - v.translation.height), maxScroll)
                }
            }
            .onEnded { _ in pan = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let base = zoomStart ?? pixelsPerSecond
                if zoomStart == nil { zoomStart = base }
                pixelsPerSecond = StudioMath.clampZoom(base * Double(v.magnification))
            }
            .onEnded { _ in zoomStart = nil }
    }

    // MARK: Clips

    private func clipView(_ item: StudioClipLayout, tracks: [Track]) -> some View {
        let clip = item.clip
        let isSelected = clip.id == selectedClipID
        let media = document.media(clip.media)
        return StudioClipView(clip: clip,
                              media: media,
                              mediaURL: media.map { document.mediaURL($0) },
                              drawing: drawing,
                              selected: isSelected,
                              pixelsPerSecond: pixelsPerSecond,
                              leftCut: item.visibleX - item.x,
                              visibleWidth: item.visibleWidth,
                              fullWidth: item.width,
                              height: rowHeight - 8)
            .frame(width: item.visibleWidth, height: rowHeight - 8)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedClipID = isSelected ? nil : clip.id
            }
            .gesture(moveGesture(clip, tracks: tracks), including: isSelected ? .all : .subviews)
            .offset(x: item.visibleX, y: item.y)
    }

    private func moveGesture(_ clip: Clip, tracks: [Track]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: NamedCoordinateSpace.named(Self.space))
            .onChanged { v in
                let key = "move|\(clip.id)|\(v.startLocation.x)|\(v.startLocation.y)"
                if drag?.key != key {
                    drag = ClipDrag(key: key, origin: clip)
                    playback.pause()
                    document.checkpoint()
                }
                guard let o = drag?.origin else { return }
                let raw = o.start + Double(v.translation.width) / pixelsPerSecond
                let candidates = StudioMath.snapCandidates(document.project.movie, playhead: playback.time, except: o.id)
                let start = StudioMath.snapMove(start: raw, length: o.length, candidates: candidates, threshold: 10 / pixelsPerSecond)
                var trackID = o.track
                if let kind = tracks.first(where: { $0.id == o.track })?.kind {
                    let same = tracks.filter { $0.kind == kind }
                    if let from = same.firstIndex(where: { $0.id == o.track }), !same.isEmpty {
                        let steps = Int((v.translation.height / rowHeight).rounded())
                        let to = min(max(0, from + steps), same.count - 1)
                        trackID = same[to].id
                    }
                }
                StudioActions.updateClip(document, o.id, undoable: false) { c in
                    c.start = max(0, start)
                    c.track = trackID
                }
            }
            .onEnded { _ in drag = nil }
    }

    @ViewBuilder
    private func trimHandles(_ item: StudioClipLayout, width: CGFloat) -> some View {
        let clip = item.clip
        let limit = StudioMath.sourceLimit(for: clip, in: document.project)
        let h = rowHeight - 8
        if item.x > -20, item.x < width + 20 {
            StudioTrimHandle(leading: true)
                .frame(width: 26, height: h)
                .contentShape(Rectangle())
                .gesture(trimGesture(clip, leading: true, limit: limit))
                .offset(x: item.x - 20, y: item.y)
        }
        let right = item.x + item.width
        if right > -20, right < width + 20 {
            StudioTrimHandle(leading: false)
                .frame(width: 26, height: h)
                .contentShape(Rectangle())
                .gesture(trimGesture(clip, leading: false, limit: limit))
                .offset(x: right - 6, y: item.y)
        }
    }

    private func trimGesture(_ clip: Clip, leading: Bool, limit: Double?) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: NamedCoordinateSpace.named(Self.space))
            .onChanged { v in
                let key = "trim\(leading)|\(clip.id)|\(v.startLocation.x)|\(v.startLocation.y)"
                if drag?.key != key {
                    drag = ClipDrag(key: key, origin: clip)
                    playback.pause()
                    document.checkpoint()
                }
                guard let o = drag?.origin else { return }
                let candidates = StudioMath.snapCandidates(document.project.movie, playhead: playback.time, except: o.id)
                let threshold = 10 / pixelsPerSecond
                let dx = Double(v.translation.width) / pixelsPerSecond
                let updated: Clip
                if leading {
                    let t = StudioMath.snap(o.start + dx, candidates: candidates, threshold: threshold)
                    updated = StudioMath.trimmedStart(o, to: t, sourceLimit: limit)
                } else {
                    let t = StudioMath.snap(o.end + dx, candidates: candidates, threshold: threshold)
                    updated = StudioMath.trimmedEnd(o, to: t, sourceLimit: limit)
                }
                StudioActions.updateClip(document, o.id, undoable: false) { c in
                    c = updated
                }
            }
            .onEnded { _ in drag = nil }
    }
}

// MARK: - Pieces

struct StudioPlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct StudioTrimHandle: View {
    let leading: Bool

    var body: some View {
        HStack(spacing: 0) {
            if !leading { Spacer(minLength: 0) }
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white)
                .frame(width: 14)
                .overlay(
                    Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.7))
                )
                .shadow(color: .black.opacity(0.3), radius: 2)
            if leading { Spacer(minLength: 0) }
        }
    }
}

struct StudioTrackHeader: View {
    let track: Track
    let onTap: () -> Void
    let onMute: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: track.kind == .video ? "film" : "waveform")
                        .font(.caption)
                        .foregroundStyle(track.kind == .video ? Theme.accent : Theme.sky)
                    Text(track.name)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onMute) {
                Image(systemName: track.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(track.muted ? Color.red : Color.secondary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.muted ? "Turn sound on" : "Mute track")
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
    }
}

/// One clip on the timeline: a colored block with pictures or a waveform.
struct StudioClipView: View {
    let clip: Clip
    let media: MediaItem?
    let mediaURL: URL?
    let drawing: StudioDrawingSnapshot
    let selected: Bool
    let pixelsPerSecond: Double
    /// How much of the clip's left side is off screen (points).
    let leftCut: CGFloat
    let visibleWidth: CGFloat
    let fullWidth: CGFloat
    let height: CGFloat

    private var isAnimation: Bool { clip.media == Clip.animation }

    private var color: Color {
        if isAnimation { return .orange }
        switch media?.kind {
        case .video?: return Theme.accent
        case .image?: return .green
        case .audio?: return Theme.sky
        case nil: return .gray
        }
    }

    private var title: String {
        if isAnimation { return "My drawing" }
        return media?.name ?? "Missing file"
    }

    private var icon: String {
        if isAnimation { return "pencil.and.scribble" }
        switch media?.kind {
        case .video?: return "film"
        case .image?: return "photo"
        case .audio?: return "waveform"
        case nil: return "questionmark"
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.75))
            content
                .frame(width: visibleWidth, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            fades
            label
            if selected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white, lineWidth: 3)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
        }
        .frame(width: visibleWidth, height: height)
    }

    @ViewBuilder
    private var content: some View {
        if media?.kind == .audio, let url = mediaURL, let m = media {
            StudioWaveform(url: url, key: m.sha256.isEmpty ? m.id : m.sha256, clip: clip,
                           pixelsPerSecond: pixelsPerSecond, leftCut: leftCut, color: .white.opacity(0.85))
                .padding(.top, 18)
        } else if isAnimation || media?.kind == .video || media?.kind == .image {
            thumbnails
        } else {
            Color.clear
        }
    }

    private var tileAspect: CGFloat {
        if media?.kind == .video { return 16.0 / 9.0 }
        let a = CGFloat(drawing.project.canvas.width / max(1, drawing.project.canvas.height))
        return min(2, max(0.5, a))
    }

    private var thumbnails: some View {
        let th = height
        let tw = max(24, th * tileAspect)
        let first = max(0, Int((leftCut / tw).rounded(.down)))
        let last = max(first + 1, Int(((leftCut + visibleWidth) / tw).rounded(.up)))
        let indices = Array(first..<min(last, first + 60))
        return ZStack(alignment: .topLeading) {
            ForEach(indices, id: \.self) { k in
                StudioThumbTile(source: tileSource(k, tileWidth: tw), drawing: drawing)
                    .frame(width: tw, height: th)
                    .clipped()
                    .offset(x: CGFloat(k) * tw - leftCut)
            }
        }
        .frame(width: visibleWidth, height: th, alignment: .topLeading)
        .opacity(0.9)
    }

    private func tileSource(_ k: Int, tileWidth tw: CGFloat) -> StudioThumbTile.Source {
        let tc = min(clip.end - 0.001, clip.start + Double((CGFloat(k) + 0.5) * tw) / max(0.0001, pixelsPerSecond))
        var s = max(0, StudioMath.sourceTime(of: clip, atTimeline: tc))
        if isAnimation {
            return .drawing(StudioMath.drawingFrameIndex(atTime: s, project: drawing.project))
        }
        guard let url = mediaURL else { return .empty }
        if media?.kind == .image { return .picture(url) }
        // Round so nearby tiles share pictures.
        let tileSeconds = Double(tw) / max(0.0001, pixelsPerSecond) * StudioMath.safeSpeed(clip.speed)
        let step = tileSeconds < 0.5 ? 0.1 : tileSeconds < 2 ? 0.5 : tileSeconds < 10 ? 2 : 10
        s = (s / step).rounded(.down) * step
        if let d = media?.duration, d > 0 { s = min(s, max(0, d - 0.05)) }
        return .video(url, s)
    }

    private var fades: some View {
        let c = StudioMath.clampFades(clip)
        let fi = CGFloat(c.fadeIn * pixelsPerSecond)
        let fo = CGFloat(c.fadeOut * pixelsPerSecond)
        let cut = leftCut
        let full = fullWidth
        return Canvas { ctx, size in
            var p = Path()
            if fi > 1 {
                p.move(to: CGPoint(x: -cut, y: 0))
                p.addLine(to: CGPoint(x: fi - cut, y: 0))
                p.addLine(to: CGPoint(x: -cut, y: size.height))
                p.closeSubpath()
            }
            if fo > 1 {
                p.move(to: CGPoint(x: full - cut, y: 0))
                p.addLine(to: CGPoint(x: full - fo - cut, y: 0))
                p.addLine(to: CGPoint(x: full - cut, y: size.height))
                p.closeSubpath()
            }
            ctx.fill(p, with: .color(.black.opacity(0.35)))
        }
        .frame(width: visibleWidth, height: height)
        .allowsHitTesting(false)
    }

    private var label: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            if visibleWidth > 70 {
                Text(title).lineLimit(1)
            }
            if abs(clip.speed - 1) > 0.001 {
                Text(String(format: "%g×", clip.speed)).fontWeight(.bold)
            }
            if clip.volume < 0.001 && !isAnimation && media?.kind != .image {
                Image(systemName: "speaker.slash.fill")
            }
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.4)))
        .padding(3)
        .frame(maxWidth: max(0, visibleWidth), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// One small picture inside a clip.
struct StudioThumbTile: View {
    enum Source: Equatable {
        case empty
        case video(URL, Double)
        case picture(URL)
        case drawing(Int)
    }

    let source: Source
    let drawing: StudioDrawingSnapshot
    @State private var image: CGImage?

    private var key: String {
        switch source {
        case .empty: return "empty"
        case .video(let url, let t): return "v\(url.lastPathComponent)@\(t)"
        case .picture(let url): return "p\(url.lastPathComponent)"
        case .drawing(let i): return "d\(drawing.version)-\(i)"
        }
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: key) {
            let loaded: CGImage?
            switch source {
            case .empty: loaded = nil
            case .video(let url, let t): loaded = await StudioAssetCache.shared.videoFrame(url: url, time: t)
            case .picture(let url): loaded = await StudioAssetCache.shared.picture(url: url)
            case .drawing(let i):
                loaded = await StudioAssetCache.shared.drawing(project: drawing.project, frameIndex: i, version: drawing.version)
            }
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// A sound's loudness drawn as bars, following trims, speed, volume and fades.
struct StudioWaveform: View {
    let url: URL
    let key: String
    let clip: Clip
    let pixelsPerSecond: Double
    let leftCut: CGFloat
    let color: Color
    @State private var peaks: StudioPeaks?

    var body: some View {
        let clip = self.clip
        let pps = max(0.0001, self.pixelsPerSecond)
        let cut = self.leftCut
        let peaks = self.peaks
        return Canvas { ctx, size in
            guard let peaks, !peaks.values.isEmpty else { return }
            let mid = size.height / 2
            var path = Path()
            var x: CGFloat = 0
            let loud = min(1.0, max(0.15, clip.volume))
            while x < size.width {
                let t0 = clip.start + Double(cut + x) / pps
                let t1 = t0 + 3 / pps
                let s0 = StudioMath.sourceTime(of: clip, atTimeline: t0)
                let s1 = StudioMath.sourceTime(of: clip, atTimeline: t1)
                let v = Double(StudioMath.peak(in: peaks.values, perSecond: peaks.perSecond, from: s0, to: s1))
                    * StudioMath.fadeGain(clip, at: t0) * loud
                let h = max(1, CGFloat(v) * size.height * 0.95)
                path.addRect(CGRect(x: x, y: mid - h / 2, width: 2, height: h))
                x += 3
            }
            ctx.fill(path, with: .color(color))
        }
        .task(id: key) {
            let loaded = await StudioAssetCache.shared.peaks(url: url, key: key)
            if !Task.isCancelled { self.peaks = loaded }
        }
    }
}
