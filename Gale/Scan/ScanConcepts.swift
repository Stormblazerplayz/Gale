import Foundation
import GaleCore
import GaleFormat

// Body scan → character concepts, drawn as real Gale vector strokes and fills.
// Pure Swift (Foundation + GaleFormat + GaleCore), so it is tested on Linux.
//
// How it works:
//  1. A style (chibi, hero, ...) re-builds the scanned skeleton with new bone lengths and head size,
//     keeping every bone's direction, so the character has the person's pose and build.
//  2. A seeded random "look" picks colors, hair, outfit and accessories (Shuffle = new seed).
//  3. The 3D figure is turned around the up axis and projected flat. Each body part becomes a
//     filled shape with an ink rim, drawn back to front, plus pen strokes for details.
//     Turnarounds draw the same figure from the front, 3/4, side and back.

// MARK: - Styles

enum ScanStyle: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chibi, hero, noodle, robot, creature, mannequin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chibi: return "Chibi"
        case .hero: return "Hero"
        case .noodle: return "Noodle"
        case .robot: return "Robot"
        case .creature: return "Creature"
        case .mannequin: return "Sketch"
        }
    }

    var blurb: String {
        switch self {
        case .chibi: return "Big head, tiny body, super cute."
        case .hero: return "Tall and strong, ready to save the day."
        case .noodle: return "Bendy rubber-hose arms like old cartoons."
        case .robot: return "Metal boxes and glowing lights."
        case .creature: return "Half animal, half you."
        case .mannequin: return "A drawing guide with your real proportions."
        }
    }

    /// SF Symbol name for buttons.
    var symbol: String {
        switch self {
        case .chibi: return "face.smiling"
        case .hero: return "bolt.fill"
        case .noodle: return "scribble"
        case .robot: return "gearshape.2.fill"
        case .creature: return "pawprint.fill"
        case .mannequin: return "pencil.and.outline"
        }
    }
}

// MARK: - Seeded random

/// SplitMix64: the same seed always gives the same numbers, on every device.
struct ScanRandom {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed ^ 0x2545F4914F6CDD1D
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func unit() -> Double { Double(next() >> 11) / 9007199254740992.0 }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    /// 0 ..< n
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    /// `items` must not be empty.
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }

    /// Mixes two numbers into a new seed.
    static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var r = ScanRandom(seed: a ^ (b &* 0xD6E8FEB86659FD93))
        _ = r.next()
        return r.next()
    }
}

// MARK: - Colors

enum ScanColor {
    static func hsv(_ h: Double, _ s: Double, _ v: Double, _ a: Double = 1) -> RGBA {
        let hh = (h - floor(h)) * 6
        let i = Int(hh) % 6
        let f = hh - floor(hh)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i {
        case 0: return RGBA(v, t, p, a)
        case 1: return RGBA(q, v, p, a)
        case 2: return RGBA(p, v, t, a)
        case 3: return RGBA(p, q, v, a)
        case 4: return RGBA(t, p, v, a)
        default: return RGBA(v, p, q, a)
        }
    }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    }

    /// k < 0 darker, k > 0 lighter (-1...1).
    static func shade(_ c: RGBA, _ k: Double) -> RGBA {
        k < 0 ? mix(c, RGBA(0, 0, 0, c.a), -k) : mix(c, RGBA(1, 1, 1, c.a), k)
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> RGBA { RGBA(r, g, b, 1) }
}

// MARK: - Look options

enum ScanHair: String, CaseIterable, Hashable, Sendable {
    case buzz, short, spiky, bob, long, ponytail, curly, mohawk, bald

    var title: String {
        switch self {
        case .buzz: return "buzz cut"
        case .short: return "short hair"
        case .spiky: return "spiky hair"
        case .bob: return "bob"
        case .long: return "long hair"
        case .ponytail: return "ponytail"
        case .curly: return "curly hair"
        case .mohawk: return "mohawk"
        case .bald: return "no hair"
        }
    }
}

enum ScanOutfit: String, CaseIterable, Hashable, Sendable {
    case tee, hoodie, jacket, dress, overalls, suit, trunks, fur, plating, none

    var title: String {
        switch self {
        case .tee: return "T-shirt"
        case .hoodie: return "hoodie"
        case .jacket: return "jacket"
        case .dress: return "dress"
        case .overalls: return "overalls"
        case .suit: return "hero suit"
        case .trunks: return "suit and trunks"
        case .fur: return "just fur"
        case .plating: return "metal plates"
        case .none: return "guide lines"
        }
    }
}

enum ScanAccessory: String, CaseIterable, Hashable, Sendable {
    case cape, scarf, cap, beanie, wizardHat, crown, glasses, headphones, backpack, mask, antenna, shoulderPads, jetpack, bowtie

    var title: String {
        switch self {
        case .cape: return "cape"
        case .scarf: return "scarf"
        case .cap: return "cap"
        case .beanie: return "beanie"
        case .wizardHat: return "wizard hat"
        case .crown: return "crown"
        case .glasses: return "glasses"
        case .headphones: return "headphones"
        case .backpack: return "backpack"
        case .mask: return "mask"
        case .antenna: return "antenna"
        case .shoulderPads: return "shoulder armor"
        case .jetpack: return "jetpack"
        case .bowtie: return "bow tie"
        }
    }

    var isHat: Bool { self == .cap || self == .beanie || self == .wizardHat || self == .crown }
}

enum ScanCreature: String, CaseIterable, Hashable, Sendable {
    case cat, fox, bunny, bear, dragon

    var title: String { rawValue }
}

struct ScanPalette: Hashable, Sendable {
    var skin: RGBA
    var hair: RGBA
    var main: RGBA
    var second: RGBA
    var accent: RGBA
    var shoes: RGBA
    var ink: RGBA
    var eye: RGBA
    var light: RGBA
}

/// Everything the dice picked for one concept. The same seed always gives the same look.
struct ScanLook: Hashable, Sendable {
    var style: ScanStyle
    var seed: UInt64
    var name: String
    var palette: ScanPalette
    var hair: ScanHair
    var outfit: ScanOutfit
    var accessories: [ScanAccessory]
    var creature: ScanCreature
    var longSleeves: Bool
    var longPants: Bool
    var variant: Int
    /// Which way the character is turned on its card (radians, 0 = facing you).
    var view: Double
    /// Thicker or thinner limbs (about 0.88...1.15).
    var bulk: Double

    func has(_ a: ScanAccessory) -> Bool { accessories.contains(a) }

    /// "Chibi · spiky hair · hoodie · cap"
    var summary: String {
        var bits: [String] = [style.title]
        switch style {
        case .creature:
            bits.append(creature.title)
        case .mannequin:
            bits.append("proportion guide")
        default:
            break
        }
        if style != .robot && style != .mannequin { bits.append(hair.title) }
        if style != .mannequin && outfit != .none { bits.append(outfit.title) }
        bits.append(contentsOf: accessories.map(\.title))
        return bits.joined(separator: " · ")
    }
}

// MARK: - Results

/// Strokes and fills in canvas pixels (y down).
struct ScanDrawing: Hashable, Sendable {
    var strokes: [Stroke]
    var fills: [Fill]

    init(strokes: [Stroke] = [], fills: [Fill] = []) {
        self.strokes = strokes
        self.fills = fills
    }

    var isEmpty: Bool { strokes.isEmpty && fills.isEmpty }

    var bounds: Box {
        var b = Geometry.bounds(of: strokes)
        for f in fills { b = b.union(Geometry.bounds(ofPath: f.path)) }
        return b
    }

    var cel: Cel { Cel(strokes: strokes, fills: fills) }

    /// Scales around (0, 0), then moves. Brush sizes scale too.
    func transformed(scale k: Double, dx: Double, dy: Double) -> ScanDrawing {
        var s = StrokeTransform.scale(strokes, by: k, around: .zero)
        var f = StrokeTransform.scale(fills, by: k, around: .zero)
        s = StrokeTransform.translate(s, dx: dx, dy: dy)
        f = StrokeTransform.translate(f, dx: dx, dy: dy)
        f = f.map { fill in
            var fill = fill
            fill.path = fill.path.map { ($0 * 100).rounded() / 100 }
            return fill
        }
        return ScanDrawing(strokes: s, fills: f)
    }

    /// Scale and position to sit in the middle of `box`, as big as fits.
    func fitted(into box: Box) -> ScanDrawing {
        let b = bounds
        guard !b.isEmpty, b.width > 0, b.height > 0, !box.isEmpty else { return self }
        let k = min(box.width / b.width, box.height / b.height)
        let dx = box.center.x - b.center.x * k
        let dy = box.center.y - b.center.y * k
        return transformed(scale: k, dx: dx, dy: dy)
    }

    /// The transform that `fitted(into:)` would use, so several drawings can share it.
    static func fitTransform(_ b: Box, into box: Box) -> (k: Double, dx: Double, dy: Double) {
        guard !b.isEmpty, b.width > 0, b.height > 0, !box.isEmpty else { return (1, 0, 0) }
        let k = min(box.width / b.width, box.height / b.height)
        return (k, box.center.x - b.center.x * k, box.center.y - b.center.y * k)
    }

    /// Same drawing with brand-new ids (for pasting a second copy).
    var withFreshIDs: ScanDrawing {
        ScanDrawing(strokes: StrokeTransform.freshIDs(strokes), fills: StrokeTransform.freshIDs(fills))
    }
}

struct ScanConcept: Identifiable, Hashable, Sendable {
    var id: String { "\(look.style.rawValue)-\(look.seed)" }
    let look: ScanLook
    /// The character in its scanned pose, in pixels, standing on y = 0.
    let drawing: ScanDrawing

    var style: ScanStyle { look.style }
    var name: String { look.name }
    var seed: UInt64 { look.seed }
}

struct ScanTurnaround: Hashable, Sendable {
    static let titles = ["Front", "3/4", "Side", "Back"]
    static let angles: [Double] = [0, Double.pi / 4, Double.pi / 2, Double.pi]

    /// Four views, each centered on x = 0 and standing on y = 0, all the same size.
    let views: [ScanDrawing]
    /// Light guide lines (top of head, chin, shoulders, hips, knees, floor) behind one view.
    let guides: ScanDrawing
    /// All four views side by side with guide lines behind them.
    let sheet: ScanDrawing
}

// MARK: - Flat shapes

struct ScanSection: Hashable, Sendable {
    var center: Vec2
    var normal: Vec2
    var half: Double
}

enum ScanShape: Hashable, Sendable {
    case capsule(Vec2, Vec2, Double, Double)
    /// center, x radius, y radius, rotation (radians)
    case ellipse(Vec2, Double, Double, Double)
    case polygon([Vec2])
    /// A body shape made from slices, bottom to top.
    case band([ScanSection])

    /// The outline as a closed polygon, made `grow` pixels bigger all round.
    func path(grow g: Double) -> [Vec2] {
        switch self {
        case let .capsule(a, b, ra, rb):
            return ScanGeo.capsule(a, b, ra + g, rb + g)
        case let .ellipse(c, rx, ry, rot):
            return ScanGeo.ellipse(c, rx + g, ry + g, rot)
        case let .polygon(pts):
            return g == 0 ? pts : ScanGeo.offset(pts, g)
        case let .band(secs):
            guard secs.count >= 2 else { return [] }
            var left: [Vec2] = []
            var right: [Vec2] = []
            for s in secs {
                left.append(s.center + s.normal * (s.half + g))
                right.append(s.center - s.normal * (s.half + g))
            }
            let n = secs.count
            var bottomDir = (secs[0].center - secs[1].center).normalized
            if bottomDir == .zero { bottomDir = Vec2(0, 1) }
            var topDir = (secs[n - 1].center - secs[n - 2].center).normalized
            if topDir == .zero { topDir = Vec2(0, -1) }
            var out: [Vec2] = []
            out.append(secs[0].center + bottomDir * g)
            out.append(contentsOf: left)
            out.append(secs[n - 1].center + topDir * g)
            out.append(contentsOf: right.reversed())
            return out
        }
    }
}

enum ScanGeo {
    static func circle(_ c: Vec2, _ r: Double, segments: Int = 24) -> [Vec2] {
        (0..<segments).map { i in
            let t = Double(i) / Double(segments) * 2 * Double.pi
            return c + Vec2(cos(t), sin(t)) * r
        }
    }

    static func ellipse(_ c: Vec2, _ rx: Double, _ ry: Double, _ rot: Double, segments: Int = 32) -> [Vec2] {
        let cr = cos(rot), sr = sin(rot)
        let x = max(0.3, rx), y = max(0.3, ry)
        return (0..<segments).map { i in
            let t = Double(i) / Double(segments) * 2 * Double.pi
            let lx = x * cos(t)
            let ly = y * sin(t)
            return Vec2(c.x + lx * cr - ly * sr, c.y + lx * sr + ly * cr)
        }
    }

    /// The outline around two circles (a rounded, tapered tube).
    static func capsule(_ a: Vec2, _ b: Vec2, _ ra0: Double, _ rb0: Double) -> [Vec2] {
        let ra = max(0.5, ra0), rb = max(0.5, rb0)
        let d = b - a
        let len = d.length
        if len < 1e-6 || len <= abs(ra - rb) {
            return circle(ra >= rb ? a : b, max(ra, rb))
        }
        let u = d / len
        let th = atan2(u.y, u.x)
        let alpha = acos(max(-1, min(1, (ra - rb) / len)))
        let step = Double.pi / 10
        var pts: [Vec2] = []
        let nb = max(4, Int((2 * alpha / step).rounded(.up)))
        for i in 0...nb {
            let t = th + alpha - 2 * alpha * Double(i) / Double(nb)
            pts.append(b + Vec2(cos(t), sin(t)) * rb)
        }
        let sweep = 2 * Double.pi - 2 * alpha
        let na = max(4, Int((sweep / step).rounded(.up)))
        for i in 0...na {
            let t = th - alpha - sweep * Double(i) / Double(na)
            pts.append(a + Vec2(cos(t), sin(t)) * ra)
        }
        return pts
    }

    /// The two straight sides of a capsule (for sketch lines).
    static func capsuleSides(_ a: Vec2, _ b: Vec2, _ ra: Double, _ rb: Double) -> [[Vec2]] {
        let d = b - a
        let len = d.length
        guard len > 1e-6, len > abs(ra - rb) else { return [] }
        let u = d / len
        let th = atan2(u.y, u.x)
        let alpha = acos(max(-1, min(1, (ra - rb) / len)))
        let n1 = Vec2(cos(th + alpha), sin(th + alpha))
        let n2 = Vec2(cos(th - alpha), sin(th - alpha))
        return [[a + n1 * ra, b + n1 * rb], [a + n2 * ra, b + n2 * rb]]
    }

    static func signedArea(_ p: [Vec2]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    /// Pushes every corner of a polygon out by d (miter joins, limited on sharp corners).
    static func offset(_ p: [Vec2], _ d: Double) -> [Vec2] {
        let n = p.count
        guard n >= 3 else { return p }
        let s: Double = signedArea(p) >= 0 ? 1 : -1
        var out: [Vec2] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let prev = p[(i - 1 + n) % n], cur = p[i], next = p[(i + 1) % n]
            let e1 = (cur - prev).normalized
            let e2 = (next - cur).normalized
            let n1 = Vec2(e1.y, -e1.x) * s
            let n2 = Vec2(e2.y, -e2.x) * s
            var bis = (n1 + n2).normalized
            if bis == .zero { bis = n1 == .zero ? n2 : n1 }
            let cosHalf = max(0.4, bis.dot(n1 == .zero ? bis : n1))
            out.append(cur + bis * (d / cosHalf))
        }
        return out
    }

