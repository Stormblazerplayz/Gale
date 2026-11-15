import Foundation

// MARK: - Ids

public enum GaleID {
    /// A new random id: 22 lowercase letters and digits. Sorts like any other string.
    public static func make() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var gen = SystemRandomNumberGenerator()
        return String((0..<22).map { _ in chars[Int(gen.next() % UInt64(chars.count))] })
    }
}

/// Reads a value that may be missing in older or newer files.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback()
    }
}

// MARK: - Stroke points

/// One sampled point of a stroke.
/// x, y: canvas pixels (0,0 is top left, y goes down).
/// pressure: 0...1 (fingers use 0.5 unless the app simulates it).
/// altitude: Apple Pencil tilt in radians, pi/2 = standing straight up.
/// azimuth: which way the pencil leans, radians.
/// time: seconds since the stroke started.
public struct StrokePoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var pressure: Double
    public var altitude: Double
    public var azimuth: Double
    public var time: Double

    public init(x: Double, y: Double, pressure: Double = 0.5, altitude: Double = .pi / 2, azimuth: Double = 0, time: Double = 0) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.altitude = altitude
        self.azimuth = azimuth
        self.time = time
    }

    /// Numbers per point in the "pts" array.
    public static let stride = 6
}

// MARK: - Brushes

public enum BrushKind: String, Codable, CaseIterable, Sendable {
    case pen, pencil, marker, brush, airbrush, eraser

    /// Unknown kinds from newer files draw as a pen.
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = BrushKind(rawValue: s) ?? .pen
    }

    public var title: String {
        switch self {
        case .pen: return "Pen"
        case .pencil: return "Pencil"
        case .marker: return "Marker"
        case .brush: return "Ink Brush"
        case .airbrush: return "Airbrush"
        case .eraser: return "Eraser"
        }
    }
}

public struct Brush: Codable, Hashable, Sendable {
    public var kind: BrushKind
    public var color: RGBA
    /// Width in canvas pixels at full pressure.
    public var size: Double
    /// 0...1
    public var opacity: Double

    public init(kind: BrushKind = .pen, color: RGBA = .black, size: Double = 8, opacity: Double = 1) {
        self.kind = kind
        self.color = color
        self.size = size
        self.opacity = opacity
    }

    enum CodingKeys: String, CodingKey { case kind, color, size, opacity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, or: .pen)
        color = c.value(.color, or: .black)
        size = c.value(.size, or: 8)
        opacity = c.value(.opacity, or: 1)
    }
}

// MARK: - Strokes and fills

public struct Stroke: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Order key inside its cel (see OrderKey). Higher keys draw on top.
    public var key: String
    public var brush: Brush
    public var points: [StrokePoint]

    public init(id: String = GaleID.make(), key: String = OrderKey.first, brush: Brush, points: [StrokePoint]) {
        self.id = id
        self.key = key
        self.brush = brush
        self.points = points
    }

    enum CodingKeys: String, CodingKey { case id, key, brush, pts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        key = c.value(.key, or: OrderKey.first)
        brush = c.value(.brush, or: Brush())
        let flat: [Double] = c.value(.pts, or: [])
        points = Stroke.unpack(flat)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(brush, forKey: .brush)
        try c.encode(Stroke.pack(points), forKey: .pts)
    }

    /// Points as one flat list: x, y, pressure, altitude, azimuth, time for each point.
    /// Rounded so files stay small: 0.01 px, 0.001 for the rest.
    public static func pack(_ points: [StrokePoint]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(points.count * StrokePoint.stride)
        for p in points {
            out.append(round2(p.x))
            out.append(round2(p.y))
            out.append(round3(p.pressure))
            out.append(round3(p.altitude))
            out.append(round3(p.azimuth))
            out.append(round3(p.time))
        }
        return out
    }

    public static func unpack(_ flat: [Double]) -> [StrokePoint] {
        let n = flat.count / StrokePoint.stride
        var out: [StrokePoint] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let b = i * StrokePoint.stride
            out.append(StrokePoint(x: flat[b], y: flat[b + 1], pressure: flat[b + 2],
                                   altitude: flat[b + 3], azimuth: flat[b + 4], time: flat[b + 5]))
        }
        return out
    }

    static func round2(_ v: Double) -> Double { v.isFinite ? (v * 100).rounded() / 100 : 0 }
    static func round3(_ v: Double) -> Double { v.isFinite ? (v * 1000).rounded() / 1000 : 0 }

    /// The stroke as it will look after saving (rounded points). Handy for tests and sync.
    public var rounded: Stroke {
        var s = self
        s.points = Stroke.unpack(Stroke.pack(points))
        return s
    }
}

