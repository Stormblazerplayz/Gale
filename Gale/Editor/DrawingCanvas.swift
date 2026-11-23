import CoreImage
import GaleCore
import GaleFormat
import SwiftUI
import UIKit

/// What the canvas needs to show. Built from the document and the editor model on every SwiftUI update.
struct CanvasState: Equatable {
    var project: GaleProject
    var frameIndex: Int
    var layerID: String
    var onion: OnionSettings
    var tool: EditorTool
    var brush: Brush
    var smoothing: Double
    var fingerDraws: Bool
    var selection: Set<String>
    var hairSide: HairSway.AttachSide
    var fillGap: Double
}

/// Things the canvas asks the editor to do.
@MainActor
struct CanvasActions {
    var commitStroke: (Stroke) -> Void
    var fill: (Vec2) -> Void
    var select: (Set<String>) -> Void
    var moveSelection: (Vec2) -> Void
    var addHair: ([Double]) -> Void
    var dropStash: (String, Vec2) -> Void
    var undo: () -> Void
    var redo: () -> Void
    var toggleEraser: () -> Void
    var pencilSeen: () -> Void
    var blocked: (String) -> Void
}

/// The drawing canvas: a zoomable sheet of paper with the layers stacked on it.
struct DrawingCanvas: UIViewRepresentable {
    var state: CanvasState
    var actions: CanvasActions
    var registerZoom: ((@escaping () -> Void) -> Void)?

    func makeUIView(context: Context) -> CanvasScrollView {
        let v = CanvasScrollView()
        v.canvas.actions = actions
        v.canvas.apply(state)
        registerZoom?({ [weak v] in v?.zoomToFit(animated: true) })
        return v
    }

    func updateUIView(_ uiView: CanvasScrollView, context: Context) {
        uiView.canvas.actions = actions
        uiView.canvas.apply(state)
        uiView.contentSizeChanged()
    }
}