    /// Smallest convex shape around the points.
    static func hull(_ pts: [Vec2]) -> [Vec2] {
        let sorted = pts.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard sorted.count >= 3 else { return sorted }
        func turn(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double { (a - o).cross(b - o) }
        var lower: [Vec2] = []
        for p in sorted {
            while lower.count >= 2 && turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Vec2] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Evenly spaced points along a polyline (keeps both ends).
    static func resample(_ pts: [Vec2], spacing: Double) -> [Vec2] {
        guard pts.count >= 2, spacing > 0 else { return pts }
        var out: [Vec2] = [pts[0]]
        var carry = 0.0
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let seg = a.distance(to: b)
            if seg < 1e-9 { continue }
            var t = spacing - carry
            while t < seg {
                out.append(Vec2.lerp(a, b, t / seg))
                t += spacing
            }
            carry = seg - (t - spacing)
        }
        if let last = pts.last, let end = out.last, end.distance(to: last) > 1e-6 { out.append(last) }
        return out
    }

    static func flat(_ pts: [Vec2]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(pts.count * 2)
        for p in pts {
            out.append((p.x * 100).rounded() / 100)
            out.append((p.y * 100).rounded() / 100)
        }
        return out
    }

    static func box(of pts: [Vec2]) -> Box {
        var b = Box.empty
        for p in pts { b.add(p) }
        return b
    }

    static func smooth(_ u: Double) -> Double {
        let t = max(0, min(1, u))
        return t * t * (3 - 2 * t)
    }

    /// Triangle wave 0...1 with period 2.
    static func tri(_ x: Double) -> Double {
        var m = x.truncatingRemainder(dividingBy: 2)
        if m < 0 { m += 2 }
        return 1 - abs(m - 1)
    }

    static func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

    /// A star or burst polygon.
    static func star(_ c: Vec2, outer: Double, inner: Double, points: Int, sx: Double = 1) -> [Vec2] {
        let n = max(3, points) * 2
        return (0..<n).map { i in
            let r = i % 2 == 0 ? outer : inner
            let t = -Double.pi / 2 + Double(i) / Double(n) * 2 * Double.pi
            return Vec2(c.x + cos(t) * r * sx, c.y + sin(t) * r)
        }
    }
}

// MARK: - Body parts and drawing order

struct ScanPaint: Hashable, Sendable {
    var shape: ScanShape
    var color: RGBA
}

struct ScanLine: Hashable, Sendable {
    var points: [Vec2]
    var color: RGBA
    var width: Double
    var kind: BrushKind = .pen
    var pressure: Double = 1
    var opacity: Double = 1
}

/// One body part: a group of shapes sharing one ink rim, then details, then lines.
struct ScanPart {
    var depth: Double
    var rim: Double = 0
    var ink: RGBA = .black
    var shapes: [ScanPaint] = []
    var details: [ScanPaint] = []
    var lines: [ScanLine] = []
    /// Sketch lines stay strokes even when something covers them.
    var keepLinesAsStrokes = false
}

enum ScanCompose {
    /// Draws parts back to front. Lines become pen strokes on top, unless a part drawn later covers
    /// them; then they become thin fills so the covering part hides them properly.
    static func drawing(parts: [ScanPart], under: [ScanPaint] = [], over: [ScanLine] = []) -> ScanDrawing {
        let order = parts.enumerated().sorted { a, b in
            a.element.depth != b.element.depth ? a.element.depth < b.element.depth : a.offset < b.offset
        }.map(\.element)
        // Each part's outline polygons (with rim), to test whether a later part hides a line.
        let cover: [[(Box, [Double])]] = order.map { part in
            var polys: [(Box, [Double])] = []
            for s in part.shapes {
                let path = s.shape.path(grow: part.rim)
                polys.append((ScanGeo.box(of: path), ScanGeo.flat(path)))
            }
            for s in part.details {
                let path = s.shape.path(grow: 0)
                polys.append((ScanGeo.box(of: path), ScanGeo.flat(path)))
            }
            return polys
        }
        func hidden(_ line: ScanLine, after i: Int) -> Bool {
            guard i + 1 < order.count else { return false }
            let lb = ScanGeo.box(of: line.points).inset(by: -line.width)
            let samples = ScanGeo.resample(line.points, spacing: max(2, line.width))
            for j in (i + 1)..<order.count {
                for (box, poly) in cover[j] where box.intersects(lb) {
                    for q in samples where box.inset(by: -line.width).contains(q) {
                        if Geometry.contains(poly, q) || Geometry.distanceToOutline(poly, q) < line.width * 0.6 { return true }
                    }
                }
            }
            return false
        }
        var cel = Cel()
        func addFill(_ pts: [Vec2], _ color: RGBA) {
            guard pts.count >= 3, color.a > 0 else { return }
            for p in pts where !(p.x.isFinite && p.y.isFinite) { return }
            cel.append(Fill(color: color, path: ScanGeo.flat(pts)))
        }
        for u in under { addFill(u.shape.path(grow: 0), u.color) }
        var strokeLines: [ScanLine] = []
        for (i, part) in order.enumerated() {
            if part.rim > 0 {
                for s in part.shapes { addFill(s.shape.path(grow: part.rim), part.ink) }
            }
            for s in part.shapes { addFill(s.shape.path(grow: 0), s.color) }
            for s in part.details { addFill(s.shape.path(grow: 0), s.color) }
            for line in part.lines where !line.points.isEmpty {
                if part.keepLinesAsStrokes {
                    strokeLines.append(line)
                    continue
                }
                if hidden(line, after: i) {
                    addFill(lineOutline(line), line.color.with(alpha: line.color.a * line.opacity))
                } else {
                    strokeLines.append(line)
                }
            }
        }
        for line in strokeLines + over {
            if let s = stroke(line) { cel.append(s) }
        }
        return ScanDrawing(strokes: cel.strokes, fills: cel.fills)
    }

    static func stroke(_ line: ScanLine) -> Stroke? {
        let pts = ScanGeo.resample(line.points, spacing: max(3, line.width * 0.9))
        guard !pts.isEmpty else { return nil }
        for p in pts where !(p.x.isFinite && p.y.isFinite) { return nil }
        let sp = pts.enumerated().map { i, p in
            StrokePoint(x: p.x, y: p.y, pressure: line.pressure, time: Double(i) * 0.01)
        }
        let brush = Brush(kind: line.kind, color: line.color, size: line.width, opacity: line.opacity)
        return Stroke(brush: brush, points: sp)
    }

    /// A pen line as a filled shape with pointy ends.
    static func lineOutline(_ line: ScanLine) -> [Vec2] {
        let pts = ScanGeo.resample(line.points, spacing: max(2, line.width * 0.7))
        let n = pts.count
        guard n > 0 else { return [] }
        let ramp = Double(max(1, min(6, n / 3)))
        let widths: [Double] = (0..<n).map { i in
            let t = min(1, min(Double(i), Double(n - 1 - i)) / ramp)
            return line.width * (n > 4 ? 0.35 + 0.65 * t : 1)
        }
        return StrokeShape.outline(points: pts, widths: widths)
    }
}

// MARK: - Camera

/// Turns the figure around the up axis and flattens it onto the page (y down).
struct ScanCamera {
    var angle: Double
    var scale: Double
    var origin: Vec2

    func turn(_ v: ScanVec3) -> ScanVec3 { v.rotatedY(angle) }

    func point(_ p: ScanVec3) -> Vec2 {
        let r = turn(p)
        return Vec2(origin.x + r.x * scale, origin.y - r.y * scale)
    }

    func depth(_ p: ScanVec3) -> Double { turn(p).z }

    /// A direction on the page (not scaled).
    func dir(_ v: ScanVec3) -> Vec2 {
        let r = turn(v)
        return Vec2(r.x, -r.y)
    }
}

// MARK: - Styled skeleton

struct ScanBuild {
    /// Target height in heads (nil keeps the person's own).
    var heads: Double?
    /// How much of the target to use (the rest is the person's own head size).
    var headBlend: Double = 0.8
    var arm: Double = 1
    var leg: Double = 1
    var torso: Double = 1
    var shoulder: Double = 1
    var hip: Double = 1
    var neck: Double = 1
}

/// The figure in 3D: the person's pose with the style's proportions. Standing height 1, feet on y = 0.
struct ScanRig {
    var j: [ScanJoint: ScanVec3]
    var headH: Double

    subscript(_ k: ScanJoint) -> ScanVec3 { j[k] ?? .zero }

    var right: ScanVec3 { ScanSkeleton.rightDirection(j) }
    var forward: ScanVec3 { ScanSkeleton.forwardDirection(j) }
    var spineUp: ScanVec3 {
        let v = (self[.neck] - self[.hips]).normalized
        return v == .zero ? .up : v
    }
    var headUp: ScanVec3 {
        let v = (self[.headTop] - self[.head]).normalized
        return v == .zero ? spineUp : v
    }

    static func make(_ body: ScanBody, _ b: ScanBuild) -> ScanRig {
        let s = body.skeleton
        let down = ScanVec3(0, -1, 0)
        func dir(_ a: ScanJoint, _ c: ScanJoint, _ fallback: ScanVec3) -> ScanVec3 {
            let v = (s.at(c) - s.at(a)).normalized
            return v == .zero ? fallback : v
        }
        func len(_ a: ScanJoint, _ c: ScanJoint) -> Double { s.at(a).distance(to: s.at(c)) }
        let right = ScanSkeleton.rightDirection(s.joints)
        let fwd = ScanSkeleton.forwardDirection(s.joints)
        var j: [ScanJoint: ScanVec3] = [:]
        let hips = s.at(.hips)
        let chest = hips + dir(.hips, .chest, .up) * (len(.hips, .chest) * b.torso)
        let neck = chest + dir(.chest, .neck, .up) * (len(.chest, .neck) * b.torso)
        j[.hips] = hips
        j[.chest] = chest
        j[.neck] = neck
        func spread(_ base: ScanVec3, _ origin: ScanVec3, _ p: ScanVec3, _ k: Double, _ rest: Double) -> ScanVec3 {
            let off = p - origin
            let lat = right * off.dot(right)
            return base + lat * k + (off - lat) * rest
        }
        for sh in [ScanJoint.leftShoulder, .rightShoulder] {
            j[sh] = spread(neck, s.at(.neck), s.at(sh), b.shoulder, b.torso)
        }
        for hp in [ScanJoint.leftHip, .rightHip] {
            j[hp] = spread(hips, s.at(.hips), s.at(hp), b.hip, b.torso)
        }
        let arms: [(ScanJoint, ScanJoint, ScanJoint, ScanJoint)] = [
            (.leftShoulder, .leftElbow, .leftWrist, .leftHand), (.rightShoulder, .rightElbow, .rightWrist, .rightHand)
        ]
        for (sh, el, wr, hd) in arms {
            let sp = j[sh] ?? s.at(sh)
            let ep = sp + dir(sh, el, down) * (len(sh, el) * b.arm)
            let wp = ep + dir(el, wr, down) * (len(el, wr) * b.arm)
            let hpnt = wp + dir(wr, hd, down) * (len(wr, hd) * b.arm)
            j[el] = ep
            j[wr] = wp
            j[hd] = hpnt
        }
        let legs: [(ScanJoint, ScanJoint, ScanJoint, ScanJoint)] = [
            (.leftHip, .leftKnee, .leftAnkle, .leftToe), (.rightHip, .rightKnee, .rightAnkle, .rightToe)
        ]
        for (hp, kn, an, to) in legs {
            let hpos = j[hp] ?? s.at(hp)
            let kp = hpos + dir(hp, kn, down) * (len(hp, kn) * b.leg)
            let ap = kp + dir(kn, an, down) * (len(kn, an) * b.leg)
            let tp = ap + dir(an, to, fwd) * (len(an, to) * (0.5 + 0.5 * b.leg))
            j[kn] = kp
            j[an] = ap
            j[to] = tp
        }
        // Head size from the target "heads tall".
        let spineUp = (neck - hips).normalized
        let personHead = body.proportions.headHeight
        let neckGap = max(0.006, s.at(.head).distance(to: s.at(.neck)) - personHead / 2) * b.neck
        let spineLen = neck.distance(to: chest) + chest.distance(to: hips)
        var drop = 0.0
        var thigh = 0.0
        var shin = 0.0
        for (hp, kn, an, _) in legs {
            let hpos = j[hp] ?? hips
            drop += max(0, (hips - hpos).dot(spineUp)) / 2
            thigh += hpos.distance(to: j[kn] ?? hpos) / 2
            shin += (j[kn] ?? hpos).distance(to: j[an] ?? hpos) / 2
        }
        let ankleH = 0.09 * (thigh + shin)
        let below = spineLen + drop + thigh + shin + ankleH
        let own = body.proportions.heightInHeads
        let target = b.heads.map { own * (1 - b.headBlend) + $0 * b.headBlend } ?? own
        let headH = (below + neckGap) / max(1.2, target - 1)
        let headC = neck + dir(.neck, .head, .up) * (neckGap + headH / 2)
        j[.head] = headC
        j[.headTop] = headC + dir(.head, .headTop, .up) * (headH / 2)

        // Feet on the floor, standing height 1, hips over the middle.
        let total = max(1e-6, below + neckGap + headH)
        let ground = min(j[.leftAnkle]?.y ?? 0, j[.rightAnkle]?.y ?? 0) - ankleH
        let offset = ScanVec3(hips.x, ground, hips.z)
        var out: [ScanJoint: ScanVec3] = [:]
        for (k, p) in j { out[k] = (p - offset) / total }
        return ScanRig(j: out, headH: headH / total)
    }
}

/// Limb thickness, as a part of standing height.
struct ScanThick {
    var neck: Double
    var upperArm: Double
    var elbow: Double
    var wrist: Double
    var hand: Double
    var thigh: Double
    var knee: Double
    var ankle: Double
    var foot: Double
    var footLength: Double = 1

    func scaled(_ k: Double) -> ScanThick {
        ScanThick(neck: neck * k, upperArm: upperArm * k, elbow: elbow * k, wrist: wrist * k, hand: hand * k,
                  thigh: thigh * k, knee: knee * k, ankle: ankle * k, foot: foot * k, footLength: footLength)
    }
}

/// Per-style drawing settings.
struct ScanKit {
    var build: ScanBuild
    var thick: ScanThick
    /// Ink rim in pixels (at 1000 px tall).
    var rim: Double
    var headWide: Double
    var headDeep: Double
    var bodyDepth: Double
    var waist: Double
    var line: Double

    static func of(_ style: ScanStyle) -> ScanKit {
        switch style {
        case .chibi:
            return ScanKit(build: ScanBuild(heads: 2.4, headBlend: 0.85, arm: 0.85, leg: 0.7, torso: 1, shoulder: 0.95, hip: 1.1, neck: 0.3),
                           thick: ScanThick(neck: 0.03, upperArm: 0.045, elbow: 0.042, wrist: 0.04, hand: 0.05,
                                            thigh: 0.07, knee: 0.064, ankle: 0.058, foot: 0.062, footLength: 0.9),
                           rim: 6, headWide: 0.55, headDeep: 0.5, bodyDepth: 0.36, waist: 1.02, line: 5)
        case .hero:
            return ScanKit(build: ScanBuild(heads: 8.2, headBlend: 0.9, arm: 1.05, leg: 1.12, torso: 1, shoulder: 1.4, hip: 0.95, neck: 1),
                           thick: ScanThick(neck: 0.042, upperArm: 0.05, elbow: 0.036, wrist: 0.027, hand: 0.034,
                                            thigh: 0.066, knee: 0.042, ankle: 0.03, foot: 0.033, footLength: 1.1),
                           rim: 4.5, headWide: 0.38, headDeep: 0.44, bodyDepth: 0.3, waist: 0.82, line: 3.5)
        case .noodle:
            return ScanKit(build: ScanBuild(heads: 3.4, headBlend: 0.75, arm: 1.25, leg: 1.15, torso: 0.9, shoulder: 0.8, hip: 0.9, neck: 0.6),
                           thick: ScanThick(neck: 0.015, upperArm: 0.014, elbow: 0.014, wrist: 0.014, hand: 0.052,
                                            thigh: 0.017, knee: 0.017, ankle: 0.017, foot: 0.048, footLength: 1.7),
                           rim: 5, headWide: 0.5, headDeep: 0.48, bodyDepth: 0.42, waist: 1.12, line: 5)
        case .robot:
            return ScanKit(build: ScanBuild(heads: 6, headBlend: 0.7, arm: 1, leg: 0.95, torso: 1.1, shoulder: 1.3, hip: 1.1, neck: 0.8),
                           thick: ScanThick(neck: 0.03, upperArm: 0.042, elbow: 0.04, wrist: 0.034, hand: 0.04,
                                            thigh: 0.055, knee: 0.05, ankle: 0.042, foot: 0.045, footLength: 1.1),
                           rim: 5, headWide: 0.45, headDeep: 0.45, bodyDepth: 0.36, waist: 0.8, line: 4)
        case .creature:
            return ScanKit(build: ScanBuild(heads: 4, headBlend: 0.75, arm: 0.95, leg: 0.85, torso: 1.05, shoulder: 1.05, hip: 1.15, neck: 0.6),
                           thick: ScanThick(neck: 0.038, upperArm: 0.045, elbow: 0.04, wrist: 0.036, hand: 0.045,
                                            thigh: 0.065, knee: 0.055, ankle: 0.045, foot: 0.05, footLength: 1.1),
                           rim: 5.5, headWide: 0.5, headDeep: 0.48, bodyDepth: 0.38, waist: 1.05, line: 4.5)
        case .mannequin:
            return ScanKit(build: ScanBuild(heads: nil),
                           thick: ScanThick(neck: 0.026, upperArm: 0.033, elbow: 0.026, wrist: 0.019, hand: 0.028,
                                            thigh: 0.052, knee: 0.036, ankle: 0.024, foot: 0.026, footLength: 1),
                           rim: 0, headWide: 0.39, headDeep: 0.45, bodyDepth: 0.3, waist: 0.85, line: 3)
        }
    }
}

// MARK: - Drawing one figure

struct ScanFigure {
    let rig: ScanRig
    let cam: ScanCamera
    let look: ScanLook
    let kit: ScanKit
    let th: ScanThick
    let pal: ScanPalette

