import AppKit
import UniformTypeIdentifiers

final class CommandHandler {
    static let shared = CommandHandler()
    private let fm = FileManager.default

    func handle(_ cmd: Command) {
        switch cmd.action {
        case "copyTo":     transfer(cmd.targets, to: cmd.dest, move: false)
        case "moveTo":     transfer(cmd.targets, to: cmd.dest, move: true)
        case "copyChoose": chooseAndTransfer(cmd.targets, move: false)
        case "moveChoose": chooseAndTransfer(cmd.targets, move: true)
        case "cut":        CutState(paths: cmd.targets).save()
        case "paste":      paste(to: cmd.dest)
        case "copyPath":   copyPath(cmd.targets)
        case "iconChoose": chooseIcon(for: cmd.targets)
        case "iconReset":  resetIcon(for: cmd.targets)
        case "open":       open(cmd.targets, appName: cmd.app)
        // 截图/录屏也可通过 easyright:// URL 触发(脚本化入口)
        case "screenshot":    ScreenshotController.shared.captureInteractive()
        case "screenshotPin": ScreenshotController.shared.captureAndPin()
        case "pinClipboard":  ScreenshotController.shared.pinFromClipboard()
        case "record":        Recorder.shared.toggle()
        case "longshot":      LongScreenshot.shared.start()
        case "closePins":     PinManager.shared.closeAll()
        case "settings":      (NSApp.delegate as? AppDelegate)?.openSettings()
        default: break
        }
    }

    // MARK: - 复制 / 移动

    private func transfer(_ paths: [String], to dest: String?, move: Bool) {
        guard let dest, !paths.isEmpty else { return }
        let destDir = URL(fileURLWithPath: dest, isDirectory: true)
        var errors: [String] = []
        for p in paths {
            let src = URL(fileURLWithPath: p)
            // 移动到自身所在目录没有意义,跳过
            if move, src.deletingLastPathComponent().path == destDir.path { continue }
            let target = uniqueDestination(for: src.lastPathComponent, in: destDir)
            do {
                if move {
                    try fm.moveItem(at: src, to: target)
                } else {
                    try fm.copyItem(at: src, to: target)
                }
            } catch {
                errors.append("\(src.lastPathComponent):\(error.localizedDescription)")
            }
        }
        if !errors.isEmpty {
            showError((move ? "移动" : "复制") + "失败:\n" + errors.joined(separator: "\n"))
        }
    }

    private func chooseAndTransfer(_ paths: [String], move: Bool) {
        guard !paths.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = move ? "选择要移动到的文件夹" : "选择要复制到的文件夹"
        panel.prompt = move ? "移动" : "复制"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        transfer(paths, to: dest.path, move: move)
    }

    private func paste(to dest: String?) {
        guard let dest, let state = CutState.load() else { return }
        transfer(state.paths, to: dest, move: true)
        CutState.clear()
    }

    /// 目标已存在时自动改名:xxx 2.txt、xxx 3.txt …
    private func uniqueDestination(for name: String, in dir: URL) -> URL {
        var candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let newName = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    // MARK: - 拷贝路径

    private func copyPath(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: - 自定义图标

    private func chooseIcon(for paths: [String]) {
        guard !paths.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择一张图片作为图标"
        panel.prompt = "设置图标"
        guard panel.runModal() == .OK, let imgURL = panel.url,
              let image = NSImage(contentsOf: imgURL) else { return }
        for p in paths {
            NSWorkspace.shared.setIcon(image, forFile: p, options: [])
        }
    }

    private func resetIcon(for paths: [String]) {
        for p in paths {
            NSWorkspace.shared.setIcon(nil, forFile: p, options: [])
        }
    }

    // MARK: - 用 App 打开

    private func open(_ paths: [String], appName: String?) {
        guard let appName, !paths.isEmpty,
              let known = kKnownApps.first(where: { $0.name == appName }),
              let application = appURL(for: known) else { return }

        var urls: [URL] = []
        if known.opensFolderOnly {
            // 终端类:文件 → 其所在目录;文件夹 → 自身;去重
            var seen = Set<String>()
            for p in paths {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: p, isDirectory: &isDir)
                let dir = isDir.boolValue ? p : (p as NSString).deletingLastPathComponent
                if seen.insert(dir).inserted {
                    urls.append(URL(fileURLWithPath: dir, isDirectory: true))
                }
            }
        } else {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - 错误提示

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "EasyRight"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
