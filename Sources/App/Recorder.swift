import AppKit

// MARK: - 录屏流程编排:框选范围 → 设置面板(帧率/格式) → 开始 → 红框指示 → 停止落盘

final class Recorder {
    static let shared = Recorder()

    var onStateChange: (() -> Void)?

    private let engine = ScreenRecorder()
    private var setupPanel: RecordSetupPanel?
    private var adjuster: RegionAdjustWindow?
    private var border: RecordBorderWindow?

    var isRecording: Bool { engine.isRecording }

    /// 快捷键 / 菜单入口:未开始 → 进入选区;设置面板已打开 → 视为点「开始」;录制中 → 停止
    func toggle() {
        if engine.isRecording {
            stop()
        } else if let panel = setupPanel {
            panel.triggerStart()
        } else {
            begin()
        }
    }

    private func begin() {
        guard ScreenshotController.shared.ensureScreenPermission(kind: "录屏") else { return }
        RegionSelector.select { [self] rect in
            guard let rect, rect.width >= 40, rect.height >= 40 else { return }
            // 选完进入可调整状态:拖动移动、拖手柄缩放
            let adj = RegionAdjustWindow(rect: rect, minSize: 40)
            adj.onChange = { [weak self] r in self?.setupPanel?.updateRect(r) }
            adj.onCancel = { [weak self] in self?.cancelSetup() }
            adjuster = adj
            let cfg = EasyConfig.load()
            setupPanel = RecordSetupPanel(
                rect: rect, fps: cfg.recordFPS, format: cfg.recordFormat,
                onStart: { [self] finalRect, fps, format in
                    // 把本次选择记为默认值
                    var c = EasyConfig.load()
                    c.recordFPS = fps
                    c.recordFormat = format
                    c.save()
                    startEngine(rect: finalRect, fps: fps, format: format)
                },
                onCancel: { [self] in
                    cancelSetup()
                },
                onRectChanged: { [self] newRect in
                    adjuster?.setRect(newRect)
                }
            )
        }
    }

    private func cancelSetup() {
        setupPanel?.close()
        setupPanel = nil
        adjuster?.orderOut(nil)
        adjuster = nil
        border?.orderOut(nil)
        border = nil
    }

