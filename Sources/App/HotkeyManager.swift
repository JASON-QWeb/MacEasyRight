import AppKit
import Carbon.HIToolbox

// MARK: - 快捷键动作定义

enum HotkeyAction: String, CaseIterable {
    case capture
    case capturePin
    case pinClipboard
    case record
    case longshot

    var label: String {
        switch self {
        case .capture:      return "区域截图"
        case .capturePin:   return "截图并贴图"
        case .pinClipboard: return "贴图(剪贴板图片)"
        case .record:       return "开始 / 停止录屏"
        case .longshot:     return "长截图(自动滚动)"
        }
    }

    func perform() {
        switch self {
        case .capture:      ScreenshotController.shared.captureInteractive()
        case .capturePin:   ScreenshotController.shared.captureAndPin()
        case .pinClipboard: ScreenshotController.shared.pinFromClipboard()
        case .record:       Recorder.shared.toggle()
        case .longshot:     LongScreenshot.shared.start()
        }
    }
}

// MARK: - Carbon 全局热键注册

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1
    private var handlerInstalled = false

    func reload(config: EasyConfig) {
        unregisterAll()
        for action in HotkeyAction.allCases {
            guard let hk = config.hotkeys[action.rawValue] else { continue }
            register(hk) { action.perform() }
        }
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
        nextId = 1
    }

    private func register(_ hk: HotkeyConfig, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4553_5254), id: nextId) // "ESRT"
        let status = RegisterEventHotKey(UInt32(hk.keyCode), hk.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            actions[nextId] = action
            nextId += 1
            NSLog("EasyRight: hotkey registered %@", hotkeyDisplay(hk))
        } else {
            NSLog("EasyRight: hotkey register FAILED %@ status=%d", hotkeyDisplay(hk), status)
        }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { HotkeyManager.shared.fire(hkID.id) }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
