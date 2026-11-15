@preconcurrency import ARKit
import Foundation
import RealityKit
import simd
import SwiftUI
import UIKit

// 3D body scan with ARKit body tracking (back camera, A12 chip or newer).
// Shows a live skeleton on top of the camera, counts down 3-2-1 when the whole body is in view,
// then mixes the last few frames together (median) so one wobbly frame can't spoil the scan.

enum ScanAR {
    /// True on devices that can track a body in 3D. Check before showing the AR scan.
    static var isSupported: Bool { ARBodyTrackingConfiguration.isSupported }

    /// ARKit joint names → Gale joints.
    static let jointNames: [(String, ScanJoint)] = [
        ("hips_joint", .hips), ("neck_1_joint", .neck), ("head_joint", .head),
        ("left_arm_joint", .leftShoulder), ("left_forearm_joint", .leftElbow), ("left_hand_joint", .leftWrist),
        ("right_arm_joint", .rightShoulder), ("right_forearm_joint", .rightElbow), ("right_hand_joint", .rightWrist),
        ("left_upLeg_joint", .leftHip), ("left_leg_joint", .leftKnee), ("left_foot_joint", .leftAnkle), ("left_toes_joint", .leftToe),
        ("right_upLeg_joint", .rightHip), ("right_leg_joint", .rightKnee), ("right_foot_joint", .rightAnkle), ("right_toes_joint", .rightToe)
    ]
}

/// One frame of tracking: joints in world space (meters, y up) and where the camera was.
struct ScanARFrame: Sendable {
    var joints: [ScanJoint: ScanVec3]
    var camera: ScanVec3
}

@MainActor
final class ScanARModel: ObservableObject {
    @Published private(set) var points: [ScanJoint: CGPoint] = [:]
    @Published private(set) var tip = ScanSeen.nobody.tip
    @Published private(set) var countdown: Int?
    @Published private(set) var whole = false
    @Published private(set) var failed: String?

    var onCapture: ((ScanSkeleton) -> Void)?

    private var frames: [ScanARFrame] = []
    private var wholeSince: Date?
    private var countdownTask: Task<Void, Never>?
    private var done = false

    func update(_ frame: ScanARFrame, screen: [ScanJoint: CGPoint], viewport: CGSize) {
        guard !done else { return }
        frames.append(frame)
        if frames.count > 20 { frames.removeFirst(frames.count - 20) }
        points = screen
        let inset: CGFloat = 6
        let area = CGRect(origin: .zero, size: viewport).insetBy(dx: inset, dy: inset)
        func inView(_ j: ScanJoint) -> Bool { screen[j].map { area.contains($0) } ?? false }
        let headIn = inView(.head)
        let feetIn = inView(.leftAnkle) && inView(.rightAnkle)
        let shouldersIn = inView(.leftShoulder) && inView(.rightShoulder)
        let seen: ScanSeen
        if !headIn { seen = .needHead } else if !shouldersIn { seen = .needShoulders } else if !feetIn { seen = .needFeet } else { seen = .whole }
        whole = seen == .whole
        if countdown == nil { tip = seen.tip }
        if whole {
            if wholeSince == nil { wholeSince = Date() }
            if countdownTask == nil, let since = wholeSince, Date().timeIntervalSince(since) > 0.8 { startCountdown() }
        } else {
            wholeSince = nil
            stopCountdown()
        }
    }

    func lost() {
        guard !done else { return }
        points = [:]
        whole = false
        wholeSince = nil
        frames.removeAll()
        stopCountdown()
        tip = ScanSeen.nobody.tip
    }

    func fail(_ message: String) {
        failed = message
        stopCountdown()
    }

    /// Scan right away (the "Scan now" button), if a body is being tracked.
    func captureNow() {
        guard !frames.isEmpty else {
            tip = "I can't see you yet. " + ScanSeen.nobody.tip
            return
        }
        finish()
    }

