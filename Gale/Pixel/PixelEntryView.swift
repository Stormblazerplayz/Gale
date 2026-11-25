import GaleFormat
import GalePixel
import SwiftUI

/// The home screen card for pixel mode: a tiny arcade screen with a bird flapping across it.
struct PixelStoryCard: View {
    var body: some View {
        VStack(spacing: 10) {
            PixelStoryArt()
                .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Retro.purple, lineWidth: 3))
            Text("Pixel Storytime").font(.headline)
            Text("Pixel art stories").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The moving arcade picture on the Pixel Storytime card (the home screen frames it like the other cards).
struct PixelStoryArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Retro.screen
            TimelineView(.periodic(from: .now, by: reduceMotion ? 3600 : 1.0 / 8)) { timeline in
                let tick = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * 8)
                ArcadeScene(tick: tick)
            }
            Scanlines()
        }
    }
}

/// A little pixel sprite drawn from rows of letters.
struct Sprite {
    let rows: [String]
    let colors: [Character: Color]

    func draw(in ctx: GraphicsContext, at origin: CGPoint, dot: CGFloat) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let c = colors[ch] else { continue }
                ctx.fill(Path(CGRect(x: origin.x + CGFloat(x) * dot, y: origin.y + CGFloat(y) * dot, width: dot, height: dot)),
                         with: .color(c))
            }
        }
    }

    var width: Int { rows.map(\.count).max() ?? 0 }

    static let palette: [Character: Color] = [
        "k": Color(red: 0.08, green: 0.08, blue: 0.12),
        "b": Retro.sky,
        "w": .white,
        "y": Retro.yellow,
        "p": Retro.pink,
    ]
    /// Gale's bird, wings up and wings down.
    static let birdUp = Sprite(rows: [
        "..kk......",
        ".kbbk.....",
        ".kbbbk.kk.",
        "kbbbbbkbwk",
        "kbbbbbbbbk",
        ".kbbbbbbyy",
        "..kkkkkk..",
    ], colors: palette)
    static let birdDown = Sprite(rows: [
        "..........",
        "........kk",
        ".kkkkk.kwk",
        "kbbbbbkbbk",
        "kbbbbbbbbk",
        ".kbbbbbbyy",
        "..kbbk.k..",
        "...kk.....",
    ], colors: palette)
}

/// Stars, a ground line and the flapping bird; `tick` counts eighths of a second.
private struct ArcadeScene: View {
    let tick: Int

    var body: some View {
        Canvas { ctx, size in
            let dot = max(2, (size.height / 36).rounded(.down))
            // Twinkling stars at fixed spots.
            for i in 0..<14 {
                let sx = CGFloat((i * 53 + 17) % 97) / 97 * size.width
                let sy = CGFloat((i * 31 + 7) % 61) / 61 * size.height * 0.6
                let on = (tick + i * 3) % 7 != 0
                if on { ctx.fill(Path(CGRect(x: sx.rounded(.down), y: sy.rounded(.down), width: dot, height: dot)), with: .color(.white.opacity(0.8))) }
            }
            // Ground.
            let ground = size.height - dot * 4
            ctx.fill(Path(CGRect(x: 0, y: ground, width: size.width, height: dot)), with: .color(Retro.mint))
            for x in Swift.stride(from: CGFloat(tick % 4) * -dot * 2, to: size.width, by: dot * 8) {
                ctx.fill(Path(CGRect(x: x, y: ground + dot * 2, width: dot * 3, height: dot)), with: .color(Retro.mint.opacity(0.5)))
            }
            // The bird flies across and bobs.
            let sprite = tick % 2 == 0 ? Sprite.birdUp : Sprite.birdDown
            let span = size.width + CGFloat(sprite.width) * dot
            let x = (CGFloat(tick % 64) / 64 * span - CGFloat(sprite.width) * dot).rounded(.down)
            let y = (size.height * 0.35 + (tick % 4 < 2 ? 0 : dot)).rounded(.down)
            sprite.draw(in: ctx, at: CGPoint(x: x, y: y), dot: dot)
        }
        .accessibilityHidden(true)
    }
}

/// The start screen of pixel mode: the title types itself in, then you pick a grid and colors.
struct PixelEntryView: View {
    @EnvironmentObject var library: ProjectLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onCreate: (URL) -> Void

    struct GridChoice: Hashable, Identifiable {
        let name: String
        let width: Int
        let height: Int
        var id: String { "\(width)x\(height)" }
    }

    static let grids = [
        GridChoice(name: "Tiny", width: 16, height: 16),
        GridChoice(name: "Classic", width: 32, height: 32),
        GridChoice(name: "Wide", width: 64, height: 36),
        GridChoice(name: "Tall", width: 36, height: 64),
        GridChoice(name: "Detailed", width: 64, height: 64),
        GridChoice(name: "Huge", width: 128, height: 128),
    ]

    @State private var name = "My pixel story"
    @State private var grid = PixelEntryView.grids[1]
    @State private var palette = PixelPalette.pico8
    @State private var titleShown = 0
    @State private var blink = true
    @State private var error: String?

    private let title = "PIXEL STORYTIME"

