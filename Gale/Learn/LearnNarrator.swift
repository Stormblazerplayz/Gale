import AVFoundation
import SwiftUI
import GaleLearn

/// The lesson voice. Speaks lesson lines out loud with the device's own text-to-speech voice
/// (no recordings, works offline) and shows them as live captions with the spoken word highlighted.
///
/// With the voice off, captions still step through the lines at reading speed, so "watch" steps
/// move along on their own either way.
@MainActor
final class LearnNarrator: NSObject, ObservableObject {
    /// Speak out loud.
    @Published var voiceOn: Bool {
        didSet {
            UserDefaults.standard.set(voiceOn, forKey: Self.voiceKey)
            if !voiceOn && synth.isSpeaking {
                // Keep the captions going at reading speed from where the voice was.
                let rest = Array(queue.dropFirst(max(0, lineIndex)))
                let done = onDone
                stop()
                if !rest.isEmpty { speak(rest, then: done) }
            }
        }
    }
    /// Show captions.
    @Published var captionsOn: Bool {
        didSet { UserDefaults.standard.set(captionsOn, forKey: Self.captionsKey) }
    }
    /// The voice the learner picked (nil = the most natural one on this device).
    @Published var voiceID: String? {
        didSet {
            if let voiceID {
                UserDefaults.standard.set(voiceID, forKey: Self.voiceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.voiceIDKey)
            }
            voiceResolved = false
        }
    }
    /// The line on screen now ("" when quiet).
    @Published private(set) var caption = ""
    /// Which word of the caption is being said (nil when the voice is off).
    @Published private(set) var highlight: Int?
    /// True while lines are being spoken or shown.
    @Published private(set) var isTalking = false

    static let voiceKey = "learn.voiceOn"
    static let captionsKey = "learn.captionsOn"
    static let voiceIDKey = "learn.voiceID"

    private let synth = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var lineIndex = 0
    private var onDone: (() -> Void)?
    /// Bumped on every new script (and on stop), so late callbacks from an old one are ignored.
    /// Views compare it with what `speak` returned to know their script is still the current one.
    private(set) var generation = 0
    private var timer: Task<Void, Never>?
    private var lastLines: [String] = []
    private var resolvedVoice: AVSpeechSynthesisVoice?
    private var voiceResolved = false
    /// Looked up the first time it's needed (listing voices takes a moment), and again after a new pick.
    private var voice: AVSpeechSynthesisVoice? {
        if !voiceResolved {
            resolvedVoice = Self.bestVoice(picked: voiceID)
            voiceResolved = true
        }
        return resolvedVoice
    }
    /// The name of the voice lessons are spoken in.
    var voiceName: String { voice?.name ?? "The iPad's voice" }

    override init() {
        let d = UserDefaults.standard
        // UI tests run silently; captions still work.
        _voiceOn = Published(initialValue: UITestMode.on ? false : (d.object(forKey: Self.voiceKey) as? Bool ?? true))
        _captionsOn = Published(initialValue: d.object(forKey: Self.captionsKey) as? Bool ?? true)
        _voiceID = Published(initialValue: d.string(forKey: Self.voiceIDKey))
        super.init()
        synth.delegate = self
    }

    // MARK: Talking

