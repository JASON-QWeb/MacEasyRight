import AppKit

// MARK: - 截图:框选区域 → 保存/复制 → 显示预览和编辑工具栏

@MainActor
final class ScreenshotController {
    static let shared = ScreenshotController()
    private let fm = FileManager.default
    private var capturePreview: PinWindow?

    // MARK: 权限预检:重新安装(签名变化)后旧授权会静默失效,这里显式检测

    @discardableResult
    func ensureScreenPermission(kind: String) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let defaultsKey = "EasyRightHasRequestedScreenCaptureAccess"
        let requestedBefore = UserDefaults.standard.bool(forKey: defaultsKey)
        UserDefaults.standard.set(true, forKey: defaultsKey)
        let accepted = CGRequestScreenCaptureAccess() // 首次只显示系统授权流程
        NSLog("EasyRight: screen capture permission missing (%@)", kind)
        if accepted && CGPreflightScreenCaptureAccess() { return true }
        if requestedBefore { showPermissionAlert(kind: kind) }
        return false
    }

    // MARK: 区域截图

    func captureInteractive() {
        startRegionCapture(pinImmediately: false)
    }

    // MARK: 兼容入口：截图后直接贴图

    func captureAndPin() {
        startRegionCapture(pinImmediately: true)
    }

    private func startRegionCapture(pinImmediately: Bool) {
        guard ensureScreenPermission(kind: "截图") else { return }
        dismissCapturePreview()
        RegionSelector.select { [self] nsRect in
            guard let nsRect else { return }
            let cg = cocoaToCG(nsRect)
            let rectArg = String(format: "%.0f,%.0f,%.0f,%.0f", cg.origin.x, cg.origin.y, cg.width, cg.height)
            let tmp = tmpPath()
            // 等选区遮罩完全消失再截
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.runScreencapture(["-R", rectArg, "-x", tmp]) { launchError in
                    if let launchError {
                        self.showCaptureError("无法启动系统截图工具", detail: launchError.localizedDescription)
                        return
                    }
                    guard let image = NSImage(contentsOfFile: tmp) else {
                        NSLog("EasyRight: region capture failed")
                        self.removeTemporaryCapture(at: tmp)
                        if CGPreflightScreenCaptureAccess() {
                            self.showCaptureError("截图失败", detail: "系统截图工具没有生成图片，请重试。")
                        } else {
                            self.showPermissionAlert(kind: "截图")
                        }
                        return
                    }
                    self.finish(
                        image: image,
                        tmpFile: tmp,
                        prefix: "截图",
                        pinRect: nsRect,
                        pinImmediately: pinImmediately
                    )
                    if !pinImmediately { self.showCapturePreview(image: image, rect: nsRect) }
                }
            }
        }
    }

    // MARK: 剪贴板贴图

    func pinFromClipboard() {
        guard let image = NSImage(pasteboard: .general) else {
            NSSound.beep()
            NSLog("EasyRight: clipboard has no image")
            return
        }
        PinManager.shared.pin(image: image, at: nil)
    }

    // MARK: 通用收尾:按配置复制/保存；只有明确点击或兼容指令才贴图

    func finish(
        image: NSImage,
        tmpFile: String?,
        prefix: String,
        pinRect: NSRect?,
        pinImmediately: Bool
    ) {
        let cfg = EasyConfig.load()
        if cfg.copyAfterCapture {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        }
        if cfg.saveAfterCapture {
            do {
                try fm.createDirectory(atPath: cfg.saveDir, withIntermediateDirectories: true)
                let dest = uniqueOutputURL(directory: cfg.saveDir, baseName: "\(prefix) \(timestamp())", extension: "png")
                if let tmpFile {
                    try fm.moveItem(at: URL(fileURLWithPath: tmpFile), to: dest)
                } else {
                    guard let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        throw NSError(
                            domain: "EasyRight.Capture",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "无法把截图编码为 PNG"]
                        )
                    }
                    try png.write(to: dest, options: .atomic)
                }
            } catch {
                showSaveError("保存截图失败", error: error)
            }
        } else if let tmpFile {
            do {
                if fm.fileExists(atPath: tmpFile) { try fm.removeItem(atPath: tmpFile) }
            } catch {
                NSLog("EasyRight: failed to remove capture temp file: %@", error.localizedDescription)
            }
        }
        if pinImmediately {
            PinManager.shared.pin(image: image, at: pinRect)
        }
        NSLog(
            "EasyRight: capture finished %.0fx%.0f pin=%d",
            image.size.width,
            image.size.height,
            pinImmediately ? 1 : 0
        )
    }

    private func showCapturePreview(image: NSImage, rect: NSRect) {
        dismissCapturePreview()
        let preview = PinWindow(
            image: image,
            frame: rect,
            purpose: .capturePreview,
            onPreviewFinished: { [weak self] in
                self?.capturePreview = nil
            }
        )
        capturePreview = preview
        preview.orderFrontRegardless()
    }

    private func dismissCapturePreview() {
        capturePreview?.closePin()
    }

    // MARK: 工具

    func runScreencapture(
        _ args: [String],
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { _ in
            Task { @MainActor in completion(nil) }
        }
        do {
            try p.run()
        } catch {
            NSLog("EasyRight: screencapture launch failed %@", error.localizedDescription)
            Task { @MainActor in completion(error) }
        }
    }

    func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return df.string(from: Date())
    }

    private func tmpPath() -> String {
        NSTemporaryDirectory() + "easyright-\(UUID().uuidString).png"
    }

    private func removeTemporaryCapture(at path: String) {
        guard fm.fileExists(atPath: path) else { return }
        do {
            try fm.removeItem(atPath: path)
        } catch {
            NSLog("EasyRight: failed to remove capture temp file: %@", error.localizedDescription)
        }
    }

    func uniqueOutputURL(directory: String, baseName: String, extension ext: String) -> URL {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var candidate = directoryURL.appendingPathComponent("\(baseName).\(ext)")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(baseName) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private func showSaveError(_ title: String, error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showCaptureError(_ title: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    func showPermissionAlert(kind: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        \(kind)需要屏幕录制权限。请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 EasyRight,然后重新触发。

        注意:如果之前已经勾选过但仍提示此消息,是因为应用重新安装后授权失效——请把列表中的 EasyRight 移除(选中后点「-」),再重新添加并勾选。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