    private func startEngine(rect: NSRect, fps: Int, format: String) {
        adjuster?.orderOut(nil)
        adjuster = nil
        if border == nil { border = RecordBorderWindow(around: rect) }
        engine.start(
            cocoaRect: rect, fps: fps, format: format,
            onStarted: { [self] in
                setupPanel?.switchToRecording()
                onStateChange?()
            },
            onFailed: { [self] message in
                teardownUI()
                onStateChange?()
                showRecordError(message)
            },
            onFinished: { [self] url in
                teardownUI()
                onStateChange?()
                if let url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        )
    }

    func stop() {
        engine.stop()
    }

    private func teardownUI() {
        setupPanel?.close()
        setupPanel = nil
        adjuster?.orderOut(nil)
        adjuster = nil
        border?.orderOut(nil)
        border = nil
    }

    private func showRecordError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "录屏失败"
        alert.informativeText = message + "\n\n如果是首次使用,请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 EasyRight 后重试。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 录制设置 / 控制面板

final class RecordSetupPanel: NSObject {
    private let panel: NSPanel
    private var rect: NSRect
    private let onStart: (NSRect, Int, String) -> Void
    private let onCancel: () -> Void

    private let sizeLabel = NSTextField(labelWithString: "")
    private let fpsPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private var setupStack: NSStackView!
    private var recordStack: NSStackView!
    private var timer: Timer?
    private var startDate: Date?
    private var started = false
    private var onRectChanged: ((NSRect) -> Void)?

    private static let fpsOptions = [60, 30, 24, 15]
    private static let formatOptions: [(title: String, value: String)] = [
        ("MP4(H.264,通用)", "mp4"),
        ("MOV(HEVC,更小)", "mov"),
    ]

    init(rect: NSRect, fps: Int, format: String,
         onStart: @escaping (NSRect, Int, String) -> Void,
         onCancel: @escaping () -> Void,
         onRectChanged: ((NSRect) -> Void)? = nil) {
        self.rect = rect
        self.onStart = onStart
        self.onCancel = onCancel
        self.onRectChanged = onRectChanged
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 108),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10

        // --- 设置状态 ---
        sizeLabel.font = .systemFont(ofSize: 12)
        updateSizeLabel()
        let fullscreenBtn = NSButton(title: "改为全屏", target: self, action: #selector(useFullScreen))
        fullscreenBtn.bezelStyle = .rounded
        fullscreenBtn.controlSize = .small
        let row1 = NSStackView(views: [sizeLabel, fullscreenBtn])
        row1.spacing = 8

        for f in Self.fpsOptions { fpsPopup.addItem(withTitle: "\(f) FPS") }
        fpsPopup.selectItem(at: Self.fpsOptions.firstIndex(of: fps) ?? 1)
        fpsPopup.controlSize = .small
        for f in Self.formatOptions { formatPopup.addItem(withTitle: f.title) }
        formatPopup.selectItem(at: Self.formatOptions.firstIndex { $0.value == format } ?? 0)
        formatPopup.controlSize = .small
        let row2 = NSStackView(views: [fpsPopup, formatPopup])
        row2.spacing = 8

        let startBtn = NSButton(title: "● 开始录制", target: self, action: #selector(startClicked))
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"
        startBtn.contentTintColor = .systemRed
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        let row3 = NSStackView(views: [startBtn, cancelBtn])
        row3.spacing = 8

        setupStack = NSStackView(views: [row1, row2, row3])
        setupStack.orientation = .vertical
        setupStack.alignment = .centerX
        setupStack.spacing = 8
        setupStack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        // --- 录制中状态 ---
        let dot = NSTextField(labelWithString: "●")
        dot.textColor = .systemRed
        dot.font = .systemFont(ofSize: 13)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let stopBtn = NSButton(title: "停止", target: self, action: #selector(stopClicked))
        stopBtn.bezelStyle = .rounded
        stopBtn.controlSize = .small
        recordStack = NSStackView(views: [dot, timeLabel, stopBtn])
        recordStack.orientation = .horizontal
        recordStack.spacing = 10
        recordStack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        recordStack.isHidden = true

        let container = NSStackView(views: [setupStack, recordStack])
        container.orientation = .vertical
        container.spacing = 0

        effect.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            container.topAnchor.constraint(equalTo: effect.topAnchor),
            container.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        resizeToFit()
        position()
        panel.orderFrontRegardless()
    }

    // MARK: 状态切换

    /// 选区被拖动 / 缩放后同步(仅更新显示,不回调)
    func updateRect(_ r: NSRect) {
        rect = r
        updateSizeLabel()
        position()
    }

    func triggerStart() {
        if !started { startClicked() }
    }

    func switchToRecording() {
        setupStack.isHidden = true
        recordStack.isHidden = false
        resizeToFit()
        position()
        startDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let d = self.startDate else { return }
            let s = Int(Date().timeIntervalSince(d))
            self.timeLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    // MARK: 动作

    @objc private func startClicked() {
        guard !started else { return }
        started = true
        let fps = Self.fpsOptions[max(0, fpsPopup.indexOfSelectedItem)]
        let format = Self.formatOptions[max(0, formatPopup.indexOfSelectedItem)].value
        onStart(rect, fps, format)
    }

    @objc private func cancelClicked() {
        close()
        onCancel()
    }

    @objc private func stopClicked() {
        Recorder.shared.stop()
    }

    @objc private func useFullScreen() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) }
            ?? NSScreen.main
        if let sf = screen?.frame {
            rect = sf
            updateSizeLabel()
            position()
            onRectChanged?(sf)
        }
    }

    // MARK: 布局

    private func updateSizeLabel() {
        sizeLabel.stringValue = "录制区域:\(Int(rect.width)) × \(Int(rect.height))"
    }

    private func resizeToFit() {
        if let size = panel.contentView?.fittingSize {
            panel.setContentSize(size)
        }
    }

    private func position() {
        let size = panel.frame.size
        var x = rect.midX - size.width / 2
        var y = rect.minY - size.height - 10
        let screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) }
            ?? NSScreen.main
        if let sf = screen?.visibleFrame {
            if y < sf.minY { y = sf.minY + 12 } // 全屏时贴底部(录制画面里看不到,已被排除)
            x = max(sf.minX + 8, min(x, sf.maxX - size.width - 8))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 录制区域红框指示(不响应鼠标;已从录制画面中排除)

final class RecordBorderWindow: NSWindow {
    init(around rect: NSRect) {
        super.init(contentRect: rect.insetBy(dx: -4, dy: -4),
                   styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = BorderView()
        orderFrontRegardless()
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.setStroke()
            path.stroke()
        }
    }
}
