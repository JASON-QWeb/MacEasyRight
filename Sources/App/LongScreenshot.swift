import AppKit
import ApplicationServices

// MARK: - 长截图:框选并调整范围 → 点「开始」 → 持续监控页面滚动并拼接 → 点「停止」保存

final class LongScreenshot: @unchecked Sendable {
    static let shared = LongScreenshot()

    private var running = false
    private var stopRequested = false
    private let stopLock = NSLock()
    private var panel: LongshotPanel?
    private var adjuster: RegionAdjustWindow?
    private var border: RecordBorderWindow?
    private var sourceApplication: NSRunningApplication?
    private var frameSource: LongshotFrameSource?

    private let maxTotalHeight = 25000 // 像素
    private let maxSlices = 120
    private let maxDuration: TimeInterval = 600 // 10 分钟硬上限

    /// 快捷键 / 菜单入口:设置阶段 → 视为点「开始」;进行中 → 停止;否则进入框选
    @MainActor
    func start() {
        if running {
            requestStop()
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

    @MainActor
    private func cancelSetup() {
        panel?.close()
        panel = nil
        adjuster?.orderOut(nil)
        adjuster = nil
        sourceApplication = nil
    }

    @MainActor
    private func beginLoop(_ nsRect: NSRect, autoScroll: Bool) {
        running = true
        setStopRequested(false)
        adjuster?.orderOut(nil)
        adjuster = nil
        border = RecordBorderWindow(around: nsRect)
        panel?.switchToMonitoring(autoScroll: autoScroll)
        // 恢复框选前的前台应用。控制面板是 nonactivatingPanel，仍可浮在上方并响应停止按钮。
        sourceApplication?.activate(options: [.activateIgnoringOtherApps])
        let cgRect = cocoaToCG(nsRect)
        NSLog("EasyRight: longshot begin rect=%@ autoScroll=%d", NSStringFromRect(nsRect), autoScroll ? 1 : 0)
        let source = LongshotFrameSource()
        frameSource = source
        let center = CGPoint(x: cgRect.midX, y: cgRect.midY)
        let scrollPoints = Int32(cgRect.height * 0.55)
        Task { [weak self] in
            do {
                try await source.start(cgRect: cgRect)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.captureLoop(
                        source: source,
                        autoScroll: autoScroll,
                        scrollLocation: center,
                        scrollPoints: scrollPoints
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finish(nil, appended: 0, autoScroll: autoScroll,
                                 failureMessage: "无法开始长截图：\n\(error.localizedDescription)")
                }
            }
        }
    }

    private func captureLoop(
        source: LongshotFrameSource,
        autoScroll: Bool,
        scrollLocation: CGPoint,
        scrollPoints: Int32
    ) {
        let store: LongshotSliceStore
        do {
            store = try LongshotSliceStore()
        } catch {
            finishOnMain(
                nil,
                appended: 0,
                autoScroll: autoScroll,
                failureMessage: "无法创建长截图临时目录：\n\(error.localizedDescription)"
            )
            return
        }
        // acceptedFrame 永远是最后一张已经成功拼进结果的帧。匹配失败时不能推进它，
        // 否则滚动过程中的模糊/动态帧会吞掉一整段内容，手动模式尤其容易只剩首屏。
        var acceptedFrame: StitchFrame?
        var totalHeight = 0
        var frameIndex = 0
        var generation = 0
        var endStreak = 0
        var matchFailureStreak = 0
        var limitMessage: String?
        let startTime = Date()

        usleep(400_000) // 等调整层消失

        while !isStopRequested() {
            if store.count >= maxSlices {
                limitMessage = "已达到 \(maxSlices) 个拼接片段上限，结果已保存到当前进度。"
                break
            }
            if totalHeight >= maxTotalHeight {
                limitMessage = "已达到 \(maxTotalHeight) 像素高度上限，结果已保存到当前进度。"
                break
            }
            if Date().timeIntervalSince(startTime) > maxDuration {
                limitMessage = "已达到 10 分钟时长上限，结果已保存到当前进度。"
                break
            }

            guard let snapshot = source.nextFrame(after: generation, timeout: 2),
                  let frame = makeFrame(snapshot.image) else {
                if isStopRequested() { break }
                NSLog("EasyRight: longshot frame unavailable")
                break
            }
            generation = snapshot.generation
            let cg = snapshot.image

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
                        do {
                            try store.append(slice)
                            totalHeight += newRows
                            acceptedFrame = frame
                            madeProgress = true
                        } catch {
                            finishOnMain(nil, appended: store.count, autoScroll: autoScroll,
                                         failureMessage: "保存长截图片段失败：\n\(error.localizedDescription)")
                            return
                        }
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
                do {
                    try store.append(cg)
                    totalHeight += frame.height
                    acceptedFrame = frame
                    madeProgress = true
                } catch {
                    finishOnMain(nil, appended: 0, autoScroll: autoScroll,
                                 failureMessage: "保存长截图首帧失败：\n\(error.localizedDescription)")
                    return
                }
            }
            frameIndex += 1

            let shownHeight = totalHeight
            let shownCount = store.count
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
                postScroll(totalPoints: scrollPoints, at: scrollLocation)
            }
            usleep(autoScroll ? 700_000 : 280_000)
        }

        let result = store.compose()
        let appended = store.count
        let stoppedBeforeFirstFrame = isStopRequested() && appended == 0
        finishOnMain(
            result,
            appended: appended,
            autoScroll: autoScroll,
            failureMessage: result == nil && !stoppedBeforeFirstFrame ? "长截图合成失败。" : nil,
            noticeMessage: limitMessage
        )
    }