/// Holds the paper and moves it around. Two fingers pinch to zoom and drag to move. One finger or the Pencil draws.
///
/// The paper keeps its real size (1 point = 1 canvas pixel) and is shown smaller or bigger with a scale,
/// always placed from the middle of this view, so it starts centered and filling the space.
final class CanvasScrollView: UIView, UIGestureRecognizerDelegate {
    let canvas = CanvasContentView()
    private(set) var zoomScale: CGFloat = 1
    /// How far the middle of the paper is from the middle of this view, in screen points.
    private var offset: CGPoint = .zero
    /// True once you pinch or move the paper yourself, so turning the iPad doesn't undo it.
    private var userMoved = false
    private var lastBoundsSize: CGSize = .zero
    private var lastCanvasSize: CGSize = .zero
    private var pinchStartScale: CGFloat = 1
    private var pinchAnchor: CGPoint = .zero
    private let pinch = UIPinchGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    static let maxZoom: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground
        clipsToBounds = true
        isMultipleTouchEnabled = true
        addSubview(canvas)

        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.addTarget(self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = direct
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 3
        pan.allowedTouchTypes = direct
        pan.delegate = self
        addGestureRecognizer(pan)

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undoTapped))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = direct
        addGestureRecognizer(undoTap)
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redoTapped))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = direct
        addGestureRecognizer(redoTap)
        let fitTap = UITapGestureRecognizer(target: self, action: #selector(fitTapped))
        fitTap.numberOfTouchesRequired = 2
        fitTap.numberOfTapsRequired = 2
        fitTap.allowedTouchTypes = direct
        addGestureRecognizer(fitTap)
        undoTap.require(toFail: fitTap)

        accessibilityIdentifier = "canvasArea"
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// The back gesture this screen turned off, so it can be turned on again when you leave.
    private weak var pausedBackGesture: UIGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            pauseFullScreenBackSwipe()
        } else {
            pausedBackGesture?.isEnabled = true
            pausedBackGesture = nil
        }
    }

    /// Since iPadOS 26 a swipe to the right anywhere on the screen goes back a page. On a drawing screen
    /// that steals every left-to-right line, so it's turned off here. The swipe from the very left edge still goes back.
    private func pauseFullScreenBackSwipe() {
        var responder: UIResponder? = self
        var nav: UINavigationController?
        while let r = responder {
            if let vc = r as? UIViewController, let n = vc.navigationController ?? (vc as? UINavigationController) {
                nav = n
                break
            }
            responder = r.next
        }
        guard let nav else { return }
        let key = "interactiveContentPopGestureRecognizer"
        guard nav.responds(to: NSSelectorFromString(key)),
              let g = nav.value(forKey: key) as? UIGestureRecognizer else { return }
        if g.isEnabled {
            g.isEnabled = false
            pausedBackGesture = g
        }
    }

    @objc private func undoTapped() { canvas.cancelStroke(); canvas.actions?.undo() }
    @objc private func redoTapped() { canvas.cancelStroke(); canvas.actions?.redo() }
    @objc private func fitTapped() { zoomToFit(animated: true) }

    /// Touches anywhere in the gray area go to the paper, so a line can start just off its edge.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? canvas : hit
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === pinch && other === pan) || (g === pan && other === pinch)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            if userMoved { clampOffset() } else { fitValues() }
        }
        applyPlacement()
    }

    /// Called after the paper may have changed size (a new project, or a different canvas size).
    func contentSizeChanged() {
        let size = canvas.bounds.size
        if size != lastCanvasSize {
            lastCanvasSize = size
            fitValues()
            applyPlacement()
        }
    }

    /// The scale that shows the whole paper with a small margin.
    var fitScale: CGFloat {
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        let margin: CGFloat = bounds.width > 500 ? 24 : 12
        let fit = min((bounds.width - margin * 2) / size.width, (bounds.height - margin * 2) / size.height)
        return max(0.01, fit)
    }

    private var minZoom: CGFloat { max(0.01, fitScale * 0.4) }

    func zoomToFit(animated: Bool) {
        fitValues()
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.applyPlacement()
            } completion: { _ in self.canvas.updateLiveScale() }
        } else {
            applyPlacement()
        }
    }

    private func fitValues() {
        zoomScale = fitScale
        offset = .zero
        userMoved = false
    }

    private func applyPlacement() {
        canvas.transform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
        canvas.center = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        canvas.zoom = zoomScale
        canvas.updateLiveScale()
    }

    /// Keeps at least part of the paper on screen so it can't get lost.
    private func clampOffset() {
        let size = canvas.bounds.size
        let keep: CGFloat = 80
        let maxX = max(0, size.width * zoomScale / 2 + bounds.width / 2 - keep)
        let maxY = max(0, size.height * zoomScale / 2 + bounds.height / 2 - keep)
        offset.x = min(maxX, max(-maxX, offset.x))
        offset.y = min(maxY, max(-maxY, offset.y))
    }

    /// Where a point on screen lands on the paper, in canvas pixels.
    private func paperPoint(_ p: CGPoint) -> CGPoint {
        let size = canvas.bounds.size
        return CGPoint(x: (p.x - bounds.midX - offset.x) / zoomScale + size.width / 2,
                       y: (p.y - bounds.midY - offset.y) / zoomScale + size.height / 2)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let size = canvas.bounds.size
        switch g.state {
        case .began:
            canvas.cancelStroke()
            pinchStartScale = zoomScale
            pinchAnchor = paperPoint(g.location(in: self))
            userMoved = true
        case .changed:
            guard g.numberOfTouches >= 2 else { return }
            zoomScale = min(Self.maxZoom, max(minZoom, pinchStartScale * g.scale))
            // Keep the spot between your fingers under your fingers while zooming and moving.
            let loc = g.location(in: self)
            offset = CGPoint(x: loc.x - bounds.midX - (pinchAnchor.x - size.width / 2) * zoomScale,
                             y: loc.y - bounds.midY - (pinchAnchor.y - size.height / 2) * zoomScale)
            clampOffset()
            applyPlacement()
        case .ended, .cancelled, .failed:
            // Zoomed out close to the fit size: snap back to fit, so the paper sits nicely in the middle again.
            if abs(zoomScale - fitScale) / fitScale < 0.08 || zoomScale < fitScale {
                zoomToFit(animated: true)
            }
        default:
            break
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            canvas.cancelStroke()
            userMoved = true
        case .changed:
            // While pinching, the pinch already moves the paper with your fingers.
            if pinch.state == .began || pinch.state == .changed {
                g.setTranslation(.zero, in: self)
                return
            }
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            offset.x += t.x
            offset.y += t.y
            clampOffset()
            applyPlacement()
        default:
            break
        }
    }
}

