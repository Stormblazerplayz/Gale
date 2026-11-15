import AVFoundation
import Foundation
import GaleFormat
import SwiftUI
import UIKit

// MARK: - Audio session

enum StudioAudioSession {
    /// Plays sound even with the silent switch on.
    static func usePlayback() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [])
        try? s.setActive(true)
    }

    /// Records from the microphone while the movie can still play out loud.
    static func useRecording() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try s.setActive(true)
    }

    /// How late the microphone hears you compared to the movie you hear (seconds).
    static var roundTripLatency: Double {
        let s = AVAudioSession.sharedInstance()
        let v = s.inputLatency + s.outputLatency
        return v.isFinite ? max(0, min(0.5, v)) : 0
    }
}

// MARK: - Recorder

/// Records your voice from the microphone into an .m4a file.
@MainActor
final class StudioRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording
        case saving
    }

    @Published private(set) var phase: Phase = .idle
    /// 0 (quiet) to 1 (loud).
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published var problem: String?
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var countdownTask: Task<Bool, Never>?
    private var fileURL: URL?

    var isBusy: Bool { phase != .idle }

    /// Asks to use the microphone the first time. True when allowed.
    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            permissionDenied = true
            return false
        case .undetermined:
            let ok = await AVAudioApplication.requestRecordPermission()
            if !ok { permissionDenied = true }
            return ok
        @unknown default:
            let ok = await AVAudioApplication.requestRecordPermission()
            if !ok { permissionDenied = true }
            return ok
        }
    }

    /// 3, 2, 1... Returns false if it was cancelled.
    func countdown() async -> Bool {
        let task = Task { @MainActor [weak self] () -> Bool in
            for n in stride(from: 3, through: 1, by: -1) {
                self?.phase = .countdown(n)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return false }
            }
            return true
        }
        countdownTask = task
        let ok = await task.value
        countdownTask = nil
        if !ok { phase = .idle }
        return ok
    }

    func start() throws {
        try StudioAudioSession.useRecording()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gale-voice-\(UUID().uuidString).m4a")
        let r = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        r.isMeteringEnabled = true
        guard r.prepareToRecord(), r.record() else {
            StudioAudioSession.usePlayback()
            throw StudioError.message("The microphone didn't start. Try again.")
        }
        recorder = r
        fileURL = url
        elapsed = 0
        level = 0
        phase = .recording
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateMeter()
            }
        }
    }

    private func updateMeter() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        let db = Double(r.averagePower(forChannel: 0))
        let target = db.isFinite ? StudioMath.clamp((db + 50) / 50, 0, 1) : 0
        // Rise fast, fall slowly, so the bar is easy to read.
        level = target > level ? target : level * 0.85 + target * 0.15
        elapsed = r.currentTime
    }

    /// Stops and gives back the file (nil if it was too short).
    func stop() -> URL? {
        countdownTask?.cancel()
        meterTimer?.invalidate()
        meterTimer = nil
        let length = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        level = 0
        StudioAudioSession.usePlayback()
        let url = fileURL
        fileURL = nil
        if length < 0.3 {
            if let url { try? FileManager.default.removeItem(at: url) }
            phase = .idle
            problem = "That was too short. Hold on a bit longer."
            return nil
        }
        phase = .saving
        return url
    }

    /// Throws the recording away.
    func cancel() {
        countdownTask?.cancel()
        meterTimer?.invalidate()
        meterTimer = nil
        if recorder != nil {
            recorder?.stop()
            _ = recorder?.deleteRecording()
            recorder = nil
            StudioAudioSession.usePlayback()
        }
        fileURL = nil
        level = 0
        phase = .idle
    }

    func finishedSaving() {
        phase = .idle
    }
}

// MARK: - Voice effects

enum StudioVoiceEffect: String, CaseIterable, Identifiable {
    case robot, chipmunk, deep, echo, reverb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .robot: return "Robot"
        case .chipmunk: return "Chipmunk"
        case .deep: return "Deep"
        case .echo: return "Echo"
        case .reverb: return "Big Hall"
        }
    }

    var icon: String {
        switch self {
        case .robot: return "cpu"
        case .chipmunk: return "hare"
        case .deep: return "tortoise"
        case .echo: return "dot.radiowaves.left.and.right"
        case .reverb: return "building.columns"
        }
    }

    /// Extra seconds at the end so echoes can ring out.
    var tail: Double {
        switch self {
        case .echo: return 1.5
        case .reverb: return 2.5
        default: return 0
        }
    }

    /// Makes a new sound file with the effect, without playing it (fast, offline).
    static func render(_ effect: StudioVoiceEffect, source: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try renderNow(effect, source: source)
        }.value
    }

    private static func makeNodes(_ effect: StudioVoiceEffect) -> [AVAudioNode] {
        switch effect {
        case .robot:
            let pitch = AVAudioUnitTimePitch()
            pitch.pitch = -200
            let ring = AVAudioUnitDistortion()
            ring.loadFactoryPreset(.speechAlienChatter)
            ring.wetDryMix = 70
            return [pitch, ring]
        case .chipmunk:
            let pitch = AVAudioUnitTimePitch()
            pitch.pitch = 900
            return [pitch]
        case .deep:
            let pitch = AVAudioUnitTimePitch()
            pitch.pitch = -600
            return [pitch]
        case .echo:
            let delay = AVAudioUnitDelay()
            delay.delayTime = 0.28
            delay.feedback = 40
            delay.lowPassCutoff = 9000
            delay.wetDryMix = 35
            return [delay]
        case .reverb:
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.largeHall)
            reverb.wetDryMix = 40
            return [reverb]
        }
    }

    private static func renderNow(_ effect: StudioVoiceEffect, source: URL) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw StudioError.message("That sound can't be changed.")
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let nodes = makeNodes(effect)
        var last: AVAudioNode = player
        for node in nodes {
            engine.attach(node)
            engine.connect(last, to: node, format: format)
            last = node
        }
        engine.connect(last, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        player.scheduleFile(input, at: nil, completionHandler: nil)
        try engine.start()
        player.play()
        defer {
            player.stop()
            engine.stop()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw StudioError.message("Not enough memory to change the sound.")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("gale-fx-\(UUID().uuidString).m4a")
        let total = input.length + AVAudioFramePosition(effect.tail * format.sampleRate)
        // The file is closed when `output` goes away at the end of this block.
        do {
            let output = try AVAudioFile(forWriting: out, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: min(2, format.channelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            var stalls = 0
            while engine.manualRenderingSampleTime < total {
                let left = total - engine.manualRenderingSampleTime
                let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), left))
                let status = try engine.renderOffline(count, to: buffer)
                switch status {
                case .success:
                    stalls = 0
                    try output.write(from: buffer)
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    stalls += 1
                    if stalls > 200 { throw StudioError.message("Changing the sound got stuck.") }
                case .error:
                    throw StudioError.message("Changing the sound didn't work.")
                @unknown default:
                    throw StudioError.message("Changing the sound didn't work.")
                }
            }
        }
        return out
    }
}