    var parts: [ScanPart] = []
    var under: [ScanPaint] = []
    var over: [ScanLine] = []
    /// Face lines go on the top part of the head stack.
    var faceLines: [ScanLine] = []
    var headStack: [Int] = []

    // Body frame
    let R: ScanVec3
    let L: ScanVec3
    let F: ScanVec3
    let U: ScanVec3
    // Head frame and size (in figure units)
    let HL: ScanVec3
    let HU: ScanVec3
    let HF: ScanVec3
    let ha: Double
    let hb: Double
    let hc: Double
    // Torso sizes
    let shoulderHalf: Double
    let hipHalf: Double
    let chestHalf: Double
    let waistHalf: Double
    let chestD: Double
    let waistD: Double
    let hipD: Double

    init(rig: ScanRig, cam: ScanCamera, look: ScanLook) {
        self.rig = rig
        self.cam = cam
        self.look = look
        let k = ScanKit.of(look.style)
        self.kit = k
        self.th = k.thick.scaled(look.bulk)
        self.pal = look.palette
        R = rig.right
        L = -rig.right
        F = rig.forward
        U = rig.spineUp
        HU = rig.headUp
        var hl = (L - HU * L.dot(HU)).normalized
        if hl == .zero { hl = L }
        HL = hl
        HF = hl.cross(HU).normalized
        hb = rig.headH * 0.5
        ha = rig.headH * k.headWide
        hc = rig.headH * k.headDeep
        let span = rig[.leftShoulder].distance(to: rig[.rightShoulder])
        shoulderHalf = span / 2 + th.upperArm * 0.85
        hipHalf = rig[.leftHip].distance(to: rig[.rightHip]) / 2 + th.thigh * 0.9
        chestHalf = max(shoulderHalf * 0.86, hipHalf * 0.95)
        waistHalf = (chestHalf + hipHalf) / 2 * k.waist
        chestD = max(0.03, span * k.bodyDepth * 0.95)
        waistD = chestD * 0.88
        hipD = chestD * 0.98
    }

    // MARK: Helpers

    var px: Double { cam.scale }
    var ink: RGBA { pal.ink }
    var rim: Double { kit.rim }
    func p(_ k: ScanJoint) -> Vec2 { cam.point(rig[k]) }
    func d(_ k: ScanJoint) -> Double { cam.depth(rig[k]) }
    func pt(_ v: ScanVec3) -> Vec2 { cam.point(v) }
    func dp(_ v: ScanVec3) -> Double { cam.depth(v) }
    func facing(_ n: ScanVec3) -> Double { cam.turn(n).z }

    func capsule(_ a: ScanVec3, _ b: ScanVec3, _ ra: Double, _ rb: Double) -> ScanShape {
        .capsule(pt(a), pt(b), ra * px, rb * px)
    }

    func ball(_ c: ScanVec3, _ r: Double) -> ScanShape { .ellipse(pt(c), r * px, r * px, 0) }

    func hull(_ pts: [ScanVec3]) -> ScanShape { .polygon(ScanGeo.hull(pts.map { pt($0) })) }

    /// A body shape from slices: (center, half width along R, half depth along F), bottom to top.
    func band(_ specs: [(ScanVec3, Double, Double)]) -> ScanShape {
        let centers = specs.map { pt($0.0) }
        let r2 = cam.dir(R)
        let f2 = cam.dir(F)
        var secs: [ScanSection] = []
        for i in 0..<specs.count {
            let a = centers[max(0, i - 1)]
            let b = centers[min(specs.count - 1, i + 1)]
            var t = (b - a).normalized
            if t == .zero { t = Vec2(0, -1) }
            let n = Vec2(-t.y, t.x)
            let ew = specs[i].1 * r2.dot(n)
            let ed = specs[i].2 * f2.dot(n)
            let half = (ew * ew + ed * ed).squareRoot() * px
            secs.append(ScanSection(center: centers[i], normal: n, half: max(1, half)))
        }
        return .band(secs)
    }

    /// The 8 corners of a box.
    func corners(_ c: ScanVec3, _ x: ScanVec3, _ y: ScanVec3, _ z: ScanVec3, _ hx: Double, _ hy: Double, _ hz: Double) -> [ScanVec3] {
        var out: [ScanVec3] = []
        for sx in [-1.0, 1.0] {
            for sy in [-1.0, 1.0] {
                for sz in [-1.0, 1.0] {
                    out.append(c + x * (hx * sx) + y * (hy * sy) + z * (hz * sz))
                }
            }
        }
        return out
    }

    /// Two axes square to `u`, using the body's right side as a hint.
    func basis(_ u: ScanVec3) -> (ScanVec3, ScanVec3) {
        var r = (R - u * R.dot(u)).normalized
        if r == .zero { r = (F - u * F.dot(u)).normalized }
        if r == .zero { r = ScanVec3(1, 0, 0) }
        let f = u.cross(r).normalized
        return (r, f)
    }

    /// A point on the head (azimuth: 0 = front, + = their left; elevation: + = up).
    func surf(_ az: Double, _ el: Double, _ out: Double = 1) -> ScanVec3 {
        let ce = cos(el)
        let x = HL * (ha * sin(az) * ce * out)
        let y = HU * (hb * sin(el) * out)
        let z = HF * (hc * cos(az) * ce * out)
        return rig[.head] + x + y + z
    }

    func surfNormal(_ az: Double, _ el: Double) -> ScanVec3 {
        let ce = cos(el)
        return (HL * (sin(az) * ce) + HU * sin(el) + HF * (cos(az) * ce)).normalized
    }

    /// The head as a flat ellipse in pixels.
    var headRadii: (Double, Double) {
        let l2 = cam.dir(HL), u2 = cam.dir(HU), f2 = cam.dir(HF)
        let rxA = ha * l2.x, rxB = hb * u2.x, rxC = hc * f2.x
        let ryA = ha * l2.y, ryB = hb * u2.y, ryC = hc * f2.y
        let rx = (rxA * rxA + rxB * rxB + rxC * rxC).squareRoot()
        let ry = (ryA * ryA + ryB * ryB + ryC * ryC).squareRoot()
        return (rx * px, ry * px)
    }

    func line(_ pts: [Vec2], _ color: RGBA? = nil, width: Double? = nil) -> ScanLine {
        ScanLine(points: pts, color: color ?? ink, width: width ?? kit.line)
    }

    /// A curve through 3D points, flattened.
    func path3(_ pts: [ScanVec3]) -> [Vec2] { pts.map { pt($0) } }

    var torsoDepth: Double { (d(.hips) + d(.chest)) / 2 }
    var headDepth: Double { d(.head) + 0.03 }

    mutating func add(_ part: ScanPart) { parts.append(part) }

    func newPart(_ depth: Double) -> ScanPart { ScanPart(depth: depth, rim: rim, ink: ink) }

    // MARK: Whole figure

    static func draw(rig: ScanRig, look: ScanLook, angle: Double, scale: Double) -> ScanDrawing {
        var fig = ScanFigure(rig: rig, cam: ScanCamera(angle: angle, scale: scale, origin: .zero), look: look)
        switch look.style {
        case .robot:
            fig.buildRobot()
        case .mannequin:
            fig.buildMannequin()
        default:
            fig.buildToon()
        }
        fig.finishHeadStack()
        return ScanCompose.drawing(parts: fig.parts, under: fig.under, over: fig.over)
    }

    mutating func finishHeadStack() {
        guard !faceLines.isEmpty else { return }
        if let top = headStack.max(by: { parts[$0].depth < parts[$1].depth }) {
            parts[top].lines.append(contentsOf: faceLines)
        } else {
            over.append(contentsOf: faceLines)
        }
        faceLines = []
    }

    mutating func groundShadow() {
        let a = p(.leftAnkle), b = p(.rightAnkle)
        let ground = pt(ScanVec3((rig[.leftAnkle].x + rig[.rightAnkle].x) / 2, 0, (rig[.leftAnkle].z + rig[.rightAnkle].z) / 2))
        let rx = abs(a.x - b.x) / 2 + 0.11 * px
        under.append(ScanPaint(shape: .ellipse(ground, rx, max(6, rx * 0.16), 0), color: RGBA(0, 0, 0, 0.12)))
    }

    // MARK: Cartoon people and creatures

    mutating func buildToon() {
        groundShadow()
        let creature = look.style == .creature
        let noodle = look.style == .noodle
        let hero = look.style == .hero
        let skin = pal.skin
        let outfit = look.outfit
        let fur = outfit == .fur
        let shirt = fur ? skin : pal.main
        let pants: RGBA
        switch outfit {
        case .suit: pants = pal.main
        case .fur: pants = skin
        case .overalls: pants = pal.second
        default: pants = pal.second
        }
        let longPants = look.longPants && outfit != .dress && !fur
        let longSleeves = look.longSleeves && !fur
        let gloves = hero || noodle
        let gloveColor = noodle ? RGBA(1, 1, 1, 1) : pal.second
        let shoeColor = pal.shoes

        // Legs
        let legs: [(ScanJoint, ScanJoint, ScanJoint, ScanJoint)] = [
            (.leftHip, .leftKnee, .leftAnkle, .leftToe), (.rightHip, .rightKnee, .rightAnkle, .rightToe)
        ]
        for (hp, kn, an, to) in legs {
            var part = newPart((d(kn) + d(an)) / 2 - 0.03)
            let h = rig[hp], k = rig[kn], a = rig[an], t = rig[to]
            let legColor = longPants ? pants : skin
            part.shapes.append(ScanPaint(shape: capsule(h, k, th.thigh, th.knee), color: legColor))
            let shinR = longPants ? th.ankle * 1.2 : th.ankle
            part.shapes.append(ScanPaint(shape: capsule(k, a, th.knee, shinR), color: legColor))
            if !longPants && outfit != .dress && !fur {
                let end = ScanVec3.lerp(h, k, 0.62)
                part.shapes.append(ScanPaint(shape: capsule(h, end, th.thigh * 1.14, th.knee * 1.22), color: pants))
                part.lines.append(hemLine(end, along: k - h, radius: th.knee * 1.22))
            }
            if hero {
                let top = ScanVec3.lerp(k, a, 0.35)
                part.shapes.append(ScanPaint(shape: capsule(top, a, th.knee * 1.12, th.ankle * 1.22), color: pal.second))
                part.lines.append(hemLine(top, along: a - k, radius: th.knee * 1.12))
            }
            // Shoe or paw
            var toeDir = (t - a).normalized
            if toeDir == .zero { toeDir = F }
            let footLen = a.distance(to: t) * th.footLength
            let heel = a + ScanVec3(0, -th.ankle * 0.4, 0) - toeDir * (th.foot * 0.3)
            let tip = a + toeDir * footLen + ScanVec3(0, -th.ankle * 0.5, 0)
            let footColor = fur ? skin : shoeColor
            part.shapes.append(ScanPaint(shape: capsule(heel, tip, th.foot, th.foot * (noodle ? 1.25 : 0.92)), color: footColor))
            // Shoe top (or a fur line at the ankle), seen from every side.
            let cuff = a + ScanVec3(0, th.ankle * 0.25, 0)
            part.lines.append(hemLine(cuff, along: k - a, radius: max(th.ankle, th.foot * 0.8)))
            add(part)
        }

        // Cape goes behind everything else on the back.
        if look.has(.cape) { addCape() }
        if look.has(.backpack) { addBackpack() }
        if look.has(.jetpack) { addJetpack() }

        // Torso
        let hips = rig[.hips], chest = rig[.chest], neck = rig[.neck]
        var torso = newPart(torsoDepth)
        let crotch = hips - U * (th.thigh * 0.8)
        let pantsSpecs: [(ScanVec3, Double, Double)] = [
            (crotch, hipHalf * 0.55, hipD * 0.8),
            (hips, hipHalf, hipD),
            (ScanVec3.lerp(hips, chest, 0.42), waistHalf, waistD)
        ]
        let shirtTop: [(ScanVec3, Double, Double)] = [
            (ScanVec3.lerp(hips, chest, 0.5), waistHalf * 1.03, waistD * 1.03),
            (chest, chestHalf, chestD),
            (ScanVec3.lerp(chest, neck, 0.8), shoulderHalf, chestD * 0.85),
            (neck + U * (th.neck * 0.7), th.neck * 1.45, th.neck * 1.3)
        ]
        let shirtSpecs = [(ScanVec3.lerp(hips, chest, 0.16), (hipHalf + waistHalf) / 2 * 1.05, hipD * 1.04)] + shirtTop
        switch outfit {
        case .dress:
            torso.shapes.append(ScanPaint(shape: band(shirtSpecs), color: shirt))
            let drop = max(0.05, hips.y - (rig[.leftKnee].y + rig[.rightKnee].y) / 2)
            let skirt: [(ScanVec3, Double, Double)] = [
                (hips - ScanVec3(0, drop * 0.92, 0), hipHalf * 1.65, hipD * 1.6),
                (hips - ScanVec3(0, drop * 0.45, 0), hipHalf * 1.3, hipD * 1.3),
                (hips + U * 0.01, waistHalf * 1.05, waistD * 1.05),
                (ScanVec3.lerp(hips, chest, 0.35), waistHalf * 1.02, waistD * 1.02)
            ]
            torso.shapes.append(ScanPaint(shape: band(skirt), color: pal.main))
        case .overalls:
            torso.shapes.append(ScanPaint(shape: band(shirtSpecs), color: pal.main))
            let bib = pantsSpecs + [(chest, chestHalf * 0.62, chestD * 1.04),
                                    (ScanVec3.lerp(chest, neck, 0.35), chestHalf * 0.58, chestD)]
            torso.shapes.append(ScanPaint(shape: band(bib), color: pants))
            if facing(F) > 0.2 {
                let topY = ScanVec3.lerp(chest, neck, 0.35) + F * chestD
                for side in [-1.0, 1.0] {
                    let from = topY + R * (chestHalf * 0.5 * side)
                    let to = rig[side < 0 ? .leftShoulder : .rightShoulder] + F * (chestD * 0.5)
                    torso.lines.append(line([pt(from), pt(to)], pants, width: kit.line * 1.6))
                    torso.details.append(ScanPaint(shape: ball(from, chestD * 0.12), color: pal.accent))
                }
            }
        default:
            torso.shapes.append(ScanPaint(shape: band(pantsSpecs), color: pants))
            torso.shapes.append(ScanPaint(shape: band(shirtSpecs), color: shirt))
        }
        if outfit == .trunks {
            let trunks: [(ScanVec3, Double, Double)] = [
                (crotch, hipHalf * 0.6, hipD * 0.85), (hips, hipHalf * 1.04, hipD * 1.04),
                (ScanVec3.lerp(hips, chest, 0.22), waistHalf * 1.05, waistD * 1.05)
            ]
            torso.shapes.append(ScanPaint(shape: band(trunks), color: pal.second))
        }
        addTorsoDetails(&torso)
        add(torso)

        // Neck
        var neckPart = newPart(min(torsoDepth, d(.head)) - 0.002)
        let headBottom = rig[.head] - HU * (hb * 0.6)
        neckPart.shapes.append(ScanPaint(shape: capsule(neck, headBottom, th.neck, th.neck * 0.95), color: skin))
        add(neckPart)
        if outfit == .hoodie { addHood() }
        if look.has(.scarf) { addScarf() }

        // Arms
        let arms: [(ScanJoint, ScanJoint, ScanJoint, ScanJoint)] = [
            (.leftShoulder, .leftElbow, .leftWrist, .leftHand), (.rightShoulder, .rightElbow, .rightWrist, .rightHand)
        ]
        for (sh, el, wr, hd) in arms {
            var part = newPart((d(el) + d(wr) + d(hd)) / 3 - 0.005)
            let s = rig[sh], e = rig[el], w = rig[wr], h = rig[hd]
            let upperColor = longSleeves ? shirt : skin
            let foreColor = longSleeves ? shirt : skin
            part.shapes.append(ScanPaint(shape: capsule(s, e, th.upperArm, th.elbow), color: upperColor))
            part.shapes.append(ScanPaint(shape: capsule(e, w, th.elbow, th.wrist), color: foreColor))
            if !longSleeves && !fur && outfit != .suit && !noodle {
                let end = ScanVec3.lerp(s, e, 0.55)
                part.shapes.append(ScanPaint(shape: capsule(s, end, th.upperArm * 1.18, th.upperArm * 1.12), color: shirt))
                part.lines.append(hemLine(end, along: e - s, radius: th.upperArm * 1.12))
            }
            if hero {
                let start = ScanVec3.lerp(e, w, 0.4)
                part.shapes.append(ScanPaint(shape: capsule(start, w, th.elbow * 1.15, th.wrist * 1.25), color: pal.second))
                part.lines.append(hemLine(start, along: w - e, radius: th.elbow * 1.15))
            }
            if noodle {
                // Big white cartoon gloves with a cuff.
                let cuff = w - (w - e).normalized * (th.hand * 0.2)
                part.shapes.append(ScanPaint(shape: capsule(cuff, w, th.hand * 0.55, th.hand * 0.6), color: gloveColor))
                part.shapes.append(ScanPaint(shape: ball(ScanVec3.lerp(w, h, 0.8), th.hand), color: gloveColor))
                let mid = pt(ScanVec3.lerp(w, h, 0.8))
                let r = th.hand * px * 0.5
                part.lines.append(line([mid + Vec2(-r * 0.2, -r), mid + Vec2(-r * 0.2, r * 0.2)], ink, width: kit.line * 0.6))
                part.lines.append(line([mid + Vec2(r * 0.4, -r), mid + Vec2(r * 0.4, r * 0.2)], ink, width: kit.line * 0.6))
            } else {
                let handColor = gloves ? gloveColor : skin
                part.shapes.append(ScanPaint(shape: capsule(w, h, th.wrist * 1.05, th.hand), color: handColor))
            }
            if look.has(.shoulderPads) {
                let pad = s + U * (th.upperArm * 0.35) + (s - rig[.neck]).normalized * (th.upperArm * 0.2)
                part.shapes.append(ScanPaint(shape: .ellipse(pt(pad), th.upperArm * 1.25 * px, th.upperArm * 0.95 * px, 0), color: pal.second))
            }
            add(part)
        }

        if creature { addTail() }

        // Head
        addHead()
    }

