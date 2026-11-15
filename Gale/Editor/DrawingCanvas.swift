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

/// Scroll view that zooms and pans the paper with two fingers. One finger or the Pencil draws.
final class CanvasScrollView: UIScrollView, UIScrollViewDelegate {
    let canvas = CanvasContentView()
    private var lastBoundsSize: CGSize = .zero
    private var lastCanvasSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = UIColor.secondarySystemBackground
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        delaysContentTouches = false
        canCancelContentTouches = true
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        bouncesZoom = true
        maximumZoomScale = 12
        addSubview(canvas)

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undoTapped))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(undoTap)
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redoTapped))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(redoTap)
        let fitTap = UITapGestureRecognizer(target: self, action: #selector(fitTapped))
        fitTap.numberOfTouchesRequired = 2
        fitTap.numberOfTapsRequired = 2
        fitTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(fitTap)
        undoTap.require(toFail: fitTap)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    @objc private func undoTapped() { canvas.cancelStroke(); canvas.actions?.undo() }
    @objc private func redoTapped() { canvas.cancelStroke(); canvas.actions?.redo() }
    @objc private func fitTapped() { zoomToFit(animated: true) }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            zoomToFit(animated: false)
        }
        centerCanvas()
    }

    func contentSizeChanged() {
        let size = canvas.bounds.size
        if size != lastCanvasSize {
            lastCanvasSize = size
            zoomToFit(animated: false)
        }
    }

    func zoomToFit(animated: Bool) {
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fit = min((bounds.width - 32) / size.width, (bounds.height - 32) / size.height)
        minimumZoomScale = max(0.02, fit * 0.5)
        setZoomScale(max(0.02, fit), animated: animated)
        centerCanvas()
    }

    private func centerCanvas() {
        let w = canvas.frame.width, h = canvas.frame.height
        let insetX = max(0, (bounds.width - w) / 2)
        let insetY = max(0, (bounds.height - h) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvas()
        canvas.zoom = zoomScale
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        canvas.zoom = scale
        canvas.updateLiveScale()
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
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    // MARK: State

    func apply(_ new: CanvasState) {
        let old = state
        state = new
        let w = CGFloat(new.project.canvas.width), h = CGFloat(new.project.canvas.height)
        if bounds.size != CGSize(width: w, height: h) {
            let center = self.center
            bounds = CGRect(x: 0, y: 0, width: w, height: h)
            self.center = center
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
            let st = StrokeStabilizer(amount: s.smoothing, scale: 1 / Double(max(0.05, zoom)))
            stabilizer = st
            livePoints = st.begin(point(for: touch, start: strokeStart))
            updateLivePath(predicted: [])
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
            guard let st = stabilizer else { return }
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for t in samples { livePoints += st.add(point(for: t, start: strokeStart)) }
            var predicted: [StrokePoint] = []
            if s.smoothing < 0.15, let pred = event?.predictedTouches(for: touch) {
                predicted = pred.map { point(for: $0, start: strokeStart) }
            }
            updateLivePath(predicted: predicted)
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
            guard let st = stabilizer else { return }
            livePoints += st.add(point(for: touch, start: strokeStart))
            livePoints += st.end()
            stabilizer = nil
            var pts = StrokeShape.dedupe(livePoints)
            if s.smoothing > 0.05 { pts = StrokeSmoother.smooth(pts, amount: s.smoothing * 0.7) }
            livePoints = []
            guard !pts.isEmpty else { liveLayer.path = nil; return }
            let stroke = Stroke(brush: s.brush, points: pts).rounded
            liveLayer.path = StrokeRenderer.path(for: stroke)
            actions?.commitStroke(stroke)
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

    private func updateLivePath(predicted: [StrokePoint]) {
        guard let s = state else { return }
        let stroke = Stroke(brush: s.brush, points: livePoints + predicted)
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
