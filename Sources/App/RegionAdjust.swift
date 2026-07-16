import AppKit

// MARK: - 可调整选区:框选完成后显示,支持拖动移动 + 8 个手柄缩放

final class RegionAdjustWindow: NSWindow {
    /// 当前选区(屏幕坐标)
    private(set) var rect: NSRect
    var onChange: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private let screenFrame: NSRect

    init(rect: NSRect, minSize: CGFloat) {
        self.rect = rect
        let screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) }
            ?? NSScreen.main
        self.screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        let view = AdjustView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.minSize = minSize
        view.rectInView = NSRect(x: rect.origin.x - screenFrame.origin.x,
                                 y: rect.origin.y - screenFrame.origin.y,
                                 width: rect.width, height: rect.height)
        view.onRectChanged = { [weak self] r in
            guard let self else { return }
            self.rect = NSRect(x: r.origin.x + self.screenFrame.origin.x,
                               y: r.origin.y + self.screenFrame.origin.y,
                               width: r.width, height: r.height)
            self.onChange?(self.rect)
        }
        view.onEscape = { [weak self] in self?.onCancel?() }
        contentView = view
        makeFirstResponder(view)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }

    /// 外部改选区(如「改为全屏」按钮),不回调 onChange 避免回环
    func setRect(_ r: NSRect) {
        rect = r
        (contentView as? AdjustView)?.rectInView = NSRect(x: r.origin.x - screenFrame.origin.x,
                                                          y: r.origin.y - screenFrame.origin.y,
                                                          width: r.width, height: r.height)
        contentView?.needsDisplay = true
    }
}

private final class AdjustView: NSView {
    var rectInView: NSRect = .zero {
        didSet { needsDisplay = true }
    }
    var minSize: CGFloat = 40
    var onRectChanged: ((NSRect) -> Void)?
    var onEscape: (() -> Void)?

    private enum DragMode {
        case none, move
        case resize(left: Bool, right: Bool, top: Bool, bottom: Bool)
    }
    private var mode: DragMode = .none
    private var dragStartPoint: NSPoint = .zero
    private var dragStartRect: NSRect = .zero

    private let handleSize: CGFloat = 9

    override var acceptsFirstResponder: Bool { true }

    // MARK: 手柄位置(4 角 + 4 边中点)

    private func handles() -> [(rect: NSRect, left: Bool, right: Bool, top: Bool, bottom: Bool)] {
        let r = rectInView
        let s = handleSize
        func h(_ x: CGFloat, _ y: CGFloat, _ l: Bool, _ rt: Bool, _ t: Bool, _ b: Bool)
            -> (NSRect, Bool, Bool, Bool, Bool) {
            (NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s), l, rt, t, b)
        }
        return [
            h(r.minX, r.minY, true, false, false, true),   // 左下
            h(r.midX, r.minY, false, false, false, true),  // 下
            h(r.maxX, r.minY, false, true, false, true),   // 右下
            h(r.minX, r.midY, true, false, false, false),  // 左
            h(r.maxX, r.midY, false, true, false, false),  // 右
            h(r.minX, r.maxY, true, false, true, false),   // 左上
            h(r.midX, r.maxY, false, false, true, false),  // 上
            h(r.maxX, r.maxY, false, true, true, false),   // 右上
        ]
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let r = rectInView
        guard r.width > 0 else { return }

        // 边框
        let borderPath = NSBezierPath(rect: r)
        borderPath.lineWidth = 2
        borderPath.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        borderPath.stroke()

        // 手柄
        for handle in handles() {
            NSColor.white.setFill()
            let p = NSBezierPath(ovalIn: handle.rect)
            p.fill()
            NSColor.systemRed.setStroke()
            p.lineWidth = 1.5
            p.stroke()
        }

        // 尺寸标注
        let text = "\(Int(r.width)) × \(Int(r.height))  拖动移动 / 拖手柄缩放" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65),
        ]
        let size = text.size(withAttributes: attrs)
        var at = NSPoint(x: r.minX, y: r.maxY + 8)
        if at.y + size.height > bounds.maxY { at.y = r.maxY - size.height - 8 }
        text.draw(at: at, withAttributes: attrs)
    }

    // MARK: 拖动

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStartPoint = p
        dragStartRect = rectInView
        // 手柄命中区域放大一些,好点
        for handle in handles() {
            if handle.rect.insetBy(dx: -6, dy: -6).contains(p) {
                mode = .resize(left: handle.left, right: handle.right, top: handle.top, bottom: handle.bottom)
                return
            }
        }
        if rectInView.contains(p) {
            mode = .move
            NSCursor.closedHand.set()
        } else {
            mode = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - dragStartPoint.x
        let dy = p.y - dragStartPoint.y
        var r = dragStartRect

        switch mode {
        case .none:
            return
        case .move:
            r.origin.x += dx
            r.origin.y += dy
            // 不许拖出屏幕
            r.origin.x = max(0, min(r.origin.x, bounds.width - r.width))
            r.origin.y = max(0, min(r.origin.y, bounds.height - r.height))
        case .resize(let left, let right, let top, let bottom):
            if left { r.origin.x += dx; r.size.width -= dx }
            if right { r.size.width += dx }
            if bottom { r.origin.y += dy; r.size.height -= dy }
            if top { r.size.height += dy }
            // 最小尺寸(保持锚定边不动)
            if r.width < minSize {
                if left { r.origin.x = dragStartRect.maxX - minSize }
                r.size.width = minSize
            }
            if r.height < minSize {
                if bottom { r.origin.y = dragStartRect.maxY - minSize }
                r.size.height = minSize
            }
            r = r.intersection(bounds)
        }
        rectInView = r
        onRectChanged?(r)
    }

    override func mouseUp(with event: NSEvent) {
        mode = .none
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } // Esc
    }

    override func resetCursorRects() {
        addCursorRect(rectInView, cursor: .openHand)
        for handle in handles() {
            let horizontal = (handle.left || handle.right) && !(handle.top || handle.bottom)
            let vertical = (handle.top || handle.bottom) && !(handle.left || handle.right)
            let cursor: NSCursor = horizontal ? .resizeLeftRight : (vertical ? .resizeUpDown : .crosshair)
            addCursorRect(handle.rect.insetBy(dx: -6, dy: -6), cursor: cursor)
        }
    }
}
