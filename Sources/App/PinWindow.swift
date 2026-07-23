import AppKit
import UniformTypeIdentifiers

// MARK: - 贴图管理

@MainActor
final class PinManager {
    static let shared = PinManager()
    private(set) var windows: [PinWindow] = []

    /// screenRect 为 nil 时贴在鼠标所在屏幕中央(多张时逐张错开)
    func pin(image: NSImage, at screenRect: NSRect?) {
        var rect: NSRect
        if let screenRect {
            rect = screenRect
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let sf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var size = image.size
            let maxW = sf.width * 0.8, maxH = sf.height * 0.8
            if size.width > maxW || size.height > maxH {
                let scale = min(maxW / size.width, maxH / size.height)
                size = NSSize(width: size.width * scale, height: size.height * scale)
            }
            let offset = CGFloat(windows.count % 8) * 24
            rect = NSRect(x: sf.midX - size.width / 2 + offset,
                          y: sf.midY - size.height / 2 - offset,
                          width: size.width, height: size.height)
        }
        let win = PinWindow(image: image, frame: rect)
        register(win)
        win.orderFrontRegardless()
    }

    func register(_ win: PinWindow) {
        guard !windows.contains(where: { $0 === win }) else { return }
        windows.append(win)
        NSLog(
            "EasyRight: PinWindow created %.0fx%.0f (total %d)",
            win.frame.width,
            win.frame.height,
            windows.count
        )
    }

    func remove(_ win: PinWindow) {
        windows.removeAll { $0 === win }
    }

    func closeAll() {
        let list = windows
        windows.removeAll()
        for w in list { w.tearDown() }
        NSLog("EasyRight: all pins closed")
    }
}

enum PinWindowPurpose {
    case pinned
    case capturePreview
}

// MARK: - 标注模型

enum PinTool: Int {
    case move = 0, pen, line, arrow, rect, text
}

struct PinAnnotation {
    enum Shape {
        case pen([CGPoint])
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case rect(CGRect)
        case text(String, CGPoint, CGFloat) // 内容、基点、字号(图像坐标系)
    }
    var shape: Shape
    var color: NSColor
    var width: CGFloat

    /// 在当前图形上下文中渲染(图像坐标系)
    func render() {
        color.set()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch shape {
        case .pen(let points):
            guard let first = points.first else { return }
            path.move(to: first)
            for p in points.dropFirst() { path.line(to: p) }
            path.stroke()
        case .line(let a, let b):
            path.move(to: a)
            path.line(to: b)
            path.stroke()
        case .arrow(let a, let b):
            path.move(to: a)
            path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(12, width * 4)
            let p1 = CGPoint(x: b.x + head * cos(angle + .pi * 0.85),
                             y: b.y + head * sin(angle + .pi * 0.85))
            let p2 = CGPoint(x: b.x + head * cos(angle - .pi * 0.85),
                             y: b.y + head * sin(angle - .pi * 0.85))
            path.move(to: p1)
            path.line(to: b)
            path.line(to: p2)
            path.stroke()
        case .rect(let r):
            path.appendRect(r)
            path.stroke()
        case .text(let s, let at, let size):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: size),
                .foregroundColor: color,
            ]
            (s as NSString).draw(at: at, withAttributes: attrs)
        }
    }
}

// MARK: - 贴图窗口

final class PinWindow: NSWindow {
    let image: NSImage
    private let aspect: CGFloat
    private var canvas: PinCanvasView { contentView as! PinCanvasView }
    private var pinToolbar: PinToolbarPanel?
    private var hideTimer: Timer?
    private var purpose: PinWindowPurpose
    private var onPreviewFinished: (() -> Void)?
    private var selectedColorIndex = 0