    func hemLine(_ at: ScanVec3, along: ScanVec3, radius: Double) -> ScanLine {
        let c = pt(at)
        var t = cam.dir(along.normalized)
        if t.length < 1e-6 { t = Vec2(0, 1) }
        let n = t.normalized.perpendicular * (radius * px * 0.95)
        return line([c - n, c + n], ink, width: kit.line * 0.7)
    }

    mutating func addTorsoDetails(_ torso: inout ScanPart) {
        let hips = rig[.hips], chest = rig[.chest], neck = rig[.neck]
        let front = facing(F)
        let fx = max(0.25, front)
        let outfit = look.outfit
        if look.style == .hero || look.outfit == .jacket || look.style == .noodle && outfit == .tee {
            // Belt
            let belt: [(ScanVec3, Double, Double)] = [
                (ScanVec3.lerp(hips, chest, 0.2), waistHalf * 1.07, waistD * 1.07),
                (ScanVec3.lerp(hips, chest, 0.32), waistHalf * 1.06, waistD * 1.06)
            ]
            if look.style == .hero {
                torso.details.append(ScanPaint(shape: band(belt), color: pal.accent))
                if front > 0.2 {
                    let buckle = ScanVec3.lerp(hips, chest, 0.26) + F * (waistD * 1.07)
                    torso.details.append(ScanPaint(shape: .ellipse(pt(buckle), waistHalf * 0.22 * px * fx, waistHalf * 0.16 * px, 0),
                                                   color: ScanColor.shade(pal.accent, 0.4)))
                }
            }
        }
        if look.style == .hero && front > 0.2 {
            // Chest emblem
            let c = pt(chest + F * (chestD * 1.02) + U * 0.008)
            let r = chestHalf * 0.42 * px
            torso.details.append(ScanPaint(shape: .ellipse(c, r * fx, r, 0), color: pal.accent))
            let shapeKind = look.variant % 3
            let emblem: [Vec2]
            switch shapeKind {
            case 0:
                emblem = ScanGeo.star(c, outer: r * 0.8, inner: r * 0.36, points: 5, sx: fx)
            case 1:
                // Lightning bolt
                let raw: [Vec2] = [Vec2(0.15, -0.85), Vec2(-0.45, 0.1), Vec2(-0.05, 0.1), Vec2(-0.2, 0.85),
                                   Vec2(0.45, -0.15), Vec2(0.05, -0.15), Vec2(0.3, -0.85)]
                emblem = raw.map { Vec2(c.x + $0.x * r * fx, c.y + $0.y * r) }
            default:
                emblem = [Vec2(c.x, c.y - r * 0.75), Vec2(c.x + r * 0.7 * fx, c.y), Vec2(c.x, c.y + r * 0.75), Vec2(c.x - r * 0.7 * fx, c.y)]
            }
            torso.details.append(ScanPaint(shape: .polygon(emblem), color: pal.second))
        }
        if outfit == .hoodie && front > 0.2 {
            // Pocket and strings
            let a = ScanVec3.lerp(hips, chest, 0.2) + F * (waistD * 1.04)
            let b = ScanVec3.lerp(hips, chest, 0.52) + F * (waistD * 1.04)
            let w = waistHalf * 0.6
            let pocket = [pt(a - R * w), pt(a + R * w), pt(b + R * (w * 0.7)), pt(b - R * (w * 0.7))]
            torso.details.append(ScanPaint(shape: .polygon(pocket), color: ScanColor.shade(pal.main, -0.12)))
            for side in [-1.0, 1.0] {
                let top = neck + F * (chestD * 0.8) + R * (th.neck * 0.8 * side)
                torso.lines.append(line([pt(top), pt(top - U * 0.06 + R * (0.004 * side))], pal.light, width: kit.line * 0.6))
            }
        }
        if outfit == .jacket && front > 0.2 {
            let strip: [(ScanVec3, Double, Double)] = [
                (ScanVec3.lerp(hips, chest, 0.16) + F * (hipD * 0.95), waistHalf * 0.24, 0.001),
                (chest + F * (chestD * 0.98), chestHalf * 0.24, 0.001),
                (ScanVec3.lerp(chest, neck, 0.85) + F * (chestD * 0.8), th.neck * 1.2, 0.001)
            ]
            torso.details.append(ScanPaint(shape: band(strip), color: pal.light))
            let zipTop = pt(ScanVec3.lerp(chest, neck, 0.8) + F * (chestD * 0.9))
            let zipBottom = pt(ScanVec3.lerp(hips, chest, 0.18) + F * (hipD))
            torso.lines.append(line([zipBottom, zipTop], ScanColor.shade(pal.main, -0.4), width: kit.line * 0.6))
        }
        if front < -0.2 {
            // Seen from behind: a seam down the back and shoulder blades.
            let back = [neck - F * (chestD * 0.6), chest - F * (chestD * 1.0), ScanVec3.lerp(hips, chest, 0.35) - F * (waistD * 1.0)]
            torso.lines.append(line(path3(back), ScanColor.shade(look.outfit == .fur ? pal.skin : pal.main, -0.35), width: kit.line * 0.6))
            for side in [-1.0, 1.0] {
                let c = chest - F * (chestD * 0.95) + R * (chestHalf * 0.45 * side) + U * 0.01
                let a = c + R * (chestHalf * 0.2 * side) + U * 0.02
                let b = c - U * 0.03
                torso.lines.append(line([pt(a), pt(c), pt(b)], ScanColor.shade(look.outfit == .fur ? pal.skin : pal.main, -0.25), width: kit.line * 0.5))
            }
        }
        if look.style == .creature && front > 0.15 {
            let c = pt(ScanVec3.lerp(hips, chest, 0.55) + F * (waistD * 0.95))
            let rx = waistHalf * 0.62 * px * fx
            let ry = chest.distance(to: hips) * 0.42 * px
            if outfit == .fur {
                torso.details.append(ScanPaint(shape: .ellipse(c, rx, ry, 0), color: pal.light))
            }
        }
        if look.style == .noodle && outfit == .tee && front > 0.2 {
            for side in [-1.0, 1.0] {
                let b = ScanVec3.lerp(hips, chest, 0.1) + F * (hipD * 1.02) + R * (hipHalf * 0.45 * side)
                torso.details.append(ScanPaint(shape: .ellipse(pt(b), hipHalf * 0.13 * px * fx, hipHalf * 0.2 * px, 0), color: RGBA(1, 1, 1, 1)))
            }
        }
        if look.has(.bowtie) && front > 0.2 {
            let c = pt(neck + F * (chestD * 0.7) - U * 0.004)
            let s = th.neck * 1.6 * px
            let left = [c, Vec2(c.x - s * fx, c.y - s * 0.6), Vec2(c.x - s * fx, c.y + s * 0.6)]
            let right = [c, Vec2(c.x + s * fx, c.y - s * 0.6), Vec2(c.x + s * fx, c.y + s * 0.6)]
            torso.details.append(ScanPaint(shape: .polygon(left), color: pal.accent))
            torso.details.append(ScanPaint(shape: .polygon(right), color: pal.accent))
            torso.details.append(ScanPaint(shape: .ellipse(c, s * 0.3, s * 0.3, 0), color: ScanColor.shade(pal.accent, -0.2)))
        }
        if look.has(.backpack) && front > 0.2 {
            for side in [-1.0, 1.0] {
                let top = rig[side < 0 ? .leftShoulder : .rightShoulder] * 0.6 + neck * 0.4 + F * (chestD * 0.8)
                let bottom = ScanVec3.lerp(hips, chest, 0.45) + R * (waistHalf * 0.7 * side) + F * (waistD * 0.9)
                torso.lines.append(line([pt(top), pt(bottom)], ScanColor.shade(pal.accent, -0.3), width: kit.line * 1.4))
            }
        }
    }

    mutating func addCape() {
        let top = ScanVec3.mid(rig[.leftShoulder], rig[.rightShoulder]) - F * (chestD * 0.9)
        var part = newPart(dp(top - F * 0.1))
        let floor = max(0.08, rig[.hips].y * 0.18)
        var pts: [ScanVec3] = []
        for side in [-1.0, 1.0] {
            let sh = rig[side < 0 ? .leftShoulder : .rightShoulder]
            pts.append(sh - F * (chestD * 0.9) + U * 0.01)
            let bottom = ScanVec3(sh.x, floor, sh.z) + R * (shoulderHalf * 0.9 * side) - F * (chestD + 0.12)
            pts.append(bottom)
        }
        pts.append(ScanVec3(top.x, floor - 0.02, top.z) - F * (chestD + 0.14))
        part.shapes.append(ScanPaint(shape: hull(pts), color: pal.second))
        for k in [-0.45, 0.0, 0.45] {
            let a = top + R * (shoulderHalf * k * 0.6) - U * 0.05
            let b = ScanVec3(a.x, floor + 0.04, a.z) + R * (shoulderHalf * k * 0.9) - F * 0.1
            part.lines.append(line([pt(a), pt(b)], ScanColor.shade(pal.second, -0.3), width: kit.line * 0.6))
        }
        add(part)
    }

    mutating func addBackpack() {
        let chest = rig[.chest]
        let c = chest - F * (chestD + 0.045) - U * 0.02
        var part = newPart(dp(c))
        let box = corners(c, R, U, F, shoulderHalf * 0.55, chest.distance(to: rig[.hips]) * 0.5, 0.045)
        part.shapes.append(ScanPaint(shape: hull(box), color: pal.accent))
        let pocket = corners(c - F * 0.045 - U * 0.03, R, U, F, shoulderHalf * 0.38, 0.05, 0.02)
        part.shapes.append(ScanPaint(shape: hull(pocket), color: ScanColor.shade(pal.accent, -0.2)))
        let flap = c - F * 0.046 + U * 0.03
        part.lines.append(line([pt(flap - R * (shoulderHalf * 0.4)), pt(flap + R * (shoulderHalf * 0.4))], ScanColor.shade(pal.accent, -0.4), width: kit.line * 0.6))
        add(part)
    }

    mutating func addJetpack() {
        let chest = rig[.chest]
        for side in [-1.0, 1.0] {
            let c = chest - F * (chestD + 0.05) + R * (shoulderHalf * 0.35 * side)
            var part = newPart(dp(c))
            let top = c + U * 0.07, bottom = c - U * 0.09
            part.shapes.append(ScanPaint(shape: capsule(top, bottom, 0.035, 0.035), color: pal.second))
            let flameTop = pt(bottom - U * 0.03)
            let fl = 0.06 * px
            let flame = [Vec2(flameTop.x - fl * 0.35, flameTop.y), Vec2(flameTop.x + fl * 0.35, flameTop.y), Vec2(flameTop.x, flameTop.y + fl * 1.6)]
            part.details.append(ScanPaint(shape: .polygon(flame), color: pal.accent))
            add(part)
        }
    }

    mutating func addHood() {
        let c = rig[.neck] + U * (hb * 0.25) - F * (chestD * 0.75)
        var part = newPart(dp(c) - 0.001)
        var pts: [ScanVec3] = []
        for i in 0..<16 {
            let t = Double(i) / 16 * 2 * Double.pi
            pts.append(c + R * (cos(t) * ha * 1.05) + U * (sin(t) * hb * 0.55) - F * 0.01)
            pts.append(c + R * (cos(t) * ha * 0.9) + U * (sin(t) * hb * 0.45) - F * (hc * 0.5))
        }
        part.shapes.append(ScanPaint(shape: hull(pts), color: ScanColor.shade(pal.main, -0.08)))
        add(part)
    }

    mutating func addScarf() {
        let neck = rig[.neck]
        var part = newPart(max(torsoDepth, d(.neck)) + 0.004)
        let ring: [(ScanVec3, Double, Double)] = [
            (neck - U * (th.neck * 0.3), th.neck * 2.0, th.neck * 1.9),
            (neck + U * (th.neck * 1.1), th.neck * 1.7, th.neck * 1.6)
        ]
        part.shapes.append(ScanPaint(shape: band(ring), color: pal.accent))
        add(part)
        let start = neck + F * (th.neck * 1.4) + L * (th.neck * 0.9)
        let end = start - U * 0.12 + F * 0.015
        var tail = newPart(dp(ScanVec3.mid(start, end)) + 0.004)
        tail.shapes.append(ScanPaint(shape: capsule(start, end, th.neck * 0.7, th.neck * 0.8), color: pal.accent))
        tail.lines.append(hemLine(ScanVec3.lerp(start, end, 0.85), along: end - start, radius: th.neck * 0.8))
        add(tail)
    }

