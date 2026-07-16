import AppKit
import ApplicationServices

// MARK: - 长截图:框选并调整范围 → 点「开始」 → 持续监控页面滚动并拼接 → 点「停止」保存

final class LongScreenshot {
    static let shared = LongScreenshot()

    private var running = false
    private var stopRequested = false
    private var panel: LongshotPanel?
    private var adjuster: RegionAdjustWindow?
    private var border: RecordBorderWindow?
    private var sourceApplication: NSRunningApplication?

    private let maxTotalHeight = 25000 // 像素
    private let maxSlices = 120
    private let maxDuration: TimeInterval = 600 // 10 分钟硬上限

    /// 快捷键 / 菜单入口:设置阶段 → 视为点「开始」;进行中 → 停止;否则进入框选
    func start() {
        if running {
            stopRequested = true
            return
        }
        if let p = panel {
            p.triggerStart()
            return
        }
        guard ScreenshotController.shared.ensureScreenPermission(kind: "长截图") else { return }

        // RegionSelector 会激活 EasyRight。记住用户正在滚动的应用，开始后把焦点还给它，
        // 否则部分浏览器/文档应用不会把手动滚轮事件交给页面。
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            sourceApplication = frontmost
        } else {
            sourceApplication = nil
        }

        RegionSelector.select { [self] rect in
            guard let rect, rect.width >= 80, rect.height >= 80 else {
                sourceApplication = nil
                return
            }
            let adj = RegionAdjustWindow(rect: rect, minSize: 80)
            adj.onChange = { [weak self] r in self?.panel?.updateRect(r) }
            adj.onCancel = { [weak self] in self?.cancelSetup() }
            adjuster = adj
            panel = LongshotPanel(
                rect: rect,
                autoScrollAvailable: AXIsProcessTrusted(),
                onStart: { [self] autoScroll in
                    let finalRect = adjuster?.rect ?? rect
                    beginLoop(finalRect, autoScroll: autoScroll)
                },
                onCancel: { [self] in cancelSetup() }
            )
        }
    }

    private func cancelSetup() {
        panel?.close()
        panel = nil
        adjuster?.orderOut(nil)
        adjuster = nil
        sourceApplication = nil
    }

    private func beginLoop(_ nsRect: NSRect, autoScroll: Bool) {
        running = true
        stopRequested = false
        adjuster?.orderOut(nil)
        adjuster = nil
        border = RecordBorderWindow(around: nsRect)
        panel?.switchToMonitoring(autoScroll: autoScroll)
        // 恢复框选前的前台应用。控制面板是 nonactivatingPanel，仍可浮在上方并响应停止按钮。
        sourceApplication?.activate(options: [.activateIgnoringOtherApps])
        let cgRect = cocoaToCG(nsRect)
        NSLog("EasyRight: longshot begin rect=%@ autoScroll=%d", NSStringFromRect(nsRect), autoScroll ? 1 : 0)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            captureLoop(cgRect: cgRect, autoScroll: autoScroll)
        }
    }

    private func captureLoop(cgRect: CGRect, autoScroll: Bool) {
        let rectArg = String(format: "%.0f,%.0f,%.0f,%.0f",
                             cgRect.origin.x, cgRect.origin.y, cgRect.width, cgRect.height)
        let center = CGPoint(x: cgRect.midX, y: cgRect.midY)
        var slices: [CGImage] = []
        // acceptedFrame 永远是最后一张已经成功拼进结果的帧。匹配失败时不能推进它，
        // 否则滚动过程中的模糊/动态帧会吞掉一整段内容，手动模式尤其容易只剩首屏。
        var acceptedFrame: StitchFrame?
        var totalHeight = 0
        var frameIndex = 0
        var endStreak = 0
        var matchFailureStreak = 0
        let startTime = Date()

        usleep(400_000) // 等调整层消失

        while !stopRequested {
            if slices.count >= maxSlices || totalHeight >= maxTotalHeight { break }
            if Date().timeIntervalSince(startTime) > maxDuration { break }

            let tmp = NSTemporaryDirectory() + "easyright-long-\(frameIndex % 4).png"
            captureSync(rectArg: rectArg, to: tmp)
            guard let (cg, frame) = loadFrame(tmp) else {
                NSLog("EasyRight: longshot frame load failed")
                break
            }
            try? FileManager.default.removeItem(atPath: tmp)

            var allowNextAutoScroll = true
            var madeProgress = false
            var unchanged = false
            if let p = acceptedFrame {
                let offset = Stitcher.scrollOffset(prev: p, cur: frame)
                if let off = offset, off > 0 {
                    endStreak = 0
                    matchFailureStreak = 0
                    let newRows = min(off, frame.height)
                    if let slice = copySlice(cg, fromRow: frame.height - newRows, rows: newRows) {
                        slices.append(slice)
                        totalHeight += newRows
                        acceptedFrame = frame
                        madeProgress = true
                    }
                    NSLog("EasyRight: longshot frame %d offset=%d total=%d", frameIndex, off, totalHeight)
                } else if offset == 0 {
                    // 画面稳定但没有向下移动。自动模式连续两次视为到底；手动模式继续等待。
                    matchFailureStreak = 0
                    endStreak += 1
                    unchanged = true
                    if autoScroll && endStreak >= 2 {
                        NSLog("EasyRight: longshot auto reached end")
                        break
                    }
                } else {
                    // 当前帧可能截在惯性滚动/动画中，或滚得太快而失去重叠。
                    // 保留 acceptedFrame 并重试；自动模式本轮也不再继续向下滚，以免越错越远。
                    endStreak = 0
                    matchFailureStreak += 1
                    allowNextAutoScroll = false
                    NSLog("EasyRight: longshot frame %d overlap not found (retry %d)",
                          frameIndex, matchFailureStreak)
                }
            } else {
                slices.append(cg)
                totalHeight += frame.height
                acceptedFrame = frame
                madeProgress = true
            }
            frameIndex += 1

            let shownHeight = totalHeight
            let shownCount = slices.count
            let progressText: String
            if matchFailureStreak >= 2 {
                progressText = autoScroll ? "正在重新识别重叠区域…" : "未识别到重叠，请慢一点或稍向上回滚"
            } else if unchanged {
                progressText = autoScroll ? "正在确认是否到底…" : "等待手动向下滚动…"
            } else if madeProgress {
                progressText = "已拼接 \(shownCount) 段 / \(shownHeight) px"
            } else {
                progressText = "正在识别重叠区域…"
            }
            DispatchQueue.main.async { [weak self] in
                self?.panel?.updateProgress(progressText)
            }

            if autoScroll && allowNextAutoScroll {
                postScroll(totalPoints: Int32(cgRect.height * 0.55), at: center)
            }
            usleep(autoScroll ? 700_000 : 280_000)
        }

        let result = compose(slices)
        let appended = slices.count
        DispatchQueue.main.async { [self] in
            finish(result, appended: appended, autoScroll: autoScroll)
        }
    }

    private func finish(_ image: CGImage?, appended: Int, autoScroll: Bool) {
        panel?.close()
        panel = nil
        border?.orderOut(nil)
        border = nil
        sourceApplication = nil
        running = false
        guard let image else {
            NSLog("EasyRight: longshot produced nothing")
            ScreenshotController.shared.showPermissionAlert(kind: "长截图")
            return
        }
        let nsImage = NSImage(cgImage: image, size: .zero)
        ScreenshotController.shared.finish(image: nsImage, tmpFile: nil, prefix: "长截图", pinRect: nil, forcePin: false)
        let cfg = EasyConfig.load()
        if cfg.saveAfterCapture {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cfg.saveDir)
        }
        NSLog("EasyRight: longshot done %dx%d (%d slices)", image.width, image.height, appended)

        if appended <= 1, autoScroll {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "只截到了一屏"
            alert.informativeText = """
            自动滚动似乎没有生效,常见原因:
            1. 「辅助功能」授权失效——重新安装应用后,需要在 系统设置 → 隐私与安全性 → 辅助功能 里把 EasyRight 移除后重新添加;
            2. 选区内不是可滚动的内容。
            也可以在开始前取消勾选「自动滚动」,改为自己滚动页面。
            """
            alert.addButton(withTitle: "打开辅助功能设置")
            alert.addButton(withTitle: "好")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 帧处理

    private func captureSync(rectArg: String, to path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-R", rectArg, "-x", path]
        try? p.run()
        p.waitUntilExit()
    }

    private func loadFrame(_ path: String) -> (CGImage, StitchFrame)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (cg, StitchFrame(width: w, height: h, pixels: pixels))
    }

    /// 从帧底部裁出新增内容并复制成独立位图(fromRow 以图像顶部为原点)
    private func copySlice(_ img: CGImage, fromRow: Int, rows: Int) -> CGImage? {
        guard rows > 0,
              let cropped = img.cropping(to: CGRect(x: 0, y: fromRow, width: img.width, height: rows)),
              let ctx = CGContext(data: nil, width: img.width, height: rows,
                                  bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: img.width, height: rows))
        return ctx.makeImage()
    }

    private func compose(_ slices: [CGImage]) -> CGImage? {
        guard let first = slices.first else { return nil }
        let w = first.width
        let totalH = slices.reduce(0) { $0 + $1.height }
        guard totalH > 0,
              let ctx = CGContext(data: nil, width: w, height: totalH,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var yFromTop = 0
        for s in slices {
            let cgY = totalH - yFromTop - s.height // CGContext 原点在左下
            ctx.draw(s, in: CGRect(x: 0, y: cgY, width: s.width, height: s.height))
            yFromTop += s.height
        }
        return ctx.makeImage()
    }

    /// 分块发送滚轮事件:一次性大增量会被部分应用忽略,小步多次更接近真实滚动
    private func postScroll(totalPoints: Int32, at center: CGPoint) {
        CGWarpMouseCursorPosition(center)
        usleep(30_000)
        let chunk: Int32 = 80
        var remaining = totalPoints
        while remaining > 0 {
            let step = min(chunk, remaining)
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0) {
                e.location = center
                e.post(tap: .cghidEventTap)
            }
            remaining -= step
            usleep(25_000)
        }
    }
}