/// The paper itself, at canvas size in points (1 point = 1 canvas pixel). Holds the stacked layer pictures.
final class CanvasContentView: UIView, UIPencilInteractionDelegate, UIDropInteractionDelegate {
    var actions: CanvasActions?
    var zoom: CGFloat = 1

    private let paper = UIView()
    private let onionView = UIImageView()
    private let belowView = UIImageView()
    private let currentView = UIImageView()
    private let floatingView = UIImageView()
    private let aboveView = UIImageView()
    private let liveLayer = CAShapeLayer()
    private let overlayLayer = CAShapeLayer()
    private let hairLayer = CAShapeLayer()

    private var state: CanvasState?
    private let renderQueue = DispatchQueue(label: "gale.canvas.render", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var renderScale: CGFloat = 1

    // What each picture currently shows, so only changed parts are drawn again.
    private var belowKey: Int?
    private var aboveKey: Int?
    private var currentKey: Int?
    private var currentCel: Cel?
    private var onionKey: Int?
    private var hiddenIDs: Set<String> = []

    // Drawing in progress.
    private var activeTouch: UITouch?
    private var stabilizer: StrokeStabilizer?
    private var livePoints: [StrokePoint] = []
    private var strokeStart: TimeInterval = 0
    private var lassoPoints: [CGPoint] = []
    private var moveStart: CGPoint?
    private var moveOffset: CGPoint = .zero
    private var pencilSeen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        paper.isUserInteractionEnabled = false
        for v in [onionView, belowView, currentView, floatingView, aboveView] {
            v.isUserInteractionEnabled = false
            v.contentMode = .scaleToFill
            // Smooth when shown smaller than drawn (zoomed out), instead of jagged stair steps.
            v.layer.minificationFilter = .trilinear
            v.layer.magnificationFilter = .linear
        }
        addSubview(paper)
        addSubview(onionView)
        addSubview(belowView)
        addSubview(currentView)
        addSubview(floatingView)
        addSubview(aboveView)
        liveLayer.fillRule = .nonZero
        layer.addSublayer(liveLayer)
        hairLayer.fillColor = UIColor.systemTeal.withAlphaComponent(0.12).cgColor
        hairLayer.strokeColor = UIColor.systemTeal.cgColor
        hairLayer.lineWidth = 2
        hairLayer.lineDashPattern = [8, 6]
        layer.addSublayer(hairLayer)
        overlayLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        overlayLayer.strokeColor = UIColor.systemBlue.cgColor
        overlayLayer.lineWidth = 2
        overlayLayer.lineDashPattern = [6, 5]
        layer.addSublayer(overlayLayer)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        addInteraction(UIDropInteraction(delegate: self))

        isAccessibilityElement = true
        accessibilityIdentifier = "canvas"
        accessibilityLabel = "Drawing paper"
        accessibilityTraits = .allowsDirectInteraction
        if UITestMode.on {
            NotificationCenter.default.addObserver(self, selector: #selector(drawTestScribble), name: UITestMode.scribble, object: nil)
        }
    }

    // MARK: Accessibility (also how the UI tests check the canvas)

    /// Sharpest bend of the last finished line, in degrees, measured every 4 screen points.
    private(set) var lastBend: Double = 0

    override var accessibilityValue: String? {
        get {
            guard let s = state, s.project.frames.indices.contains(s.frameIndex) else { return "empty" }
            let cel = s.project.frames[s.frameIndex].cel(s.layerID)
            let ink = Self.inkPixels(currentView.image?.cgImage)
            let onion = onionView.image == nil ? "off" : "on"
            return "strokes \(cel.strokes.count), fills \(cel.fills.count), ink \(ink), onion \(onion), bend \(Int(lastBend.rounded())), zoom \(String(format: "%.2f", zoom))"
        }
        set {}
    }

    /// How many pixels of a small copy of the picture have paint on them.
    nonisolated static func inkPixels(_ image: CGImage?) -> Int {
        guard let image else { return 0 }
        let w = 160
        let h = max(1, Int(Double(w) * Double(image.height) / Double(max(1, image.width))))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var n = 0
        for i in 0..<(w * h) where px[i * 4 + 3] > 24 { n += 1 }
        return n
    }

    /// UI tests only: draws a quick, shaky wave through the same steps as a real finger,
    /// so the test can check that the wobble comes out smooth.
    @objc private func drawTestScribble() {
        guard let s = state, s.tool == .brush || s.tool == .eraser else { return }
        let z = Double(max(0.05, zoom))
        let size = s.project.canvas
        // A wave about 300 points wide on screen, around the middle of the paper.
        let cx = size.width / 2, cy = size.height / 2
        var pts: [StrokePoint] = []
        var seed: UInt64 = 42
        func wobble() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 33) / Double(1 << 31)) * 2 - 1
        }
        for i in 0...150 {
            // Screen points with a shaky hand (1.5 points of wobble), then turned into canvas pixels.
            let x = Double(i) * 2
            let sx = x - 150 + wobble() * 1.5
            let sy = sin(x / 40) * 40 + wobble() * 1.5
            pts.append(StrokePoint(x: cx + sx / z, y: cy + sy / z, pressure: 0.5, time: Double(i) / 120))
        }
        guard beginLine(pts[0]) else { return }
        for p in pts.dropFirst() { continueLine([p]) }
        finishLine(pts[pts.count - 1])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    // MARK: State

    func apply(_ new: CanvasState) {
        let old = state
        state = new
        let w = CGFloat(new.project.canvas.width), h = CGFloat(new.project.canvas.height)
        if bounds.size != CGSize(width: w, height: h) {
            // The holder view places and scales the paper; here it only gets its real size.
            bounds = CGRect(x: 0, y: 0, width: w, height: h)
            for v in [paper, onionView, belowView, currentView, floatingView, aboveView] { v.frame = bounds }
            liveLayer.frame = bounds
            overlayLayer.frame = bounds
            hairLayer.frame = bounds
            // Big enough to look sharp when zoomed in, small enough to stay fast.
            renderScale = max(0.5, min(1.5, 3000 / max(w, h)))
            layer.shadowPath = UIBezierPath(rect: bounds).cgPath
            belowKey = nil; aboveKey = nil; currentKey = nil; onionKey = nil
        }
        paper.backgroundColor = new.project.canvas.background.uiColor
        if old?.frameIndex != new.frameIndex || old?.layerID != new.layerID { hiddenIDs = [] }
        refreshPictures()
        updateOverlays()
    }

    private func layerSplit(_ s: CanvasState) -> (below: [Layer], current: Layer?, above: [Layer]) {
        guard let i = s.project.layers.firstIndex(where: { $0.id == s.layerID }) else {
            return (s.project.layers, nil, [])
        }
        return (Array(s.project.layers[..<i]), s.project.layers[i], Array(s.project.layers[(i + 1)...]))
    }

    private func refreshPictures() {
        guard let s = state, s.project.frames.indices.contains(s.frameIndex) else { return }
        let frame = s.project.frames[s.frameIndex]
        let split = layerSplit(s)
        let canvasSize = s.project.canvas
        let scale = renderScale

        func key(_ layers: [Layer]) -> Int {
            var h = Hasher()
            h.combine(s.frameIndex)
            h.combine(frame.id)
            for l in layers where l.visible {
                h.combine(l)
                h.combine(frame.cels[l.id])
            }
            h.combine(canvasSize.width)
            h.combine(canvasSize.height)
            return h.finalize()
        }

        let bk = key(split.below)
        if bk != belowKey {
            belowKey = bk
            render(into: belowView, layers: split.below, frame: frame, canvas: canvasSize, scale: scale) { [weak self] in self?.belowKey == bk }
        }
        let ak = key(split.above)
        if ak != aboveKey {
            aboveKey = ak
            render(into: aboveView, layers: split.above, frame: frame, canvas: canvasSize, scale: scale) { [weak self] in self?.aboveKey == ak }
        }

        if let current = split.current {
            var cel = frame.cel(current.id)
            if !hiddenIDs.isEmpty { cel.strokes.removeAll { hiddenIDs.contains($0.id) }; cel.fills.removeAll { hiddenIDs.contains($0.id) } }
            var h = Hasher()
            h.combine(frame.id)
            h.combine(current.id)
            h.combine(current.visible)
            h.combine(cel)
            h.combine(canvasSize.width)
            let ck = h.finalize()
            currentView.alpha = current.visible ? CGFloat(current.opacity) : 0
            if ck != currentKey {
                currentKey = ck
                renderCurrent(cel, canvas: canvasSize, scale: scale)
            }
        } else {
            currentView.image = nil
            currentKey = nil
            currentCel = nil
        }
        refreshOnion()
    }

    private func render(into view: UIImageView, layers: [Layer], frame: Frame, canvas: GaleCanvas, scale: CGFloat,
                        stillWanted: @escaping () -> Bool) {
        let visible = layers.filter { $0.visible && !frame.cel($0.id).isEmpty }
        if visible.isEmpty {
            view.image = nil
            return
        }
        var temp = GaleProject(id: "render", name: "render", canvas: canvas, fps: 12)
        temp.layers = visible
        temp.frames = [frame]
        renderQueue.async {
            var opts = FrameRenderer.Options()
            opts.background = false
            let img = FrameRenderer.image(temp, frameIndex: 0, scale: scale, options: opts)
            DispatchQueue.main.async { [weak view] in
                guard let view, stillWanted() else { return }
                view.image = img.map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
            }
        }
    }

    /// Draws the current layer. When the only change is one new stroke on top, it's added to the old picture
    /// instead of drawing everything again, so drawing stays fast even with lots of strokes.
    private func renderCurrent(_ cel: Cel, canvas: GaleCanvas, scale: CGFloat) {
        let previous = currentCel
        let oldImage = currentView.image?.cgImage
        currentCel = cel
        var addOnly: [Stroke]? = nil
        if let previous, let oldImage, cel.fills == previous.fills,
           cel.strokes.count > previous.strokes.count,
           Array(cel.strokes.prefix(previous.strokes.count)) == previous.strokes {
            addOnly = Array(cel.strokes.dropFirst(previous.strokes.count))
        }
        let base = addOnly != nil ? oldImage : nil
        renderQueue.async {
            guard let ctx = FrameRenderer.makeContext(canvasWidth: canvas.width, canvasHeight: canvas.height, scale: scale) else { return }
            if let base, let add = addOnly {
                ctx.saveGState()
                ctx.scaleBy(x: 1 / scale, y: -1 / scale)
                ctx.translateBy(x: 0, y: -CGFloat(base.height))
                ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
                ctx.restoreGState()
                for s in add { StrokeRenderer.draw(s, in: ctx) }
            } else {
                StrokeRenderer.draw(cel, in: ctx)
            }
            let img = ctx.makeImage()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentCel == cel else { return }
                self.currentView.image = img.map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
                // The finished stroke is now in the picture, so the preview can go.
                if self.activeTouch == nil { self.liveLayer.path = nil }
            }
        }
    }

    private func refreshOnion() {
        guard let s = state else { return }
        let ghosts = s.onion.on ? OnionSkin.ghosts(current: s.frameIndex, frameCount: s.project.frames.count, settings: s.onion) : []
        var h = Hasher()
        h.combine(s.onion)
        for g in ghosts {
            h.combine(g)
            h.combine(s.project.frames[g.frameIndex])
        }
        h.combine(s.project.layers)
        let k = h.finalize()
        guard k != onionKey else { return }
        onionKey = k
        if ghosts.isEmpty {
            onionView.image = nil
            return
        }
        let project = s.project
        let scale = max(0.25, renderScale * 0.5)
        let ci = ciContext
        renderQueue.async {
            guard let ctx = FrameRenderer.makeContext(canvasWidth: project.canvas.width, canvasHeight: project.canvas.height, scale: scale) else { return }
            for g in ghosts {
                var opts = FrameRenderer.Options()
                opts.background = false
                opts.tint = g.tint
                guard var img = FrameRenderer.image(project, frameIndex: g.frameIndex, scale: scale, options: opts) else { continue }
                if g.blur > 0, let frosted = FrameRenderer.frosted(img, blur: g.blur * Double(scale) * 1.5, context: ci) {
                    img = frosted
                }
                ctx.saveGState()
                ctx.setAlpha(CGFloat(g.opacity))
                ctx.scaleBy(x: 1 / scale, y: -1 / scale)
                ctx.translateBy(x: 0, y: -CGFloat(img.height))
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                ctx.restoreGState()
            }
            let out = ctx.makeImage()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.onionKey == k else { return }
                self.onionView.image = out.map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
            }
        }
    }

    private func updateOverlays() {
        guard let s = state else { return }
        // Hair regions show while the hair tool is on.
        if s.tool == .hair {
            let path = CGMutablePath()
            for r in s.project.hair where r.layer == s.layerID {
                addPolygon(r.polygon, to: path)
            }
            hairLayer.path = path
        } else {
            hairLayer.path = nil
        }
        // Selection box.
        if s.tool == .select, !s.selection.isEmpty, s.project.frames.indices.contains(s.frameIndex) {
            let strokes = s.project.frames[s.frameIndex].cel(s.layerID).strokes.filter { s.selection.contains($0.id) }
            let b = Geometry.bounds(of: strokes)
            if !b.isEmpty {
                overlayLayer.path = CGPath(rect: CGRect(x: b.minX + moveOffset.x, y: b.minY + moveOffset.y, width: b.width, height: b.height).insetBy(dx: -6, dy: -6), transform: nil)
            }
        } else if lassoPoints.isEmpty {
            overlayLayer.path = nil
        }
        updateLiveScale()
    }

    private func addPolygon(_ flat: [Double], to path: CGMutablePath) {
        guard flat.count >= 6 else { return }
        path.move(to: CGPoint(x: flat[0], y: flat[1]))
        var i = 2
        while i + 1 < flat.count {
            path.addLine(to: CGPoint(x: flat[i], y: flat[i + 1]))
            i += 2
        }
        path.closeSubpath()
    }

    func updateLiveScale() {
        let scale = traitCollection.displayScale * max(0.1, zoom)
        for l in [liveLayer, overlayLayer, hairLayer] { l.contentsScale = min(scale, 8) }
        overlayLayer.lineWidth = 2 / max(0.05, zoom)
        hairLayer.lineWidth = 2 / max(0.05, zoom)
        overlayLayer.lineDashPattern = [NSNumber(value: Double(6 / max(0.05, zoom))), NSNumber(value: Double(5 / max(0.05, zoom)))]
        hairLayer.lineDashPattern = overlayLayer.lineDashPattern
    }

    // MARK: Touches

    private func accepts(_ touch: UITouch) -> Bool {
        if touch.type == .pencil {
            if !pencilSeen {
                pencilSeen = true
                actions?.pencilSeen()
            }
            return true
        }
        guard touch.type == .direct else { return false }
        // Palm rejection: once the Pencil is used, fingers only draw if you allow it.
        if pencilSeen, let s = state, !s.fingerDraws { return false }
        return true
    }

    private func point(for touch: UITouch, start: TimeInterval) -> StrokePoint {
        let loc = touch.preciseLocation(in: self)
        var pressure = 0.5
        if touch.type == .pencil, touch.maximumPossibleForce > 0 {
            pressure = Double(touch.force / touch.maximumPossibleForce)
        } else if touch.force > 0, touch.maximumPossibleForce > 0 {
            pressure = 0.3 + 0.7 * Double(touch.force / touch.maximumPossibleForce)
        }
        let altitude = touch.type == .pencil ? Double(touch.altitudeAngle) : .pi / 2
        let azimuth = touch.type == .pencil ? Double(touch.azimuthAngle(in: self)) : 0
        return StrokePoint(x: Double(loc.x), y: Double(loc.y), pressure: min(1, max(0.02, pressure)),
                           altitude: altitude, azimuth: azimuth, time: max(0, touch.timestamp - start))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let s = state else { return }
        // A second finger means zoom, not draw.
        if let all = event?.allTouches, all.filter({ $0.type == .direct }).count > 1 {
            cancelStroke()
            return
        }
        guard let touch = touches.first(where: { accepts($0) }) else { return }
        guard let layer = s.project.layers.first(where: { $0.id == s.layerID }) else { return }

        switch s.tool {
        case .brush, .eraser:
            if layer.locked { actions?.blocked("This layer is locked. Unlock it to draw."); return }
            if !layer.visible { actions?.blocked("This layer is hidden. Show it to draw."); return }
            activeTouch = touch
            strokeStart = touch.timestamp
            _ = beginLine(point(for: touch, start: strokeStart))
        case .fill:
            if layer.locked { actions?.blocked("This layer is locked."); return }
            let p = touch.location(in: self)
            actions?.fill(Vec2(Double(p.x), Double(p.y)))
        case .select:
            activeTouch = touch
            let p = touch.location(in: self)
            if !s.selection.isEmpty, selectionBounds(s).insetBy(dx: -24, dy: -24).contains(p), !layer.locked {
                moveStart = p
                moveOffset = .zero
                beginFloating(s)
            } else {
                lassoPoints = [p]
            }
        case .hair:
            activeTouch = touch
            lassoPoints = [touch.location(in: self)]
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let s = state else { return }
        switch s.tool {
        case .brush, .eraser:
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            var predicted: [StrokePoint] = []
            // Predicted touches cut lag, but only make sense when nothing holds the line back.
            if s.smoothing < StrokeSmoothing.stringStarts, let pred = event?.predictedTouches(for: touch) {
                predicted = pred.map { point(for: $0, start: strokeStart) }
            }
            continueLine(samples.map { point(for: $0, start: strokeStart) }, predicted: predicted)
        case .select:
            let p = touch.location(in: self)
            if let start = moveStart {
                moveOffset = CGPoint(x: p.x - start.x, y: p.y - start.y)
                floatingView.transform = CGAffineTransform(translationX: moveOffset.x, y: moveOffset.y)
                updateOverlays()
            } else {
                lassoPoints.append(p)
                drawLasso(on: overlayLayer)
            }
        case .hair:
            lassoPoints.append(touch.location(in: self))
            drawLasso(on: hairLayer)
        case .fill:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let s = state else { return }
        activeTouch = nil
        switch s.tool {
        case .brush, .eraser:
            finishLine(point(for: touch, start: strokeStart))
        case .select:
            if moveStart != nil {
                let offset = moveOffset
                moveStart = nil
                endFloating()
                if abs(offset.x) > 0.5 || abs(offset.y) > 0.5 {
                    actions?.moveSelection(Vec2(Double(offset.x), Double(offset.y)))
                }
                moveOffset = .zero
            } else {
                finishLasso(s)
            }
        case .hair:
            let pts = lassoPoints
            lassoPoints = []
            updateOverlays()
            let simple = Geometry.simplify(pts.map { Vec2(Double($0.x), Double($0.y)) }, tolerance: 3)
            guard simple.count >= 3, Geometry.bounds(ofPath: simple.flatMap { [$0.x, $0.y] }).maxSide > 20 else { return }
            actions?.addHair(simple.flatMap { [$0.x, $0.y] })
        case .fill:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelStroke()
    }

    func cancelStroke() {
        activeTouch = nil
        stabilizer = nil
        livePoints = []
        liveLayer.path = nil
        lassoPoints = []
        if moveStart != nil {
            moveStart = nil
            moveOffset = .zero
            endFloating()
        }
        updateOverlays()
    }

    // MARK: The line pipeline (fingers, the Pencil and the UI test scribble all go through here)

    /// Canvas pixels per screen point for the line being drawn.
    private var lineScale: Double = 1

    /// Starts a line. Returns false if nothing can be drawn right now.
    @discardableResult
    private func beginLine(_ p: StrokePoint) -> Bool {
        guard let s = state else { return false }
        lineScale = 1 / Double(max(0.05, zoom))
        let st = StrokeStabilizer(amount: s.smoothing, scale: lineScale)
        stabilizer = st
        livePoints = st.begin(p)
        updateLivePath(predicted: [])
        return true
    }

    private func continueLine(_ samples: [StrokePoint], predicted: [StrokePoint] = []) {
        guard let st = stabilizer else { return }
        for p in samples { livePoints += st.add(p) }
        updateLivePath(predicted: predicted)
    }

    private func finishLine(_ last: StrokePoint) {
        guard let s = state, let st = stabilizer else { return }
        livePoints += st.add(last)
        livePoints += st.end()
        stabilizer = nil
        let pts = rounded(StrokeShape.dedupe(livePoints), smoothing: s.smoothing)
        livePoints = []
        guard !pts.isEmpty else { liveLayer.path = nil; return }
        let stroke = Stroke(brush: s.brush, points: pts).rounded
        lastBend = StrokeShape.sharpestBend(stroke.points, spacing: 4 * lineScale)
        liveLayer.path = StrokeRenderer.path(for: stroke)
        actions?.commitStroke(stroke)
    }

    /// Evens out wobbles the same way while drawing and when you lift, so the line never jumps.
    /// Corners and short strokes (eyes, mouths) keep the shape you drew.
    private func rounded(_ pts: [StrokePoint], smoothing: Double) -> [StrokePoint] {
        StrokeSmoothing.shape(pts, amount: smoothing, scale: lineScale)
    }

    private func updateLivePath(predicted: [StrokePoint]) {
        guard let s = state else { return }
        let stroke = Stroke(brush: s.brush, points: rounded(livePoints, smoothing: s.smoothing) + predicted)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if s.brush.kind == .eraser {
            liveLayer.fillColor = UIColor.systemGray.withAlphaComponent(0.35).cgColor
        } else {
            let a = StrokeShape.alpha(of: stroke) * (layerOpacity(s))
            liveLayer.fillColor = s.brush.color.with(alpha: a).cgColor
        }
        liveLayer.path = StrokeRenderer.path(for: stroke)
        CATransaction.commit()
    }

    private func layerOpacity(_ s: CanvasState) -> Double {
        s.project.layers.first { $0.id == s.layerID }?.opacity ?? 1
    }

    // MARK: Lasso and moving

    private func drawLasso(on shape: CAShapeLayer) {
        let path = CGMutablePath()
        if let f = lassoPoints.first {
            path.move(to: f)
            for p in lassoPoints.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
    }

    private func finishLasso(_ s: CanvasState) {
        let pts = lassoPoints
        lassoPoints = []
        overlayLayer.path = nil
        guard s.project.frames.indices.contains(s.frameIndex) else { return }
        let cel = s.project.frames[s.frameIndex].cel(s.layerID)
        if pts.count < 3 {
            // A tap picks the stroke under your finger, or clears the selection.
            guard let p = pts.first else { return }
            let v = Vec2(Double(p.x), Double(p.y))
            let hit = cel.strokes.last { st in
                st.brush.kind != .eraser && st.points.contains { Vec2($0).distance(to: v) < max(14, st.brush.size) / Double(max(0.3, zoom)) }
            }
            actions?.select(hit.map { [$0.id] } ?? [])
            return
        }
        let poly = pts.flatMap { [Double($0.x), Double($0.y)] }
        var picked: Set<String> = []
        for st in cel.strokes where st.brush.kind != .eraser {
            let inside = st.points.filter { Geometry.contains(poly, Vec2($0)) }.count
            if inside * 2 >= st.points.count, inside > 0 { picked.insert(st.id) }
        }
        actions?.select(picked)
    }

    private func selectionBounds(_ s: CanvasState) -> CGRect {
        guard s.project.frames.indices.contains(s.frameIndex) else { return .null }
        let strokes = s.project.frames[s.frameIndex].cel(s.layerID).strokes.filter { s.selection.contains($0.id) }
        let b = Geometry.bounds(of: strokes)
        return b.isEmpty ? .null : CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height)
    }

    private func beginFloating(_ s: CanvasState) {
        let strokes = s.project.frames[s.frameIndex].cel(s.layerID).strokes.filter { s.selection.contains($0.id) }
        let canvas = s.project.canvas
        let scale = renderScale
        hiddenIDs = s.selection
        floatingView.transform = .identity
        floatingView.alpha = CGFloat(layerOpacity(s))
        if let ctx = FrameRenderer.makeContext(canvasWidth: canvas.width, canvasHeight: canvas.height, scale: scale) {
            for st in strokes { StrokeRenderer.draw(st, in: ctx) }
            floatingView.image = ctx.makeImage().map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
        }
        refreshPictures()
    }

    private func endFloating() {
        hiddenIDs = []
        // Keep the moved copy showing until the layer picture catches up.
        let floating = floatingView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            floating.image = nil
            floating.transform = .identity
        }
        currentKey = nil
        refreshPictures()
    }

    // MARK: Pencil double tap

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        actions?.toggleEraser()
    }

    // MARK: Dropping stash items

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: NSString.self)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let p = session.location(in: self)
        _ = session.loadObjects(ofClass: NSString.self) { [weak self] items in
            guard let text = items.first as? String, text.hasPrefix(StashDrag.prefix) else { return }
            let id = String(text.dropFirst(StashDrag.prefix.count))
            DispatchQueue.main.async {
                self?.actions?.dropStash(id, Vec2(Double(p.x), Double(p.y)))
            }
        }
    }
}

/// Text carried when you drag a stash item.
enum StashDrag {
    static let prefix = "gale-stash:"
}
