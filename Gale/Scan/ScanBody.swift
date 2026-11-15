import Foundation

// Body scan → body proportions. Pure Swift (Foundation only), so it is tested on Linux.
//
// Every capture path (ARKit body tracking, Vision 3D, Vision 2D) turns what it saw into a
// `ScanSkeleton` in one shared space:
//   x = to the camera's right, y = up, z = toward the camera. Any unit (meters for 3D scans).
// `ScanBody(scan:)` then fills small gaps, turns the body to face +z, puts the feet on the
// floor, scales it so the standing height is 1, and measures proportions and pose.
// Nothing here is saved anywhere: the scan lives in memory only.

// MARK: - 3D vector

struct ScanVec3: Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = ScanVec3(0, 0, 0)
    static let up = ScanVec3(0, 1, 0)

    static func + (a: ScanVec3, b: ScanVec3) -> ScanVec3 { ScanVec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: ScanVec3, b: ScanVec3) -> ScanVec3 { ScanVec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: ScanVec3, s: Double) -> ScanVec3 { ScanVec3(a.x * s, a.y * s, a.z * s) }
    static func / (a: ScanVec3, s: Double) -> ScanVec3 { ScanVec3(a.x / s, a.y / s, a.z / s) }
    static prefix func - (a: ScanVec3) -> ScanVec3 { ScanVec3(-a.x, -a.y, -a.z) }

    var length: Double { (x * x + y * y + z * z).squareRoot() }
    func dot(_ o: ScanVec3) -> Double { x * o.x + y * o.y + z * o.z }
    func cross(_ o: ScanVec3) -> ScanVec3 {
        ScanVec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    var normalized: ScanVec3 {
        let l = length
        return l > 1e-12 ? self / l : .zero
    }
    func distance(to o: ScanVec3) -> Double { (self - o).length }
    var horizontal: ScanVec3 { ScanVec3(x, 0, z) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    static func lerp(_ a: ScanVec3, _ b: ScanVec3, _ t: Double) -> ScanVec3 { a + (b - a) * t }
    static func mid(_ a: ScanVec3, _ b: ScanVec3) -> ScanVec3 { (a + b) * 0.5 }

    /// Turns around the up (y) axis. A positive angle turns +z toward +x.
    func rotatedY(_ a: Double) -> ScanVec3 {
        let c = cos(a), s = sin(a)
        return ScanVec3(x * c + z * s, y, -x * s + z * c)
    }
}

/// A 2D point with y going up (used for flat photo poses).
struct ScanPoint2: Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to o: ScanPoint2) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
    static func mid(_ a: ScanPoint2, _ b: ScanPoint2) -> ScanPoint2 { ScanPoint2((a.x + b.x) / 2, (a.y + b.y) / 2) }
}

// MARK: - Joints

/// The body points Gale cares about. Left and right are the person's own left and right.
enum ScanJoint: String, CaseIterable, Hashable, Sendable {
    case headTop, head, neck, chest, hips
    case leftShoulder, leftElbow, leftWrist, leftHand
    case rightShoulder, rightElbow, rightWrist, rightHand
    case leftHip, leftKnee, leftAnkle, leftToe
    case rightHip, rightKnee, rightAnkle, rightToe

    /// The same joint on the other side (center joints stay the same).
    var mirrored: ScanJoint {
        switch self {
        case .leftShoulder: return .rightShoulder
        case .leftElbow: return .rightElbow
        case .leftWrist: return .rightWrist
        case .leftHand: return .rightHand
        case .rightShoulder: return .leftShoulder
        case .rightElbow: return .leftElbow
        case .rightWrist: return .leftWrist
        case .rightHand: return .leftHand
        case .leftHip: return .rightHip
        case .leftKnee: return .rightKnee
        case .leftAnkle: return .rightAnkle
        case .leftToe: return .rightToe
        case .rightHip: return .leftHip
        case .rightKnee: return .leftKnee
        case .rightAnkle: return .leftAnkle
        case .rightToe: return .leftToe
        default: return self
        }
    }

