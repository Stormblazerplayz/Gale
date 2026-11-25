import Foundation
import GaleFormat

/// Lays a scene's frames out on one picture for games (Unity, Godot, Scratch...).
public enum SpriteSheet {
    public struct Layout: Hashable, Sendable {
        public let columns: Int
        public let rows: Int
        /// One frame's size in output pixels.
        public let cellWidth: Int
        public let cellHeight: Int
        public var width: Int { columns * cellWidth }
        public var height: Int { rows * cellHeight }
    }

    /// `columns` nil makes it as square as it can.
    public static func layout(frames: Int, cellWidth: Int, cellHeight: Int, columns: Int? = nil) -> Layout {
        let n = max(1, frames)
        let cols = min(n, max(1, columns ?? Int(Double(n).squareRoot().rounded(.up))))
        let rows = (n + cols - 1) / cols
        return Layout(columns: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
    }

    /// The sheet: frames left to right, top to bottom, each scaled by `scale`.
    /// With `transparent`, empty cells stay see-through (best for games); otherwise the scene background shows.
    public static func render(_ story: PixelStory, scene s: Int, scale: Int = 1, columns: Int? = nil,
                              transparent: Bool = true) -> (image: RGBAImage, layout: Layout) {
        let k = max(1, scale)
        guard story.scenes.indices.contains(s) else {
            let l = layout(frames: 1, cellWidth: story.width * k, cellHeight: story.height * k)
            return (RGBAImage(width: l.width, height: l.height), l)
        }
        let scene = story.scenes[s]
        let l = layout(frames: scene.frames.count, cellWidth: story.width * k, cellHeight: story.height * k, columns: columns)
        var sheet = RGBAImage(width: l.width, height: l.height)
        let colors = PixelRender.colors(story)
        let bg: Pixel32? = transparent ? nil : PixelRender.background(story, scene: scene)
        for (i, f) in scene.frames.enumerated() {
            let img = PixelRender.frame(f.cells, width: story.width, height: story.height, colors: colors, background: bg).scaled(by: k)
            sheet.draw(img, x: (i % l.columns) * l.cellWidth, y: (i / l.columns) * l.cellHeight)
        }
        return (sheet, l)
    }

    /// A small JSON description games can read: frame rectangles and how long each shows.
    public static func json(_ story: PixelStory, scene s: Int, layout l: Layout, imageName: String) -> String {
        guard story.scenes.indices.contains(s) else { return "{}" }
        let scene = story.scenes[s]
        var frames: [String] = []
        for (i, f) in scene.frames.enumerated() {
            let x = (i % l.columns) * l.cellWidth, y = (i / l.columns) * l.cellHeight
            let ms = Int((Double(f.hold) / Double(scene.fps) * 1000).rounded())
            frames.append("    {\"x\": \(x), \"y\": \(y), \"w\": \(l.cellWidth), \"h\": \(l.cellHeight), \"duration\": \(ms)}")
        }
        let name = imageName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "image": "\(name)",
          "width": \(l.width),
          "height": \(l.height),
          "fps": \(scene.fps),
          "frames": [
        \(frames.joined(separator: ",\n"))
          ]
        }

        """
    }
}
