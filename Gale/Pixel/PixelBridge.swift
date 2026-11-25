import CoreGraphics
import GaleFormat
import GalePixel
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Helpers that turn pixel pictures into things iOS can show and save, plus the retro look of pixel mode.

extension RGBAImage {
    /// The picture as a CGImage with hard pixels (straight alpha, sRGB).
    var cgImage: CGImage? {
        guard width > 0, height > 0, bytes.count == width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func pngData() -> Data? {
        guard let cg = cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

extension Pixel32 {
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

/// A pixel picture drawn with crisp square pixels, fitted into the space it gets.
struct PixelImageView: View {
    let image: RGBAImage

    var body: some View {
        if let cg = image.cgImage {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }
}

/// Words in the storytime pixel font (the same letters stories use).
struct PixelLabel: View {
    let text: String
    var color: Color = .white
    /// Height of one font dot in points.
    var dot: CGFloat = 3

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let size = PixelFont.size(lines: lines)
        let rows = CGFloat((lines.count - 1) * PixelFont.lineHeight + PixelFont.glyphRows)
        Canvas { ctx, _ in
            var path = Path()
            for (li, line) in lines.enumerated() {
                for (ci, ch) in line.enumerated() {
                    let glyph = PixelFont.rows(for: ch)
                    for (r, mask) in glyph.enumerated() where mask != 0 {
                        for c in 0..<PixelFont.glyphWidth where mask & (1 << (4 - c)) != 0 {
                            let x = CGFloat(ci * PixelFont.advance + c) * dot
                            let y = CGFloat(li * PixelFont.lineHeight + r) * dot
                            path.addRect(CGRect(x: x, y: y, width: dot, height: dot))
                        }
                    }
                }
            }
            ctx.fill(path, with: .color(color))
        }
        .frame(width: max(1, CGFloat(size.width)) * dot, height: rows * dot)
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

/// The colors of pixel mode: a dark arcade screen with bright buttons.
enum Retro {
    static let screen = Color(red: 0.09, green: 0.10, blue: 0.17)
    static let panel = Color(red: 0.14, green: 0.15, blue: 0.25)
    static let line = Color(red: 0.30, green: 0.32, blue: 0.48)
    static let yellow = Color(red: 1.0, green: 0.925, blue: 0.153)
    static let pink = Color(red: 1.0, green: 0.0, blue: 0.302)
    static let mint = Color(red: 0.0, green: 0.894, blue: 0.212)
    static let purple = Theme.accent
    static let sky = Color(red: 0.161, green: 0.678, blue: 1.0)

    static func font(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A chunky arcade button: a hard shadow under it that disappears when pressed.
struct RetroButtonStyle: ButtonStyle {
    var color: Color = Retro.purple
    var text: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        configuration.label
            .font(Retro.font(15))
            .foregroundStyle(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(color, in: Rectangle())
            .overlay(Rectangle().strokeBorder(.black.opacity(0.55), lineWidth: 2))
            .background(Rectangle().fill(.black.opacity(0.6)).offset(x: down ? 0 : 3, y: down ? 0 : 3))
            .offset(x: down ? 3 : 0, y: down ? 3 : 0)
    }
}

/// Thin dark lines across the screen, like an old TV.
struct Scanlines: View {
    var spacing: CGFloat = 3
    var opacity: Double = 0.16

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += spacing
            }
            ctx.fill(path, with: .color(.black.opacity(opacity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// See-through squares, shown behind empty pixels.
struct Checkerboard: View {
    var square: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            var path = Path()
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : square
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: square, height: square))
                    x += square * 2
                }
                y += square
                row += 1
            }
            ctx.fill(path, with: .color(Color(white: 0.78)))
        }
        .allowsHitTesting(false)
    }
}

/// One palette color as a square chip; index 0 shows as see-through.
struct PaletteChip: View {
    let color: RGBA
    let isClear: Bool
    var selected = false
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            if isClear {
                Checkerboard(square: size / 4)
                Image(systemName: "eraser").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.black.opacity(0.7))
            } else {
                Rectangle().fill(color.color)
            }
        }
        .frame(width: size, height: size)
        .overlay(Rectangle().strokeBorder(selected ? Retro.yellow : .black.opacity(0.5), lineWidth: selected ? 3 : 1))
        .scaleEffect(selected ? 1.12 : 1)
    }
}

extension PixelStory {
    /// A picture of one frame with its scene's background, for thumbnails and covers.
    func thumbnail(scene s: Int, frame f: Int = 0) -> RGBAImage {
        guard scenes.indices.contains(s), !scenes[s].frames.isEmpty else { return RGBAImage(width: width, height: height) }
        let scene = scenes[s]
        let frame = scene.frames[min(max(0, f), scene.frames.count - 1)]
        return PixelRender.frame(frame.cells, width: width, height: height, colors: PixelRender.colors(self),
                                 background: PixelRender.background(self, scene: scene))
    }

    /// The cover picture for the project library: the first frame of the first scene, scaled up crisply.
    func coverImage(maxSide: Int = 480) -> RGBAImage {
        let k = max(1, maxSide / max(width, height))
        return thumbnail(scene: 0).scaled(by: k)
    }
}