    /// Lines of the skeleton, for drawing a stick figure.
    static let bones: [(ScanJoint, ScanJoint)] = [
        (.hips, .chest), (.chest, .neck), (.neck, .head), (.head, .headTop),
        (.neck, .leftShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist), (.leftWrist, .leftHand),
        (.neck, .rightShoulder), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.rightWrist, .rightHand),
        (.hips, .leftHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle), (.leftAnkle, .leftToe),
        (.hips, .rightHip), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle), (.rightAnkle, .rightToe)
    ]
}

enum ScanSource: String, Hashable, Sendable {
    /// ARKit body tracking with the back camera (real 3D, real size).
    case arkit
    /// Vision 3D body pose from a photo (3D, size is a guess unless the camera measured depth).
    case vision3D
    /// Vision 2D body pose from a photo, with depth estimated from bone lengths.
    case vision2D

    var title: String {
        switch self {
        case .arkit: return "3D body scan"
        case .vision3D: return "3D photo scan"
        case .vision2D: return "Photo scan"
        }
    }
}

// MARK: - Skeleton

struct ScanSkeleton: Hashable, Sendable {
    /// Joint positions (see the top of this file for the axes).
    var joints: [ScanJoint: ScanVec3]
    var source: ScanSource
    /// Real standing height in meters, when the scan knows it.
    var measuredHeight: Double?
    /// Joints that were not seen and had to be guessed.
    var guessed: [ScanJoint]

    init(joints: [ScanJoint: ScanVec3], source: ScanSource, measuredHeight: Double? = nil, guessed: [ScanJoint] = []) {
        var clean: [ScanJoint: ScanVec3] = [:]
        for (k, v) in joints where v.isFinite { clean[k] = v }
        self.joints = clean
        self.source = source
        if let h = measuredHeight, h.isFinite, h > 0.4, h < 2.6 {
            self.measuredHeight = h
        } else {
            self.measuredHeight = nil
        }
        self.guessed = guessed
    }

    subscript(_ j: ScanJoint) -> ScanVec3? { joints[j] }

    /// Position of a joint, or zero (only use on a completed skeleton).
    func at(_ j: ScanJoint) -> ScanVec3 { joints[j] ?? .zero }

    /// Big things that stop the scan from working, in simple words. Empty means it can be used.
    var problems: [String] {
        var out: [String] = []
        if joints[.leftShoulder] == nil || joints[.rightShoulder] == nil {
            out.append("I couldn't see both of your shoulders. Face the camera.")
        }
        if joints[.hips] == nil && joints[.leftHip] == nil && joints[.rightHip] == nil {
            out.append("I couldn't see your hips. Step back so your whole body fits.")
        }
        if joints[.head] == nil && joints[.headTop] == nil {
            out.append("I couldn't see your head. Make sure your head is in the picture.")
        }
        let leftArm = joints[.leftElbow] != nil || joints[.leftWrist] != nil
        let rightArm = joints[.rightElbow] != nil || joints[.rightWrist] != nil
        if !leftArm && !rightArm {
            out.append("I couldn't see your arms. Keep them away from your body a little.")
        }
        let leftLeg = joints[.leftKnee] != nil
        let rightLeg = joints[.rightKnee] != nil
        if !leftLeg && !rightLeg {
            out.append("I couldn't see your legs. Step back so I can see you from head to toe.")
        }
        return out
    }

    var isUsable: Bool { problems.isEmpty }

    // MARK: Filling gaps

    /// Turns the skeleton so the spine points along +y (fixes scans that came in sideways).
    private static func uprighted(_ joints: [ScanJoint: ScanVec3]) -> [ScanJoint: ScanVec3] {
        guard let hips = joints[.hips], let neck = joints[.neck] else { return joints }
        let v = neck - hips
        let l = v.length
        guard l > 1e-9 else { return joints }
        let ax = abs(v.x), ay = abs(v.y), az = abs(v.z)
        let m = max(ax, ay, az)
        guard m > 0.5 * l else { return joints }
        let map: (ScanVec3) -> ScanVec3
        if m == ay {
            if v.y >= 0 { return joints }
            map = { p in ScanVec3(p.x, -p.y, -p.z) }
        } else if m == ax {
            if v.x > 0 {
                map = { p in ScanVec3(-p.y, p.x, p.z) }
            } else {
                map = { p in ScanVec3(p.y, -p.x, p.z) }
            }
        } else {
            if v.z > 0 {
                map = { p in ScanVec3(p.x, p.z, -p.y) }
            } else {
                map = { p in ScanVec3(p.x, -p.z, p.y) }
            }
        }
        var out: [ScanJoint: ScanVec3] = [:]
        for (k, p) in joints { out[k] = map(p) }
        return out
    }

