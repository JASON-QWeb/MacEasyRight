import AppKit
import FinderSync
import SwiftUI

extension Notification.Name {
    static let easyConfigChanged = Notification.Name("EasyConfigChanged")
    static let hotkeyRegistrationFailed = Notification.Name("HotkeyRegistrationFailed")
    static let finderExtensionRegistrationChanged = Notification.Name("FinderExtensionRegistrationChanged")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var recordMenuItem: NSMenuItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        var startupErrors: [String] = []
        // 首次启动写入默认配置,让扩展有配置可读
        if FileManager.default.contents(atPath: kConfigFilePath) == nil {
            do {
                try EasyConfig.defaultConfig().save()
            } catch {
                NSLog("EasyRight: failed to create default config: %@", error.localizedDescription)
                startupErrors.append("创建默认配置失败：\(error.localizedDescription)")
            }
        }
        do {
            _ = try CommandAuthentication.ensureToken()
        } catch {
            NSLog("EasyRight: failed to initialize command authentication: %@", error.localizedDescription)
            startupErrors.append("初始化 Finder 指令认证失败：\(error.localizedDescription)")
        }
        setupStatusItem()
        _ = HotkeyManager.shared.reload(config: EasyConfig.load())
        repairFinderExtensionRegistrationIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configChanged(_:)),
            name: .easyConfigChanged,
            object: nil
        )
        Recorder.shared.onStateChange = { [weak self] in
            self?.updateRecordingUI()
        }

        // 只在用户直接启动应用时展示 Dashboard。URL、文件、服务等非默认启动
        // 由 AppKit 通过 launchIsDefaultUserInfoKey 明确标识，无需猜延迟。
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue ?? true
        if isDefaultLaunch { openSettings() }
        if !startupErrors.isEmpty { showStartupErrors(startupErrors) }
        NSLog("EasyRight: launched")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if isCommandBootstrapURL(url) {
                do {
                    _ = try CommandAuthentication.ensureToken()
                } catch {
                    NSLog("EasyRight: command bootstrap failed: %@", error.localizedDescription)
                    showStartupErrors([
                        "初始化 Finder 指令认证失败：\(error.localizedDescription)"
                    ])
                }
                continue
            }
            guard let token = CommandAuthentication.loadToken(),
                  let cmd = decodeCommand(from: url, expectedToken: token) else {
                NSLog("EasyRight: rejected unauthenticated or malformed command URL")
                continue
            }
            CommandHandler.shared.handle(cmd)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: "EasyRight")
            ?? NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "EasyRight")
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let cfg = EasyConfig.load()
        let menu = NSMenu()

        func add(_ title: String, _ sel: Selector, hotkeyKey: String? = nil, symbol: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            // 菜单里展示当前全局快捷键(仅展示用,真正触发靠全局热键)
            if let key = hotkeyKey, let hk = cfg.hotkeys[key],
               let name = kKeyNames[hk.keyCode], name.count == 1 {
                item.keyEquivalent = name.lowercased()
                item.keyEquivalentModifierMask = nsModifiers(hk.modifiers)
            }
            menu.addItem(item)
            return item
        }

        _ = add("区域截图", #selector(actCapture), hotkeyKey: "capture", symbol: "camera.viewfinder")
        _ = add("贴图(剪贴板图片)", #selector(actPinClipboard), symbol: "doc.on.clipboard")
        _ = add("长截图", #selector(actLongshot), hotkeyKey: "longshot", symbol: "arrow.down.doc")
        recordMenuItem = add(Recorder.shared.isRecording ? "停止录屏" : "开始录屏",
                             #selector(actToggleRecord), hotkeyKey: "record", symbol: "record.circle")
        menu.addItem(.separator())
        _ = add("关闭所有贴图", #selector(actCloseAllPins), symbol: "xmark.square")
        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let ext = NSMenuItem(title: "在系统设置中管理 Finder 扩展", action: #selector(openExtensionSettings), keyEquivalent: "")
        ext.target = self
        menu.addItem(ext)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 EasyRight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func updateRecordingUI() {
        let recording = Recorder.shared.isRecording
        recordMenuItem?.title = recording ? "停止录屏" : "开始录屏"
        if let btn = statusItem?.button {
            btn.image = NSImage(
                systemSymbolName: recording ? "record.circle.fill" : "contextualmenu.and.cursorarrow",
                accessibilityDescription: "EasyRight"
            )
            btn.contentTintColor = recording ? .systemRed : nil
        }
    }

    @objc private func configChanged(_ note: Notification) {
        guard note.userInfo?["hotkeysChanged"] as? Bool == true else { return }
        let failures = HotkeyManager.shared.reload(config: EasyConfig.load())
        rebuildStatusMenu()
        if !failures.isEmpty {
            NotificationCenter.default.post(
                name: .hotkeyRegistrationFailed,
                object: nil,
                userInfo: ["message": failures.map(\.userMessage).joined(separator: "\n")]
            )
        }
    }

    private func showStartupErrors(_ errors: [String]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "EasyRight 初始化失败"
        alert.informativeText = errors.joined(separator: "\n\n")
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func repairFinderExtensionRegistrationIfNeeded() {
        Task {
            let result = await FinderExtensionManager.repairIfNeeded(reloadFinder: true)
            if result.changed {
                NSLog("EasyRight: repaired Finder extension registration")
            }
            for error in result.errors {
                NSLog("EasyRight: Finder extension repair warning: %@", error)
            }
            NotificationCenter.default.post(
                name: .finderExtensionRegistrationChanged,
                object: nil,
                userInfo: result.errors.isEmpty ? nil : ["errors": result.errors]
            )
        }
    }

    // MARK: - 动作

    @objc private func actCapture() { ScreenshotController.shared.captureInteractive() }
    @objc private func actPinClipboard() { ScreenshotController.shared.pinFromClipboard() }
    @objc private func actLongshot() { LongScreenshot.shared.start() }
    @objc private func actToggleRecord() { Recorder.shared.toggle() }
    @objc private func actCloseAllPins() { PinManager.shared.closeAll() }

    @objc func openSettings() {
        // 每次打开都重建内容,保证显示最新配置和最新界面
        let hosting = NSHostingController(rootView: SettingsView())
        if let win = settingsWindow {
            win.contentViewController = hosting
        } else {
            let win = NSWindow(contentViewController: hosting)
            win.title = "EasyRight 设置"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 820, height: 650))
            win.minSize = NSSize(width: 760, height: 600)
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }
}