// MARK: - 长截图控制面板:设置阶段(自动滚动开关 + 开始/取消) → 监控阶段(进度 + 停止)

private final class LongshotPanel: NSObject {
    private let panel: NSPanel
    private var rect: NSRect
    private let onStart: (Bool) -> Void
    private let onCancel: () -> Void

    private let sizeLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "滚动页面,应用会持续拼接…")
    private let autoCheck: NSButton
    private var setupStack: NSStackView!
    private var monitorStack: NSStackView!
    private var started = false

    init(rect: NSRect, autoScrollAvailable: Bool,
         onStart: @escaping (Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.rect = rect
        self.onStart = onStart
        self.onCancel = onCancel
        autoCheck = NSButton(checkboxWithTitle: "自动滚动(需辅助功能权限)", target: nil, action: nil)
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

        // --- 设置阶段 ---
        sizeLabel.font = .systemFont(ofSize: 12)
        updateSizeLabel()

        autoCheck.controlSize = .small
        autoCheck.state = autoScrollAvailable ? .on : .off
        autoCheck.isEnabled = autoScrollAvailable
        var row2Views: [NSView] = [autoCheck]
        if !autoScrollAvailable {
            let grantBtn = NSButton(title: "去授权…", target: self, action: #selector(grantAX))
            grantBtn.bezelStyle = .rounded
            grantBtn.controlSize = .small
            row2Views.append(grantBtn)
        }
        let row2 = NSStackView(views: row2Views)
        row2.spacing = 8

        let startBtn = NSButton(title: "开始长截图", target: self, action: #selector(startClicked))
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        let row3 = NSStackView(views: [startBtn, cancelBtn])
        row3.spacing = 8

        setupStack = NSStackView(views: [sizeLabel, row2, row3])
        setupStack.orientation = .vertical
        setupStack.alignment = .centerX
        setupStack.spacing = 8
        setupStack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        // --- 监控阶段 ---
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let stopBtn = NSButton(title: "停止并保存", target: self, action: #selector(stopClicked))
        stopBtn.bezelStyle = .rounded
        stopBtn.controlSize = .small
        monitorStack = NSStackView(views: [progressLabel, stopBtn])
        monitorStack.orientation = .horizontal
        monitorStack.spacing = 10
        monitorStack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        monitorStack.isHidden = true

        let container = NSStackView(views: [setupStack, monitorStack])
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

    // MARK: 对外

    func updateRect(_ r: NSRect) {
        rect = r
        updateSizeLabel()
        position()
    }

    func triggerStart() {
        if !started { startClicked() }
    }

    func switchToMonitoring(autoScroll: Bool) {
        setupStack.isHidden = true
        monitorStack.isHidden = false
        progressLabel.stringValue = autoScroll ? "自动滚动中…" : "请滚动页面,持续拼接中…"
        resizeToFit()
        position()
    }

    func updateProgress(_ text: String) {
        progressLabel.stringValue = text
    }

    func close() {
        panel.orderOut(nil)
    }

    // MARK: 动作

    @objc private func startClicked() {
        guard !started else { return }
        started = true
        onStart(autoCheck.state == .on && autoCheck.isEnabled)
    }

    @objc private func cancelClicked() {
        close()
        onCancel()
    }

    @objc private func stopClicked() {
        LongScreenshot.shared.start() // 进行中再触发 = 停止
    }

    @objc private func grantAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 布局

    private func updateSizeLabel() {
        sizeLabel.stringValue = "长截图区域:\(Int(rect.width)) × \(Int(rect.height))"
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
            if y < sf.minY { y = rect.maxY + 10 }
            if y + size.height > sf.maxY { y = sf.minY + 12 }
            x = max(sf.minX + 8, min(x, sf.maxX - size.width - 8))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