    /// The person's right side, flat on the floor. Falls back to -x (a person facing the camera).
    static func rightDirection(_ j: [ScanJoint: ScanVec3]) -> ScanVec3 {
        var r = ScanVec3.zero
        if let l = j[.leftShoulder], let rr = j[.rightShoulder] { r = r + (rr - l) }
        if let l = j[.leftHip], let rr = j[.rightHip] { r = r + (rr - l) }
        let h = r.horizontal.normalized
        return h == .zero ? ScanVec3(-1, 0, 0) : h
    }

    /// Which way the chest faces, flat on the floor.
    static func forwardDirection(_ j: [ScanJoint: ScanVec3]) -> ScanVec3 {
        let r = rightDirection(j)
        return ScanVec3(r.z, 0, -r.x)
    }

    /// Reflects a point across the body's middle plane (through `center`, facing `right`).
    private static func mirror(_ p: ScanVec3, center: ScanVec3, right: ScanVec3) -> ScanVec3 {
        p - right * (2 * (p - center).dot(right))
    }

    /// Fills in joints that weren't seen (copying the other side, or guessing from bone lengths).
    /// Returns nil when too much is missing (see `problems`).
    func completed() -> ScanSkeleton? {
        guard isUsable else { return nil }
        var j = joints
        var guessed = Set(self.guessed)
        func guess(_ k: ScanJoint, _ p: ScanVec3) {
            j[k] = p
            guessed.insert(k)
        }
        guard let lS = j[.leftShoulder], let rS = j[.rightShoulder] else { return nil }
        if j[.neck] == nil { guess(.neck, ScanVec3.mid(lS, rS)) }
        if j[.hips] == nil, let lH = j[.leftHip], let rH = j[.rightHip] {
            guess(.hips, ScanVec3.mid(lH, rH))
        }
        if j[.hips] == nil, let one = j[.leftHip] ?? j[.rightHip] {
            // One hip: the middle is a little toward the body's center line under the neck.
            let neck = j[.neck] ?? ScanVec3.mid(lS, rS)
            guess(.hips, ScanVec3(neck.x, one.y, neck.z) * 0.5 + one * 0.5)
        }
        j = ScanSkeleton.uprighted(j)
        guard let hips = j[.hips], let neck = j[.neck],
              let shL = j[.leftShoulder], let shR = j[.rightShoulder] else { return nil }
        let right = ScanSkeleton.rightDirection(j)
        let shoulderWidth = max(1e-6, shL.distance(to: shR))
        let torso = max(1e-6, neck.distance(to: hips))
        let spineUp = (neck - hips).normalized

        // Hips
        switch (j[.leftHip], j[.rightHip]) {
        case (nil, nil):
            guess(.leftHip, hips - right * (shoulderWidth * 0.26))
            guess(.rightHip, hips + right * (shoulderWidth * 0.26))
        case (let l?, nil):
            guess(.rightHip, ScanSkeleton.mirror(l, center: hips, right: right))
        case (nil, let r?):
            guess(.leftHip, ScanSkeleton.mirror(r, center: hips, right: right))
        default:
            break
        }

        // Arms
        let shoulderMid = ScanVec3.mid(shL, shR)
        for (s, e, w) in [(ScanJoint.leftShoulder, ScanJoint.leftElbow, ScanJoint.leftWrist),
                          (ScanJoint.rightShoulder, ScanJoint.rightElbow, ScanJoint.rightWrist)] {
            guard let sp = j[s] else { continue }
            let other = (j[e.mirrored], j[w.mirrored])
            switch (j[e], j[w]) {
            case (nil, nil):
                if let oe = other.0, let ow = other.1 {
                    guess(e, ScanSkeleton.mirror(oe, center: shoulderMid, right: right))
                    guess(w, ScanSkeleton.mirror(ow, center: shoulderMid, right: right))
                } else if let oe = other.0 {
                    guess(e, ScanSkeleton.mirror(oe, center: shoulderMid, right: right))
                } else if let ow = other.1 {
                    guess(w, ScanSkeleton.mirror(ow, center: shoulderMid, right: right))
                } else {
                    return nil
                }
            default:
                break
            }
            switch (j[e], j[w]) {
            case (let ep?, nil):
                let d = (ep - sp)
                guess(w, ep + d.normalized * (d.length * 0.8))
            case (nil, let wp?):
                guess(e, ScanVec3.lerp(sp, wp, 0.55))
            default:
                break
            }
        }

        // Legs
        guard let hipL = j[.leftHip], let hipR = j[.rightHip] else { return nil }
        let hipMid = ScanVec3.mid(hipL, hipR)
        for (h, k, a) in [(ScanJoint.leftHip, ScanJoint.leftKnee, ScanJoint.leftAnkle),
                          (ScanJoint.rightHip, ScanJoint.rightKnee, ScanJoint.rightAnkle)] {
            guard let hp = j[h] else { continue }
            if j[k] == nil {
                if let ok = j[k.mirrored] {
                    guess(k, ScanSkeleton.mirror(ok, center: hipMid, right: right))
                    if j[a] == nil, let oa = j[a.mirrored] {
                        guess(a, ScanSkeleton.mirror(oa, center: hipMid, right: right))
                    }
                } else {
                    return nil
                }
            }
            if j[a] == nil, let kp = j[k] {
                // Feet out of view: the shin is about as long as the thigh, pointing down.
                let thigh = kp.distance(to: hp)
                let down = ((kp - hp).normalized + ScanVec3(0, -1, 0)).normalized
                guess(a, kp + (down == .zero ? ScanVec3(0, -1, 0) : down) * thigh)
            }
        }

        // Head
        var headH: Double
        switch (j[.head], j[.headTop]) {
        case (let c?, let t?):
            headH = 2 * c.distance(to: t)
        case (let c?, nil):
            headH = c.distance(to: neck) / 0.87
        case (nil, let t?):
            headH = t.distance(to: neck) / 1.37
        case (nil, nil):
            return nil
        }
        headH = min(max(headH, torso * 0.33), torso * 0.8)
        if let c = j[.head] {
            let toward = j[.headTop].map { ($0 - c).normalized } ?? .zero
            var dir = toward
            if dir == .zero {
                dir = ((c - neck).normalized + spineUp).normalized
            }
            if dir == .zero { dir = .up }
            if j[.headTop] == nil { guessed.insert(.headTop) }
            j[.headTop] = c + dir * (headH / 2)
        } else if let t = j[.headTop] {
            var dir = (t - neck).normalized
            if dir == .zero { dir = .up }
            guess(.head, t - dir * (headH / 2))
        }

        if j[.chest] == nil { j[.chest] = ScanVec3.lerp(hips, neck, 0.62) }

        // Hands and toes need the body height.
        let h = ScanSkeleton.standingHeight(j)
        guard h > 1e-9 else { return nil }
        for (e, w, hand) in [(ScanJoint.leftElbow, ScanJoint.leftWrist, ScanJoint.leftHand),
                             (ScanJoint.rightElbow, ScanJoint.rightWrist, ScanJoint.rightHand)] where j[hand] == nil {
            guard let ep = j[e], let wp = j[w] else { return nil }
            var d = (wp - ep).normalized
            if d == .zero { d = ScanVec3(0, -1, 0) }
            j[hand] = wp + d * (0.055 * h)
        }
        let forward = ScanSkeleton.forwardDirection(j)
        for (a, t) in [(ScanJoint.leftAnkle, ScanJoint.leftToe), (ScanJoint.rightAnkle, ScanJoint.rightToe)] where j[t] == nil {
            guard let ap = j[a] else { return nil }
            j[t] = ap + forward * (0.1 * h) + ScanVec3(0, -0.035 * h, 0)
        }
        for k in ScanJoint.allCases where j[k] == nil { return nil }
        return ScanSkeleton(joints: j, source: source, measuredHeight: measuredHeight,
                            guessed: ScanJoint.allCases.filter { guessed.contains($0) })
    }

