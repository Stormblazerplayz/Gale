import AVFoundation
import Combine
import Foundation
import GaleFormat
import SwiftUI
import UIKit

/// Plays the movie preview and keeps the playhead time.
@MainActor
final class StudioPlayback: ObservableObject {
    let player = AVPlayer()
    /// Where the playhead is, in seconds.
    @Published private(set) var time: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = StudioMath.minimumMovieLength
    @Published private(set) var isReady = false
    @Published var problem: String?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var buildTask: Task<Void, Never>?
    private var buildVersion = 0
    private var seeking = false
    private var pendingSeek: Double?

    init() {
        player.actionAtItemEnd = .pause
        attachTimeObserver()
    }

    private func attachTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.observed(t)
            }
        }
    }

    /// Stops everything (call when the studio closes).
    func shutDown() {
        buildTask?.cancel()
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func observed(_ t: CMTime) {
        guard isPlaying, !seeking else { return }
        time = min(duration, t.studioSeconds)
        if time >= duration - 0.001 {
            pause()
            time = duration
        }
    }

    // MARK: Building

    /// Makes the preview again from the project (waits a moment so fast changes only build once).
    func rebuild(project: GaleProject, folder: URL, immediately: Bool = false) {
        attachTimeObserver()
        buildTask?.cancel()
        buildVersion += 1
        let version = buildVersion
        buildTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }
            do {
                let built = try await StudioMovieBuilder.build(project: project, folder: folder, maxSide: 1280)
                guard let self, !Task.isCancelled, version == self.buildVersion else { return }
                self.install(built)
            } catch {
                guard let self, !Task.isCancelled, version == self.buildVersion else { return }
                self.problem = "The preview couldn't be made. \(error.localizedDescription)"
            }
        }
    }

    private func install(_ built: StudioMovieBuild) {
        let wasPlaying = isPlaying
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription ?? ""
            Task { @MainActor in
                if failed { self?.problem = "The preview stopped working. \(message)" }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.player.pause()
                self.isPlaying = false
                self.time = self.duration
            }
        }
        player.replaceCurrentItem(with: item)
        duration = max(StudioMath.minimumMovieLength, built.duration)
        isReady = true
        problem = nil
        let t = min(time, duration)
        time = t
        seeking = false
        pendingSeek = nil
        seek(to: t)
        if wasPlaying {
            player.play()
        } else {
            player.pause()
        }
    }

    // MARK: Controls

    func play() {
        guard isReady else { return }
        if time >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        if isPlaying {
            isPlaying = false
            let t = player.currentTime().studioSeconds
            if !seeking { time = min(duration, max(0, t)) }
        }
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    /// Moves the playhead. Fast repeated calls (scrubbing) only keep the newest one.
    func seek(to t: Double) {
        let target = min(max(0, t.isFinite ? t : 0), duration)
        time = target
        if seeking {
            pendingSeek = target
            return
        }
        seeking = true
        player.seek(to: .studio(target), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.seekFinished()
            }
        }
    }

    private func seekFinished() {
        seeking = false
        if let next = pendingSeek {
            pendingSeek = nil
            seek(to: next)
        }
    }
}

// MARK: - Player view

/// Shows the AVPlayer's picture, fit inside the view.
struct StudioPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> StudioPlayerUIView {
        let view = StudioPlayerUIView()
        view.backgroundColor = .black
        view.playerLayer?.videoGravity = .resizeAspect
        view.playerLayer?.player = player
        return view
    }

    func updateUIView(_ uiView: StudioPlayerUIView, context: Context) {
        if uiView.playerLayer?.player !== player {
            uiView.playerLayer?.player = player
        }
    }
}

final class StudioPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}