    var body: some View {
        ZStack {
            Retro.screen.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    header
                    nameField
                    section("GRID") { gridPicker }
                    section("COLORS") { palettePicker }
                    if let error { Text(error).font(Retro.font(13, weight: .bold)).foregroundStyle(Retro.pink) }
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            Scanlines().ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom) {
            // Always on screen, however long the lists get.
            Button {
                create()
            } label: {
                Label("START", systemImage: "play.fill").frame(minWidth: 180)
            }
            .buttonStyle(RetroButtonStyle(color: Retro.yellow, text: .black))
            .accessibilityIdentifier("createPixelStory")
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Retro.panel.opacity(0.95).ignoresSafeArea())
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .black))
            }
            .buttonStyle(RetroButtonStyle(color: Retro.panel))
            .accessibilityLabel("Close")
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .task { await typeTitle() }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Sprite.birdUp.preview(dot: 6)
                .padding(.top, 40)
            HStack(spacing: 0) {
                PixelLabel(text: String(title.prefix(titleShown)), color: Retro.yellow, dot: 4)
                PixelLabel(text: "_", color: .white, dot: 4).opacity(blink ? 1 : 0)
            }
            .frame(height: 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pixel Storytime")
            Text("Draw tiny pixel scenes, then chain them into a story with words and speech bubbles.")
                .font(Retro.font(14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }

    private var nameField: some View {
        TextField("Name", text: $name)
            .font(Retro.font(18, weight: .bold))
            .foregroundStyle(.white)
            .padding(12)
            .background(Retro.panel, in: Rectangle())
            .overlay(Rectangle().strokeBorder(Retro.line, lineWidth: 2))
            .accessibilityIdentifier("pixelStoryName")
    }

    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PixelLabel(text: label, color: Retro.sky, dot: 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gridPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
            ForEach(Self.grids) { g in
                Button {
                    grid = g
                } label: {
                    VStack(spacing: 6) {
                        GridIcon(width: g.width, height: g.height)
                            .frame(height: 54)
                        Text(g.name).font(Retro.font(14))
                        Text("\(g.width) × \(g.height)").font(Retro.font(11, weight: .semibold)).opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(grid == g ? Retro.purple : Retro.panel, in: Rectangle())
                    .overlay(Rectangle().strokeBorder(grid == g ? Retro.yellow : Retro.line, lineWidth: grid == g ? 3 : 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(g.name), \(g.width) by \(g.height)")
                .accessibilityAddTraits(grid == g ? .isSelected : [])
            }
        }
    }

    private var palettePicker: some View {
        VStack(spacing: 10) {
            ForEach(PixelPalette.all) { p in
                Button {
                    palette = p
                } label: {
                    HStack(spacing: 10) {
                        Text(p.name).font(Retro.font(14)).frame(width: 120, alignment: .leading)
                        HStack(spacing: 0) {
                            ForEach(Array(p.colors.prefix(32).enumerated()), id: \.offset) { _, c in
                                Rectangle().fill(c.color)
                            }
                        }
                        .frame(height: 22)
                        .overlay(Rectangle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
                        Text("\(p.colors.count)").font(Retro.font(11, weight: .semibold)).opacity(0.7).frame(width: 26)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(palette == p ? Retro.purple : Retro.panel, in: Rectangle())
                    .overlay(Rectangle().strokeBorder(palette == p ? Retro.yellow : Retro.line, lineWidth: palette == p ? 3 : 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(p.name), \(p.colors.count) colors")
                .accessibilityAddTraits(palette == p ? .isSelected : [])
            }
        }
    }

    private func typeTitle() async {
        if reduceMotion {
            titleShown = title.count
            return
        }
        titleShown = 0
        for i in 1...title.count {
            try? await Task.sleep(nanoseconds: 55_000_000)
            if Task.isCancelled { return }
            titleShown = i
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 450_000_000)
            blink.toggle()
        }
    }

    private func create() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let story = PixelStory(width: grid.width, height: grid.height, palette: palette)
        do {
            let url = try library.createPixelStory(name: clean.isEmpty ? "My pixel story" : clean, story: story)
            onCreate(url)
        } catch {
            self.error = "Couldn't make the story: \(error.localizedDescription)"
        }
    }
}

/// A small grid drawing showing a size's shape.
private struct GridIcon: View {
    let width: Int
    let height: Int

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / CGFloat(width), size.height / CGFloat(height))
            let w = CGFloat(width) * k, h = CGFloat(height) * k
            let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            ctx.fill(Path(rect), with: .color(.white.opacity(0.12)))
            // Lines every 8 cells, so bigger grids look busier.
            var path = Path()
            for i in Swift.stride(from: 8, to: width, by: 8) {
                let x = rect.minX + CGFloat(i) * k
                path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for i in Swift.stride(from: 8, to: height, by: 8) {
                let y = rect.minY + CGFloat(i) * k
                path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1)
            ctx.stroke(Path(rect), with: .color(.white), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}

extension Sprite {
    /// The sprite as a view.
    func preview(dot: CGFloat) -> some View {
        Canvas { ctx, _ in draw(in: ctx, at: .zero, dot: dot) }
            .frame(width: CGFloat(width) * dot, height: CGFloat(rows.count) * dot)
            .accessibilityHidden(true)
    }
}