    /// How tall the person would be standing straight, from bone lengths (so it doesn't change with the pose).
    static func standingHeight(_ j: [ScanJoint: ScanVec3]) -> Double {
        guard let top = j[.headTop], let neck = j[.neck], let chest = j[.chest], let hips = j[.hips],
              let lH = j[.leftHip], let rH = j[.rightHip], let lK = j[.leftKnee], let rK = j[.rightKnee],
              let lA = j[.leftAnkle], let rA = j[.rightAnkle] else { return 0 }
        let spineUp = (neck - hips).normalized
        let head = top.distance(to: neck)
        let spine = neck.distance(to: chest) + chest.distance(to: hips)
        let drop = (max(0, (hips - lH).dot(spineUp)) + max(0, (hips - rH).dot(spineUp))) / 2
        let thigh = (lH.distance(to: lK) + rH.distance(to: rK)) / 2
        let shin = (lK.distance(to: lA) + rK.distance(to: rA)) / 2
        return (head + spine + drop + thigh + shin) / (1 - 0.045)
    }

    /// Completed, turned to face +z, hips over the middle, feet on the floor (y = 0), standing height 1.
    func normalized() -> ScanSkeleton? {
        guard let done = completed() else { return nil }
        var j = done.joints
        let h = ScanSkeleton.standingHeight(j)
        guard h > 1e-9 else { return nil }
        let f = ScanSkeleton.forwardDirection(j)
        let angle = -atan2(f.x, f.z)
        for (k, p) in j { j[k] = p.rotatedY(angle) }
        let hips = j[.hips] ?? .zero
        let ankleY = min(j[.leftAnkle]?.y ?? 0, j[.rightAnkle]?.y ?? 0)
        let offset = ScanVec3(hips.x, ankleY - 0.045 * h, hips.z)
        for (k, p) in j { j[k] = (p - offset) / h }
        return ScanSkeleton(joints: j, source: source, measuredHeight: done.measuredHeight, guessed: done.guessed)
    }

