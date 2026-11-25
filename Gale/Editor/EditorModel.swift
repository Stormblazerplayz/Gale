import Combine
import Foundation
import GaleCore
import GaleFormat
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case brush, eraser, fill, select, hair
    var id: String { rawValue }

    var title: String {
        switch self {
        case .brush: return "Draw"
        case .eraser: return "Erase"
        case .fill: return "Fill"
        case .select: return "Select"
        case .hair: return "Hair"
        }
    }

    var icon: String {
        switch self {
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .fill: return "drop.fill"
        case .select: return "lasso"
        case .hair: return "wind"
        }
    }
}

/// Everything about the editor that isn't saved in the project: the tool, the brush, onion skin, playback.
@MainActor
final class EditorModel: ObservableObject {
    @Published var tool: EditorTool = .brush
    @Published var brushKind: BrushKind = .pen { didSet { saveSettings() } }
    @Published var color: RGBA = .black { didSet { saveSettings() } }
    @Published var size: Double = 8 { didSet { saveSettings() } }
    @Published var opacity: Double = 1 { didSet { saveSettings() } }
    @Published var eraserSize: Double = 30 { didSet { saveSettings() } }
    /// 0 = off (draw exactly), 1 = smoothest. Starts light so faces and small details keep their shape.
    @Published var smoothing: Double = StrokeSmoothing.defaultAmount { didSet { saveSettings() } }
    /// Snap to corners while drawing and smooth less at bends, so zigzags and boxes stay crisp.
    @Published var sharpCorners: Bool = true { didSet { saveSettings() } }
    /// What the last stabilizer test found (nil until you take it).
    @Published var calibration: StabilizerCalibration.Result? { didSet { saveSettings() } }
    /// The raw touches (screen points) of the last line you drew, for the before and after preview.
    @Published var lastRawLine: [StrokePoint] = []
    /// Let fingers draw even after an Apple Pencil was used (otherwise fingers only move and zoom).
    @Published var fingerDraws: Bool = true { didSet { saveSettings() } }
    @Published var onion = OnionSettings() { didSet { saveSettings() } }
    @Published var recentColors: [RGBA] = [] { didSet { saveSettings() } }
    @Published var fillGapClose: Double = 4 { didSet { saveSettings() } }

    @Published var isPlaying = false
    @Published var playFrame = 0
    /// Strokes picked with the lasso (ids on the current frame and layer).
    @Published var selection: Set<String> = []
    /// Points of a hair outline being drawn.
    @Published var hairSide: HairSway.AttachSide = .top
    @Published var pencilSeen = false
    /// Set by the canvas so buttons can zoom it.
    var zoomToFit: (() -> Void)?

    var brush: Brush {
        if tool == .eraser { return Brush(kind: .eraser, color: .black, size: eraserSize, opacity: 1) }
        return Brush(kind: brushKind, color: color, size: size, opacity: opacity)
    }

    init() {
        loadSettings()
    }

    func useColor(_ c: RGBA) {
        color = c
        var list = recentColors.filter { $0 != c }
        list.insert(c, at: 0)
        recentColors = Array(list.prefix(12))
    }

    // MARK: Settings (kept between launches)

    private struct Saved: Codable {
        var brushKind: BrushKind
        var color: RGBA
        var size: Double
        var opacity: Double
        var eraserSize: Double
        var smoothing: Double
        var fingerDraws: Bool
        var onion: OnionSettings
        var recentColors: [RGBA]
        var fillGapClose: Double?
        /// Which smoothing tuning the saved amount was picked for. Missing means the old, much stronger one.
        var smoothingVersion: Int?
        var sharpCorners: Bool?
        var calibration: StabilizerCalibration.Result?
    }

    /// Bump when the smoothing math changes so much that an old saved amount would feel wrong.
    private static let smoothingVersion = 2

    private var loading = false

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: "gale.editor.settings"),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        loading = true
        brushKind = s.brushKind == .eraser ? .pen : s.brushKind
        color = s.color
        size = s.size
        opacity = s.opacity
        eraserSize = s.eraserSize
        // The old tuning started at a strong 0.55 that rounded off faces. Start everyone on the new light default once.
        smoothing = (s.smoothingVersion ?? 1) < Self.smoothingVersion ? StrokeSmoothing.defaultAmount : min(1, max(0, s.smoothing))
        fingerDraws = s.fingerDraws
        onion = s.onion
        recentColors = s.recentColors
        fillGapClose = s.fillGapClose ?? 4
        sharpCorners = s.sharpCorners ?? true
        calibration = s.calibration
        loading = false
        if (s.smoothingVersion ?? 1) < Self.smoothingVersion { saveSettings() }
    }

    private func saveSettings() {
        guard !loading else { return }
        let s = Saved(brushKind: brushKind, color: color, size: size, opacity: opacity, eraserSize: eraserSize,
                      smoothing: smoothing, fingerDraws: fingerDraws, onion: onion, recentColors: recentColors,
                      fillGapClose: fillGapClose, smoothingVersion: Self.smoothingVersion,
                      sharpCorners: sharpCorners, calibration: calibration)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "gale.editor.settings") }
    }
}