    private func finishOnMain(
        _ image: CGImage?,
        appended: Int,
        autoScroll: Bool,
        failureMessage: String?,
        noticeMessage: String? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.finish(
                image,
                appended: appended,
                autoScroll: autoScroll,
                failureMessage: failureMessage,
                noticeMessage: noticeMessage
            )
        }
    }

    @MainActor
    private func finish(
        _ image: CGImage?,
        appended: Int,
        autoScroll: Bool,
        failureMessage: String? = nil,
        noticeMessage: String? = nil
    ) {
        let source = frameSource
        frameSource = nil
        Task { await source?.stop() }
        panel?.close()
        panel = nil
        border?.orderOut(nil)
        border = nil
        sourceApplication = nil
        running = false
        guard let image else {
            NSLog("EasyRight: longshot produced nothing")
            if let failureMessage { showLongshotError(failureMessage) }
            return
        }
        let nsImage = NSImage(cgImage: image, size: .zero)
        ScreenshotController.shared.finish(image: nsImage, tmpFile: nil, prefix: "长截图", pinRect: nil, forcePin: false)
        let cfg = EasyConfig.load()
        if cfg.saveAfterCapture {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cfg.saveDir)
        }
        NSLog("EasyRight: longshot done %dx%d (%d slices)", image.width, image.height, appended)
        if let noticeMessage {
            showLongshotNotice(noticeMessage)
        }

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

    private func makeFrame(_ cg: CGImage) -> StitchFrame? {
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return StitchFrame(width: w, height: h, pixels: pixels)
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

    /// 分块发送滚轮事件:一次性大增量会被部分应用忽略,小步多次更接近真实滚动
    private func postScroll(totalPoints: Int32, at location: CGPoint) {
        let chunk: Int32 = 80
        var remaining = totalPoints
        while remaining > 0 {
            let step = min(chunk, remaining)
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0) {
                // 指定事件位置即可把滚轮发给选区下方窗口，无需移动真实鼠标。
                e.location = location
                e.post(tap: .cghidEventTap)
            }
            remaining -= step
            usleep(25_000)
        }
    }

    private func requestStop() { setStopRequested(true) }

    private func setStopRequested(_ value: Bool) {
        stopLock.lock()
        stopRequested = value
        stopLock.unlock()
    }

    private func isStopRequested() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    @MainActor
    private func showLongshotError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "长截图失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @MainActor
    private func showLongshotNotice(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "长截图已达到安全上限"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

// MARK: - 长截图控制面板:设置阶段(自动滚动开关 + 开始/取消) → 监控阶段(进度 + 停止)

@MainActor
private final class LongshotPanel: NSObject {
    private let panel: FloatingHUDPanel
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
        panel = FloatingHUDPanel()
        super.init()

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

        panel.setHUDContent(container)
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
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
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
        panel.fitContent()
    }

    private func position() {
        panel.position(relativeTo: rect, placement: .belowOrAbove)
    }
}