    // MARK: Making skeletons

    /// From points in any y-up space plus where the camera was. Turns things so the camera looks along -z.
    static func fromWorld(_ joints: [ScanJoint: ScanVec3], camera: ScanVec3?, source: ScanSource,
                          measuredHeight: Double? = nil) -> ScanSkeleton {
        var j = joints
        if let cam = camera, let center = joints[.hips] ?? joints[.neck] {
            let v = (cam - center).horizontal
            if v.length > 1e-9 {
                let angle = -atan2(v.x, v.z)
                for (k, p) in j { j[k] = (p - center).rotatedY(angle) }
            }
        }
        return ScanSkeleton(joints: j, source: source, measuredHeight: measuredHeight)
    }
}

// MARK: - Flat (2D) photo pose → 3D

/// Body points found in a flat photo (y goes up, any unit like pixels), plus face points for the head.
struct ScanFlatPose: Hashable, Sendable {
    var points: [ScanJoint: ScanPoint2]
    var leftEye: ScanPoint2?
    var rightEye: ScanPoint2?
    var leftEar: ScanPoint2?
    var rightEar: ScanPoint2?
    var nose: ScanPoint2?

    init(points: [ScanJoint: ScanPoint2], leftEye: ScanPoint2? = nil, rightEye: ScanPoint2? = nil,
         leftEar: ScanPoint2? = nil, rightEar: ScanPoint2? = nil, nose: ScanPoint2? = nil) {
        self.points = points
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftEar = leftEar
        self.rightEar = rightEar
        self.nose = nose
    }

    /// Typical bone lengths as a part of standing height (adult averages).
    static let ratios: [(ScanJoint, ScanJoint, Double)] = [
        (.neck, .hips, 0.28),
        (.leftShoulder, .leftElbow, 0.186), (.rightShoulder, .rightElbow, 0.186),
        (.leftElbow, .leftWrist, 0.146), (.rightElbow, .rightWrist, 0.146),
        (.leftHip, .leftKnee, 0.245), (.rightHip, .rightKnee, 0.245),
        (.leftKnee, .leftAnkle, 0.246), (.rightKnee, .rightAnkle, 0.246)
    ]

