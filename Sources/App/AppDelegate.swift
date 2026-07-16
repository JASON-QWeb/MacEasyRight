import AppKit
import SwiftUI

extension Notification.Name {
    static let easyConfigChanged = Notification.Name("EasyConfigChanged")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var recordMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 首次启动写入默认配置,让扩展有配置可读
        if FileManager.default.contents(atPath: kConfigFilePath) == nil {
            EasyConfig.defaultConfig().save()
        }
        setupStatusItem()
        HotkeyManager.shared.reload(config: EasyConfig.load())

        NotificationCenter.default.addObserver(forName: .easyConfigChanged, object: nil, queue: .main) { [weak self] _ in
            HotkeyManager.shared.reload(config: EasyConfig.load())
            self?.rebuildStatusMenu()
        }
        Recorder.shared.onStateChange = { [weak self] in
            self?.updateRecordingUI()
        }
        NSLog("EasyRight: launched")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let cmd = decodeCommand(from: url) {
                CommandHandler.shared.handle(cmd)
            }
        }
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
        _ = add("截图并贴图", #selector(actCapturePin), hotkeyKey: "capturePin", symbol: "pin")
        _ = add("贴图(剪贴板图片)", #selector(actPinClipboard), hotkeyKey: "pinClipboard", symbol: "doc.on.clipboard")
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

    // MARK: - 动作

    @objc private func actCapture() { ScreenshotController.shared.captureInteractive() }
    @objc private func actCapturePin() { ScreenshotController.shared.captureAndPin() }
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
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }
}
