import AVFoundation
import GaleFormat
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The movie studio: put videos, pictures, sounds and your drawing on tracks, record your voice,
/// and save the movie. Show it full screen from the editor.
struct StudioView: View {
    @ObservedObject var document: ProjectDocument

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var playback = StudioPlayback()
    @StateObject private var exporter = StudioExporter()
    @State private var selectedClipID: String?
    @State private var pixelsPerSecond = StudioMath.defaultPixelsPerSecond
    @State private var drawing: StudioDrawingSnapshot?
    @State private var sheet: StudioSheet?
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var busy: String?
    @State private var message: String?

    enum StudioSheet: Identifiable {
        case clip(String)
        case track(String)
        case record
        case export

        var id: String {
            switch self {
            case .clip(let id): return "clip-\(id)"
            case .track(let id): return "track-\(id)"
            case .record: return "record"
            case .export: return "export"
            }
        }
    }

    private var selectedClip: Clip? {
        guard let id = selectedClipID else { return nil }
        return document.project.movie.clips.first { $0.id == id }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                Divider()
                preview
                    .frame(height: previewHeight(geo.size))
                transport
                Divider()
                StudioTimeline(document: document,
                               playback: playback,
                               selectedClipID: $selectedClipID,
                               pixelsPerSecond: $pixelsPerSecond,
                               drawing: drawing ?? StudioDrawingSnapshot(project: document.project),
                               onTrackTap: { sheet = .track($0) })
                    .frame(maxHeight: .infinity)
                if let clip = selectedClip {
                    Divider()
                    clipBar(clip)
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        // The studio has its own top bar (with Done), so hide any navigation bar it is shown in.
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            StudioAudioSession.usePlayback()
            drawing = StudioDrawingSnapshot(project: document.project)
            playback.rebuild(project: document.project, folder: document.folder, immediately: true)
        }
        .onDisappear {
            playback.shutDown()
            exporter.cancel()
        }
        .onChange(of: document.project) { _, newValue in
            playback.rebuild(project: newValue, folder: document.folder)
            if let id = selectedClipID, !newValue.movie.clips.contains(where: { $0.id == id }) {
                selectedClipID = nil
            }
        }
        .onChange(of: document.project.frames) { _, _ in
            drawing = StudioDrawingSnapshot(project: document.project)
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            importPhotos(items)
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .clip(let id):
                StudioClipSheet(document: document, clipID: id)
                    .presentationDetents([.medium, .large])
            case .track(let id):
                StudioTrackSheet(document: document, trackID: id)
                    .presentationDetents([.medium])
            case .record:
                StudioRecordSheet(document: document, playback: playback) { clipID in
                    if let clipID { selectedClipID = clipID }
                }
                .presentationDetents([.medium])
            case .export:
                StudioExportSheet(document: document, exporter: exporter)
                    .presentationDetents([.medium, .large])
            }
        }
        .overlay {
            if let busy {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(busy)
                            .font(.headline)
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
                }
            }
        }
        .alert("Movie Studio", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func previewHeight(_ size: CGSize) -> CGFloat {
        let canvas = document.project.canvas
        let aspect = CGFloat(canvas.width / max(1, canvas.height))
        let byWidth = size.width / max(0.1, aspect)
        let share: CGFloat = sizeClass == .compact ? 0.34 : 0.42
        return max(120, min(byWidth, size.height * share))
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "chevron.down")
                    .font(.headline)
            }
            Spacer(minLength: 4)
            Text("Movie Studio")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                document.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!document.canUndo)
            .accessibilityLabel("Undo")
            Button {
                document.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!document.canRedo)
            .accessibilityLabel("Redo")
            Button {
                playback.pause()
                sheet = .export
            } label: {
                Label("Save", systemImage: "square.and.arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .font(.title3)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color.black
            StudioPlayerView(player: playback.player)
            if !playback.isReady {
                ProgressView()
                    .tint(.white)
            }
            if let problem = playback.problem {
                VStack(spacing: 8) {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        playback.problem = nil
                        playback.rebuild(project: document.project, folder: document.folder, immediately: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { playback.togglePlay() }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Text("\(StudioMath.timeLabel(playback.time, tenths: true)) / \(StudioMath.timeLabel(playback.duration, tenths: true))")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            addMenu
            Button {
                playback.pause()
                playback.seek(to: 0)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Go to start")
            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button {
                playback.pause()
                sheet = .record
            } label: {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Record your voice")
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { document.project.movie.overlay },
                                 set: { StudioActions.setOverlay(document, $0) })) {
                if sizeClass == .compact {
                    Label("Draw on video", systemImage: "pencil.and.scribble")
                        .labelStyle(.iconOnly)
                } else {
                    Label("Draw on video", systemImage: "pencil.and.scribble")
                        .font(.footnote.weight(.semibold))
                }
            }
            .toggleStyle(.button)
            .accessibilityLabel("Draw on video")
            .accessibilityHint("Your drawing plays on top of the video")
            if sizeClass != .compact {
                HStack(spacing: 2) {
                    Button {
                        pixelsPerSecond = StudioMath.clampZoom(pixelsPerSecond / 1.5)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .accessibilityLabel("Zoom out")
                    Button {
                        pixelsPerSecond = StudioMath.clampZoom(pixelsPerSecond * 1.5)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .accessibilityLabel("Zoom in")
                }
            }
        }
        .font(.title3)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10,
                      matching: .any(of: [.videos, .images]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .audio, .image],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importFiles(urls)
            case .failure(let error):
                message = "Couldn't open that. \(error.localizedDescription)"
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                playback.pause()
                showPhotos = true
            } label: {
                Label("Video or picture from Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                playback.pause()
                showFiles = true
            } label: {
                Label("Video, music or picture from Files", systemImage: "folder")
            }
            Button {
                if let clip = StudioActions.addAnimation(document, at: playback.time) { selectedClipID = clip.id }
            } label: {
                Label("My drawing as a clip", systemImage: "pencil.and.scribble")
            }
            Button {
                playback.pause()
                sheet = .record
            } label: {
                Label("Record my voice", systemImage: "mic")
            }
            Divider()
            Button {
                StudioActions.addTrack(document, kind: .video)
            } label: {
                Label("New video track", systemImage: "film")
            }
            Button {
                StudioActions.addTrack(document, kind: .audio)
            } label: {
                Label("New sound track", systemImage: "waveform")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
        }
        .accessibilityLabel("Add")
    }

    // MARK: Clip bar

    private func clipBar(_ clip: Clip) -> some View {
        let media = document.media(clip.media)
        let isSound = media?.kind == .audio
        let canSplit = clip.start + StudioMath.minClipLength / 2 < playback.time && playback.time < clip.end - StudioMath.minClipLength / 2
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                barButton("Split", "scissors", enabled: canSplit) {
                    if let id = StudioActions.split(document, clip.id, at: playback.time) { selectedClipID = id }
                }
                barButton("Copy", "plus.square.on.square") {
                    if let id = StudioActions.duplicate(document, clip.id) { selectedClipID = id }
                }
                barButton("Speed", "speedometer") { sheet = .clip(clip.id) }
                if clip.media != Clip.animation && media?.kind != .image {
                    barButton("Volume", "speaker.wave.2") { sheet = .clip(clip.id) }
                }
                barButton("Fade", "circle.lefthalf.filled") { sheet = .clip(clip.id) }
                if isSound, let media {
                    Menu {
                        ForEach(StudioVoiceEffect.allCases) { effect in
                            Button {
                                applyEffect(effect, clipID: clip.id, media: media)
                            } label: {
                                Label(effect.title, systemImage: effect.icon)
                            }
                        }
                    } label: {
                        barLabel("Voice", "theatermasks")
                    }
                }
                barButton("Delete", "trash", role: .destructive) {
                    StudioActions.delete(document, clip.id)
                    selectedClipID = nil
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    private func barLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 20))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .frame(minWidth: 58, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func barButton(_ title: String, _ icon: String, role: ButtonRole? = nil, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            barLabel(title, icon)
        }
        .disabled(!enabled)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }

    // MARK: Work

    private func importPhotos(_ items: [PhotosPickerItem]) {
        busy = "Adding from Photos…"
        let start = playback.time
        Task {
            let result = await StudioActions.importPhotos(document, items: items, at: start)
            busy = nil
            if result.failed > 0 {
                message = result.added == 0
                    ? "Couldn't add that. Try another video or picture."
                    : "Added \(result.added). \(result.failed) couldn't be added."
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = "Adding files…"
        let start = playback.time
        Task {
            var t = start
            var problems: [String] = []
            for url in urls {
                guard let kind = StudioActions.kind(of: url) else {
                    problems.append("\(url.lastPathComponent) isn't a video, sound or picture.")
                    continue
                }
                do {
                    if let clip = try await StudioActions.importFile(document, url: url, kind: kind, name: nil, at: t) {
                        t = clip.end
                        selectedClipID = clip.id
                    }
                } catch {
                    problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            busy = nil
            if !problems.isEmpty { message = problems.joined(separator: "\n") }
        }
    }

    private func applyEffect(_ effect: StudioVoiceEffect, clipID: String, media: MediaItem) {
        playback.pause()
        busy = "Adding the \(effect.title) voice…"
        let source = document.mediaURL(media)
        Task {
            do {
                let out = try await StudioVoiceEffect.render(effect, source: source)
                defer { try? FileManager.default.removeItem(at: out) }
                let made = try await document.importMedia(from: out, kind: .audio, name: "\(media.name) (\(effect.title))")
                StudioActions.updateClip(document, clipID) { c in c.media = made.id }
            } catch {
                message = "Couldn't change the voice. \(error.localizedDescription)"
            }
            busy = nil
        }
    }
}

// MARK: - Clip settings

/// Speed, volume and fades for one clip.
struct StudioClipSheet: View {
    @ObservedObject var document: ProjectDocument
    let clipID: String
    @Environment(\.dismiss) private var dismiss

    private var clip: Clip? { document.project.movie.clips.first { $0.id == clipID } }

    var body: some View {
        NavigationStack {
            Group {
                if let clip {
                    form(clip)
                } else {
                    Text("This clip is gone.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func set(undoable: Bool, _ change: @escaping (inout Clip) -> Void) {
        StudioActions.updateClip(document, clipID, undoable: undoable, change)
    }

    private func slider(_ value: @escaping (Clip) -> Double, range: ClosedRange<Double>,
                        apply: @escaping (inout Clip, Double) -> Void) -> some View {
        Slider(value: Binding(get: { clip.map(value) ?? range.lowerBound },
                              set: { v in set(undoable: false) { apply(&$0, v) } }),
               in: range,
               onEditingChanged: { began in if began { document.checkpoint() } })
    }

    @ViewBuilder
    private func form(_ clip: Clip) -> some View {
        let hasSound = clip.media != Clip.animation && document.media(clip.media)?.kind != .image
        let maxFade = max(0.1, min(10, clip.length))
        Form {
            Section {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text(String(format: "%.2g×", clip.speed)).monospacedDigit().foregroundStyle(.secondary)
                }
                slider({ $0.speed }, range: StudioMath.minSpeed...StudioMath.maxSpeed) { c, v in
                    c = StudioMath.withSpeed(c, (v * 20).rounded() / 20)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(StudioMath.speedPresets, id: \.self) { s in
                            Button(String(format: "%g×", s)) {
                                set(undoable: true) { $0 = StudioMath.withSpeed($0, s) }
                            }
                            .buttonStyle(.bordered)
                            .tint(abs(clip.speed - s) < 0.001 ? Theme.accent : .gray)
                        }
                    }
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("Slow is under 1×, fast is over 1×.")
            }

            if hasSound {
                Section("Volume") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        slider({ $0.volume }, range: 0...StudioMath.maxVolume) { c, v in
                            c = StudioMath.withVolume(c, (v * 20).rounded() / 20)
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("\(Int((clip.volume * 100).rounded()))%").monospacedDigit()
                        Spacer()
                        Button(clip.volume < 0.001 ? "Sound on" : "Mute") {
                            set(undoable: true) { $0.volume = $0.volume < 0.001 ? 1 : 0 }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Fade in")
                    Spacer()
                    Text(String(format: "%.1f s", clip.fadeIn)).monospacedDigit().foregroundStyle(.secondary)
                }
                slider({ $0.fadeIn }, range: 0...maxFade) { c, v in
                    c = StudioMath.withFades(c, fadeIn: (v * 10).rounded() / 10, fadeOut: c.fadeOut)
                }
                HStack {
                    Text("Fade out")
                    Spacer()
                    Text(String(format: "%.1f s", clip.fadeOut)).monospacedDigit().foregroundStyle(.secondary)
                }
                slider({ $0.fadeOut }, range: 0...maxFade) { c, v in
                    c = StudioMath.withFades(c, fadeIn: c.fadeIn, fadeOut: (v * 10).rounded() / 10)
                }
            } header: {
                Text("Fades")
            } footer: {
                Text(hasSound ? "Fades make the picture and sound come in and go out gently." : "Fades make the picture come in and go out gently.")
            }
        }
    }
}

// MARK: - Track settings

struct StudioTrackSheet: View {
    @ObservedObject var document: ProjectDocument
    let trackID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDelete = false

    private var track: Track? { document.project.movie.tracks.first { $0.id == trackID } }

    var body: some View {
        NavigationStack {
            Group {
                if let track {
                    Form {
                        Section("Name") {
                            TextField("Track name", text: $name)
                                .onSubmit(saveName)
                        }
                        Section {
                            Toggle("Mute", isOn: Binding(get: { self.track?.muted ?? false },
                                                         set: { v in StudioActions.updateTrack(document, trackID) { $0.muted = v } }))
                            HStack {
                                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                                Slider(value: Binding(get: { self.track?.volume ?? 1 },
                                                      set: { v in
                                                          StudioActions.updateTrack(document, trackID, undoable: false) {
                                                              $0.volume = StudioMath.clamp((v * 20).rounded() / 20, 0, StudioMath.maxVolume)
                                                          }
                                                      }),
                                       in: 0...StudioMath.maxVolume,
                                       onEditingChanged: { began in if began { document.checkpoint() } })
                                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                            }
                            Text("Volume \(Int((track.volume * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } header: {
                            Text("Sound")
                        } footer: {
                            Text(track.kind == .video ? "This changes the sound of the videos on this track." : "This changes every sound on this track.")
                        }
                        Section {
                            Button("Delete track", role: .destructive) { confirmDelete = true }
                        }
                    }
                } else {
                    Text("This track is gone.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(track?.kind == .video ? "Video Track" : "Sound Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveName()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Delete this track and everything on it?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete track", role: .destructive) {
                    StudioActions.deleteTrack(document, trackID)
                    dismiss()
                }
            } message: {
                Text("You can undo this.")
            }
        }
        .onAppear { name = track?.name ?? "" }
        .onDisappear(perform: saveName)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let track, trimmed != track.name else { return }
        StudioActions.updateTrack(document, trackID) { $0.name = String(trimmed.prefix(40)) }
    }
}

// MARK: - Recording

struct StudioRecordSheet: View {
    @ObservedObject var document: ProjectDocument
    @ObservedObject var playback: StudioPlayback
    let onFinished: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = StudioRecorder()
    @AppStorage("studio.countdown") private var useCountdown = true
    @AppStorage("studio.playWhileRecording") private var playMovie = true
    @State private var startTime: Double = 0
    @State private var latency: Double = 0
    @State private var flow: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                status
                meter
                bigButton
                if recorder.phase == .idle {
                    VStack(spacing: 8) {
                        Toggle("3-2-1 countdown", isOn: $useCountdown)
                        Toggle("Play the movie while I talk", isOn: $playMovie)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: 360)
                }
                if recorder.permissionDenied {
                    VStack(spacing: 8) {
                        Text("Gale needs the microphone to record. Turn it on in Settings > Gale > Microphone.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
                if let problem = recorder.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Record Your Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancel()
                        dismiss()
                    }
                    .disabled(recorder.phase == .saving)
                }
            }
        }
        .interactiveDismissDisabled(recorder.isBusy)
        .onDisappear {
            if recorder.phase != .idle && recorder.phase != .saving {
                cancel()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch recorder.phase {
        case .idle:
            Text("Your voice goes on a sound track at \(StudioMath.timeLabel(playback.time, tenths: true)).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .countdown(let n):
            Text("\(n)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
        case .recording:
            Label(StudioMath.timeLabel(recorder.elapsed, tenths: true), systemImage: "record.circle")
                .font(.system(.title, design: .monospaced))
                .foregroundStyle(.red)
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving…")
            }
        }
    }

    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * CGFloat(recorder.level)))
                    .opacity(recorder.phase == .recording ? 1 : 0.25)
            }
        }
        .frame(maxWidth: 360)
        .frame(height: 14)
        .animation(.linear(duration: 0.05), value: recorder.level)
        .accessibilityHidden(true)
    }

    private var bigButton: some View {
        Button {
            switch recorder.phase {
            case .idle: begin()
            case .recording: finish()
            case .countdown: cancel()
            case .saving: break
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 78, height: 78)
                if recorder.phase == .recording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: recorder.phase == .idle ? "mic.fill" : "xmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .disabled(recorder.phase == .saving)
        .accessibilityLabel(recorder.phase == .recording ? "Stop recording" : "Start recording")
    }

    private func begin() {
        recorder.problem = nil
        flow?.cancel()
        flow = Task {
            guard await recorder.requestPermission() else { return }
            if useCountdown {
                guard await recorder.countdown() else { return }
            }
            if Task.isCancelled { return }
            do {
                // Start the microphone first: switching the sound setup can pause the movie.
                try recorder.start()
                latency = 0
                if playMovie {
                    playback.setMuted(true)
                    playback.play()
                    latency = StudioAudioSession.roundTripLatency
                }
                startTime = playback.time
            } catch {
                recorder.cancel()
                playback.setMuted(false)
                StudioAudioSession.usePlayback()
                recorder.problem = error.localizedDescription
            }
        }
    }

    private func finish() {
        playback.pause()
        playback.setMuted(false)
        guard let url = recorder.stop() else { return }
        let start = startTime
        let skip = latency
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let n = document.project.media.filter { $0.kind == .audio && $0.name.hasPrefix("My voice") }.count + 1
                let media = try await document.importMedia(from: url, kind: .audio, name: "My voice \(n)")
                let clip = StudioActions.addRecording(document, media: media, at: start, skip: skip)
                recorder.finishedSaving()
                onFinished(clip?.id)
                dismiss()
            } catch {
                recorder.finishedSaving()
                recorder.problem = "Couldn't save the recording. \(error.localizedDescription)"
            }
        }
    }

    private func cancel() {
        flow?.cancel()
        flow = nil
        if recorder.phase != .idle {
            playback.pause()
            playback.setMuted(false)
        }
        if recorder.phase != .saving {
            recorder.cancel()
        }
    }
}