    init(
        image: NSImage,
        frame: NSRect,
        purpose: PinWindowPurpose = .pinned,
        onPreviewFinished: (() -> Void)? = nil
    ) {
        self.image = image
        self.aspect = image.size.width > 0 && image.size.height > 0
            ? image.size.width / image.size.height
            : 1
        self.purpose = purpose
        self.onPreviewFinished = onPreviewFinished
        super.init(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentAspectRatio = NSSize(
            width: max(1, image.size.width),
            height: max(1, image.size.height)
        )
        minSize = aspect >= 1
            ? NSSize(width: 60, height: 60 / aspect)
            : NSSize(width: 60 * aspect, height: 60)

        let view = PinCanvasView(image: image)
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        contentView = view

        installToolbar()
        showToolbar()
        if purpose == .pinned { scheduleToolbarHide(after: 5) }
    }

    override var canBecomeKey: Bool { true }
    var isCapturePreview: Bool { purpose == .capturePreview }

    // MARK: 工具栏显隐

    private func installToolbar() {
        if let oldToolbar = pinToolbar {
            removeChildWindow(oldToolbar)
            oldToolbar.orderOut(nil)
        }
        let toolbar = PinToolbarPanel(pin: self, isCapturePreview: isCapturePreview)
        pinToolbar = toolbar
        addChildWindow(toolbar, ordered: .above)
        toolbar.highlightTool(canvas.tool)
        toolbar.highlightColor(selectedColorIndex)
    }

    func showToolbar() {
        hideTimer?.invalidate()
        hideTimer = nil
        pinToolbar?.orderFront(nil)
        positionToolbar()
    }

    func scheduleToolbarHide(after seconds: TimeInterval = 0.8) {
        guard purpose == .pinned else { return }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(
            timeInterval: seconds,
            target: self,
            selector: #selector(hideToolbarTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    func positionToolbar() {
        guard let tb = pinToolbar else { return }
        let size = tb.frame.size
        var x = frame.midX - size.width / 2
        var y = frame.minY - size.height - 8
        let screen = self.screen ?? NSScreen.main
        if let sf = screen?.visibleFrame {
            if y < sf.minY { y = frame.maxY + 8 }
            x = max(sf.minX + 4, min(x, sf.maxX - size.width - 4))
        }
        tb.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func hideToolbarTimerFired() {
        if canvas.tool != .move || canvas.isEditingText { return }
        pinToolbar?.orderOut(nil)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        positionToolbar()
    }

    override func becomeKey() {
        super.becomeKey()
        showToolbar()
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 51, 117: // Esc / ⌫ / ⌦ 关闭贴图
            closePin()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c": copyImage(); return true
            case "s": saveImage(); return true
            case "w": closePin(); return true
            case "z": undoAnnotation(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = max(0.8, min(1.25, 1 + event.scrollingDeltaY * 0.006))
        var f = frame
        let newW = max(60, min(f.width * factor, 6000))
        let newH = newW / aspect
        f.origin.x -= (newW - f.width) / 2
        f.origin.y -= (newH - f.height) / 2
        f.size = NSSize(width: newW, height: newH)
        setFrame(f, display: true)
    }

    // MARK: 工具栏动作

    @objc func selectTool(_ sender: NSButton) {
        let tool = PinTool(rawValue: sender.tag) ?? .move
        canvas.tool = tool
        pinToolbar?.highlightTool(tool)
        showToolbar()
    }

    @objc func pickColor(_ sender: NSButton) {
        let colors = PinToolbarPanel.colors
        guard sender.tag < colors.count else { return }
        selectedColorIndex = sender.tag
        canvas.color = colors[sender.tag]
        pinToolbar?.highlightColor(sender.tag)
        // 选颜色时如果还在移动工具,自动切成画笔
        if canvas.tool == .move {
            canvas.tool = .pen
            pinToolbar?.highlightTool(.pen)
        }
        showToolbar()
    }

    @objc func undoAnnotation() {
        canvas.undo()
        showToolbar()
    }

    @objc func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([canvas.compositedImage()])
    }

    @objc func actualSize() {
        var f = frame
        f.origin.x -= (image.size.width - f.width) / 2
        f.origin.y -= (image.size.height - f.height) / 2
        f.size = image.size
        setFrame(f, display: true)
    }

    @objc func saveImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let prefix = isCapturePreview ? "截图" : "贴图"
        panel.nameFieldStringValue = "\(prefix) \(df.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let out = canvas.compositedImage()
        do {
            guard let tiff = out.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw NSError(
                    domain: "EasyRight.Pin",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "无法把贴图编码为 PNG"]
                )
            }
            try png.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = isCapturePreview ? "保存截图失败" : "保存贴图失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc func pinCapture() {
        guard purpose == .capturePreview else { return }
        canvas.commitTextEditor()
        purpose = .pinned
        PinManager.shared.register(self)
        finishPreview()
        installToolbar()
        showToolbar()
        scheduleToolbarHide(after: 5)
    }

    @objc func closePin() {
        if purpose == .pinned {
            PinManager.shared.remove(self)
        } else {
            finishPreview()
        }
        tearDown()
    }

    @objc func closeAllPins() {
        PinManager.shared.closeAll()
    }

    func tearDown() {
        hideTimer?.invalidate()
        if let tb = pinToolbar {
            removeChildWindow(tb)
            tb.orderOut(nil)
        }
        pinToolbar = nil
        orderOut(nil)
    }

    private func finishPreview() {
        let completion = onPreviewFinished
        onPreviewFinished = nil
        completion?()
    }
}

// MARK: - 画布:显示图片 + 绘制/编辑标注

final class PinCanvasView: NSView, NSTextFieldDelegate {
    let image: NSImage
    var tool: PinTool = .move
    var color: NSColor = .systemRed
    private var annotations: [PinAnnotation] = []
    private var inProgress: PinAnnotation?
    private var dragStart: CGPoint = .zero
    private var editor: NSTextField?
    private var editorImagePoint: CGPoint = .zero