/// A paint-bucket fill: a closed outline filled with one color. Fills draw under the strokes of their cel.
public struct Fill: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var color: RGBA
    /// Closed outline as x, y, x, y, ...
    public var path: [Double]

    public init(id: String = GaleID.make(), key: String = OrderKey.first, color: RGBA, path: [Double]) {
        self.id = id
        self.key = key
        self.color = color
        self.path = path
    }

    enum CodingKeys: String, CodingKey { case id, key, color, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        key = c.value(.key, or: OrderKey.first)
        color = c.value(.color, or: .black)
        path = c.value(.path, or: [])
    }
}

/// What one layer shows on one frame.
public struct Cel: Codable, Hashable, Sendable {
    public var strokes: [Stroke]
    public var fills: [Fill]

    public init(strokes: [Stroke] = [], fills: [Fill] = []) {
        self.strokes = strokes
        self.fills = fills
    }

    enum CodingKeys: String, CodingKey { case strokes, fills }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokes = c.value(.strokes, or: [])
        fills = c.value(.fills, or: [])
        sortByKey()
    }

    public var isEmpty: Bool { strokes.isEmpty && fills.isEmpty }

    /// Keeps strokes and fills in key order (ties by id).
    public mutating func sortByKey() {
        strokes.sort { ($0.key, $0.id) < ($1.key, $1.id) }
        fills.sort { ($0.key, $0.id) < ($1.key, $1.id) }
    }

    /// Adds a stroke on top and gives it the right key.
    public mutating func append(_ stroke: Stroke) {
        var s = stroke
        s.key = OrderKey.between(strokes.last?.key, nil) ?? OrderKey.first
        strokes.append(s)
    }

    public mutating func append(_ fill: Fill) {
        var f = fill
        f.key = OrderKey.between(fills.last?.key, nil) ?? OrderKey.first
        fills.append(f)
    }
}

// MARK: - Layers and frames

public struct Layer: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Order key: lower keys are further back.
    public var key: String
    public var name: String
    public var visible: Bool
    public var locked: Bool
    /// 0...1
    public var opacity: Double

    public init(id: String = GaleID.make(), key: String = OrderKey.first, name: String, visible: Bool = true, locked: Bool = false, opacity: Double = 1) {
        self.id = id
        self.key = key
        self.name = name
        self.visible = visible
        self.locked = locked
        self.opacity = opacity
    }

    enum CodingKeys: String, CodingKey { case id, key, name, visible, locked, opacity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        key = c.value(.key, or: OrderKey.first)
        name = c.value(.name, or: "Layer")
        visible = c.value(.visible, or: true)
        locked = c.value(.locked, or: false)
        opacity = c.value(.opacity, or: 1)
    }
}

public struct Frame: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var key: String
    /// How many ticks (1/fps seconds) this frame stays on screen. 1 = "on ones", 2 = "on twos".
    public var hold: Int
    /// Cels by layer id. A layer with no entry is empty on this frame.
    public var cels: [String: Cel]

    public init(id: String = GaleID.make(), key: String = OrderKey.first, hold: Int = 1, cels: [String: Cel] = [:]) {
        self.id = id
        self.key = key
        self.hold = max(1, hold)
        self.cels = cels
    }

    enum CodingKeys: String, CodingKey { case id, key, hold, cels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        key = c.value(.key, or: OrderKey.first)
        hold = max(1, c.value(.hold, or: 1))
        cels = c.value(.cels, or: [:])
    }

    public func cel(_ layerID: String) -> Cel { cels[layerID] ?? Cel() }
}