    mutating func addTail() {
        let base = rig[.hips] - F * (hipD * 0.9) - U * 0.02
        var pts: [ScanVec3]
        var radii: [Double]
        var tip: RGBA? = nil
        switch look.creature {
        case .cat:
            pts = [base, base - F * 0.12 - U * 0.08, base - F * 0.22 + U * 0.08, base - F * 0.18 + U * 0.26]
            radii = [0.02, 0.018, 0.016, 0.013]
        case .fox:
            pts = [base, base - F * 0.1 - U * 0.08, base - F * 0.2 - U * 0.06, base - F * 0.28 + U * 0.04]
            radii = [0.025, 0.06, 0.07, 0.035]
            tip = pal.light
        case .bunny:
            pts = [base, base - F * 0.02]
            radii = [0.04, 0.045]
            tip = pal.light
        case .bear:
            pts = [base, base - F * 0.015]
            radii = [0.026, 0.028]
        case .dragon:
            pts = [base, base - F * 0.16 - U * 0.16, base - F * 0.3 - U * 0.32, base - F * 0.46 - U * 0.36]
            radii = [0.06, 0.042, 0.024, 0.008]
        }
        var mid = ScanVec3.zero
        for q in pts { mid = mid + q / Double(pts.count) }
        var part = newPart(dp(mid))
        for i in 0..<(pts.count - 1) {
            let color = (i == pts.count - 2 && tip != nil) ? (tip ?? pal.skin) : pal.skin
            part.shapes.append(ScanPaint(shape: capsule(pts[i], pts[i + 1], radii[i], radii[i + 1]), color: color))
        }
        if pts.count == 2, let tip = tip {
            part.shapes.append(ScanPaint(shape: ball(pts[1], radii[1]), color: tip))
        }
        if look.creature == .dragon {
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let m = ScanVec3.lerp(a, b, 0.5)
                let spike = [m - (b - a) * 0.25, m + (b - a) * 0.25, m + U * (radii[i] * 1.6)]
                part.details.append(ScanPaint(shape: hull(spike + [m + U * radii[i]]), color: pal.light))
            }
        }
        add(part)
    }

    // MARK: Head

    mutating func addHead() {
        let head = rig[.head]
        var part = newPart(headDepth)
        let (rx, ry) = headRadii
        let c = pt(head)
        let creature = look.style == .creature
        // Ears (behind the head shape so they look attached)
        if creature {
            addCreatureEars(&part)
        } else {
            for side in [-1.0, 1.0] {
                let az = side * Double.pi / 2
                let n = surfNormal(az, -0.05)
                let f = facing(n)
                let ear = surf(az, -0.05, 0.98)
                let shape = ScanShape.ellipse(pt(ear), hb * 0.2 * px, hb * 0.3 * px, 0)
                if f > 0.55 {
                    part.details.append(ScanPaint(shape: .ellipse(pt(ear), hb * 0.15 * px, hb * 0.24 * px, 0),
                                                  color: ScanColor.shade(pal.skin, -0.1)))
                } else {
                    part.shapes.append(ScanPaint(shape: shape, color: pal.skin))
                }
            }
        }
        if look.creature == .dragon && creature { addHorns(&part) }
        part.shapes.append(ScanPaint(shape: .ellipse(c, rx, ry, 0), color: pal.skin))
        if look.has(.mask) { addMask(&part) }
        addFace(&part)
        add(part)
        headStack.append(parts.count - 1)
        if look.hair != .bald && !creature { addHair(rx: rx, ry: ry) }
        if creature && look.creature == .fox || creature && look.creature == .cat {
            // A small tuft of fur on top.
            let tuftBase = surf(0, 1.15, 1.0)
            let t = pt(tuftBase)
            let s = hb * 0.18 * px
            parts[parts.count - 1].lines.append(line([t + Vec2(-s, s * 0.6), t + Vec2(-s * 0.2, -s * 0.6), t + Vec2(s * 0.3, s * 0.4)], ink, width: kit.line * 0.6))
        }
        if facing(HF) < -0.2 && (look.hair == .bald || creature) {
            let a = surf(Double.pi - 0.25, 0.35, 1.01), b = surf(Double.pi, 0.15, 1.01), c2 = surf(Double.pi + 0.25, 0.35, 1.01)
            faceLines.append(line(path3([a, b, c2]), ScanColor.shade(pal.skin, -0.3), width: kit.line * 0.6))
        }
        if look.has(.headphones) { addHeadphones() }
        if let hat = look.accessories.first(where: { $0.isHat }) { addHat(hat) }
        if look.has(.glasses) { addGlasses() }
    }

    /// Eye spots: (azimuth, elevation) per style.
    var eyePlace: (az: Double, el: Double) {
        switch look.style {
        case .chibi: return (0.42, -0.2)
        case .hero: return (0.33, 0.0)
        case .noodle: return (0.22, 0.05)
        case .creature: return (0.38, -0.05)
        default: return (0.33, 0)
        }
    }

    mutating func addFace(_ part: inout ScanPart) {
        let (eaz, eel) = eyePlace
        let style = look.style
        let lineW = kit.line * 0.8
        for side in [-1.0, 1.0] {
            let az = side * eaz
            let f = facing(surfNormal(az, eel))
            guard f > 0.12 else { continue }
            let e = pt(surf(az, eel, 1.0))
            let sq = max(0.25, f)
            switch style {
            case .chibi:
                let ex = hb * 0.13 * px * sq, ey = hb * 0.19 * px
                part.details.append(ScanPaint(shape: .ellipse(e, ex, ey, 0), color: pal.eye))
                part.details.append(ScanPaint(shape: .ellipse(Vec2(e.x - ex * 0.3, e.y - ey * 0.38), ex * 0.42, ex * 0.42, 0), color: RGBA(1, 1, 1, 1)))
                part.details.append(ScanPaint(shape: .ellipse(Vec2(e.x + ex * 0.35, e.y + ey * 0.4), ex * 0.2, ex * 0.2, 0), color: RGBA(1, 1, 1, 0.9)))
                let cheek = pt(surf(side * 0.68, -0.45, 1.0))
                if facing(surfNormal(side * 0.68, -0.45)) > 0.25 {
                    part.details.append(ScanPaint(shape: .ellipse(cheek, hb * 0.15 * px * sq, hb * 0.08 * px, 0), color: RGBA(1, 0.45, 0.5, 0.45)))
                }
            case .hero:
                let ex = hb * 0.12 * px * sq, ey = hb * 0.055 * px
                if !look.has(.mask) {
                    part.details.append(ScanPaint(shape: .ellipse(e, ex, ey, 0), color: RGBA(1, 1, 1, 1)))
                    part.details.append(ScanPaint(shape: .ellipse(e, ey * 0.85, ey * 0.85, 0), color: pal.eye))
                } else {
                    part.details.append(ScanPaint(shape: .ellipse(e, ex * 1.05, ey * 1.1, 0), color: RGBA(1, 1, 1, 1)))
                }
                let b0 = pt(surf(az - side * 0.14, 0.2, 1.02))
                let b1 = pt(surf(az + side * 0.14, 0.15, 1.02))
                faceLines.append(line([b0, b1], ScanColor.shade(pal.hair, -0.2), width: lineW * 1.3))
            case .noodle:
                let ex = hb * 0.1 * px * sq, ey = hb * 0.22 * px
                part.details.append(ScanPaint(shape: .ellipse(e, ex * 1.6, ey * 1.15, 0), color: RGBA(1, 1, 1, 1)))
                part.details.append(ScanPaint(shape: .ellipse(Vec2(e.x, e.y + ey * 0.25), ex, ey * 0.75, 0), color: pal.eye))
                let notch = [Vec2(e.x - ex * 0.5, e.y - ey * 0.15), Vec2(e.x + ex * 0.15, e.y - ey * 0.05), Vec2(e.x - ex * 0.25, e.y + ey * 0.25)]
                part.details.append(ScanPaint(shape: .polygon(notch), color: RGBA(1, 1, 1, 1)))
            case .creature:
                let ex = hb * 0.14 * px * sq, ey = hb * 0.16 * px
                part.details.append(ScanPaint(shape: .ellipse(e, ex, ey, 0), color: pal.eye))
                let slit = look.creature == .cat || look.creature == .dragon || look.creature == .fox
                let pupil = ScanShape.ellipse(e, slit ? ex * 0.25 : ex * 0.55, slit ? ey * 0.85 : ey * 0.6, 0)
                part.details.append(ScanPaint(shape: pupil, color: RGBA(0.05, 0.05, 0.08, 1)))
                part.details.append(ScanPaint(shape: .ellipse(Vec2(e.x - ex * 0.35, e.y - ey * 0.4), ex * 0.25, ex * 0.25, 0), color: RGBA(1, 1, 1, 1)))
            default:
                break
            }
        }
        // Mouth, nose, muzzle
        let front = facing(surfNormal(0, -0.45))
        guard front > 0.15 else { return }
        switch style {
        case .chibi:
            faceLines.append(line(curve(width: 0.12, el: -0.52, smile: 0.06), ink, width: lineW))
        case .hero:
            faceLines.append(line([pt(surf(0, -0.05, 1.05)), pt(surf(0.06, -0.3, 1.1)), pt(surf(0, -0.33, 1.06))],
                                  ScanColor.shade(pal.skin, -0.35), width: lineW * 0.8))
            faceLines.append(line(curve(width: 0.17, el: -0.56, smile: 0.03), ink, width: lineW))
        case .noodle:
            part.details.append(ScanPaint(shape: .ellipse(pt(surf(0, -0.18, 1.04)), hb * 0.1 * px, hb * 0.07 * px, 0), color: pal.eye))
            faceLines.append(line(curve(width: 0.55, el: -0.42, smile: 0.22), ink, width: lineW * 1.3))
        case .creature:
            let mc = surf(0, -0.42, 1.02)
            part.details.append(ScanPaint(shape: .ellipse(pt(mc), ha * 0.38 * px * max(0.3, front), hb * 0.27 * px, 0), color: pal.light))
            let nose = pt(surf(0, -0.26, 1.06))
            let ns = hb * (look.creature == .bear ? 0.11 : 0.07) * px
            let nosePoly = [Vec2(nose.x - ns, nose.y - ns * 0.5), Vec2(nose.x + ns, nose.y - ns * 0.5), Vec2(nose.x, nose.y + ns * 0.6)]
            part.details.append(ScanPaint(shape: .polygon(nosePoly), color: look.creature == .bunny ? RGBA(0.95, 0.5, 0.6, 1) : RGBA(0.1, 0.08, 0.1, 1)))
            let m0 = pt(surf(-0.12, -0.5, 1.03)), m1 = pt(surf(0, -0.44, 1.05)), m2 = pt(surf(0.12, -0.5, 1.03))
            faceLines.append(line([m0, pt(surf(-0.06, -0.54, 1.04)), m1], ink, width: lineW * 0.8))
            faceLines.append(line([m1, pt(surf(0.06, -0.54, 1.04)), m2], ink, width: lineW * 0.8))
            if look.creature == .cat || look.creature == .fox {
                for side in [-1.0, 1.0] where facing(surfNormal(side * 0.3, -0.4)) > 0.2 {
                    let s = pt(surf(side * 0.3, -0.4, 1.02))
                    let headC = pt(rig[.head])
                    let dir: Double = s.x >= headC.x ? 1 : -1
                    for k in [-1.0, 0.0, 1.0] {
                        let end = Vec2(s.x + dir * ha * 0.6 * px, s.y + k * hb * 0.12 * px)
                        faceLines.append(line([s, end], ink, width: lineW * 0.5))
                    }
                }
            }
        default:
            break
        }
    }

    /// A mouth-like curve across the face.
    func curve(width: Double, el: Double, smile: Double) -> [Vec2] {
        (0...8).map { i in
            let t = Double(i) / 8 * 2 - 1
            let e = el - smile * (1 - t * t)
            return pt(surf(t * width, e, 1.02))
        }
    }

    mutating func addMask(_ part: inout ScanPart) {
        let (eaz, eel) = eyePlace
        var pts: [ScanVec3] = []
        var low: [ScanVec3] = []
        for i in 0...12 {
            let az = -1.4 + 2.8 * Double(i) / 12
            guard facing(surfNormal(az, eel)) > 0.02 else { continue }
            pts.append(surf(az, eel + 0.16 + (abs(az - eaz) < 0.2 || abs(az + eaz) < 0.2 ? 0.04 : 0), 1.02))
            low.append(surf(az, eel - 0.13, 1.02))
        }
        guard pts.count >= 2 else { return }
        let poly = path3(pts) + path3(low.reversed())
        part.details.append(ScanPaint(shape: .polygon(poly), color: pal.second))
    }

    mutating func addCreatureEars(_ part: inout ScanPart) {
        let inner = look.creature == .bunny ? RGBA(0.98, 0.7, 0.75, 1) : ScanColor.mix(pal.light, RGBA(1, 0.6, 0.7, 1), 0.5)
        for side in [-1.0, 1.0] {
            switch look.creature {
            case .bear:
                let c = surf(side * 0.75, 0.62, 1.0)
                part.shapes.append(ScanPaint(shape: ball(c, hb * 0.3), color: pal.skin))
                if facing(surfNormal(side * 0.75, 0.62)) > 0.2 {
                    part.details.append(ScanPaint(shape: ball(c + HF * (hb * 0.1), hb * 0.16), color: inner))
                }
            case .bunny:
                let base = surf(side * 0.35, 0.75, 0.95)
                let dir = (surfNormal(side * 0.35, 0.75) * 0.35 + HU).normalized
                let tip = base + dir * (hb * 1.6)
                part.shapes.append(ScanPaint(shape: capsule(base, tip, hb * 0.18, hb * 0.22), color: pal.skin))
                if facing(HF) > 0.2 {
                    part.details.append(ScanPaint(shape: capsule(base + dir * (hb * 0.3), tip, hb * 0.08, hb * 0.12), color: inner))
                }
            case .cat, .fox, .dragon:
                if look.creature == .dragon {
                    // Small fins instead of ears.
                    let base = surf(side * 1.2, 0.2, 0.95)
                    let tip = base + (surfNormal(side * 1.2, 0.2) * 0.7 - HF * 0.5 + HU * 0.3).normalized * (hb * 0.55)
                    part.shapes.append(ScanPaint(shape: hull([base + HU * (hb * 0.15), base - HU * (hb * 0.15), tip]), color: pal.light))
                    continue
                }
                let az = side * 0.55, el = 0.72
                let big = look.creature == .fox ? 1.25 : 1.0
                let n = surfNormal(az, el)
                let dir = (n * 0.5 + HU * 0.8).normalized
                let baseC = surf(az, el, 0.96)
                let tip = baseC + dir * (hb * 0.75 * big)
                let b1 = surf(az - 0.3 * big, el - 0.05, 0.96), b2 = surf(az + 0.3 * big, el - 0.05, 0.96)
                let b3 = surf(az, el - 0.22, 0.96), b4 = surf(az, el + 0.18, 0.96)
                part.shapes.append(ScanPaint(shape: hull([b1, b2, b3, b4, tip]), color: pal.skin))
                if facing(HF) > 0.25 {
                    let ic = ScanVec3.lerp(baseC, tip, 0.35) + HF * (hc * 0.05)
                    let i1 = ScanVec3.lerp(b1, tip, 0.25), i2 = ScanVec3.lerp(b2, tip, 0.25)
                    part.details.append(ScanPaint(shape: hull([ic, i1, i2, ScanVec3.lerp(baseC, tip, 0.85)]), color: inner))
                }
            }
        }
    }

    mutating func addHorns(_ part: inout ScanPart) {
        for side in [-1.0, 1.0] {
            let base = surf(side * 0.42, 0.72, 0.95)
            let p1 = base + (HU * 0.8 - HF * 0.5 + HL * (0.2 * side)).normalized * (hb * 0.5)
            let p2 = p1 + (HU * 0.25 - HF * 0.9).normalized * (hb * 0.45)
            part.shapes.append(ScanPaint(shape: capsule(base, p1, hb * 0.14, hb * 0.1), color: pal.light))
            part.shapes.append(ScanPaint(shape: capsule(p1, p2, hb * 0.1, hb * 0.025), color: pal.light))
        }
    }

    // MARK: Hair

    struct HairShape {
        var puff: Double
        var front: Double
        var side: Double
        var back: Double
        var bangs: Double = 0
        var bangsCount: Double = 5
        var spikes: Double = 0
        var spikesCount: Double = 9
        var bumps: Double = 0
        var bumpsCount: Double = 14
    }

