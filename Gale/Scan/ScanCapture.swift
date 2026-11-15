@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import GaleCore
import GaleFormat
import simd
import UIKit
@preconcurrency import Vision

// Camera permission, finding a body in a photo with Vision, and drawing concepts to pictures.
// Everything runs on this device. Photos are only looked at in memory and never saved or sent.

// MARK: - Camera permission

enum ScanCameraPermission {
    case allowed, ask, blocked

    static var current: ScanCameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return .ask
        default: return .blocked
        }
    }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static var hasFrontCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    static var hasBackCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }
}

// MARK: - What a scan found

enum ScanFound: Sendable {
    case body(ScanBody)
    case problem(String)
}

/// What the live camera can see right now.
enum ScanSeen: Equatable, Sendable {
    case nobody, needHead, needFeet, needShoulders, whole

    var tip: String {
        switch self {
        case .nobody: return "Step back until I can see all of you, head to toes."
        case .needHead: return "I can't see your head. Move back a little or tilt the camera up."
        case .needFeet: return "Almost! I need to see your feet too. Step back a bit."
        case .needShoulders: return "Face the camera so I can see both shoulders."
        case .whole: return "I can see all of you! Hold your pose…"
        }
    }
}

enum ScanVision {
    static let noPerson = "I couldn't find a person in that picture. Stand back so your whole body fits, in good light, then try again."

    /// The picture turned the right way up and made a sensible size (Vision wants upright people).
    static func upright(_ image: UIImage, maxSide: CGFloat = 2000) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let k = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let drawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return drawn.cgImage
    }

    /// Looks for a body: Vision 3D first, then flat 2D with guessed depth. Slow: call off the main thread.
    static func findBody(in image: CGImage) -> ScanFound {
        if let s = find3D(in: image), let body = ScanBody(scan: s) {
            return .body(body)
        }
        guard let flat = find2D(in: image) else { return .problem(noPerson) }
        let skeleton = flat.lifted()
        if let body = ScanBody(scan: skeleton) { return .body(body) }
        return .problem(skeleton.problems.first ?? noPerson)
    }

    static func find3D(in image: CGImage) -> ScanSkeleton? {
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let names: [(VNHumanBodyPose3DObservation.JointName, ScanJoint)] = [
            (.topHead, .headTop), (.centerHead, .head), (.centerShoulder, .neck), (.root, .hips),
            (.leftShoulder, .leftShoulder), (.leftElbow, .leftElbow), (.leftWrist, .leftWrist),
            (.rightShoulder, .rightShoulder), (.rightElbow, .rightElbow), (.rightWrist, .rightWrist),
            (.leftHip, .leftHip), (.leftKnee, .leftKnee), (.leftAnkle, .leftAnkle),
            (.rightHip, .rightHip), (.rightKnee, .rightKnee), (.rightAnkle, .rightAnkle)
        ]
        var joints: [ScanJoint: ScanVec3] = [:]
        for (name, joint) in names {
            guard let point = try? observation.recognizedPoint(name) else { continue }
            let t = point.position.columns.3
            joints[joint] = ScanVec3(Double(t.x), Double(t.y), Double(t.z))
        }
        let cam = observation.cameraOriginMatrix.columns.3
        let measured: Double? = observation.heightEstimation == .measured ? Double(observation.bodyHeight) : nil
        let skeleton = ScanSkeleton.fromWorld(joints, camera: ScanVec3(Double(cam.x), Double(cam.y), Double(cam.z)),
                                              source: .vision3D, measuredHeight: measured)
        return skeleton.isUsable ? skeleton : nil
    }

    static let flatNames: [(VNHumanBodyPoseObservation.JointName, ScanJoint)] = [
        (.neck, .neck), (.root, .hips),
        (.leftShoulder, .leftShoulder), (.leftElbow, .leftElbow), (.leftWrist, .leftWrist),
        (.rightShoulder, .rightShoulder), (.rightElbow, .rightElbow), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.leftKnee, .leftKnee), (.leftAnkle, .leftAnkle),
        (.rightHip, .rightHip), (.rightKnee, .rightKnee), (.rightAnkle, .rightAnkle)
    ]

    /// The person Vision is surest about (points with origin bottom-left, 0...1).
    static func bestFlatPoints(_ request: VNDetectHumanBodyPoseRequest) -> [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]? {
        guard let results = request.results, !results.isEmpty else { return nil }
        var best: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]?
        var bestScore: Float = 0
        for observation in results {
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            var score: Float = 0
            for (_, p) in points where p.confidence > 0.3 { score += p.confidence }
            if score > bestScore {
                bestScore = score
                best = points
            }
        }
        return best
    }

    static func find2D(in image: CGImage) -> ScanFlatPose? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let points = bestFlatPoints(request) else { return nil }
        let w = Double(image.width), h = Double(image.height)
        func at(_ name: VNHumanBodyPoseObservation.JointName) -> ScanPoint2? {
            guard let p = points[name], p.confidence > 0.25 else { return nil }
            return ScanPoint2(Double(p.location.x) * w, Double(p.location.y) * h)
        }
        var joints: [ScanJoint: ScanPoint2] = [:]
        for (name, joint) in flatNames {
            if let p = at(name) { joints[joint] = p }
        }
        guard !joints.isEmpty else { return nil }
        return ScanFlatPose(points: joints, leftEye: at(.leftEye), rightEye: at(.rightEye),
                            leftEar: at(.leftEar), rightEar: at(.rightEar), nose: at(.nose))
    }

    /// Quick check on a live camera frame (already turned upright): can we see the whole body?
    static func seen(in buffer: CMSampleBuffer) -> ScanSeen {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cmSampleBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .nobody
        }
        guard let points = bestFlatPoints(request) else { return .nobody }
        func has(_ name: VNHumanBodyPoseObservation.JointName) -> Bool {
            guard let p = points[name] else { return false }
            return p.confidence > 0.3
        }
        let count = flatNames.filter { has($0.0) }.count
        if count < 4 { return .nobody }
        if !(has(.nose) || has(.leftEye) || has(.rightEye) || has(.leftEar) || has(.rightEar)) { return .needHead }
        if !(has(.leftShoulder) && has(.rightShoulder)) { return .needShoulders }
        if !(has(.leftAnkle) && has(.rightAnkle)) { return .needFeet }
        return .whole
    }
}

// MARK: - Pictures of concepts

enum ScanRender {
    /// A picture of a drawing on white paper, `maxSide` pixels on its longest side.
    static func image(_ d: ScanDrawing, maxSide: Double) -> CGImage? {
        let b = d.bounds
        guard !b.isEmpty, b.maxSide > 0 else { return nil }
        let pad = max(8, maxSide * 0.03)
        let k = (maxSide - pad * 2) / b.maxSide
        let w = b.width * k + pad * 2
        let h = b.height * k + pad * 2
        guard let ctx = FrameRenderer.makeContext(canvasWidth: w, canvasHeight: h, scale: 1, opaque: true) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: CGFloat(pad), y: CGFloat(pad))
        ctx.scaleBy(x: CGFloat(k), y: CGFloat(k))
        ctx.translateBy(x: CGFloat(-b.minX), y: CGFloat(-b.minY))
        StrokeRenderer.draw(d.cel, in: ctx)
        return ctx.makeImage()
    }
}