    /// Guesses depth from how short each bone looks (a bone pointing at the camera looks short).
    func lifted() -> ScanSkeleton {
        var pts = points
        var lEye = leftEye, rEye = rightEye, lEar = leftEar, rEar = rightEar
        // The person faces the camera, so their left side is on the camera's right (+x).
        if let ls = pts[.leftShoulder], let rs = pts[.rightShoulder], ls.x < rs.x {
            let hipsAgree: Bool
            if let lh = pts[.leftHip], let rh = pts[.rightHip] { hipsAgree = lh.x <= rh.x } else { hipsAgree = true }
            if hipsAgree {
                var swapped: [ScanJoint: ScanPoint2] = [:]
                for (k, v) in pts { swapped[k.mirrored] = v }
                pts = swapped
                swap(&lEye, &rEye)
                swap(&lEar, &rEar)
            }
        }
        if pts[.neck] == nil, let a = pts[.leftShoulder], let b = pts[.rightShoulder] { pts[.neck] = ScanPoint2.mid(a, b) }
        if pts[.hips] == nil, let a = pts[.leftHip], let b = pts[.rightHip] { pts[.hips] = ScanPoint2.mid(a, b) }

        // Head: eye level is the middle of the head.
        var headCenter: ScanPoint2?
        if let a = lEye, let b = rEye { headCenter = ScanPoint2.mid(a, b) }
        else if let n = nose { headCenter = n }
        else if let a = lEar, let b = rEar { headCenter = ScanPoint2.mid(a, b) }
        else if let one = lEye ?? rEye ?? lEar ?? rEar { headCenter = one }
        if pts[.head] == nil, let c = headCenter { pts[.head] = c }
        if pts[.headTop] == nil, let c = pts[.head] {
            var sizes: [Double] = []
            if let a = lEar, let b = rEar { sizes.append(a.distance(to: b) * 1.45) }
            if let a = lEye, let b = rEye { sizes.append(a.distance(to: b) * 3.6) }
            if let n = pts[.neck] { sizes.append(c.distance(to: n) / 0.87) }
            sizes.sort()
            if !sizes.isEmpty {
                let headH = sizes[sizes.count / 2]
                var ux = 0.0, uy = 1.0
                if let n = pts[.neck] {
                    let dx = c.x - n.x, dy = c.y - n.y
                    let l = (dx * dx + dy * dy).squareRoot()
                    if l > 1e-9 {
                        ux = dx / l * 0.5
                        uy = dy / l * 0.5 + 0.5
                        let l2 = (ux * ux + uy * uy).squareRoot()
                        if l2 > 1e-9 { ux /= l2; uy /= l2 } else { ux = 0; uy = 1 }
                    }
                }
                pts[.headTop] = ScanPoint2(c.x + ux * headH / 2, c.y + uy * headH / 2)
            }
        }

        // How tall is the person in this picture? Bones only look shorter, never longer,
        // so the bigger guesses are closer to the truth (the second biggest skips one bad point).
        var guesses: [Double] = []
        for (a, b, r) in ScanFlatPose.ratios {
            if let pa = pts[a], let pb = pts[b] { guesses.append(pa.distance(to: pb) / r) }
        }
        guesses.sort(by: >)
        let height = guesses.count >= 3 ? guesses[1] : (guesses.first ?? 0)

        var j: [ScanJoint: ScanVec3] = [:]
        for (k, p) in pts { j[k] = ScanVec3(p.x, p.y, 0) }
        guard height > 1e-9 else { return ScanSkeleton(joints: j, source: .vision2D) }

        func lift(_ parent: ScanJoint, _ child: ScanJoint, ratio: Double, sign: Double) {
            guard let pp = j[parent], let cp = j[child] else { return }
            let l2 = (cp.x - pp.x) * (cp.x - pp.x) + (cp.y - pp.y) * (cp.y - pp.y)
            let full = ratio * height
            let dz = (max(0, full * full - l2)).squareRoot()
            j[child] = ScanVec3(cp.x, cp.y, pp.z + dz * sign)
        }
        // Turned shoulders or hips look narrow: put one side forward.
        func turn(_ l: ScanJoint, _ r: ScanJoint, half: Double) {
            guard let lp = j[l], let rp = j[r] else { return }
            let w = lp.distance(to: rp) / 2
            let expected = half * height
            guard w < expected * 0.6 else { return }
            let dz = (max(0, expected * expected - w * w)).squareRoot()
            j[l] = ScanVec3(lp.x, lp.y, lp.z + dz)
            j[r] = ScanVec3(rp.x, rp.y, rp.z - dz)
        }
        turn(.leftShoulder, .rightShoulder, half: 0.105)
        turn(.leftHip, .rightHip, half: 0.055)
        lift(.leftShoulder, .leftElbow, ratio: 0.186, sign: 1)
        lift(.leftElbow, .leftWrist, ratio: 0.146, sign: 1)
        lift(.rightShoulder, .rightElbow, ratio: 0.186, sign: 1)
        lift(.rightElbow, .rightWrist, ratio: 0.146, sign: 1)
        lift(.leftHip, .leftKnee, ratio: 0.245, sign: 1)
        lift(.leftKnee, .leftAnkle, ratio: 0.246, sign: -1)
        lift(.rightHip, .rightKnee, ratio: 0.245, sign: 1)
        lift(.rightKnee, .rightAnkle, ratio: 0.246, sign: -1)
        return ScanSkeleton(joints: j, source: .vision2D)
    }
}

