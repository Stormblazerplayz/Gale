import Foundation
import GaleFormat

/// One straight piece of a volume curve on the movie timeline: the volume goes from `from` to `to`
/// between `start` and `end` (seconds).
struct StudioVolumeSegment: Equatable {
    var start: Double
    var end: Double
    var from: Double
    var to: Double
}

/// Collects loudest-sample "peaks" from audio, a little at a time (for waveforms).
struct StudioPeakAccumulator {
    /// How many audio frames go into one peak.
    let framesPerPeak: Int
    private(set) var peaks: [Float] = []
    private var current: Float = 0
    private var count = 0

    init(framesPerPeak: Int) {
        self.framesPerPeak = max(1, framesPerPeak)
    }

    /// Adds interleaved samples (L R L R ... for stereo).
    mutating func add(interleaved samples: UnsafeBufferPointer<Float>, channels: Int) {
        let ch = max(1, channels)
        let frames = samples.count / ch
        guard frames > 0 else { return }
        var i = 0
        for _ in 0..<frames {
            var m: Float = 0
            for _ in 0..<ch {
                let v = samples[i]
                i += 1
                let a = v.isFinite ? abs(v) : 0
                if a > m { m = a }
            }
            if m > current { current = m }
            count += 1
            if count >= framesPerPeak {
                peaks.append(min(1, current))
                current = 0
                count = 0
            }
        }
    }

    mutating func add(_ samples: [Float], channels: Int) {
        samples.withUnsafeBufferPointer { add(interleaved: $0, channels: channels) }
    }

    /// The peaks, including a last partly filled one.
    mutating func finish() -> [Float] {
        if count > 0 {
            peaks.append(min(1, current))
            current = 0
            count = 0
        }
        return peaks
    }
}

/// All the math for the movie studio. No screen code, so it can be tested anywhere.
enum StudioMath {
    // MARK: Limits