    /// Says (or shows) the lines in order, then calls `then`. Returns the script's number.
    @discardableResult
    func speak(_ lines: [String], then: (() -> Void)? = nil) -> Int {
        stop()
        let clean = lines.map(LearnNarration.clean).filter { !$0.isEmpty }
        lastLines = clean
        guard !clean.isEmpty else {
            then?()
            return generation
        }
        generation += 1
        queue = clean
        lineIndex = 0
        onDone = then
        isTalking = true
        if voiceOn {
            activateAudio()
            let chosen = voice
            for (i, line) in clean.enumerated() {
                // Each line gets its own pace: short lines slower, questions lifted, real pauses between sentences.
                let pace = LearnNarration.pacing(for: line, index: i, count: clean.count)
                let u = AVSpeechUtterance(string: LearnNarration.speechText(line))
                u.voice = chosen
                let rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * pace.rate)
                u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
                u.pitchMultiplier = Float(pace.pitch)
                u.preUtteranceDelay = pace.preDelay
                u.postUtteranceDelay = pace.postDelay
                synth.speak(u)
            }
            show(0)
        } else {
            showTimed(0, generation: generation)
        }
        return generation
    }

    /// Says the last lines again.
    func replay() {
        let lines = lastLines
        let done = onDone
        speak(lines, then: done)
    }

    /// Goes quiet now. The `then` of the current script is not called.
    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        onDone = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        queue = []
        lineIndex = 0
        caption = ""
        highlight = nil
        isTalking = false
        deactivateAudio()
    }

    private func show(_ i: Int) {
        lineIndex = i
        caption = queue.indices.contains(i) ? queue[i] : ""
        highlight = nil
    }

    /// Voice off: each caption stays up for about as long as it takes to read.
    private func showTimed(_ i: Int, generation gen: Int) {
        guard gen == generation else { return }
        guard queue.indices.contains(i) else {
            finished(generation: gen)
            return
        }
        show(i)
        let seconds = LearnNarration.readingSeconds(queue[i])
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.showTimed(i + 1, generation: gen)
        }
    }

    private func finished(generation gen: Int) {
        guard gen == generation else { return }
        let done = onDone
        onDone = nil
        isTalking = false
        highlight = nil
        caption = ""
        deactivateAudio()
        done?()
    }

    // MARK: Audio

    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Says a short line in the current voice, so the learner can hear what it sounds like.
    func sample() {
        if !voiceOn { voiceOn = true }
        speak(["Hi! This is how your lessons will sound.", "Ready to animate something awesome?"])
    }

    /// The English language the device would rather hear.
    static var preferredLanguage: String {
        LearnVoiceChoice.preferredLanguage(deviceLanguage: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Every voice on the device, described for `LearnVoiceChoice`.
    static func voiceCandidates() -> [LearnVoiceCandidate] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            let quality: LearnVoiceCandidate.Quality
            switch v.quality {
            case .premium: quality = .premium
            case .enhanced: quality = .enhanced
            default: quality = .standard
            }
            return LearnVoiceCandidate(id: v.identifier, name: v.name, language: v.language, quality: quality,
                                       isNovelty: v.voiceTraits.contains(.isNoveltyVoice))
        }
    }

    /// The learner's pick if it's still installed, otherwise the most natural English voice on this device
    /// (premium, then enhanced; novelty and robotic voices last).
    static func bestVoice(picked: String? = nil) -> AVSpeechSynthesisVoice? {
        let language = preferredLanguage
        if let best = LearnVoiceChoice.best(voiceCandidates(), preferredLanguage: language, picked: picked),
           let v = AVSpeechSynthesisVoice(identifier: best.id) {
            return v
        }
        return AVSpeechSynthesisVoice(language: language)
    }
}

extension LearnNarrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let spoken = utterance.speechString
        Task { @MainActor in self.started(spoken) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let spoken = utterance.speechString
        let offset = characterRange.location
        Task { @MainActor in self.saying(spoken, at: offset) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let spoken = utterance.speechString
        Task { @MainActor in self.ended(spoken) }
    }

    private func started(_ spoken: String) {
        // Find which line this is (lines repeat rarely; search from the current one).
        if let i = queue.indices.dropFirst(lineIndex).first(where: { LearnNarration.speechText(queue[$0]) == spoken }) {
            show(i)
        }
    }

    private func saying(_ spoken: String, at offset: Int) {
        guard queue.indices.contains(lineIndex), LearnNarration.speechText(queue[lineIndex]) == spoken else { return }
        highlight = LearnNarration.captionWord(shown: queue[lineIndex], spoken: spoken, spokenOffset: offset)
    }

    private func ended(_ spoken: String) {
        guard isTalking, queue.indices.contains(lineIndex),
              LearnNarration.speechText(queue[lineIndex]) == spoken else { return }
        if lineIndex >= queue.count - 1 {
            finished(generation: generation)
        } else {
            show(lineIndex + 1)
        }
    }
}

// MARK: - Caption bar