// MARK: - Proportions and pose

/// Body measurements as parts of standing height (height = 1).
struct ScanProportions: Hashable, Sendable {
    var heightInHeads: Double
    var headHeight: Double
    var shoulderWidth: Double
    var hipWidth: Double
    var upperArm: Double
    var forearm: Double
    var thigh: Double
    var shin: Double
    var torso: Double
    var neck: Double
    var legLength: Double
    var armLength: Double
    /// Real height in meters, when known.
    var meters: Double?

    init(_ s: ScanSkeleton) {
        let p = s.at
        headHeight = max(0.05, 2 * p(.head).distance(to: p(.headTop)))
        heightInHeads = 1 / headHeight
        shoulderWidth = p(.leftShoulder).distance(to: p(.rightShoulder))
        hipWidth = p(.leftHip).distance(to: p(.rightHip))
        upperArm = (p(.leftShoulder).distance(to: p(.leftElbow)) + p(.rightShoulder).distance(to: p(.rightElbow))) / 2
        forearm = (p(.leftElbow).distance(to: p(.leftWrist)) + p(.rightElbow).distance(to: p(.rightWrist))) / 2
        thigh = (p(.leftHip).distance(to: p(.leftKnee)) + p(.rightHip).distance(to: p(.rightKnee))) / 2
        shin = (p(.leftKnee).distance(to: p(.leftAnkle)) + p(.rightKnee).distance(to: p(.rightAnkle))) / 2
        torso = p(.neck).distance(to: p(.chest)) + p(.chest).distance(to: p(.hips))
        neck = max(0, p(.head).distance(to: p(.neck)) - headHeight / 2)
        legLength = thigh + shin + 0.045
        armLength = upperArm + forearm + 0.11
        meters = s.measuredHeight
    }

    /// Fun facts in simple words.
    var facts: [String] {
        var out: [String] = []
        out.append(String(format: "You are about %.1f heads tall.", heightInHeads))
        if let m = meters {
            let cm = Int((m * 100).rounded())
            out.append("You are about \(cm) cm tall.")
        }
        if legLength > 0.5 { out.append("Your legs are long: more than half of you!") }
        else { out.append("Your legs are \(Int((legLength * 100).rounded()))% of your height.") }
        let span = shoulderWidth / max(0.01, hipWidth)
        if span > 2.2 { out.append("Your shoulders are nice and wide.") }
        else if span < 1.5 { out.append("Your shoulders and hips are about the same width.") }
        if armLength > 0.46 { out.append("Your arms are long, great for big poses.") }
        return out
    }
}

