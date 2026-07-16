import AppKit

// MARK: - 截图:区域截图(系统交互式)/ 截图并贴图(自绘选区)/ 剪贴板贴图

final class ScreenshotController {
    static let shared = ScreenshotController()
    private let fm = FileManager.default

    // MARK: 权限预检:重新安装(签名变化)后旧授权会静默失效,这里显式检测

    @discardableResult
    func ensureScreenPermission(kind: String) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess() // 触发系统弹窗 / 把 App 加进权限列表
        NSLog("EasyRight: screen capture permission missing (%@)", kind)
        showPermissionAlert(kind: kind)
        return false
    }

    // MARK: 区域截图(系统原生十字选框,支持按空格切换窗口模式)

    func captureInteractive() {
        guard ensureScreenPermission(kind: "截图") else { return }
        let tmp = tmpPath()
        runScreencapture(["-i", "-x", tmp]) { [self] in
            guard fm.fileExists(atPath: tmp), let image = NSImage(contentsOfFile: tmp) else {
                NSLog("EasyRight: interactive capture cancelled or failed")
                return
            }
            finish(image: image, tmpFile: tmp, prefix: "截图", pinRect: nil, forcePin: false)
        }
    }

    // MARK: 截图并贴图(自绘选区 → 精确捕获 → 原位浮起)

    func captureAndPin() {
        guard ensureScreenPermission(kind: "截图") else { return }
        RegionSelector.select { [self] nsRect in
            guard let nsRect else { return }
            let cg = cocoaToCG(nsRect)
            let rectArg = String(format: "%.0f,%.0f,%.0f,%.0f", cg.origin.x, cg.origin.y, cg.width, cg.height)
            let tmp = tmpPath()
            // 等选区遮罩完全消失再截
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.runScreencapture(["-R", rectArg, "-x", tmp]) {
                    guard let image = NSImage(contentsOfFile: tmp) else {
                        NSLog("EasyRight: region capture failed (可能未授予屏幕录制权限)")
                        self.showPermissionAlert(kind: "截图")
                        return
                    }
                    self.finish(image: image, tmpFile: tmp, prefix: "截图", pinRect: nsRect, forcePin: true)
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

    // MARK: 通用收尾:按配置 复制 / 保存 / 贴图

    func finish(image: NSImage, tmpFile: String?, prefix: String, pinRect: NSRect?, forcePin: Bool) {
        let cfg = EasyConfig.load()
        let pin = forcePin || cfg.pinAfterCapture
        if cfg.copyAfterCapture {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        }
        if cfg.saveAfterCapture {
            try? fm.createDirectory(atPath: cfg.saveDir, withIntermediateDirectories: true)
            let dest = cfg.saveDir + "/\(prefix) \(timestamp()).png"
            if let tmpFile {
                try? fm.moveItem(atPath: tmpFile, toPath: dest)
            } else if let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dest))
            }
        } else if let tmpFile {
            try? fm.removeItem(atPath: tmpFile)
        }
        if pin {
            PinManager.shared.pin(image: image, at: pinRect)
        }
        NSLog("EasyRight: capture finished %.0fx%.0f pin=%d", image.size.width, image.size.height, pin ? 1 : 0)
    }

    // MARK: 工具

    func runScreencapture(_ args: [String], completion: @escaping () -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { _ in
            DispatchQueue.main.async(execute: completion)
        }
        do {
            try p.run()
        } catch {
            NSLog("EasyRight: screencapture launch failed %@", error.localizedDescription)
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