    static let minSpeed = 0.25
    static let maxSpeed = 4.0
    static let maxVolume = 2.0
    /// The shortest a clip can be on the timeline, in seconds.
    static let minClipLength = 0.1
    static let minPixelsPerSecond = 8.0
    static let maxPixelsPerSecond = 400.0
    static let defaultPixelsPerSecond = 60.0
    /// How long a picture stays on screen when you add it.
    static let defaultPictureLength = 3.0
    /// The shortest movie we make (so a one-frame drawing still makes a real video).
    static let minimumMovieLength = 1.0
    static let speedPresets: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4]
    /// Tiny amount of time we treat as "the same moment".
    static let epsilon = 1e-6

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        if v.isNaN { return lo }
        return min(hi, max(lo, v))
    }

    // MARK: Time mapping

    /// Where in the source file we are at movie time `t`.
    static func sourceTime(of clip: Clip, atTimeline t: Double) -> Double {
        clip.inPoint + (t - clip.start) * safeSpeed(clip.speed)
    }

    /// The movie time that shows source time `s`.
    static func timelineTime(of clip: Clip, atSource s: Double) -> Double {
        clip.start + (s - clip.inPoint) / safeSpeed(clip.speed)
    }

    static func safeSpeed(_ s: Double) -> Double {
        guard s.isFinite, s > 0 else { return 1 }
        return clamp(s, minSpeed, maxSpeed)
    }

    /// True when the clip is on screen at movie time `t` (start included, end not).
    static func contains(_ clip: Clip, time t: Double) -> Bool {
        t >= clip.start - epsilon && t < clip.end - epsilon
    }

    // MARK: Drawing frames

    /// Which drawing frame shows at `time` seconds into the animation. It loops.
    /// (Same rule as GaleCore's Playback, kept here so this file only needs GaleFormat.)
    static func drawingFrameIndex(atTime time: Double, project: GaleProject) -> Int {
        let frames = project.frames
        guard !frames.isEmpty else { return 0 }
        let fps = Double(max(1, project.fps))
        let tick = Int((max(0, time.isFinite ? time : 0) * fps + 1e-9).rounded(.down))
        let total = frames.reduce(0) { $0 + max(1, $1.hold) }
        guard total > 0 else { return 0 }
        let t = tick % total
        var acc = 0
        for (i, f) in frames.enumerated() {
            acc += max(1, f.hold)
            if t < acc { return i }
        }
        return frames.count - 1
    }

    /// Animation length in seconds (at least one tick).
    static func animationLength(_ project: GaleProject) -> Double {
        let total = project.frames.reduce(0) { $0 + max(1, $1.hold) }
        return Double(max(1, total)) / Double(max(1, project.fps))
    }

    // MARK: Tracks and movie

    /// Tracks in saved order (back to front for video).
    static func orderedTracks(_ movie: Movie) -> [Track] {
        movie.tracks.sorted { ($0.key, $0.id) < ($1.key, $1.id) }
    }

    /// The order rows are shown: video tracks with the top one first, then sound tracks.
    static func displayTracks(_ movie: Movie) -> [Track] {
        let ordered = orderedTracks(movie)
        return Array(ordered.filter { $0.kind == .video }.reversed()) + ordered.filter { $0.kind == .audio }
    }

    static func track(_ id: String, in movie: Movie) -> Track? {
        movie.tracks.first { $0.id == id }
    }

    static func clips(onTrack id: String, in movie: Movie) -> [Clip] {
        movie.clips.filter { $0.track == id }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// True when any clip sits on a video track.
    static func hasVisualClips(_ project: GaleProject) -> Bool {
        let videoTracks = Set(project.movie.tracks.filter { $0.kind == .video }.map(\.id))
        return project.movie.clips.contains { videoTracks.contains($0.track) }
    }

    /// The drawing covers the whole movie on top when "draw on video" is on,
    /// or when there is no video at all (then it plays on the paper).
    static func drawsAnimationOnTop(_ project: GaleProject) -> Bool {
        project.movie.overlay || !hasVisualClips(project)
    }

    /// How long the movie is, in seconds.
    static func movieLength(_ project: GaleProject) -> Double {
        let trackIDs = Set(project.movie.tracks.map(\.id))
        var length = project.movie.clips.filter { trackIDs.contains($0.track) }.map(\.end).max() ?? 0
        if !hasVisualClips(project) {
            length = max(length, animationLength(project))
        }
        return max(minimumMovieLength, length.isFinite ? length : 0)
    }

    /// What is on screen at movie time `t`, back to front: the clip showing on each video track.
    static func visualStack(_ project: GaleProject, at t: Double) -> [Clip] {
        var out: [Clip] = []
        for track in orderedTracks(project.movie) where track.kind == .video {
            let here = project.movie.clips.filter { $0.track == track.id && contains($0, time: t) }
            if let top = here.max(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
                out.append(top)
            }
        }
        return out
    }

    /// How long a clip's source can be. nil = as long as you like (pictures and the drawing).
    static func sourceLimit(for clip: Clip, in project: GaleProject) -> Double? {
        if clip.media == Clip.animation { return nil }
        guard let item = project.media.first(where: { $0.id == clip.media }) else { return nil }
        switch item.kind {
        case .image: return nil
        case .video, .audio: return item.duration > 0 ? item.duration : nil
        }
    }

    // MARK: Clip edits

    /// Keeps fades inside the clip: never below 0, and together never longer than the clip.
    static func clampFades(_ clip: Clip) -> Clip {
        var c = clip
        let length = max(0, c.length)
        var fi = max(0, c.fadeIn.isFinite ? c.fadeIn : 0)
        var fo = max(0, c.fadeOut.isFinite ? c.fadeOut : 0)
        if fi + fo > length {
            let total = fi + fo
            fi = total > 0 ? length * fi / total : 0
            fo = total > 0 ? length * fo / total : 0
        }
        c.fadeIn = fi
        c.fadeOut = fo
        return c
    }

    /// Moves a clip so it starts at `start` (never before 0).
    static func moved(_ clip: Clip, to start: Double) -> Clip {
        var c = clip
        c.start = max(0, start.isFinite ? start : 0)
        return c
    }

    /// Drags the front edge to `newStart`. The back edge stays put.
    static func trimmedStart(_ clip: Clip, to newStart: Double, sourceLimit: Double?) -> Clip {
        let speed = safeSpeed(clip.speed)
        let end = clip.end
        var lo = 0.0
        if sourceLimit != nil {
            // Can't show from before the start of the file.
            lo = max(lo, clip.start - clip.inPoint / speed)
        }
        let hi = end - minClipLength
        guard hi >= lo else { return clip }
        let ns = clamp(newStart, lo, hi)
        var c = clip
        c.inPoint = max(0, clip.inPoint + (ns - clip.start) * speed)
        c.start = ns
        c.duration = max(minClipLength * speed, (end - ns) * speed)
        return clampFades(c)
    }

    /// Drags the back edge to `newEnd`. The front edge stays put.
    static func trimmedEnd(_ clip: Clip, to newEnd: Double, sourceLimit: Double?) -> Clip {
        let speed = safeSpeed(clip.speed)
        var maxDuration = Double.greatestFiniteMagnitude
        if let limit = sourceLimit {
            maxDuration = max(minClipLength * speed, limit - clip.inPoint)
        }
        let wanted = max(minClipLength, (newEnd.isFinite ? newEnd : clip.end) - clip.start) * speed
        var c = clip
        c.duration = min(maxDuration, wanted)
        return clampFades(c)
    }

    /// Cuts a clip in two at movie time `t`. nil when `t` is too close to an edge.
    static func split(_ clip: Clip, at t: Double, newID: String) -> (Clip, Clip)? {
        guard t > clip.start + minClipLength / 2, t < clip.end - minClipLength / 2 else { return nil }
        let speed = safeSpeed(clip.speed)
        let leftDuration = (t - clip.start) * speed
        var left = clip
        left.duration = leftDuration
        left.fadeOut = 0
        var right = clip
        right.id = newID
        right.start = t
        right.inPoint = clip.inPoint + leftDuration
        right.duration = max(0, clip.duration - leftDuration)
        right.fadeIn = 0
        return (clampFades(left), clampFades(right))
    }

    /// Changes the speed (0.25x to 4x). The clip keeps its start; its length changes.
    static func withSpeed(_ clip: Clip, _ speed: Double) -> Clip {
        var c = clip
        c.speed = clamp(speed, minSpeed, maxSpeed)
        return clampFades(c)
    }

    static func withVolume(_ clip: Clip, _ volume: Double) -> Clip {
        var c = clip
        c.volume = clamp(volume, 0, maxVolume)
        return c
    }

    static func withFades(_ clip: Clip, fadeIn: Double, fadeOut: Double) -> Clip {
        var c = clip
        c.fadeIn = fadeIn
        c.fadeOut = fadeOut
        return clampFades(c)
    }

    /// The (start, end) of each clip on a track, skipping one clip id.
    static func occupied(onTrack trackID: String, in movie: Movie, except clipID: String? = nil) -> [(Double, Double)] {
        movie.clips.filter { $0.track == trackID && $0.id != clipID }.map { ($0.start, $0.end) }
    }

    static func isFree(start: Double, length: Double, occupied: [(Double, Double)]) -> Bool {
        let end = start + length
        let tolerance = 1e-4
        for (a, b) in occupied where start < b - tolerance && a < end - tolerance {
            return false
        }
        return true
    }

    /// The first start at or after `desired` where a clip of `length` fits without covering another.
    static func freeStart(desired: Double, length: Double, occupied: [(Double, Double)]) -> Double {
        let d = max(0, desired.isFinite ? desired : 0)
        var candidates = [d]
        candidates += occupied.map(\.1).filter { $0 >= d }
        candidates.sort()
        for c in candidates where isFree(start: c, length: length, occupied: occupied) {
            return c
        }
        return max(d, occupied.map(\.1).max() ?? d)
    }

    /// Snaps a moving clip's start or end onto a nearby time (another clip edge, the playhead, 0).
    static func snapMove(start: Double, length: Double, candidates: [Double], threshold: Double) -> Double {
        var best = start
        var bestDistance = threshold
        for c in candidates {
            let ds = abs(c - start)
            if ds <= bestDistance {
                bestDistance = ds
                best = c
            }
            let de = abs(c - (start + length))
            if de < bestDistance {
                bestDistance = de
                best = c - length
            }
        }
        return max(0, best)
    }

    /// Snaps one time (a trim edge) onto a nearby time.
    static func snap(_ value: Double, candidates: [Double], threshold: Double) -> Double {
        var best = value
        var bestDistance = threshold
        for c in candidates where abs(c - value) <= bestDistance {
            bestDistance = abs(c - value)
            best = c
        }
        return best
    }

    /// Edges worth snapping to: 0, the playhead, and every clip's start and end.
    static func snapCandidates(_ movie: Movie, playhead: Double, except clipID: String?) -> [Double] {
        var out = [0, playhead]
        for c in movie.clips where c.id != clipID {
            out.append(c.start)
            out.append(c.end)
        }
        return out
    }

    /// Finds a track of `kind` where a clip of `length` fits at `start`. nil = make a new track.
    /// Looks at tracks top first for video, first first for sound.
    static func trackWithRoom(kind: TrackKind, start: Double, length: Double, in movie: Movie) -> Track? {
        let tracks = displayTracks(movie).filter { $0.kind == kind }
        return tracks.first { isFree(start: start, length: length, occupied: occupied(onTrack: $0.id, in: movie)) }
    }

    /// A name like "Video 2" that no track has yet.
    static func newTrackName(kind: TrackKind, in movie: Movie) -> String {
        let base = kind == .video ? "Video" : "Sound"
        let names = Set(movie.tracks.map(\.name))
        var n = movie.tracks.filter { $0.kind == kind }.count + 1
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Volume and fades

    /// How faded the clip is at movie time `t`: 0 (silent / see-through) to 1 (full).
    static func fadeGain(_ clip: Clip, at t: Double) -> Double {
        let c = clampFades(clip)
        let u = t - c.start
        let left = c.end - t
        var g = 1.0
        if c.fadeIn > 0 { g = min(g, u / c.fadeIn) }
        if c.fadeOut > 0 { g = min(g, left / c.fadeOut) }
        return clamp(g, 0, 1)
    }

    /// Clip volume times track volume (0 when the track is muted).
    static func totalGain(clip: Clip, track: Track?) -> Double {
        if track?.muted == true { return 0 }
        let tv = clamp(track?.volume ?? 1, 0, maxVolume)
        return clamp(clip.volume, 0, maxVolume) * tv
    }

    /// The player can only turn one copy of a sound down, not up. To make it louder than 100%
    /// we play the same sound 2-4 times at once, each a bit quieter.
    static func copiesNeeded(gain: Double) -> Int {
        guard gain.isFinite, gain > 1 + 1e-9 else { return 1 }
        return min(4, Int(gain.rounded(.up)))
    }

    /// The volume curve for one copy of a clip on the movie timeline.
    static func volumeSegments(_ clip: Clip, gain: Double, copies: Int) -> [StudioVolumeSegment] {
        let c = clampFades(clip)
        let level = clamp(gain / Double(max(1, copies)), 0, 1)
        let s = c.start, e = c.end
        guard e > s else { return [] }
        if level <= 0 { return [StudioVolumeSegment(start: s, end: e, from: 0, to: 0)] }
        var out: [StudioVolumeSegment] = []
        if c.fadeIn > 0 { out.append(StudioVolumeSegment(start: s, end: s + c.fadeIn, from: 0, to: level)) }
        let midStart = s + c.fadeIn, midEnd = e - c.fadeOut
        if midEnd - midStart > epsilon { out.append(StudioVolumeSegment(start: midStart, end: midEnd, from: level, to: level)) }
        if c.fadeOut > 0 { out.append(StudioVolumeSegment(start: e - c.fadeOut, end: e, from: level, to: 0)) }
        return out
    }

    // MARK: Timeline layout

    static func clampZoom(_ pixelsPerSecond: Double) -> Double {
        clamp(pixelsPerSecond, minPixelsPerSecond, maxPixelsPerSecond)
    }

    /// Screen x of movie time `t` when the playhead (at `playheadTime`) sits at `playheadX`.
    static func x(forTime t: Double, playheadTime: Double, playheadX: Double, pixelsPerSecond: Double) -> Double {
        playheadX + (t - playheadTime) * pixelsPerSecond
    }

    static func time(forX x: Double, playheadTime: Double, playheadX: Double, pixelsPerSecond: Double) -> Double {
        playheadTime + (x - playheadX) / max(0.0001, pixelsPerSecond)
    }

    /// The gap between labelled ruler marks: the smallest nice step at least `minSpacing` pixels wide.
    static func rulerStep(pixelsPerSecond: Double, minSpacing: Double) -> Double {
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let pps = max(0.0001, pixelsPerSecond)
        return steps.first { $0 * pps >= minSpacing } ?? steps[steps.count - 1]
    }

    /// The ruler marks between two times.
    static func rulerMarks(from t0: Double, to t1: Double, step: Double) -> [Double] {
        guard step > 0, t1 >= t0 else { return [] }
        let first = max(0, (t0 / step).rounded(.up))
        let last = (t1 / step).rounded(.down)
        guard last >= first, last - first < 2000 else { return [] }
        return stride(from: first, through: last, by: 1).map { $0 * step }
    }

    /// "1:05" or with tenths "1:05.3".
    static func timeLabel(_ seconds: Double, tenths: Bool = false) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        if tenths {
            let totalTenths = Int((s * 10).rounded(.down))
            let m = totalTenths / 600
            let sec = (totalTenths / 10) % 60
            let t = totalTenths % 10
            return String(format: "%d:%02d.%d", m, sec, t)
        }
        let total = Int(s.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The video size: the canvas size, made smaller if its long side is over `maxSide`, in even pixels.
    static func renderSize(canvasWidth: Double, canvasHeight: Double, maxSide: Double) -> (width: Int, height: Int) {
        let w = max(16, canvasWidth.isFinite ? canvasWidth : 16)
        let h = max(16, canvasHeight.isFinite ? canvasHeight : 16)
        let k = min(1, maxSide / max(w, h))
        func even(_ v: Double) -> Int { max(16, Int((v * k / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    /// Frames per second of the made video.
    static func videoFPS(projectFPS: Int) -> Int32 {
        projectFPS > 30 ? 60 : 30
    }

    /// The box a picture of `size` fills when fit inside `box`, centered.
    static func aspectFit(width: Double, height: Double, inWidth bw: Double, inHeight bh: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        guard width > 0, height > 0, bw > 0, bh > 0 else { return (0, 0, bw, bh) }
        let k = min(bw / width, bh / height)
        let w = width * k, h = height * k
        return ((bw - w) / 2, (bh - h) / 2, w, h)
    }

    // MARK: Waveforms

    /// Squeezes peaks into `count` bars, each the loudest of its share.
    static func downsample(_ peaks: [Float], to count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty else { return [] }
        if peaks.count <= count { return peaks }
        var out = [Float](repeating: 0, count: count)
        let n = peaks.count
        for i in 0..<count {
            let a = i * n / count
            let b = max(a + 1, (i + 1) * n / count)
            var m: Float = 0
            for j in a..<min(b, n) where peaks[j] > m { m = peaks[j] }
            out[i] = m
        }
        return out
    }

    /// The loudest peak between two source times.
    static func peak(in peaks: [Float], perSecond rate: Double, from t0: Double, to t1: Double) -> Float {
        guard !peaks.isEmpty, rate > 0, t1.isFinite, t0.isFinite else { return 0 }
        let a = max(0, Int((min(t0, t1) * rate).rounded(.down)))
        let b = min(peaks.count, max(a + 1, Int((max(t0, t1) * rate).rounded(.up))))
        guard a < b else { return 0 }
        var m: Float = 0
        for j in a..<b where peaks[j] > m { m = peaks[j] }
        return m
    }
}