/// What the body is doing, in angles (degrees).
struct ScanPose: Hashable, Sendable {
    /// 0 = arm hanging down, 90 = straight out to the side or front, 180 = straight up.
    var leftArmRaise: Double
    var rightArmRaise: Double
    /// 0 = straight, bigger = more bent.
    var leftElbowBend: Double
    var rightElbowBend: Double
    var leftKneeBend: Double
    var rightKneeBend: Double
    /// How far the body leans from straight up.
    var lean: Double
    /// How far apart the feet are compared with the hips.
    var stance: Double

    init(_ s: ScanSkeleton) {
        let p = s.at
        func raise(_ sh: ScanJoint, _ el: ScanJoint) -> Double {
            let d = (p(el) - p(sh)).normalized
            return acos(max(-1, min(1, d.dot(ScanVec3(0, -1, 0))))) * 180 / .pi
        }
        func bend(_ a: ScanJoint, _ b: ScanJoint, _ c: ScanJoint) -> Double {
            let u = (p(b) - p(a)).normalized
            let v = (p(c) - p(b)).normalized
            return acos(max(-1, min(1, u.dot(v)))) * 180 / .pi
        }
        leftArmRaise = raise(.leftShoulder, .leftElbow)
        rightArmRaise = raise(.rightShoulder, .rightElbow)
        leftElbowBend = bend(.leftShoulder, .leftElbow, .leftWrist)
        rightElbowBend = bend(.rightShoulder, .rightElbow, .rightWrist)
        leftKneeBend = bend(.leftHip, .leftKnee, .leftAnkle)
        rightKneeBend = bend(.rightHip, .rightKnee, .rightAnkle)
        let spine = (p(.neck) - p(.hips)).normalized
        lean = acos(max(-1, min(1, spine.dot(.up)))) * 180 / .pi
        let feet = p(.leftAnkle).distance(to: p(.rightAnkle))
        stance = feet / max(0.01, p(.leftHip).distance(to: p(.rightHip)))
    }

    /// One short line about the pose.
    var summary: String {
        let up = 135.0, out = 60.0
        let l = leftArmRaise, r = rightArmRaise
        var parts: [String] = []
        if l > up && r > up { parts.append("Arms up high") }
        else if l > up || r > up { parts.append("One arm up") }
        else if l > out && r > out { parts.append("Arms out wide") }
        else if l > out || r > out { parts.append("One arm out") }
        else if leftElbowBend > 70 && rightElbowBend > 70 { parts.append("Elbows bent") }
        else { parts.append("Arms down") }
        if leftKneeBend > 35 && rightKneeBend > 35 { parts.append("knees bent") }
        else if leftKneeBend > 35 || rightKneeBend > 35 { parts.append("one knee up") }
        if stance > 2.6 { parts.append("wide stance") }
        if lean > 15 { parts.append("leaning") }
        if parts.count == 1 { parts.append("standing tall") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The scanned body, ready for concepts

struct ScanBody: Hashable, Sendable {
    /// Normalized: facing +z, feet on y = 0, standing height 1, every joint present.
    let skeleton: ScanSkeleton
    let proportions: ScanProportions
    let pose: ScanPose

    init?(scan: ScanSkeleton) {
        guard let n = scan.normalized() else { return nil }
        skeleton = n
        proportions = ScanProportions(n)
        pose = ScanPose(n)
    }

    var source: ScanSource { skeleton.source }

    /// Gentle notes about guesses, in simple words.
    var notes: [String] {
        let g = Set(skeleton.guessed)
        var out: [String] = []
        if g.contains(.leftAnkle) || g.contains(.rightAnkle) {
            out.append("Your feet were hard to see, so I guessed where they are.")
        }
        if (g.contains(.leftElbow) && g.contains(.leftWrist)) || (g.contains(.rightElbow) && g.contains(.rightWrist)) {
            out.append("I couldn't see one arm, so I copied the other one.")
        }
        if g.contains(.leftKnee) || g.contains(.rightKnee) {
            out.append("I couldn't see one leg, so I copied the other one.")
        }
        if skeleton.source == .vision2D {
            out.append("This was a flat photo, so the side views are my best guess.")
        }
        return out
    }
}
