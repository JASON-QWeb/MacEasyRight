import AppKit
import UniformTypeIdentifiers

@MainActor
final class CommandHandler {
    static let shared = CommandHandler()
    private let fm = FileManager.default

    func handle(_ cmd: Command) {
        guard validate(cmd) else {
            NSLog("EasyRight: rejected invalid %@ command", cmd.action.rawValue)
            showError("收到的操作参数无效，已拒绝执行。")
            return
        }
        switch cmd.action {
        case .createFile: createFile(cmd.fileKind, in: cmd.dest)
        case .copyTo:     _ = transfer(cmd.targets, to: cmd.dest, move: false)
        case .moveTo:     _ = transfer(cmd.targets, to: cmd.dest, move: true)
        case .copyChoose: chooseAndTransfer(cmd.targets, move: false)
        case .moveChoose: chooseAndTransfer(cmd.targets, move: true)
        case .cut:        saveCutState(cmd.targets)
        case .paste:      paste(to: cmd.dest)
        case .copyPath:   copyPath(cmd.targets)
        case .iconChoose: chooseIcon(for: cmd.targets)
        case .iconReset:  resetIcon(for: cmd.targets)
        case .open:       open(appName: cmd.app)
        // 截图/录屏也可由 Finder 扩展通过已认证的 easyright:// URL 触发。
        case .screenshot:    ScreenshotController.shared.captureInteractive()
        case .screenshotPin: ScreenshotController.shared.captureAndPin()
        case .pinClipboard:  ScreenshotController.shared.pinFromClipboard()
        case .record:        Recorder.shared.toggle()
        case .longshot:      LongScreenshot.shared.start()
        case .closePins:     PinManager.shared.closeAll()
        case .settings:      (NSApp.delegate as? AppDelegate)?.openSettings()
        }
    }

    private func validate(_ cmd: Command) -> Bool {
        func isDirectory(_ path: String?) -> Bool {
            guard let path else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        func targetsExist() -> Bool {
            !cmd.targets.isEmpty && cmd.targets.allSatisfy { fm.fileExists(atPath: $0) }
        }

        switch cmd.action {
        case .createFile:
            return cmd.fileKind != nil && isDirectory(cmd.dest)
        case .copyTo, .moveTo:
            return targetsExist() && isDirectory(cmd.dest)
        case .copyChoose, .moveChoose, .cut, .copyPath, .iconChoose, .iconReset:
            return targetsExist()
        case .paste:
            return isDirectory(cmd.dest)
        case .open:
            // targets 可能来自尚未重载的旧扩展，为了升级兼容直接忽略。
            return cmd.dest == nil && cmd.fileKind == nil &&
                kKnownApps.contains { $0.name == cmd.app }
        case .screenshot, .screenshotPin, .pinClipboard, .record, .longshot, .closePins, .settings:
            return cmd.targets.isEmpty && cmd.dest == nil && cmd.app == nil && cmd.fileKind == nil
        }
    }

    // MARK: - 新建文件

    private func createFile(_ kind: NewFileKind?, in directoryPath: String?) {
        guard let kind, let directoryPath else { return }
        do {
            let url = try NewFileCreator(fileManager: fm).create(kind, inDirectoryPath: directoryPath)
            NSLog("EasyRight: created %@", url.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("EasyRight: create file failed in %@: %@", directoryPath, error.localizedDescription)
            showError("新建文件失败：\n\(error.localizedDescription)")
        }
    }

    // MARK: - 复制 / 移动

    private struct TransferOutcome {
        var failedPaths: [String] = []
        var errorMessages: [String] = []
    }

    @discardableResult
    private func transfer(_ paths: [String], to dest: String?, move: Bool) -> TransferOutcome {
        guard let dest, !paths.isEmpty else { return TransferOutcome() }
        let destDir = URL(fileURLWithPath: dest, isDirectory: true)
        var outcome = TransferOutcome()
        for p in paths {
            let src = URL(fileURLWithPath: p)
            // 移动到自身所在目录没有意义,跳过
            if move, src.deletingLastPathComponent().standardizedFileURL.path == destDir.standardizedFileURL.path {
                outcome.failedPaths.append(p)
                outcome.errorMessages.append("\(src.lastPathComponent)：已位于目标文件夹")
                continue
            }
            let target = uniqueDestination(for: src.lastPathComponent, in: destDir)
            do {
                if move {
                    try fm.moveItem(at: src, to: target)
                } else {
                    try fm.copyItem(at: src, to: target)
                }
            } catch {
                outcome.failedPaths.append(p)
                outcome.errorMessages.append("\(src.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !outcome.errorMessages.isEmpty {
            showError((move ? "移动" : "复制") + "未全部完成：\n" + outcome.errorMessages.joined(separator: "\n"))
        }
        return outcome
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
        _ = transfer(paths, to: dest.path, move: move)
    }

    private func paste(to dest: String?) {
        guard let dest, let state = CutState.load() else { return }
        let outcome = transfer(state.paths, to: dest, move: true)
        do {
            if outcome.failedPaths.isEmpty {
                try CutState.clear()
            } else {
                try CutState(paths: outcome.failedPaths).save()
            }
        } catch {
            showError("更新剪切状态失败：\n\(error.localizedDescription)")
        }
    }

    private func saveCutState(_ paths: [String]) {
        do {
            try CutState(paths: paths).save()
        } catch {
            showError("保存剪切状态失败：\n\(error.localizedDescription)")
        }
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
        var failures: [String] = []
        for p in paths {
            if !NSWorkspace.shared.setIcon(image, forFile: p, options: []) {
                failures.append((p as NSString).lastPathComponent)
            }
        }
        if !failures.isEmpty {
            showError("以下项目设置图标失败：\n" + failures.joined(separator: "\n"))
        }
    }

    private func resetIcon(for paths: [String]) {
        var failures: [String] = []
        for p in paths {
            if !NSWorkspace.shared.setIcon(nil, forFile: p, options: []) {
                failures.append((p as NSString).lastPathComponent)
            }
        }
        if !failures.isEmpty {
            showError("以下项目恢复默认图标失败：\n" + failures.joined(separator: "\n"))
        }
    }

    // MARK: - 启动 App

    private func open(appName: String?) {
        guard let appName,
              let known = kKnownApps.first(where: { $0.name == appName }) else { return }
        guard let application = appURL(for: known) else {
            NSLog("EasyRight: application %@ is no longer available", appName)
            showError("未找到「\(appName)」，请确认该应用已安装。")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) { [weak self] app, error in
            if error == nil, app != nil {
                NSLog("EasyRight: activated application %@", appName)
                return
            }
            let detail = error?.localizedDescription ?? "系统未返回已启动的应用"
            NSLog("EasyRight: failed to activate application %@: %@", appName, detail)
            Task { @MainActor [weak self] in
                self?.showError("无法打开「\(appName)」：\n\(detail)")
            }
        }
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
