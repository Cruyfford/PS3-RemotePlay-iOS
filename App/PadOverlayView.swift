import UIKit

/// Translucent on-screen PS3 controls with multi-touch.
final class PadOverlayView: UIView {
    var onButton: ((Int32, Bool) -> Void)?
    var onAxis: ((Int32, Float) -> Void)?
    var onHome: (() -> Void)?
    var onClose: (() -> Void)?

    private enum Action {
        case button(Int32)
        case home
        case close
    }

    private struct Zone {
        let label: String
        let rect: CGRect
        let action: Action
        let round: Bool
    }

    private var zones: [Zone] = []
    private var pressed = Set<Int>()
    private var stickCenters: [CGPoint] = [.zero, .zero]
    private var stickOffsets: [CGPoint] = [.zero, .zero]
    private var stickTouches: [UITouch?] = [nil, nil]
    private var stickRadius: CGFloat = 40
    private var laidOutSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            releaseAll()
            buildZones()
            setNeedsDisplay()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        releaseAll()
        buildZones()
        setNeedsDisplay()
    }

    private func buildZones() {
        zones.removeAll()
        let w = bounds.width
        let h = bounds.height
        if w < 100 || h < 100 { return }
        let ml = max(safeAreaInsets.left, 12)
        let mr = max(safeAreaInsets.right, 12)
        let u = min(h / 7.5, 56, (w - ml - mr) / 13.2)
        let top: CGFloat = max(safeAreaInsets.top, 8)

        func add(_ label: String, _ rect: CGRect, _ action: Action, round: Bool = false) {
            zones.append(Zone(label: label, rect: rect, action: action, round: round))
        }
        func circle(_ label: String, _ cx: CGFloat, _ cy: CGFloat, _ code: Int32) {
            add(label, CGRect(x: cx - u * 0.5, y: cy - u * 0.5, width: u, height: u), .button(code), round: true)
        }

        // shoulder buttons
        let sw = u * 1.55
        let sh = u * 0.8
        add("L2", CGRect(x: ml, y: top, width: sw, height: sh), .button(Pad.l2))
        add("L1", CGRect(x: ml + u * 1.7, y: top, width: sw, height: sh), .button(Pad.l1))
        add("R2", CGRect(x: w - mr - sw, y: top, width: sw, height: sh), .button(Pad.r2))
        add("R1", CGRect(x: w - mr - u * 1.7 - sw, y: top, width: sw, height: sh), .button(Pad.r1))

        // centre row
        let cw = u * 1.1
        let ch = u * 0.62
        let step = u * 1.22
        let cx = w / 2
        let row: [(String, Action)] = [("SELECT", .button(Pad.select)), ("L3", .button(Pad.l3)), ("PS", .home),
                                       ("R3", .button(Pad.r3)), ("START", .button(Pad.start))]
        for (i, item) in row.enumerated() {
            let x = cx + CGFloat(i - 2) * step - cw / 2
            add(item.0, CGRect(x: x, y: top + (sh - ch) / 2, width: cw, height: ch), item.1)
        }

        // d-pad
        let dx = ml + u * 1.7
        let dy = h * 0.52
        circle("\u{25B2}", dx, dy - u, Pad.up)
        circle("\u{25B6}", dx + u, dy, Pad.right)
        circle("\u{25BC}", dx, dy + u, Pad.down)
        circle("\u{25C0}", dx - u, dy, Pad.left)

        // face buttons
        let fx = w - mr - u * 1.7
        circle("\u{25B3}", fx, dy - u, Pad.triangle)
        circle("\u{25CB}", fx + u, dy, Pad.circle)
        circle("\u{2715}", fx, dy + u, Pad.cross)
        circle("\u{25A1}", fx - u, dy, Pad.square)

        // close
        add("EXIT", CGRect(x: cx - cw / 2, y: h - ch - max(safeAreaInsets.bottom, 10), width: cw, height: ch), .close)

        // analog sticks
        stickRadius = u * 0.9
        stickCenters[0] = CGPoint(x: ml + u * 4.25, y: h - u * 1.3)
        stickCenters[1] = CGPoint(x: w - mr - u * 4.25, y: h - u * 1.3)
    }

    private func fire(_ index: Int, _ down: Bool) {
        guard index >= 0 && index < zones.count else { return }
        switch zones[index].action {
        case .button(let code):
            onButton?(code, down)
        case .home:
            if down { onHome?() }
        case .close:
            if !down { onClose?() }
        }
    }

    private func releaseAll() {
        for index in pressed {
            if index < zones.count, case .button(let code) = zones[index].action {
                onButton?(code, false)
            }
        }
        pressed.removeAll()
        for s in 0..<2 where stickTouches[s] != nil {
            stickTouches[s] = nil
            setStick(s, CGPoint.zero)
        }
    }

    private func setStick(_ s: Int, _ offset: CGPoint) {
        stickOffsets[s] = offset
        onAxis?(s == 0 ? Pad.axisLX : Pad.axisRX, Float(offset.x))
        onAxis?(s == 0 ? Pad.axisLY : Pad.axisRY, Float(offset.y))
    }

    private func moveStick(_ s: Int, to point: CGPoint) {
        let c = stickCenters[s]
        let x = max(-1, min(1, (point.x - c.x) / stickRadius))
        let y = max(-1, min(1, (point.y - c.y) / stickRadius))
        setStick(s, CGPoint(x: x, y: y))
    }

    private func isStickTouch(_ touch: UITouch) -> Bool {
        return stickTouches[0] === touch || stickTouches[1] === touch
    }

    private func refresh(_ event: UIEvent?, ending: Set<UITouch>) {
        var now = Set<Int>()
        let all: Set<UITouch> = event?.allTouches ?? []
        for touch in all {
            if ending.contains(touch) || touch.phase == .ended || touch.phase == .cancelled { continue }
            if touch.view !== self || isStickTouch(touch) { continue }
            let point = touch.location(in: self)
            for (index, zone) in zones.enumerated() where zone.rect.insetBy(dx: -5, dy: -5).contains(point) {
                now.insert(index)
            }
        }
        for index in now.subtracting(pressed) { fire(index, true) }
        for index in pressed.subtracting(now) { fire(index, false) }
        pressed = now
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            for s in 0..<2 where stickTouches[s] == nil {
                let c = stickCenters[s]
                if hypot(point.x - c.x, point.y - c.y) <= stickRadius * 1.25 {
                    stickTouches[s] = touch
                    moveStick(s, to: point)
                    break
                }
            }
        }
        refresh(event, ending: [])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            for s in 0..<2 where stickTouches[s] === touch {
                moveStick(s, to: touch.location(in: self))
            }
        }
        refresh(event, ending: [])
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, event)
    }

    private func endTouches(_ touches: Set<UITouch>, _ event: UIEvent?) {
        for touch in touches {
            for s in 0..<2 where stickTouches[s] === touch {
                stickTouches[s] = nil
                setStick(s, CGPoint.zero)
            }
        }
        refresh(event, ending: touches)
    }

    override func draw(_ rect: CGRect) {
        let stroke = UIColor(white: 1, alpha: 0.45)
        for (index, zone) in zones.enumerated() {
            let path = zone.round ? UIBezierPath(ovalIn: zone.rect) : UIBezierPath(roundedRect: zone.rect, cornerRadius: 8)
            let fill = pressed.contains(index) ? UIColor(white: 1, alpha: 0.42) : UIColor(white: 0, alpha: 0.22)
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let fontSize = max(9, min(zone.rect.height * 0.40, 20))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor(white: 1, alpha: 0.8)
            ]
            let text = zone.label as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: zone.rect.midX - size.width / 2, y: zone.rect.midY - size.height / 2),
                      withAttributes: attributes)
        }
        for s in 0..<2 {
            let c = stickCenters[s]
            if c == .zero { continue }
            let ring = UIBezierPath(ovalIn: CGRect(x: c.x - stickRadius, y: c.y - stickRadius,
                                                   width: stickRadius * 2, height: stickRadius * 2))
            UIColor(white: 0, alpha: 0.18).setFill()
            ring.fill()
            stroke.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
            let k = stickRadius * 0.5
            let kc = CGPoint(x: c.x + stickOffsets[s].x * stickRadius * 0.5, y: c.y + stickOffsets[s].y * stickRadius * 0.5)
            let knob = UIBezierPath(ovalIn: CGRect(x: kc.x - k, y: kc.y - k, width: k * 2, height: k * 2))
            UIColor(white: 1, alpha: stickTouches[s] == nil ? 0.25 : 0.5).setFill()
            knob.fill()
        }
    }
}
