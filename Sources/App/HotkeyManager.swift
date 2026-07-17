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

    @MainActor
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

@MainActor
final class HotkeyManager {
    struct RegistrationFailure {
        let action: HotkeyAction
        let hotkey: HotkeyConfig
        let status: OSStatus

        var userMessage: String {
            if status == eventHotKeyExistsErr {
                return "\(action.label)：\(hotkeyDisplay(hotkey)) 已被系统或其他应用占用"
            }
            return "\(action.label)：\(hotkeyDisplay(hotkey)) 注册失败（错误码 \(status)）"
        }
    }

    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1
    private var handlerInstalled = false
    private(set) var lastFailures: [RegistrationFailure] = []

    @discardableResult
    func reload(config: EasyConfig) -> [RegistrationFailure] {
        unregisterAll()
        var failures: [RegistrationFailure] = []
        for action in HotkeyAction.allCases {
            guard let hk = config.hotkeys[action.rawValue] else { continue }
            if let status = register(hk, action: { action.perform() }) {
                failures.append(RegistrationFailure(action: action, hotkey: hk, status: status))
            }
        }
        lastFailures = failures
        return failures
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
        nextId = 1
    }

    private func register(_ hk: HotkeyConfig, action: @escaping () -> Void) -> OSStatus? {
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return handlerStatus }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4553_5254), id: nextId) // "ESRT"
        let status = RegisterEventHotKey(UInt32(hk.keyCode), hk.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            actions[nextId] = action
            nextId += 1
            NSLog("EasyRight: hotkey registered %@", hotkeyDisplay(hk))
            return nil
        } else {
            NSLog("EasyRight: hotkey register FAILED %@ status=%d", hotkeyDisplay(hk), status)
            return status
        }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard !handlerInstalled else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { HotkeyManager.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
        if status != noErr {
            NSLog("EasyRight: failed to install hotkey event handler status=%d", status)
        }
        return status
    }
}