// MARK: - Effects

public struct MotionBlurSettings: Codable, Hashable, Sendable {
    public var on: Bool
    /// 0...1: how long the blur trail is compared to how far things moved.
    public var amount: Double
    /// How many faded copies make the trail (2...16).
    public var samples: Int

    public init(on: Bool = false, amount: Double = 0.6, samples: Int = 6) {
        self.on = on
        self.amount = amount
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey { case on, amount, samples }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = c.value(.on, or: false)
        amount = c.value(.amount, or: 0.6)
        samples = c.value(.samples, or: 6)
    }
}

/// A hair (or cloth, tail, grass...) region that the app sways by itself.
public struct HairRegion: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Only strokes on this layer move.
    public var layer: String
    /// Closed outline around the hair: x, y, x, y, ...
    public var polygon: [Double]
    /// Where the hair is attached: x1, y1, x2, y2. Points on this line stay still; the far side sways most.
    public var root: [Double]
    /// 0 = floppy, 1 = stiff.
    public var stiffness: Double
    /// -1...1: steady wind pushing one way.
    public var wind: Double
    /// 0...1: extra random-ish gusts.
    public var gust: Double
    /// Sways per second (0.2...3).
    public var speed: Double
    public var on: Bool

    public init(id: String = GaleID.make(), layer: String, polygon: [Double], root: [Double],
                stiffness: Double = 0.4, wind: Double = 0, gust: Double = 0.3, speed: Double = 0.8, on: Bool = true) {
        self.id = id
        self.layer = layer
        self.polygon = polygon
        self.root = root
        self.stiffness = stiffness
        self.wind = wind
        self.gust = gust
        self.speed = speed
        self.on = on
    }

    enum CodingKeys: String, CodingKey { case id, layer, polygon, root, stiffness, wind, gust, speed, on }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        layer = c.value(.layer, or: "")
        polygon = c.value(.polygon, or: [])
        root = c.value(.root, or: [0, 0, 0, 0])
        stiffness = c.value(.stiffness, or: 0.4)
        wind = c.value(.wind, or: 0)
        gust = c.value(.gust, or: 0.3)
        speed = c.value(.speed, or: 0.8)
        on = c.value(.on, or: true)
    }
}

// MARK: - Movie (video and audio editing)

public enum MediaKind: String, Codable, Sendable {
    case video, audio, image

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = MediaKind(rawValue: s) ?? .video
    }
}

/// A file inside the project's media folder.
public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// File name inside "media/", like "k3j2....m4a".
    public var file: String
    public var kind: MediaKind
    public var name: String
    /// Length in seconds (0 for pictures).
    public var duration: Double
    /// SHA-256 of the file in lowercase hex (used by sync to copy the file once).
    public var sha256: String

    public init(id: String = GaleID.make(), file: String, kind: MediaKind, name: String, duration: Double, sha256: String = "") {
        self.id = id
        self.file = file
        self.kind = kind
        self.name = name
        self.duration = duration
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey { case id, file, kind, name, duration, sha256 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        file = c.value(.file, or: "")
        kind = c.value(.kind, or: .video)
        name = c.value(.name, or: "Clip")
        duration = c.value(.duration, or: 0)
        sha256 = c.value(.sha256, or: "")
    }
}

public enum TrackKind: String, Codable, Sendable {
    case video, audio

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = TrackKind(rawValue: s) ?? .audio
    }
}

public struct Track: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var kind: TrackKind
    public var name: String
    public var muted: Bool
    /// 0...2
    public var volume: Double

    public init(id: String = GaleID.make(), key: String = OrderKey.first, kind: TrackKind, name: String, muted: Bool = false, volume: Double = 1) {
        self.id = id
        self.key = key
        self.kind = kind
        self.name = name
        self.muted = muted
        self.volume = volume
    }

    enum CodingKeys: String, CodingKey { case id, key, kind, name, muted, volume }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        key = c.value(.key, or: OrderKey.first)
        kind = c.value(.kind, or: .audio)
        name = c.value(.name, or: "Track")
        muted = c.value(.muted, or: false)
        volume = c.value(.volume, or: 1)
    }
}

