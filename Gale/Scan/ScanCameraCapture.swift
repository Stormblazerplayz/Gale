@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import SwiftUI
import UIKit

// Photo scan with the front (selfie) or back camera, for devices without 3D body tracking.
// A quick body check runs on the live picture so it can say "step back" and count down
// 3-2-1 by itself once the whole body is in view. Only one photo is taken, kept in memory,
// handed to Vision, and then thrown away.

/// Runs the camera on its own queue. Callbacks are set once before `start()` and never changed.
final class ScanCameraEngine: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let device: AVCaptureDevice?
    var onSeen: (@Sendable (ScanSeen) -> Void)?
    var onPhoto: (@Sendable (CGImage?) -> Void)?

    private let queue = DispatchQueue(label: "gale.scan.camera")
    private let videoQueue = DispatchQueue(label: "gale.scan.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false
    private var lastCheck = Date.distantPast
    private var angle: CGFloat = 90

    init(front: Bool) {
        device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
        super.init()
    }

    func start(_ started: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            configureIfNeeded()
            if configured && !session.isRunning { session.startRunning() }
            applyAngle()
            started()
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Turns the pictures so people stand upright (Vision needs that).
    func setRotation(_ newAngle: CGFloat) {
        queue.async { [self] in
            angle = newAngle
            applyAngle()
        }
    }

    func capture() {
        queue.async { [self] in
            guard session.isRunning else {
                onPhoto?(nil)
                return
            }
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    private func applyAngle() {
        for connection in [photoOutput.connection(with: .video), videoOutput.connection(with: .video)] {
            if let c = connection, c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
        }
    }

    private func configureIfNeeded() {
        guard !configured, let device = device else { return }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 0.3 else { return }
        lastCheck = now
        onSeen?(ScanVision.seen(in: sampleBuffer))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            onPhoto?(nil)
            return
        }
        onPhoto?(ScanVision.upright(image))
    }
}

@MainActor
final class ScanCameraModel: ObservableObject {
    @Published private(set) var seen: ScanSeen = .nobody
    @Published private(set) var countdown: Int?
    @Published private(set) var busy = false

    let engine: ScanCameraEngine
    let front: Bool
    var onPhoto: ((CGImage?) -> Void)?

    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var wholeSince: Date?
    private var countdownTask: Task<Void, Never>?
    private var done = false

    init(front: Bool) {
        self.front = front
        engine = ScanCameraEngine(front: front)
        engine.onSeen = { [weak self] seen in
            Task { @MainActor [weak self] in self?.handle(seen) }
        }
        engine.onPhoto = { [weak self] image in
            Task { @MainActor [weak self] in self?.finished(image) }
        }
    }

    var hasCamera: Bool { engine.device != nil }

    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        guard rotation == nil, let device = engine.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotation = coordinator
        observation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.applyRotation() }
        }
    }

    private func applyRotation() {
        guard let coordinator = rotation else { return }
        engine.setRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        let preview = coordinator.videoRotationAngleForHorizonLevelPreview
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(preview) {
            connection.videoRotationAngle = preview
        }
    }

    func start() {
        done = false
        engine.start { [weak self] in
            Task { @MainActor [weak self] in self?.applyRotation() }
        }
    }

    func stop() {
        done = true
        stopCountdown()
        engine.stop()
    }

    /// The "Take photo" button.
    func captureNow() {
        guard !busy, !done else { return }
        stopCountdown()
        busy = true
        engine.capture()
    }

    private func handle(_ s: ScanSeen) {
        guard !done, !busy else { return }
        seen = s
        if s == .whole {
            if wholeSince == nil { wholeSince = Date() }
            if countdownTask == nil, let since = wholeSince, Date().timeIntervalSince(since) > 0.8 { startCountdown() }
        } else {
            wholeSince = nil
            stopCountdown()
        }
    }

    private func startCountdown() {
        countdownTask = Task { @MainActor [weak self] in
            for n in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                self.countdown = n
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.countdownTask = nil
            self.countdown = nil
            self.captureNow()
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func finished(_ image: CGImage?) {
        busy = false
        guard !done else { return }
        if image != nil { done = true }
        onPhoto?(image)
    }
}

final class ScanPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
}

struct ScanCameraPreview: UIViewRepresentable {
    let model: ScanCameraModel

    func makeUIView(context: Context) -> ScanPreviewUIView {
        let view = ScanPreviewUIView()
        view.backgroundColor = .black
        if let layer = view.previewLayer {
            layer.session = model.engine.session
            layer.videoGravity = .resizeAspectFill
            model.attach(layer)
        }
        return view
    }

    func updateUIView(_ uiView: ScanPreviewUIView, context: Context) {}
}

/// Full-screen photo scan.
struct ScanCameraScreen: View {
    let front: Bool
    let onPhoto: (CGImage) -> Void
    let onCancel: () -> Void

    @StateObject private var model: ScanCameraModel
    @State private var note: String?

    init(front: Bool, onPhoto: @escaping (CGImage) -> Void, onCancel: @escaping () -> Void) {
        self.front = front
        self.onPhoto = onPhoto
        self.onCancel = onCancel
        _model = StateObject(wrappedValue: ScanCameraModel(front: front))
    }

    var body: some View {
        ZStack {
            ScanCameraPreview(model: model)
                .ignoresSafeArea()
            // A friendly outline to stand inside.
            Image(systemName: "figure.stand")
                .resizable()
                .scaledToFit()
                .fontWeight(.ultraLight)
                .foregroundStyle(.white.opacity(model.seen == .whole ? 0 : 0.25))
                .padding(.vertical, 110)
                .allowsHitTesting(false)
            VStack(spacing: 12) {
                Text(note ?? (model.countdown != nil ? "Hold still…" : model.seen.tip))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: 520)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 12)
                if front && model.countdown == nil && model.seen != .whole {
                    Text("Lean your device on something, then step back.")
                        .font(.callout)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                if let n = model.countdown {
                    Text("\(n)")
                        .font(.system(size: 120, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                }
                if model.busy {
                    ProgressView().controlSize(.large).tint(.white)
                }
                Spacer()
                HStack(spacing: 16) {
                    Button("Cancel", role: .cancel) {
                        model.stop()
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    Button {
                        model.captureNow()
                    } label: {
                        Label("Take photo", systemImage: "camera.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || !model.hasCamera)
                }
                .controlSize(.large)
                .padding(.bottom, 20)
            }
            .padding(.horizontal)
        }
        .background(Color.black)
        .animation(.easeOut(duration: 0.2), value: model.countdown)
        .onAppear {
            if !model.hasCamera { note = "I can't find that camera on this device. Try picking a photo instead." }
            model.onPhoto = { image in
                if let image {
                    onPhoto(image)
                } else {
                    note = "That photo didn't work. Let's try again."
                }
            }
            model.start()
        }
        .onDisappear { model.stop() }
    }
}