    func cancel() {
        done = true
        stopCountdown()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            for n in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                self.countdown = n
                self.tip = "Hold still…"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.finish()
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func finish() {
        guard !done, !frames.isEmpty else { return }
        done = true
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        tip = "Got it!"
        let recent = Array(frames.suffix(12))
        var fused: [ScanJoint: ScanVec3] = [:]
        for joint in ScanJoint.allCases {
            let values = recent.compactMap { $0.joints[joint] }
            guard !values.isEmpty else { continue }
            fused[joint] = ScanVec3(Self.median(values.map(\.x)), Self.median(values.map(\.y)), Self.median(values.map(\.z)))
        }
        let cams = recent.map(\.camera)
        let camera = ScanVec3(Self.median(cams.map(\.x)), Self.median(cams.map(\.y)), Self.median(cams.map(\.z)))
        onCapture?(ScanSkeleton.fromWorld(fused, camera: camera, source: .arkit))
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Gets ARKit updates. ARKit calls these on the main queue (no delegate queue is set).
final class ScanARDelegate: NSObject, ARSessionDelegate {
    let model: ScanARModel
    weak var view: ARView?

    init(model: ScanARModel) {
        self.model = model
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated { self.handle(session, anchors) }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated { self.handle(session, anchors) }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard anchors.contains(where: { $0 is ARBodyAnchor }) else { return }
        MainActor.assumeIsolated { self.model.lost() }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            self.model.fail("The 3D camera stopped working. Try the photo scan instead.")
        }
    }

    @MainActor
    private func handle(_ session: ARSession, _ anchors: [ARAnchor]) {
        guard let body = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
        guard body.isTracked else {
            model.lost()
            return
        }
        guard let frame = session.currentFrame, let view = view else { return }
        let viewport = view.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        var joints: [ScanJoint: ScanVec3] = [:]
        var screen: [ScanJoint: CGPoint] = [:]
        func world(_ name: String) -> SIMD3<Float>? {
            guard let m = body.skeleton.modelTransform(for: ARSkeleton.JointName(rawValue: name)) else { return nil }
            let w = body.transform * m
            return SIMD3<Float>(w.columns.3.x, w.columns.3.y, w.columns.3.z)
        }
        for (name, joint) in ScanAR.jointNames {
            guard let p = world(name) else { continue }
            joints[joint] = ScanVec3(Double(p.x), Double(p.y), Double(p.z))
            screen[joint] = frame.camera.projectPoint(p, orientation: orientation, viewportSize: viewport)
        }
        // Eye level is the middle of the head, so use the eyes to place the head center when we can.
        if let head = world("head_joint"), let le = world("left_eye_joint"), let re = world("right_eye_joint") {
            let eyes = (le + re) * 0.5
            let center = (eyes + head) * 0.5
            joints[.head] = ScanVec3(Double(center.x), Double(eyes.y), Double(center.z))
        }
        let cam = frame.camera.transform.columns.3
        model.update(ScanARFrame(joints: joints, camera: ScanVec3(Double(cam.x), Double(cam.y), Double(cam.z))),
                     screen: screen, viewport: viewport)
    }
}

struct ScanARCameraView: UIViewRepresentable {
    let model: ScanARModel

    func makeCoordinator() -> ScanARDelegate {
        ScanARDelegate(model: model)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.view = view
        view.session.delegate = context.coordinator
        if ARBodyTrackingConfiguration.isSupported {
            let config = ARBodyTrackingConfiguration()
            config.automaticSkeletonScaleEstimationEnabled = true
            view.session.run(config)
        } else {
            let model = self.model
            Task { @MainActor in model.fail("This device can't do 3D body scans. Use the photo scan instead.") }
        }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ScanARDelegate) {
        uiView.session.pause()
        uiView.session.delegate = nil
    }
}

/// Full-screen 3D scan.
struct ScanARScreen: View {
    let onSkeleton: (ScanSkeleton) -> Void
    let onCancel: () -> Void

    @StateObject private var model = ScanARModel()

    var body: some View {
        ZStack {
            ScanARCameraView(model: model)
                .ignoresSafeArea()
            Canvas { ctx, _ in
                let pts = model.points
                var path = Path()
                for (a, b) in ScanJoint.bones {
                    guard let p = pts[a], let q = pts[b] else { continue }
                    path.move(to: p)
                    path.addLine(to: q)
                }
                let color: Color = model.whole ? .green : .yellow
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                for (_, p) in pts {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(spacing: 12) {
                Text(model.failed ?? model.tip)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: 520)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 12)
                Spacer()
                if let n = model.countdown {
                    Text("\(n)")
                        .font(.system(size: 120, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .transition(.scale)
                }
                Spacer()
                HStack(spacing: 16) {
                    Button("Cancel", role: .cancel) {
                        model.cancel()
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    Button {
                        model.captureNow()
                    } label: {
                        Label("Scan now", systemImage: "figure.stand")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.failed != nil)
                }
                .controlSize(.large)
                .padding(.bottom, 20)
            }
            .padding(.horizontal)
        }
        .background(Color.black)
        .animation(.easeOut(duration: 0.2), value: model.countdown)
        .onAppear {
            model.onCapture = { skeleton in onSkeleton(skeleton) }
        }
        .onDisappear { model.cancel() }
    }
}