/// A piece of media placed on a track.
public struct Clip: Codable, Hashable, Identifiable, Sendable {
    /// Use this as `media` to place the drawn animation itself.
    public static let animation = "animation"

    public var id: String
    public var track: String
    /// A MediaItem id, or "animation".
    public var media: String
    /// Where it starts on the movie timeline, in seconds.
    public var start: Double
    /// Where it starts inside the source file, in seconds (trim from the front).
    public var inPoint: Double
    /// How much of the source it uses, in seconds (before speed).
    public var duration: Double
    /// 0.25...4
    public var speed: Double
    /// 0...2
    public var volume: Double
    public var fadeIn: Double
    public var fadeOut: Double

    public init(id: String = GaleID.make(), track: String, media: String, start: Double, inPoint: Double = 0, duration: Double,
                speed: Double = 1, volume: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.id = id
        self.track = track
        self.media = media
        self.start = start
        self.inPoint = inPoint
        self.duration = duration
        self.speed = speed
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    /// How long it lasts on the timeline (duration / speed).
    public var length: Double { duration / max(0.01, speed) }
    public var end: Double { start + length }

    enum CodingKeys: String, CodingKey {
        case id, track, media, start, duration, speed, volume, fadeIn, fadeOut
        case inPoint = "in"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: GaleID.make())
        track = c.value(.track, or: "")
        media = c.value(.media, or: "")
        start = c.value(.start, or: 0)
        inPoint = c.value(.inPoint, or: 0)
        duration = c.value(.duration, or: 0)
        speed = c.value(.speed, or: 1)
        volume = c.value(.volume, or: 1)
        fadeIn = c.value(.fadeIn, or: 0)
        fadeOut = c.value(.fadeOut, or: 0)
    }
}

public struct Movie: Codable, Hashable, Sendable {
    /// true: the drawing plays on top of the video clips (draw on video).
    public var overlay: Bool
    public var tracks: [Track]
    public var clips: [Clip]

    public init(overlay: Bool = false, tracks: [Track] = [], clips: [Clip] = []) {
        self.overlay = overlay
        self.tracks = tracks
        self.clips = clips
    }

    enum CodingKeys: String, CodingKey { case overlay, tracks, clips }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlay = c.value(.overlay, or: false)
        tracks = c.value(.tracks, or: [])
        clips = c.value(.clips, or: [])
        tracks.sort { ($0.key, $0.id) < ($1.key, $1.id) }
    }

    public var isEmpty: Bool { clips.isEmpty }
    /// End of the last clip, in seconds.
    public var length: Double { clips.map(\.end).max() ?? 0 }
}

// MARK: - Project

public struct Canvas: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public var background: RGBA

    public init(width: Double = 1920, height: Double = 1080, background: RGBA = .white) {
        self.width = width
        self.height = height
        self.background = background
    }

    enum CodingKeys: String, CodingKey { case width, height, background }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = max(16, c.value(.width, or: 1920))
        height = max(16, c.value(.height, or: 1080))
        background = c.value(.background, or: .white)
    }
}

public struct GaleProject: Codable, Hashable, Identifiable, Sendable {
    public static let formatName = "gale/1"

    public var format: String
    public var id: String
    public var name: String
    public var created: Date
    public var modified: Date
    public var canvas: Canvas
    /// Ticks per second for the animation (1...60).
    public var fps: Int
    public var motionBlur: MotionBlurSettings
    /// Back to front.
    public var layers: [Layer]
    /// In play order.
    public var frames: [Frame]
    public var hair: [HairRegion]
    public var movie: Movie
    public var media: [MediaItem]

    public init(id: String = GaleID.make(), name: String, canvas: Canvas = Canvas(), fps: Int = 12) {
        format = GaleProject.formatName
        self.id = id
        self.name = name
        let now = Date()
        created = now
        modified = now
        self.canvas = canvas
        self.fps = fps
        motionBlur = MotionBlurSettings()
        let layer = Layer(key: OrderKey.first, name: "Layer 1")
        layers = [layer]
        frames = [Frame(key: OrderKey.first)]
        hair = []
        movie = Movie()
        media = []
    }

