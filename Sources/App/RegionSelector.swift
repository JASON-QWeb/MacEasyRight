import AppKit

// MARK: - 自绘屏幕选区(用于「截图并贴图」和「长截图」)

@MainActor
final class RegionSelector {
    private static var current: RegionSelector?

    private var window: SelectorWindow?
    private var completion: ((NSRect?) -> Void)?

    /// 回调返回 Cocoa 屏幕坐标系(左下原点)下的选区;nil = 取消
    static func select(completion: @escaping (NSRect?) -> Void) {
        guard current == nil else { completion(nil); return }
        let s = RegionSelector()
        current = s
        s.begin(completion)
    }

    private func begin(_ completion: @escaping (NSRect?) -> Void) {
        self.completion = completion
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { finish(nil); return }
        let win = SelectorWindow(screen: screen) { [weak self] rect in
            self?.finish(rect)
        }
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func finish(_ rect: NSRect?) {
        window?.orderOut(nil)
        window = nil
        let cb = completion
        completion = nil
        RegionSelector.current = nil
        cb?(rect)
    }
}

/// Cocoa 屏幕坐标(左下原点) → CG 全局坐标(主屏左上原点),供屏幕抓取 API 使用
func cocoaToCG(_ r: NSRect) -> CGRect {
    let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(x: r.origin.x, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
}

private final class SelectorWindow: NSWindow {
    init(screen: NSScreen, onDone: @escaping (NSRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        let view = SelectorView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.screenOrigin = screen.frame.origin
        view.onDone = onDone
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectorView: NSView {
    var onDone: ((NSRect?) -> Void)?
    var screenOrigin: NSPoint = .zero
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    private var selectionRect: NSRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let r = selectionRect else { return }
        // 选区内挖空
        NSColor.clear.setFill()
        r.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        border.stroke()
        // 尺寸标注
        let text = "\(Int(r.width)) × \(Int(r.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ]
        let size = text.size(withAttributes: attrs)
        var at = NSPoint(x: r.minX, y: r.maxY + 6)
        if at.y + size.height > bounds.maxY { at.y = r.maxY - size.height - 6 }
        text.draw(at: at, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let r = selectionRect, r.width >= 8, r.height >= 8 else {
            onDone?(nil)
            return
        }
        let screenRect = NSRect(x: r.origin.x + screenOrigin.x,
                                y: r.origin.y + screenOrigin.y,
                                width: r.width, height: r.height)
        onDone?(screenRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } // Esc
    }
}