/// The caption under the lesson, with the spoken word highlighted, and the voice buttons.
struct LearnCaptionBar: View {
    @ObservedObject var narrator: LearnNarrator
    /// Says the step again from the start.
    let onReplay: () -> Void
    @State private var pickingVoice = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                narrator.voiceOn.toggle()
                if narrator.voiceOn && !narrator.isTalking { onReplay() }
            } label: {
                Image(systemName: narrator.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(narrator.voiceOn ? 0.16 : 0.06), in: Circle())
            }
            .accessibilityLabel(narrator.voiceOn ? "Turn the voice off" : "Turn the voice on")
            .accessibilityIdentifier("learnVoiceButton")

            Group {
                if narrator.captionsOn && !narrator.caption.isEmpty {
                    Text(captionText)
                        .font(.callout.weight(.medium))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.12), value: narrator.highlight)
                        .accessibilityIdentifier("learnCaption")
                } else {
                    Text(narrator.isTalking ? "Talking…" : "Tap ↻ to hear this step")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button(action: onReplay) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Say it again")
            Button {
                narrator.captionsOn.toggle()
            } label: {
                Image(systemName: narrator.captionsOn ? "captions.bubble.fill" : "captions.bubble")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(narrator.captionsOn ? "Hide captions" : "Show captions")
            Button {
                pickingVoice = true
            } label: {
                Image(systemName: "person.wave.2")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Choose the lesson voice")
            .accessibilityIdentifier("learnVoicePicker")
        }
        .sheet(isPresented: $pickingVoice) {
            LearnVoicePicker(narrator: narrator)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// The caption with the word being said in the accent colour.
    private var captionText: AttributedString {
        let line = narrator.caption
        guard let w = narrator.highlight else { return AttributedString(line) }
        let ranges = LearnNarration.wordRanges(in: line)
        guard ranges.indices.contains(w) else { return AttributedString(line) }
        let utf16 = line.utf16
        guard let lo = utf16.index(utf16.startIndex, offsetBy: ranges[w].lowerBound, limitedBy: utf16.endIndex),
              let hi = utf16.index(utf16.startIndex, offsetBy: ranges[w].upperBound, limitedBy: utf16.endIndex),
              let sLo = lo.samePosition(in: line), let sHi = hi.samePosition(in: line), sLo <= sHi
        else { return AttributedString(line) }
        var word = AttributedString(String(line[sLo..<sHi]))
        word.foregroundColor = Theme.accent
        word.font = .callout.weight(.bold)
        return AttributedString(String(line[..<sLo])) + word + AttributedString(String(line[sHi...]))
    }
}

// MARK: - Voice picker

/// Pick the voice lessons are spoken in. Tapping a voice plays a sample.
struct LearnVoicePicker: View {
    @ObservedObject var narrator: LearnNarrator
    @Environment(\.dismiss) private var dismiss
    @State private var voices: [LearnVoiceCandidate] = []

    private var ranked: [LearnVoiceCandidate] {
        LearnVoiceChoice.ranked(voices, preferredLanguage: LearnNarrator.preferredLanguage)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        narrator.voiceID = nil
                        narrator.sample()
                    } label: {
                        row(title: "Most natural voice", detail: "Picks the best one on this iPad",
                            selected: narrator.voiceID == nil)
                    }
                    ForEach(ranked, id: \.id) { v in
                        Button {
                            narrator.voiceID = v.id
                            narrator.sample()
                        } label: {
                            row(title: v.name, detail: detail(for: v), selected: narrator.voiceID == v.id)
                        }
                    }
                } footer: {
                    Text("Tap a voice to hear it. Now speaking: \(narrator.voiceName).")
                }
                Section {
                    Label {
                        Text("For the most human-sounding voice, open Settings, then Accessibility, Spoken Content, "
                             + "Voices, English. Download a voice marked Premium or Enhanced, like Ava or Zoe, "
                             + "then pick it here.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accent)
                    }
                    .font(.footnote)
                } header: {
                    Text(LearnVoiceChoice.shouldSuggestDownload(voices) ? "Get a better voice" : "More voices")
                }
            }
            .navigationTitle("Lesson voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .onAppear { voices = LearnNarrator.voiceCandidates() }
    }

    private func row(title: String, detail: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func detail(for v: LearnVoiceCandidate) -> String {
        let quality: String
        switch v.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        case .standard: quality = "Standard"
        }
        let language = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
        return "\(quality) · \(language)"
    }
}