    enum CodingKeys: String, CodingKey { case format, id, name, created, modified, canvas, fps, motionBlur, layers, frames, hair, movie, media }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.value(.format, or: GaleProject.formatName)
        id = c.value(.id, or: GaleID.make())
        name = c.value(.name, or: "Untitled")
        created = c.value(.created, or: Date())
        modified = c.value(.modified, or: created)
        canvas = c.value(.canvas, or: Canvas())
        fps = min(60, max(1, c.value(.fps, or: 12)))
        motionBlur = c.value(.motionBlur, or: MotionBlurSettings())
        layers = c.value(.layers, or: [])
        frames = c.value(.frames, or: [])
        hair = c.value(.hair, or: [])
        movie = c.value(.movie, or: Movie())
        media = c.value(.media, or: [])
        normalize()
    }

    /// Fixes anything a hand-edited or synced file could get wrong: sort orders, at least one layer and one frame.
    public mutating func normalize() {
        layers.sort { ($0.key, $0.id) < ($1.key, $1.id) }
        frames.sort { ($0.key, $0.id) < ($1.key, $1.id) }
        if layers.isEmpty { layers = [Layer(key: OrderKey.first, name: "Layer 1")] }
        if frames.isEmpty { frames = [Frame(key: OrderKey.first)] }
        fps = min(60, max(1, fps))
        movie.tracks.sort { ($0.key, $0.id) < ($1.key, $1.id) }
    }

    // MARK: Lookups

    public func layerIndex(_ id: String) -> Int? { layers.firstIndex { $0.id == id } }
    public func frameIndex(_ id: String) -> Int? { frames.firstIndex { $0.id == id } }

    /// Total length of the animation in ticks (sum of holds).
    public var totalTicks: Int { frames.reduce(0) { $0 + $1.hold } }
    public var duration: Double { Double(totalTicks) / Double(max(1, fps)) }

    // MARK: Edits that keep keys right

    @discardableResult
    public mutating func addLayer(name: String, above index: Int? = nil) -> Layer {
        let i = min(layers.count - 1, index ?? layers.count - 1)
        let lower = i >= 0 ? layers[i].key : nil
        let upper = i + 1 < layers.count ? layers[i + 1].key : nil
        let layer = Layer(key: OrderKey.between(lower, upper) ?? OrderKey.first, name: name)
        layers.insert(layer, at: i + 1)
        return layer
    }

    /// Inserts a frame after `index` (nil = at the end) and returns where it went.
    @discardableResult
    public mutating func insertFrame(_ frame: Frame, after index: Int?) -> Int {
        let i = min(frames.count - 1, index ?? frames.count - 1)
        let lower = i >= 0 ? frames[i].key : nil
        let upper = i + 1 < frames.count ? frames[i + 1].key : nil
        var f = frame
        f.key = OrderKey.between(lower, upper) ?? OrderKey.first
        frames.insert(f, at: i + 1)
        return i + 1
    }

    /// Moves a frame to a new place in the list.
    public mutating func moveFrame(from: Int, to: Int) {
        guard frames.indices.contains(from), to >= 0, to < frames.count, from != to else { return }
        var f = frames.remove(at: from)
        let lower = to > 0 ? frames[to - 1].key : nil
        let upper = to < frames.count ? frames[to].key : nil
        f.key = OrderKey.between(lower, upper) ?? f.key
        frames.insert(f, at: to)
    }

    public mutating func moveLayer(from: Int, to: Int) {
        guard layers.indices.contains(from), to >= 0, to < layers.count, from != to else { return }
        var l = layers.remove(at: from)
        let lower = to > 0 ? layers[to - 1].key : nil
        let upper = to < layers.count ? layers[to].key : nil
        l.key = OrderKey.between(lower, upper) ?? l.key
        layers.insert(l, at: to)
    }

    public mutating func addTrack(kind: TrackKind, name: String) -> Track {
        let t = Track(key: OrderKey.between(movie.tracks.last?.key, nil) ?? OrderKey.first, kind: kind, name: name)
        movie.tracks.append(t)
        return t
    }
}