    static func hairShape(_ h: ScanHair) -> HairShape {
        switch h {
        case .buzz: return HairShape(puff: 0.03, front: 0.55, side: 0.25, back: -0.35)
        case .short: return HairShape(puff: 0.08, front: 0.42, side: 0.05, back: -0.55, bangs: 0.12, bangsCount: 5)
        case .spiky: return HairShape(puff: 0.1, front: 0.45, side: 0.05, back: -0.5, bangs: 0.17, bangsCount: 4, spikes: 0.28, spikesCount: 9)
        case .bob: return HairShape(puff: 0.14, front: 0.3, side: -0.85, back: -0.9, bangs: 0.05, bangsCount: 9)
        case .long: return HairShape(puff: 0.1, front: 0.5, side: -1.9, back: -2.2, bangs: 0.06, bangsCount: 3)
        case .ponytail: return HairShape(puff: 0.07, front: 0.5, side: 0.0, back: -0.45, bangs: 0.08, bangsCount: 3)
        case .curly: return HairShape(puff: 0.3, front: 0.45, side: -0.25, back: -0.6, bumps: 0.06, bumpsCount: 16)
        case .mohawk: return HairShape(puff: 0.02, front: 0.62, side: 0.38, back: -0.15)
        case .bald: return HairShape(puff: 0, front: 1, side: 1, back: 1)
        }
    }

    func hairline(_ phi0: Double, _ hs: HairShape) -> Double {
        let phi = ScanGeo.wrap(phi0)
        let u = abs(phi)
        var y: Double
        if u <= Double.pi / 2 {
            let t = ScanGeo.smooth((u - 0.45) / (Double.pi / 2 - 0.45))
            y = hs.front + (hs.side - hs.front) * t
        } else {
            let t = ScanGeo.smooth((u - Double.pi / 2) / (Double.pi / 2))
            y = hs.side + (hs.back - hs.side) * t
        }
        if hs.bangs > 0 && u < 1.1 {
            y -= hs.bangs * ScanGeo.tri(phi * hs.bangsCount / Double.pi + 1) * (1 - u / 1.1)
        }
        return y
    }

    func hairPoint(_ phi: Double, _ y: Double, _ puff: Double) -> ScanVec3 {
        var k = (max(0, 1 - y * y)).squareRoot()
        if y < -0.35 { k = max(k, 0.85) }
        if y < -1 { k = 0.85 }
        let x = HL * (ha * (1 + puff) * sin(phi) * k)
        let up = HU * (hb * y)
        let z = HF * (hc * (1 + puff) * cos(phi) * k)
        return rig[.head] + x + up + z
    }

    mutating func addHair(rx: Double, ry: Double) {
        let hs = ScanFigure.hairShape(look.hair)
        let c2 = pt(rig[.head])
        let lz = facing(HL), fz = facing(HF)
        let phiC = atan2(lz, fz)
        let e1 = phiC + Double.pi / 2, e2 = phiC - Double.pi / 2
        let s1 = pt(hairPoint(e1, 0, hs.puff)), s2 = pt(hairPoint(e2, 0, hs.puff))
        let phiL = s1.x <= s2.x ? e1 : e2
        let phiR = s1.x <= s2.x ? e2 : e1
        let left = pt(hairPoint(phiL, hairline(phiL, hs), hs.puff))
        let right = pt(hairPoint(phiR, hairline(phiR, hs), hs.puff))
        let rxH = rx * (1 + hs.puff), ryH = ry * (1 + hs.puff)
        func arcT(_ y: Double, _ leftSide: Bool) -> Double {
            let v = max(-0.6, min(1, (c2.y - y) / max(1, ryH)))
            let s = asin(v)
            return leftSide ? Double.pi - s : s
        }
        func ellipsePoint(_ t: Double, _ r: Double) -> Vec2 { Vec2(c2.x + rxH * cos(t) * r, c2.y - ryH * sin(t) * r) }
        let tL = arcT(left.y, true), tR = arcT(right.y, false)
        var poly: [Vec2] = []
        let startE = ellipsePoint(tL, 1)
        if left.y > startE.y + 1 { poly.append(Vec2(startE.x, left.y)) }
        let n = 48
        for i in 0...n {
            let t = tL + (tR - tL) * Double(i) / Double(n)
            var r = 1.0
            if hs.spikes > 0 { r += hs.spikes * ScanGeo.tri((t - tR) / (tL - tR) * hs.spikesCount * 2) * max(0, sin(t)) }
            if hs.bumps > 0 { r += hs.bumps * 0.5 * (1 + sin(t * hs.bumpsCount)) }
            poly.append(ellipsePoint(t, r))
        }
        let endE = ellipsePoint(tR, 1)
        if right.y > endE.y + 1 { poly.append(Vec2(endE.x, right.y)) }
        let m = 32
        for i in 0...m {
            let phi = phiR + (phiL - phiR) * Double(i) / Double(m)
            poly.append(pt(hairPoint(phi, hairline(phi, hs), hs.puff)))
        }
        var part = newPart(headDepth + 0.0005)
        part.shapes.append(ScanPaint(shape: .polygon(poly), color: pal.hair))
        // A few strands for shine
        let strandColor = ScanColor.shade(pal.hair, -0.3)
        for k in [-0.5, 0.1, 0.6] {
            let phi = phiC + k
            let top = hairPoint(phi, 0.92, hs.puff * 0.9)
            let low = hairPoint(phi + 0.1, min(0.85, hairline(phi, hs) + 0.22), hs.puff * 0.9)
            if facing(surfNormal(phi, 0.6)) > 0.1 {
                faceLines.append(line([pt(top), pt(ScanVec3.lerp(top, low, 0.5) + HL * (ha * 0.03)), pt(low)], strandColor, width: kit.line * 0.6))
            }
        }
        add(part)
        headStack.append(parts.count - 1)
        // Hair that hangs down the back
        if look.hair == .long {
            let head = rig[.head]
            // Hangs down to about the chest, rounded at the bottom, behind the head.
            let chestDrop = (head.y - rig[.chest].y) / max(1e-6, hb)
            let bottom = max(hs.back, -max(1.2, chestDrop))
            var pts: [ScanVec3] = []
            for i in 0..<12 {
                let a = Double.pi / 2 + Double.pi * Double(i) / 11
                let topP = head + HL * (ha * 1.06 * sin(a)) + HU * (hb * 0.2) + HF * (hc * 0.95 * cos(a))
                let lowP = head + HL * (ha * 0.85 * sin(a)) + HU * (hb * bottom) + HF * (hc * (0.75 * cos(a) - 0.3))
                pts.append(topP)
                pts.append(lowP)
            }
            for i in 0...6 {
                let a = Double.pi * Double(i) / 6
                pts.append(head + HL * (ha * 0.85 * cos(a)) + HU * (hb * (bottom - 0.25 * sin(a))) - HF * (hc * 0.5))
            }
            var back = newPart(dp(head - HF * (hc * 0.65)))
            back.shapes.append(ScanPaint(shape: hull(pts), color: pal.hair))
            add(back)
        }
        if look.hair == .ponytail {
            let head = rig[.head]
            let tie = head + HU * (hb * 0.25) - HF * (hc * 1.0)
            let p1 = tie - HF * (hc * 0.45) - HU * (hb * 0.9)
            let p2 = p1 - HU * (hb * 0.9) + HF * (hc * 0.1)
            var tail = newPart(dp(p1))
            tail.shapes.append(ScanPaint(shape: capsule(tie, p1, ha * 0.28, ha * 0.26), color: pal.hair))
            tail.shapes.append(ScanPaint(shape: capsule(p1, p2, ha * 0.26, ha * 0.08), color: pal.hair))
            tail.details.append(ScanPaint(shape: ball(tie, ha * 0.14), color: pal.accent))
            add(tail)
        }
        if look.hair == .mohawk {
            var fin = newPart(headDepth + 0.0007)
            for i in 0..<6 {
                let m = 1.0 + Double(i) * 0.3
                let dirOut = HU * sin(m) + HF * cos(m)
                let baseC = rig[.head] + HU * (hb * sin(m)) + HF * (hc * cos(m))
                let tip = baseC + dirOut * (hb * 0.55)
                let along = (HU * cos(m) - HF * sin(m)) * (hb * 0.18)
                let side = HL * (ha * 0.16)
                fin.shapes.append(ScanPaint(shape: hull([baseC + along, baseC - along, baseC + side, baseC - side, tip]), color: pal.hair))
            }
            add(fin)
            headStack.append(parts.count - 1)
        }
    }

    // MARK: Hats and extras

    mutating func addHat(_ hat: ScanAccessory) {
        let head = rig[.head]
        var part = newPart(headDepth + 0.001)
        func ring(_ y: Double, _ r: Double, count: Int = 20) -> [ScanVec3] {
            (0..<count).map { i in
                let a = Double(i) / Double(count) * 2 * Double.pi
                return head + HL * (ha * r * sin(a)) + HU * (hb * y) + HF * (hc * r * cos(a))
            }
        }
        func dome(_ from: Double, _ scale: Double) -> [ScanVec3] {
            var pts: [ScanVec3] = []
            for k in 0...4 {
                let y = from + (1 - from) * Double(k) / 4
                let r = (max(0, 1 - y * y)).squareRoot()
                pts.append(contentsOf: ring(y * scale, r * scale, count: 16))
            }
            pts.append(head + HU * (hb * scale))
            return pts
        }
        switch hat {
        case .cap:
            part.shapes.append(ScanPaint(shape: hull(dome(0.35, 1.1)), color: pal.accent))
            let base = head + HU * (hb * 0.4) + HF * (hc * 0.95)
            var brim: [ScanVec3] = []
            for i in 0...10 {
                let s = -Double.pi / 2 + Double.pi * Double(i) / 10
                brim.append(base + HL * (ha * 0.85 * sin(s)) + HF * (hc * 0.7 * cos(s)))
            }
            brim.append(base - HF * (hc * 0.1))
            part.shapes.append(ScanPaint(shape: hull(brim), color: ScanColor.shade(pal.accent, -0.25)))
        case .beanie:
            part.shapes.append(ScanPaint(shape: hull(dome(0.25, 1.14)), color: pal.accent))
            part.shapes.append(ScanPaint(shape: hull(ring(0.22, 1.18) + ring(0.42, 1.12)), color: ScanColor.shade(pal.accent, -0.2)))
            part.shapes.append(ScanPaint(shape: ball(head + HU * (hb * 1.2), hb * 0.2), color: pal.light))
        case .wizardHat:
            part.shapes.append(ScanPaint(shape: hull(ring(0.42, 1.55)), color: ScanColor.shade(pal.accent, -0.2)))
            let tip = head + HU * (hb * 2.7) - HF * (hc * 0.5)
            part.shapes.append(ScanPaint(shape: hull(ring(0.45, 1.0) + [tip]), color: pal.accent))
            let starC = pt(head + HU * (hb * 1.1) + HF * (hc * 0.75))
            if facing(HF) > 0.3 {
                part.details.append(ScanPaint(shape: .polygon(ScanGeo.star(starC, outer: hb * 0.22 * px, inner: hb * 0.09 * px, points: 5)), color: pal.light))
            }
        case .crown:
            let lz = facing(HL), fz = facing(HF)
            let phiC = atan2(lz, fz)
            var bottom: [Vec2] = []
            var top: [Vec2] = []
            let n = 10
            for i in 0...n {
                let phi = phiC - Double.pi / 2 + Double.pi * Double(i) / Double(n)
                let b = head + HL * (ha * 0.88 * sin(phi)) + HU * (hb * 0.55) + HF * (hc * 0.88 * cos(phi))
                let up = i % 2 == 0 ? 1.15 : 0.82
                let t = head + HL * (ha * 0.88 * sin(phi)) + HU * (hb * up) + HF * (hc * 0.88 * cos(phi))
                bottom.append(pt(b))
                top.append(pt(t))
            }
            part.shapes.append(ScanPaint(shape: .polygon(bottom + top.reversed()), color: RGBA(0.98, 0.8, 0.2, 1)))
            if facing(HF) > 0.3 {
                part.details.append(ScanPaint(shape: ball(head + HU * (hb * 0.7) + HF * (hc * 0.9), hb * 0.09), color: pal.accent))
            }
        default:
            break
        }
        add(part)
        headStack.append(parts.count - 1)
    }

    mutating func addGlasses() {
        let (eaz, eel) = eyePlace
        var centers: [Vec2] = []
        for side in [-1.0, 1.0] {
            let az = side * eaz
            let f = facing(surfNormal(az, eel))
            guard f > 0.15 else { continue }
            let c = pt(surf(az, eel, 1.08))
            let r = hb * 0.2 * px
            let loop = ScanGeo.ellipse(c, r * max(0.3, f), r * 0.85, 0, segments: 20)
            faceLines.append(line(loop + [loop[0]], ink, width: kit.line * 0.7))
            centers.append(c)
        }
        if centers.count == 2 {
            let a = centers[0], b = centers[1]
            let r = hb * 0.2 * px
            let leftC = a.x < b.x ? a : b, rightC = a.x < b.x ? b : a
            faceLines.append(line([Vec2(leftC.x + r * 0.7, leftC.y - r * 0.2), Vec2(rightC.x - r * 0.7, rightC.y - r * 0.2)], ink, width: kit.line * 0.7))
        }
    }

    mutating func addHeadphones() {
        let head = rig[.head]
        var bandPts: [ScanVec3] = []
        for i in 0...12 {
            let a = -Double.pi / 2 + Double.pi * Double(i) / 12
            bandPts.append(head + HL * (ha * 1.1 * sin(a)) + HU * (hb * 1.1 * cos(a)) - HF * (hc * 0.05))
        }
        faceLines.append(line(path3(bandPts), ScanColor.shade(pal.accent, -0.3), width: kit.line * 2))
        for side in [-1.0, 1.0] {
            let c = head + HL * (ha * 1.02 * side)
            var cup = newPart(dp(c) + 0.03)
            cup.shapes.append(ScanPaint(shape: ball(c, hb * 0.28), color: pal.accent))
            add(cup)
        }
    }

    // MARK: Robot