    var isEditingText: Bool { editor != nil }

    private var strokeWidth: CGFloat { max(3, image.size.width / 400) }
    private var fontSize: CGFloat { max(16, image.size.height * 0.045) }
    private var scale: CGFloat { image.size.width > 0 ? bounds.width / image.size.width : 1 }

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds)
        guard scale > 0 else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        let t = NSAffineTransform()
        t.scale(by: scale)
        t.concat()
        for a in annotations { a.render() }
        inProgress?.render()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // MARK: 鼠标

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        commitTextEditor()
        switch tool {
        case .move:
            if event.clickCount == 2 {
                (window as? PinWindow)?.actualSize()
                return
            }
            window?.performDrag(with: event)
        case .text:
            beginTextEntry(at: imagePoint(event))
        case .pen:
            dragStart = imagePoint(event)
            inProgress = PinAnnotation(shape: .pen([dragStart]), color: color, width: strokeWidth)
        case .line:
            dragStart = imagePoint(event)
            inProgress = PinAnnotation(shape: .line(dragStart, dragStart), color: color, width: strokeWidth)
        case .arrow:
            dragStart = imagePoint(event)
            inProgress = PinAnnotation(shape: .arrow(dragStart, dragStart), color: color, width: strokeWidth)
        case .rect:
            dragStart = imagePoint(event)
            inProgress = PinAnnotation(shape: .rect(CGRect(origin: dragStart, size: .zero)), color: color, width: strokeWidth)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard inProgress != nil else { return }
        let p = imagePoint(event)
        switch inProgress!.shape {
        case .pen(var points):
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) > 1.5 / max(scale, 0.01) {
                points.append(p)
            }
            inProgress!.shape = .pen(points)
        case .line:
            inProgress!.shape = .line(dragStart, p)
        case .arrow:
            inProgress!.shape = .arrow(dragStart, p)
        case .rect:
            inProgress!.shape = .rect(CGRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                                             width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y)))
        case .text:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let a = inProgress {
            // 过小的形状(误点)不保留
            var keep = true
            switch a.shape {
            case .pen(let pts): keep = pts.count > 1
            case .line(let s, let e), .arrow(let s, let e): keep = hypot(e.x - s.x, e.y - s.y) > 2
            case .rect(let r): keep = r.width > 2 && r.height > 2
            case .text: break
            }
            if keep { annotations.append(a) }
            inProgress = nil
            needsDisplay = true
        }
    }

    // MARK: 文字标注

    private func beginTextEntry(at point: CGPoint) {
        commitTextEditor()
        editorImagePoint = point
        let field = NSTextField(frame: NSRect(x: point.x * scale, y: point.y * scale,
                                              width: max(120, bounds.width - point.x * scale - 8),
                                              height: fontSize * scale + 10))
        field.font = .boldSystemFont(ofSize: fontSize * scale)
        field.textColor = color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "输入文字,回车确认"
        field.delegate = self
        addSubview(field)
        editor = field
        window?.makeKey()
        window?.makeFirstResponder(field)
    }

    func commitTextEditor() {
        guard let field = editor else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            annotations.append(PinAnnotation(
                shape: .text(text, editorImagePoint, fontSize),
                color: color, width: strokeWidth))
        }
        field.removeFromSuperview()
        editor = nil
        needsDisplay = true
    }

    private func cancelTextEditor() {
        editor?.removeFromSuperview()
        editor = nil
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditor()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditor()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditor()
            return true
        }
        return false
    }

    // MARK: 撤销 / 导出

    func undo() {
        if inProgress != nil {
            inProgress = nil
        } else {
            _ = annotations.popLast()
        }
        needsDisplay = true
    }

    /// 合成标注后的图片(保持原始像素分辨率)
    func compositedImage() -> NSImage {
        guard !annotations.isEmpty else { return image }
        var pw = Int(image.size.width), ph = Int(image.size.height)
        if let rep = image.representations.first {
            if rep.pixelsWide > 0 { pw = rep.pixelsWide }
            if rep.pixelsHigh > 0 { ph = rep.pixelsHigh }
        }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        bitmap.size = image.size // 让绘制坐标系保持「点」,自动映射到全分辨率像素
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        for a in annotations { a.render() }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: image.size)
        out.addRepresentation(bitmap)
        return out
    }

    // MARK: 悬停显示工具栏

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        (window as? PinWindow)?.showToolbar()
    }

    override func mouseExited(with event: NSEvent) {
        (window as? PinWindow)?.scheduleToolbarHide()
    }

    // MARK: 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let win = window as? PinWindow else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "撤销标注", action: #selector(PinWindow.undoAnnotation), keyEquivalent: "z").target = win
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制图片", action: #selector(PinWindow.copyImage), keyEquivalent: "c").target = win
        menu.addItem(withTitle: "另存为…", action: #selector(PinWindow.saveImage), keyEquivalent: "s").target = win
        menu.addItem(withTitle: "实际大小(双击)", action: #selector(PinWindow.actualSize), keyEquivalent: "").target = win
        menu.addItem(.separator())
        if win.isCapturePreview {
            menu.addItem(withTitle: "贴图", action: #selector(PinWindow.pinCapture), keyEquivalent: "").target = win
            menu.addItem(withTitle: "完成", action: #selector(PinWindow.closePin), keyEquivalent: "w").target = win
        } else {
            menu.addItem(withTitle: "关闭贴图(⌫)", action: #selector(PinWindow.closePin), keyEquivalent: "w").target = win
            menu.addItem(withTitle: "关闭所有贴图", action: #selector(PinWindow.closeAllPins), keyEquivalent: "").target = win
        }
        return menu
    }
}

// MARK: - 悬浮标注工具栏(跟随贴图窗口的子窗口)

final class PinToolbarPanel: NSPanel {
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                    .systemGreen, .systemBlue, .white, .black]

    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []

    init(pin: PinWindow, isCapturePreview: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = pin.level
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8

        var views: [NSView] = []

        let moveTip = isCapturePreview ? "移动 / 拖动截图预览" : "移动 / 拖动贴图"
        let tools: [(PinTool, String, String)] = [
            (.move, "cursorarrow", moveTip),
            (.pen, "scribble", "画笔"),
            (.line, "line.diagonal", "直线"),
            (.arrow, "arrow.up.right", "箭头"),
            (.rect, "rectangle", "矩形框"),
            (.text, "textformat", "文字"),
        ]
        for (tool, symbol, tip) in tools {
            let b = makeButton(symbol: symbol, tip: tip, target: pin, action: #selector(PinWindow.selectTool(_:)))
            b.tag = tool.rawValue
            toolButtons.append(b)
            views.append(b)
        }
        views.append(separator())
        for (i, c) in Self.colors.enumerated() {
            let b = NSButton(title: "", target: pin, action: #selector(PinWindow.pickColor(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 7
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.gray.withAlphaComponent(0.6).cgColor
            b.toolTip = "标注颜色"
            b.widthAnchor.constraint(equalToConstant: 14).isActive = true
            b.heightAnchor.constraint(equalToConstant: 14).isActive = true
            colorButtons.append(b)
            views.append(b)
        }
        views.append(separator())
        views.append(makeButton(symbol: "arrow.uturn.backward", tip: "撤销标注 (⌘Z)", target: pin, action: #selector(PinWindow.undoAnnotation)))
        views.append(makeButton(symbol: "doc.on.doc", tip: "复制到剪贴板 (⌘C)", target: pin, action: #selector(PinWindow.copyImage)))
        views.append(makeButton(symbol: "square.and.arrow.down", tip: "另存为… (⌘S)", target: pin, action: #selector(PinWindow.saveImage)))
        if isCapturePreview {
            views.append(separator())
            views.append(makeButton(symbol: "pin.fill", tip: "贴图", target: pin, action: #selector(PinWindow.pinCapture)))
            views.append(makeButton(symbol: "checkmark", tip: "完成", target: pin, action: #selector(PinWindow.closePin)))
        } else {
            views.append(makeButton(symbol: "xmark", tip: "关闭贴图 (⌫)", target: pin, action: #selector(PinWindow.closePin)))
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)

        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect

        let size = stack.fittingSize
        setContentSize(NSSize(width: size.width, height: size.height))

        highlightTool(.move)
        highlightColor(0)
    }

    override var canBecomeKey: Bool { false }

    private func makeButton(symbol: String, tip: String, target: AnyObject, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: img, target: target, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        return b
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    func highlightTool(_ tool: PinTool) {
        for b in toolButtons {
            b.contentTintColor = (b.tag == tool.rawValue) ? .controlAccentColor : .secondaryLabelColor
        }
    }

    func highlightColor(_ index: Int) {
        for b in colorButtons {
            b.layer?.borderWidth = (b.tag == index) ? 2.5 : 1
            b.layer?.borderColor = (b.tag == index)
                ? NSColor.controlAccentColor.cgColor
                : NSColor.gray.withAlphaComponent(0.6).cgColor
        }
    }
}