    mutating func buildRobot() {
        groundShadow()
        let metal = pal.main
        let dark = pal.second
        let glow = pal.accent
        // Legs
        let legs: [(ScanJoint, ScanJoint, ScanJoint, ScanJoint)] = [
            (.leftHip, .leftKnee, .leftAnkle, .leftToe), (.rightHip, .rightKnee, .rightAnkle, .rightToe)
        ]
        for (hp, kn, an, to) in legs {
            var part = newPart((d(kn) + d(an)) / 2 - 0.03)
            let h = rig[hp], k = rig[kn], a = rig[an], t = rig[to]
            part.shapes.append(ScanPaint(shape: limbBox(h, k, th.thigh, th.thigh * 0.85), color: metal))
            part.shapes.append(ScanPaint(shape: limbBox(k, a, th.knee * 0.9, th.knee * 0.8), color: metal))
            var toe = (t - a).normalized
            if toe == .zero { toe = F }
            let footC = a + toe * (a.distance(to: t) * 0.35) + ScanVec3(0, -th.ankle * 0.5, 0)
            let (fr, ff) = basis(toe)
            _ = ff
            part.shapes.append(ScanPaint(shape: hull(corners(footC, toe, fr, toe.cross(fr).normalized,
                                                              a.distance(to: t) * 0.7 * th.footLength, th.foot, th.foot * 0.7)), color: dark))
            part.shapes.append(ScanPaint(shape: ball(k, th.knee * 0.8), color: dark))
            add(part)
        }
        if look.has(.jetpack) { addJetpack() }
        // Torso
        let hips = rig[.hips], chest = rig[.chest], neck = rig[.neck]
        var torso = newPart(torsoDepth)
        let torsoLen = neck.distance(to: hips)
        let pelvis = corners(hips + U * 0.005, R, U, F, hipHalf * 0.95, torsoLen * 0.12, hipD)
        torso.shapes.append(ScanPaint(shape: hull(pelvis), color: metal))
        let belly = corners(ScanVec3.lerp(hips, chest, 0.4), R, U, F, waistHalf * 0.6, torsoLen * 0.14, waistD * 0.8)
        torso.shapes.append(ScanPaint(shape: hull(belly), color: dark))
        let chestC = ScanVec3.lerp(hips, neck, 0.66)
        let chestBox = corners(chestC, R, U, F, shoulderHalf * 0.92, torsoLen * 0.3, chestD * 1.15)
        torso.shapes.append(ScanPaint(shape: hull(chestBox), color: metal))
        if facing(F) > 0.15 {
            let fc = chestC + F * (chestD * 1.16)
            let w = shoulderHalf * 0.55, h = torsoLen * 0.18
            let panel = [fc - R * w - U * h, fc + R * w - U * h, fc + R * w + U * h, fc - R * w + U * h]
            torso.details.append(ScanPaint(shape: .polygon(path3(panel)), color: ScanColor.shade(dark, 0.1)))
            torso.details.append(ScanPaint(shape: ball(fc + U * (h * 0.2), min(w, h) * 0.55), color: ScanColor.shade(glow, 0.3).with(alpha: 0.5)))
            torso.details.append(ScanPaint(shape: ball(fc + U * (h * 0.2), min(w, h) * 0.35), color: glow))
            for k in 0..<3 {
                let y = fc - U * (h * 0.55) + R * (w * (Double(k) - 1) * 0.5)
                torso.lines.append(line([pt(y - U * (h * 0.15)), pt(y + U * (h * 0.15))], glow, width: kit.line * 0.6))
            }
        } else if facing(F) < -0.15 {
            // Back vents
            let bc = chestC - F * (chestD * 1.16)
            for k in 0..<4 {
                let y = bc + U * (torsoLen * 0.15 - Double(k) * torsoLen * 0.08)
                torso.lines.append(line([pt(y - R * (shoulderHalf * 0.5)), pt(y + R * (shoulderHalf * 0.5))], dark, width: kit.line * 0.7))
            }
        }
        add(torso)
        // Neck
        var neckPart = newPart(min(torsoDepth, d(.head)) - 0.002)
        neckPart.shapes.append(ScanPaint(shape: capsule(neck, rig[.head] - HU * (hb * 0.6), th.neck, th.neck), color: dark))
        add(neckPart)
        // Arms
        let arms: [(ScanJoint, ScanJoint, ScanJoint, ScanJoint)] = [
            (.leftShoulder, .leftElbow, .leftWrist, .leftHand), (.rightShoulder, .rightElbow, .rightWrist, .rightHand)
        ]
        for (sh, el, wr, hd) in arms {
            var part = newPart((d(el) + d(wr) + d(hd)) / 3 - 0.005)
            let s = rig[sh], e = rig[el], w = rig[wr], h = rig[hd]
            part.shapes.append(ScanPaint(shape: limbBox(s, e, th.upperArm, th.upperArm * 0.9), color: metal))
            part.shapes.append(ScanPaint(shape: limbBox(e, w, th.elbow * 0.95, th.wrist), color: metal))
            part.shapes.append(ScanPaint(shape: ball(e, th.elbow * 0.85), color: dark))
            part.shapes.append(ScanPaint(shape: limbBox(w, h, th.hand * 0.8, th.hand * 0.55), color: dark))
            part.shapes.append(ScanPaint(shape: ball(s, th.upperArm * 1.1), color: dark))
            if look.has(.shoulderPads) {
                let up = s + U * (th.upperArm * 0.6)
                part.shapes.append(ScanPaint(shape: hull(corners(up, R, U, F, th.upperArm * 1.5, th.upperArm * 0.7, th.upperArm * 1.4)), color: glow))
            }
            add(part)
        }
        // Head
        let head = rig[.head]
        var hp = newPart(headDepth)
        switch look.variant % 3 {
        case 0:
            hp.shapes.append(ScanPaint(shape: hull(corners(head, HL, HU, HF, ha * 0.95, hb * 0.85, hc * 0.9)), color: metal))
        case 1:
            let (rx, ry) = headRadii
            hp.shapes.append(ScanPaint(shape: .ellipse(pt(head), rx, ry, 0), color: metal))
        default:
            hp.shapes.append(ScanPaint(shape: hull(corners(head + HU * (hb * 0.1), HL, HU, HF, ha * 0.75, hb * 1.0, hc * 0.8)), color: metal))
        }
        let ff = facing(HF)
        if ff > 0.1 {
            let vc = head + HF * (hc * 0.98) + HU * (hb * 0.15)
            let w = ha * 0.7, h = hb * 0.2
            let visor = [vc - HL * w - HU * h, vc + HL * w - HU * h, vc + HL * w + HU * h, vc - HL * w + HU * h]
            hp.details.append(ScanPaint(shape: .polygon(path3(visor)), color: dark))
            if look.variant % 2 == 0 {
                for side in [-1.0, 1.0] {
                    hp.details.append(ScanPaint(shape: ball(vc + HL * (w * 0.5 * side), h * 0.7), color: glow))
                }
            } else {
                let bar = [vc - HL * (w * 0.85) - HU * (h * 0.35), vc + HL * (w * 0.85) - HU * (h * 0.35),
                           vc + HL * (w * 0.85) + HU * (h * 0.35), vc - HL * (w * 0.85) + HU * (h * 0.35)]
                hp.details.append(ScanPaint(shape: .polygon(path3(bar)), color: glow))
            }
            for k in 0..<3 {
                let gc = head + HF * (hc * 0.98) - HU * (hb * 0.45) + HL * (ha * 0.25 * (Double(k) - 1))
                faceLines.append(line([pt(gc + HU * (hb * 0.1)), pt(gc - HU * (hb * 0.1))], dark, width: kit.line * 0.7))
            }
        } else {
            let bc = head - HF * (hc * 0.95)
            faceLines.append(line([pt(bc - HL * (ha * 0.5)), pt(bc + HL * (ha * 0.5))], dark, width: kit.line * 0.7))
        }
        for side in [-1.0, 1.0] {
            let bolt = head + HL * (ha * 0.97 * side)
            if facing(HL * side) > 0.2 {
                hp.details.append(ScanPaint(shape: ball(bolt, hb * 0.14), color: dark))
            } else {
                hp.shapes.insert(ScanPaint(shape: ball(bolt, hb * 0.18), color: dark), at: 0)
            }
        }
        if look.has(.antenna) {
            let base = rig[.headTop]
            let tip = base + HU * (hb * 0.9) + HL * (ha * 0.15)
            faceLines.append(line([pt(base), pt(tip)], dark, width: kit.line * 0.9))
            hp.details.append(ScanPaint(shape: ball(tip, hb * 0.13), color: glow))
        }
        add(hp)
        headStack.append(parts.count - 1)
    }

    /// A long box along a bone.
    func limbBox(_ a: ScanVec3, _ b: ScanVec3, _ ra: Double, _ rb: Double) -> ScanShape {
        var u = (b - a).normalized
        if u == .zero { u = ScanVec3(0, -1, 0) }
        let (r, f) = basis(u)
        var pts: [ScanVec3] = []
        for (c, rad) in [(a, ra), (b, rb)] {
            for sx in [-1.0, 1.0] {
                for sz in [-1.0, 1.0] {
                    pts.append(c + r * (rad * sx) + f * (rad * 0.9 * sz))
                }
            }
        }
        return hull(pts)
    }

    // MARK: Sketch mannequin

    mutating func buildMannequin() {
        let pencil = pal.ink
        let tone = pal.light
        let w = kit.line
        func sketch(_ pts: [Vec2], _ depth: Double, width: Double? = nil) -> ScanLine {
            var l = ScanLine(points: pts, color: pencil, width: width ?? w, kind: .pencil, pressure: 0.75)
            l.opacity = depth < -0.02 ? 0.45 : 1
            return l
        }
        func loop(_ pts: [Vec2]) -> [Vec2] { pts.isEmpty ? pts : pts + [pts[0]] }
        func tube(_ part: inout ScanPart, _ a: ScanVec3, _ b: ScanVec3, _ ra: Double, _ rb: Double, _ depth: Double) {
            part.shapes.append(ScanPaint(shape: capsule(a, b, ra, rb), color: tone))
            for side in ScanGeo.capsuleSides(pt(a), pt(b), ra * px, rb * px) {
                part.lines.append(sketch(side, depth))
            }
        }
        func joint(_ part: inout ScanPart, _ c: ScanVec3, _ r: Double, _ depth: Double) {
            part.lines.append(sketch(loop(ScanGeo.circle(pt(c), r * px, segments: 18)), depth, width: w * 0.8))
        }
        // Legs
        let legs: [(ScanJoint, ScanJoint, ScanJoint, ScanJoint)] = [
            (.leftHip, .leftKnee, .leftAnkle, .leftToe), (.rightHip, .rightKnee, .rightAnkle, .rightToe)
        ]
        for (hp, kn, an, to) in legs {
            let depth = (d(kn) + d(an)) / 2 - 0.03
            var part = ScanPart(depth: depth, keepLinesAsStrokes: true)
            let h = rig[hp], k = rig[kn], a = rig[an], t = rig[to]
            tube(&part, h, k, th.thigh, th.knee, depth)
            tube(&part, k, a, th.knee * 0.95, th.ankle, depth)
            joint(&part, k, th.knee * 0.9, depth)
            joint(&part, a, th.ankle * 0.9, depth)
            joint(&part, h, th.thigh * 0.7, depth)
            // Foot as a wedge
            var toe = (t - a).normalized
            if toe == .zero { toe = F }
            let tip = a + toe * (a.distance(to: t) * 1.25) + ScanVec3(0, -th.ankle * 0.6, 0)
            let heel = a - toe * (th.ankle * 0.8) + ScanVec3(0, -th.ankle * 0.9, 0)
            let top = a + ScanVec3(0, th.ankle * 0.4, 0)
            let wedge = [pt(heel), pt(tip), pt(top)]
            part.shapes.append(ScanPaint(shape: .polygon(ScanGeo.hull(wedge)), color: tone))
            part.lines.append(sketch(loop(wedge), depth))
            add(part)
        }
        // Torso: rib cage and pelvis
        let hips = rig[.hips], chest = rig[.chest], neck = rig[.neck]
        let tDepth = torsoDepth
        var torso = ScanPart(depth: tDepth, keepLinesAsStrokes: true)
        let ribC = ScanVec3.lerp(chest, neck, 0.15)
        let ribs = band([(ScanVec3.lerp(hips, chest, 0.55), waistHalf * 0.9, waistD),
                         (chest, chestHalf * 0.95, chestD),
                         (ScanVec3.lerp(chest, neck, 0.75), shoulderHalf * 0.85, chestD * 0.85),
                         (neck + U * 0.01, th.neck * 1.3, th.neck * 1.2)])
        torso.shapes.append(ScanPaint(shape: ribs, color: tone))
        torso.lines.append(sketch(loop(ribs.path(grow: 0)), tDepth))
        let pelvisBox = corners(hips + U * 0.01, R, U, F, hipHalf * 0.95, neck.distance(to: hips) * 0.12, hipD)
        let pelvis = ScanGeo.hull(pelvisBox.map { pt($0) })
        torso.shapes.append(ScanPaint(shape: .polygon(pelvis), color: tone))
        torso.lines.append(sketch(loop(pelvis), tDepth))
        // Center line down the front (or the spine on the back)
        let sideSign: Double = facing(F) >= 0 ? 1 : -1
        let center = [hips, ScanVec3.lerp(hips, chest, 0.5), ribC, neck].map { $0 + F * (chestD * sideSign * 0.98) }
        torso.lines.append(sketch(path3(center), tDepth, width: w * 0.6))
        // Shoulder line
        torso.lines.append(sketch([p(.leftShoulder), p(.rightShoulder)], tDepth, width: w * 0.6))
        add(torso)
        // Neck
        var neckPart = ScanPart(depth: min(tDepth, d(.head)) - 0.002, keepLinesAsStrokes: true)
        tube(&neckPart, neck, rig[.head] - HU * (hb * 0.6), th.neck, th.neck * 0.9, neckPart.depth)
        add(neckPart)
        // Arms
        let arms: [(ScanJoint, ScanJoint, ScanJoint, ScanJoint)] = [
            (.leftShoulder, .leftElbow, .leftWrist, .leftHand), (.rightShoulder, .rightElbow, .rightWrist, .rightHand)
        ]
        for (sh, el, wr, hd) in arms {
            let depth = (d(el) + d(wr) + d(hd)) / 3 - 0.005
            var part = ScanPart(depth: depth, keepLinesAsStrokes: true)
            let s = rig[sh], e = rig[el], wv = rig[wr], h = rig[hd]
            tube(&part, s, e, th.upperArm, th.elbow, depth)
            tube(&part, e, wv, th.elbow * 0.95, th.wrist, depth)
            joint(&part, s, th.upperArm * 0.95, depth)
            joint(&part, e, th.elbow * 0.85, depth)
            let mitt = ScanShape.capsule(pt(wv), pt(h + (h - wv) * 0.4), th.wrist * px, th.hand * px)
            part.shapes.append(ScanPaint(shape: mitt, color: tone))
            part.lines.append(sketch(loop(mitt.path(grow: 0)), depth))
            add(part)
        }
        // Head with guide lines
        let head = rig[.head]
        let hDepth = headDepth
        var hp = ScanPart(depth: hDepth, keepLinesAsStrokes: true)
        let (rx, ry) = headRadii
        let headShape = ScanShape.ellipse(pt(head), rx, ry, 0)
        hp.shapes.append(ScanPaint(shape: headShape, color: tone))
        hp.lines.append(sketch(loop(headShape.path(grow: 0)), hDepth))
        var meridian: [Vec2] = []
        for i in 0...16 {
            let el = -1.3 + 2.6 * Double(i) / 16
            for az in [0.0] where facing(surfNormal(az, el)) > 0 { meridian.append(pt(surf(az, el, 1))) }
        }
        if meridian.count >= 2 { hp.lines.append(sketch(meridian, hDepth, width: w * 0.6)) }
        var equator: [Vec2] = []
        for i in 0...24 {
            let az = -Double.pi + 2 * Double.pi * Double(i) / 24
            if facing(surfNormal(az, 0)) > 0 { equator.append(pt(surf(az, 0, 1))) }
        }
        if equator.count >= 2 { hp.lines.append(sketch(equator, hDepth, width: w * 0.6)) }
        add(hp)
        headStack.append(parts.count - 1)
        // Line of action (through the leg that holds the weight)
        let standLeft = rig[.leftAnkle].y <= rig[.rightAnkle].y
        let gesture = [rig[.headTop], head, neck, chest, hips,
                       rig[standLeft ? .leftKnee : .rightKnee], rig[standLeft ? .leftAnkle : .rightAnkle]]
        var g = ScanLine(points: path3(gesture), color: pal.accent, width: w * 1.2, kind: .pencil, pressure: 0.6)
        g.opacity = 0.7
        over.append(g)
        // Floor line and a ruler counting heads
        let leftX = min(p(.leftAnkle).x, p(.rightAnkle).x) - 0.12 * px
        let rightX = max(p(.leftAnkle).x, p(.rightAnkle).x) + 0.12 * px
        over.append(ScanLine(points: [Vec2(leftX, 0), Vec2(rightX, 0)], color: pencil, width: w, kind: .pencil, pressure: 0.7))
        var maxX = -Double.infinity
        for k in ScanJoint.allCases { maxX = max(maxX, p(k).x) }
        let rulerX = maxX + 0.12 * px
        let topY = -rig[.headTop].y * px
        let step = rig.headH * px
        over.append(ScanLine(points: [Vec2(rulerX, topY), Vec2(rulerX, 0)], color: pal.accent, width: w * 0.8, kind: .pencil, pressure: 0.6))
        var y = topY
        var count = 0
        while y <= 0.5 && count < 30 {
            let tick = count % 2 == 0 ? 0.03 * px : 0.018 * px
            over.append(ScanLine(points: [Vec2(rulerX - tick, y), Vec2(rulerX + tick, y)], color: pal.accent, width: w * 0.8, kind: .pencil, pressure: 0.6))
            y += step
            count += 1
        }
    }
}

// MARK: - Making concepts

enum ScanConceptMaker {
    /// Figures are drawn this many pixels tall.
    static let pixelHeight = 1000.0

    /// Rolls the dice for one concept's look.
    static func look(style: ScanStyle, seed: UInt64) -> ScanLook {
        var r = ScanRandom(seed: ScanRandom.mix(seed, UInt64(ScanStyle.allCases.firstIndex(of: style) ?? 0) + 17))
        let skins: [RGBA] = [
            ScanColor.rgb(0.99, 0.86, 0.75), ScanColor.rgb(0.95, 0.78, 0.64), ScanColor.rgb(0.87, 0.66, 0.5),
            ScanColor.rgb(0.75, 0.54, 0.39), ScanColor.rgb(0.58, 0.4, 0.28), ScanColor.rgb(0.42, 0.28, 0.2),
            ScanColor.rgb(1.0, 0.9, 0.82), ScanColor.rgb(0.9, 0.72, 0.58)
        ]
        let naturalHair: [RGBA] = [
            ScanColor.rgb(0.12, 0.09, 0.08), ScanColor.rgb(0.3, 0.19, 0.12), ScanColor.rgb(0.52, 0.33, 0.18),
            ScanColor.rgb(0.88, 0.72, 0.42), ScanColor.rgb(0.74, 0.32, 0.15), ScanColor.rgb(0.9, 0.88, 0.84)
        ]
        let hue = r.unit()
        let main = ScanColor.hsv(hue, r.range(0.5, 0.8), r.range(0.65, 0.92))
        let second = ScanColor.hsv(hue + r.pick([0.5, 0.33, -0.33, 0.08, 0.58]), r.range(0.45, 0.8), r.range(0.45, 0.85))
        let accent = ScanColor.hsv(hue + r.pick([0.15, -0.15, 0.45]), r.range(0.7, 0.95), r.range(0.85, 1))
        let ink = ScanColor.hsv(hue, 0.35, 0.16)
        var pal = ScanPalette(skin: r.pick(skins), hair: r.pick(naturalHair), main: main, second: second, accent: accent,
                              shoes: r.chance(0.5) ? ScanColor.hsv(hue + 0.5, 0.3, 0.25) : ScanColor.shade(second, -0.35),
                              ink: ink, eye: ScanColor.hsv(r.range(0, 1), r.range(0.3, 0.7), r.range(0.25, 0.5)),
                              light: ScanColor.rgb(0.98, 0.96, 0.92))
        if r.chance(style == .chibi || style == .noodle ? 0.35 : 0.12) {
            pal.hair = ScanColor.hsv(r.unit(), r.range(0.45, 0.7), r.range(0.7, 0.95))
        }
        var hair: ScanHair = .short
        var outfit: ScanOutfit = .tee
        var accessories: [ScanAccessory] = []
        var creature: ScanCreature = .cat
        var longSleeves = r.chance(0.5)
        var longPants = r.chance(0.6)
        let variant = r.int(6)
        let bulk = r.range(0.88, 1.15)
        var view = r.pick([0.0, 0.0, 0.3, -0.3, 0.55, -0.55])
        var name = ""

        func addSome(_ options: [ScanAccessory], upTo n: Int, chance p: Double) {
            for _ in 0..<n where r.chance(p) {
                let a = r.pick(options)
                if accessories.contains(a) { continue }
                if a.isHat && accessories.contains(where: { $0.isHat }) { continue }
                if a == .headphones && accessories.contains(where: { $0 == .wizardHat || $0 == .crown }) { continue }
                if a.isHat && (a == .wizardHat || a == .crown) && accessories.contains(.headphones) { continue }
                accessories.append(a)
            }
        }

        switch style {
        case .chibi:
            hair = r.pick([.short, .spiky, .bob, .long, .ponytail, .curly, .buzz])
            outfit = r.pick([.tee, .hoodie, .dress, .overalls, .jacket])
            addSome([.cap, .beanie, .wizardHat, .crown, .glasses, .headphones, .backpack, .scarf], upTo: 2, chance: 0.6)
            name = r.pick(["Mochi", "Pip", "Bean", "Sprout", "Dumpling", "Button", "Taffy", "Pebble", "Sunny", "Biscuit"])
                + r.pick(["", "", " Jr.", " the Brave", " Star"])
        case .hero:
            hair = r.pick([.short, .spiky, .mohawk, .long, .buzz, .ponytail, .bald])
            outfit = r.pick([.suit, .suit, .trunks])
            longSleeves = true
            longPants = true
            if r.chance(0.7) { accessories.append(.cape) }
            if r.chance(0.45) { accessories.append(.mask) }
            if r.chance(0.2) { accessories.append(.shoulderPads) }
            view = r.pick([0.0, 0.35, -0.35, 0.6])
            name = r.pick(["Captain", "Doctor", "Agent", "Major", "Super", "Ultra", "Night", "Iron"]) + " "
                + r.pick(["Comet", "Volt", "Nova", "Thunder", "Flash", "Granite", "Arrow", "Blaze", "Cyclone", "Spark"])
        case .noodle:
            hair = r.pick([.buzz, .short, .spiky, .bald, .bob, .curly])
            outfit = r.pick([.tee, .overalls, .dress])
            longSleeves = false
            longPants = false
            let toon: [RGBA] = [ScanColor.rgb(1, 0.95, 0.86), ScanColor.rgb(0.96, 0.9, 0.8), ScanColor.rgb(0.85, 0.85, 0.88),
                                ScanColor.hsv(r.unit(), 0.35, 0.95), ScanColor.hsv(r.unit(), 0.45, 0.9)]
            pal.skin = r.chance(0.5) ? r.pick(toon) : r.pick(skins)
            pal.eye = RGBA(0.08, 0.06, 0.08, 1)
            pal.shoes = r.chance(0.5) ? RGBA(0.12, 0.1, 0.12, 1) : ScanColor.shade(main, -0.3)
            addSome([.cap, .bowtie, .scarf, .glasses], upTo: 1, chance: 0.6)
            name = r.pick(["Wiggly", "Bendy", "Squiggle", "Rubber", "Boing", "Slinky"]) + " "
                + r.pick(["Sam", "Kit", "Jo", "Pip", "Ace", "Lou"])
        case .robot:
            hair = .bald
            outfit = .plating
            let metalHue = r.unit()
            pal.main = ScanColor.hsv(metalHue, r.range(0.12, 0.5), r.range(0.72, 0.92))
            pal.second = ScanColor.hsv(metalHue, 0.25, r.range(0.22, 0.35))
            pal.accent = ScanColor.hsv(metalHue + r.pick([0.5, 0.33, 0.0]), 0.75, 1)
            pal.ink = ScanColor.hsv(metalHue, 0.3, 0.12)
            if r.chance(0.6) { accessories.append(.antenna) }
            if r.chance(0.45) { accessories.append(.shoulderPads) }
            if r.chance(0.35) { accessories.append(.jetpack) }
            view = r.pick([0.0, 0.35, -0.35, 0.6])
            name = r.pick(["RX", "Bolt", "Unit", "MK", "Gear", "Zap", "Servo"]) + "-" + String(2 + r.int(98))
        case .creature:
            creature = r.pick(ScanCreature.allCases)
            hair = .bald
            outfit = r.pick([.fur, .fur, .tee, .overalls, .hoodie])
            let furs: [RGBA]
            switch creature {
            case .cat: furs = [ScanColor.rgb(0.95, 0.6, 0.25), ScanColor.rgb(0.6, 0.6, 0.64), ScanColor.rgb(0.28, 0.26, 0.3), ScanColor.rgb(0.96, 0.94, 0.9)]
            case .fox: furs = [ScanColor.rgb(0.93, 0.5, 0.2), ScanColor.rgb(0.85, 0.42, 0.18), ScanColor.rgb(0.7, 0.7, 0.75)]
            case .bunny: furs = [ScanColor.rgb(0.97, 0.96, 0.94), ScanColor.rgb(0.7, 0.66, 0.64), ScanColor.rgb(0.6, 0.45, 0.32)]
            case .bear: furs = [ScanColor.rgb(0.55, 0.36, 0.22), ScanColor.rgb(0.35, 0.24, 0.16), ScanColor.rgb(0.95, 0.93, 0.9)]
            case .dragon: furs = [ScanColor.rgb(0.35, 0.7, 0.4), ScanColor.rgb(0.8, 0.28, 0.25), ScanColor.rgb(0.5, 0.35, 0.75), ScanColor.rgb(0.25, 0.55, 0.85)]
            }
            pal.skin = r.pick(furs)
            pal.light = ScanColor.shade(pal.skin, 0.65)
            pal.eye = r.pick([ScanColor.rgb(0.95, 0.8, 0.2), ScanColor.rgb(0.4, 0.8, 0.35), ScanColor.rgb(0.35, 0.65, 0.95), ScanColor.rgb(0.55, 0.35, 0.2)])
            longPants = false
            addSome([.scarf, .backpack, .glasses, .cape, .crown], upTo: 1, chance: 0.6)
            name = r.pick(["Captain", "Little", "Sir", "Ranger", "Professor", "Mega"]) + " "
                + ["cat": "Whiskers", "fox": "Fox", "bunny": "Bun", "bear": "Bear", "dragon": "Dragon"][creature.rawValue, default: "Pal"]
        case .mannequin:
            hair = .bald
            outfit = .none
            let pencils: [RGBA] = [ScanColor.rgb(0.22, 0.22, 0.26), ScanColor.rgb(0.25, 0.42, 0.8), ScanColor.rgb(0.62, 0.24, 0.18), ScanColor.rgb(0.4, 0.29, 0.2)]
            pal.ink = r.pick(pencils)
            pal.accent = r.pick([ScanColor.rgb(0.3, 0.55, 0.95), ScanColor.rgb(0.9, 0.35, 0.3), ScanColor.rgb(0.95, 0.6, 0.2)])
            pal.light = r.pick([ScanColor.rgb(0.94, 0.94, 0.95), ScanColor.rgb(0.96, 0.93, 0.88), ScanColor.rgb(0.92, 0.95, 0.98)])
            view = r.pick([0.0, 0.4, -0.4, 0.8])
            name = "Pose study #" + String(1 + r.int(99))
        }
        return ScanLook(style: style, seed: seed, name: name, palette: pal, hair: hair, outfit: outfit, accessories: accessories,
                        creature: creature, longSleeves: longSleeves, longPants: longPants, variant: variant, view: view, bulk: bulk)
    }

    static func rig(for body: ScanBody, style: ScanStyle) -> ScanRig {
        ScanRig.make(body, ScanKit.of(style).build)
    }

    /// Draws the character from any angle (0 = facing you, pi/2 = side, pi = back).
    static func draw(body: ScanBody, look: ScanLook, angle: Double) -> ScanDrawing {
        let rig = rig(for: body, style: look.style)
        return ScanFigure.draw(rig: rig, look: look, angle: angle, scale: pixelHeight)
    }

    static func concept(body: ScanBody, style: ScanStyle, seed: UInt64) -> ScanConcept {
        let l = look(style: style, seed: seed)
        return ScanConcept(look: l, drawing: draw(body: body, look: l, angle: l.view))
    }

    /// Several concepts per style. A new `seed` gives a new batch (that's Shuffle).
    static func concepts(body: ScanBody, styles: [ScanStyle] = ScanStyle.allCases, perStyle: Int = 2, seed: UInt64) -> [ScanConcept] {
        var out: [ScanConcept] = []
        for i in 0..<max(1, perStyle) {
            for style in styles {
                let s = ScanRandom.mix(seed, UInt64(i) &* 7919 &+ UInt64(ScanStyle.allCases.firstIndex(of: style) ?? 0))
                out.append(concept(body: body, style: style, seed: s))
            }
        }
        return out
    }

    /// Front, 3/4, side and back of the same character, built by turning the 3D figure.
    static func turnaround(body: ScanBody, look: ScanLook) -> ScanTurnaround {
        let rig = rig(for: body, style: look.style)
        let views = ScanTurnaround.angles.map { ScanFigure.draw(rig: rig, look: look, angle: $0, scale: pixelHeight) }
        let px = pixelHeight
        // Guide line heights (the same from every side).
        let chin = rig[.head].y - rig.headH / 2
        let levels = [rig[.headTop].y, chin, (rig[.leftShoulder].y + rig[.rightShoulder].y) / 2,
                      rig[.hips].y, (rig[.leftKnee].y + rig[.rightKnee].y) / 2, 0]
        var widest = 0.0
        for v in views {
            let b = v.bounds
            if !b.isEmpty { widest = max(widest, max(abs(b.minX), abs(b.maxX))) }
        }
        let half = max(0.2 * px, widest)
        let gap = half * 2 + 0.12 * px
        let guideColor = RGBA(0.45, 0.65, 0.95, 0.55)
        func guideFills(from x0: Double, to x1: Double) -> [Fill] {
            levels.map { y in
                let yy = -y * px
                let path = [x0, yy - 1.5, x1, yy - 1.5, x1, yy + 1.5, x0, yy + 1.5]
                return Fill(color: guideColor, path: path.map { ($0 * 100).rounded() / 100 })
            }
        }
        var guideCel = Cel()
        for f in guideFills(from: -half - 0.05 * px, to: half + 0.05 * px) { guideCel.append(f) }
        var sheet = Cel()
        for f in guideFills(from: -half - 0.08 * px, to: gap * 3 + half + 0.08 * px) { sheet.append(f) }
        var placed: [ScanDrawing] = []
        for (i, v) in views.enumerated() {
            placed.append(v.transformed(scale: 1, dx: gap * Double(i), dy: 0).withFreshIDs)
        }
        for v in placed { for f in v.fills { sheet.append(f) } }
        for v in placed { for s in v.strokes { sheet.append(s) } }
        return ScanTurnaround(views: views, guides: ScanDrawing(strokes: [], fills: guideCel.fills),
                              sheet: ScanDrawing(strokes: sheet.strokes, fills: sheet.fills))
    }

    // MARK: Saving

    /// A stash item: points are relative to the top-left of `bounds`.
    static func stashItem(name: String, drawing: ScanDrawing) -> StashItem? {
        let b = drawing.bounds
        guard !b.isEmpty, !drawing.isEmpty else { return nil }
        let moved = drawing.transformed(scale: 1, dx: -b.minX, dy: -b.minY).withFreshIDs
        return StashItem(name: name, auto: false, bounds: [b.minX, b.minY, b.width, b.height],
                         strokes: moved.strokes, fills: moved.fills)
    }

    static let poseCanvas = GaleCanvas(width: 1080, height: 1920, background: .white)
    static let turnaroundCanvas = GaleCanvas(width: 1920, height: 1080, background: .white)

    /// Puts a concept into a fresh project: a "Concept" layer with the character on frame 0, or,
    /// for a turnaround, four frames (front, 3/4, side, back) plus a "Guides" layer.
    /// A "Draw here" layer goes on top for the user's own lines.
    static func fill(_ project: inout GaleProject, concept: ScanConcept, body: ScanBody, turnaround: Bool) {
        project.normalize()
        let canvas = project.canvas
        let margin = min(canvas.width, canvas.height) * 0.08
        let box = Box(minX: margin, minY: margin, maxX: canvas.width - margin, maxY: canvas.height - margin)
        project.layers[0].name = "Concept"
        let conceptID = project.layers[0].id
        if turnaround {
            let t = ScanConceptMaker.turnaround(body: body, look: concept.look)
            var all = t.guides.bounds
            for v in t.views { all = all.union(v.bounds) }
            let (k, dx, dy) = ScanDrawing.fitTransform(all, into: box)
            let guides = Layer(key: OrderKey.between(nil, project.layers[0].key) ?? "Zz", name: "Guides", opacity: 0.7)
            project.layers.insert(guides, at: 0)
            let hold = max(1, project.fps / 2)
            project.frames[0].hold = hold
            while project.frames.count < t.views.count {
                project.insertFrame(Frame(hold: hold), after: nil)
            }
            let guideDrawing = t.guides.transformed(scale: k, dx: dx, dy: dy)
            for (i, v) in t.views.enumerated() {
                let placed = v.transformed(scale: k, dx: dx, dy: dy).withFreshIDs
                project.frames[i].cels[conceptID] = placed.cel
                project.frames[i].cels[guides.id] = guideDrawing.withFreshIDs.cel
            }
        } else {
            let placed = concept.drawing.fitted(into: box).withFreshIDs
            project.frames[0].cels[conceptID] = placed.cel
        }
        project.addLayer(name: "Draw here")
        project.modified = Date()
    }
}
