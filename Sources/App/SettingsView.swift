import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import FinderSync

final class ConfigStore: ObservableObject {
    @Published var config: EasyConfig {
        didSet {
            config.save()
            NotificationCenter.default.post(name: .easyConfigChanged, object: nil)
        }
    }
    init() { config = EasyConfig.load() }
}

final class SystemStatusStore: ObservableObject {
    @Published private(set) var finderExtensionEnabled = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false

    init() { refresh() }

    func refresh() {
        finderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func openFinderExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
        refreshAfterReturningFromSystemSettings()
    }

    func openScreenRecordingSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        refreshAfterReturningFromSystemSettings()
    }

    func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        refreshAfterReturningFromSystemSettings()
    }

    private func refreshAfterReturningFromSystemSettings() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case overview
    case rightMenu
    case capture

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview:  return "概览"
        case .rightMenu: return "右键菜单"
        case .capture:   return "截图与录屏"
        }
    }
    var symbol: String {
        switch self {
        case .overview:  return "square.grid.2x2"
        case .rightMenu: return "cursorarrow.click.2"
        case .capture:   return "camera.viewfinder"
        }
    }
}

struct SettingsView: View {
    @StateObject private var store = ConfigStore()
    @StateObject private var systemStatus = SystemStatusStore()
    @State private var destination: SettingsDestination? = .overview

    var body: some View {
        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $destination) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(Optional(item))
            }
            .navigationTitle("EasyRight")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            switch destination ?? .overview {
            case .overview:
                OverviewDashboard(status: systemStatus)
            case .rightMenu:
                RightMenuSettingsTab(store: store)
            case .capture:
                CaptureSettingsTab(store: store)
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { systemStatus.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemStatus.refresh()
        }
    }
}

// MARK: - 概览 / 首次使用引导

private struct OverviewDashboard: View {
    @ObservedObject var status: SystemStatusStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("EasyRight")
                            .font(.system(size: 28, weight: .bold))
                        Text("Finder 右键增强、截图、贴图与录屏")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }

                StatusCard(
                    title: "Finder 右键扩展",
                    detail: status.finderExtensionEnabled
                        ? "扩展已启用。现在可以在 Finder 的文件、文件夹或空白处点击右键。"
                        : "需要在系统设置中启用 EasyRight 扩展，右键菜单才会出现。",
                    isReady: status.finderExtensionEnabled,
                    readyText: "已启用",
                    actionTitle: "打开 Finder 扩展设置",
                    action: status.openFinderExtensionSettings
                )

                HStack(alignment: .top, spacing: 14) {
                    StatusCard(
                        title: "屏幕录制",
                        detail: "截图、录屏和长截图需要此权限。",
                        isReady: status.screenRecordingGranted,
                        readyText: "已授权",
                        actionTitle: "打开权限设置",
                        action: status.openScreenRecordingSettings
                    )
                    StatusCard(
                        title: "辅助功能",
                        detail: "自动滚动长截图需要此权限。",
                        isReady: status.accessibilityGranted,
                        readyText: "已授权",
                        actionTitle: "打开权限设置",
                        action: status.openAccessibilitySettings
                    )
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("安装后的首次使用", systemImage: "checklist")
                            .font(.headline)
                        Text("1. 启用 Finder 扩展\n2. 回到 Finder 重新点击右键\n3. 使用截图或长截图时再按系统提示授权")
                            .foregroundColor(.secondary)
                        if status.finderExtensionEnabled {
                            Text("如果刚启用后菜单仍未出现，请关闭并重新打开 Finder 窗口；必要时重新启动 Finder。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                HStack {
                    Button("重新检查状态") { status.refresh() }
                    Button("在 Finder 中查看主目录") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: realHomePath(), isDirectory: true))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatusCard: View {
    let title: String
    let detail: String
    let isReady: Bool
    let readyText: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(isReady ? .green : .orange)
                    Text(title).font(.headline)
                    Spacer()
                    Text(isReady ? readyText : "需要设置")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(isReady ? .green : .orange)
                }
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isReady {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                } else {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .frame(maxWidth: .infinity)
    }
}

private func openSystemSettings(_ value: String) {
    if let url = URL(string: value) { NSWorkspace.shared.open(url) }
}

// MARK: - 右键菜单设置

struct RightMenuSettingsTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section("「复制/移动到」目标文件夹") {
                ForEach(store.config.folders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            store.config.folders.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("添加文件夹…") { addFolder() }
            }

            Section("「进入 App」菜单项(未安装的不会出现在右键菜单)") {
                ForEach(kKnownApps, id: \.name) { app in
                    Toggle(isOn: binding(for: app.name)) {
                        HStack {
                            Text(app.name)
                            if appURL(for: app) == nil {
                                Text("(未安装)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section("其他菜单项") {
                Toggle("快捷新建 TXT / MD / JSON", isOn: $store.config.showNewFile)
                Toggle("拷贝路径", isOn: $store.config.showCopyPath)
                Toggle("剪切 / 粘贴", isOn: $store.config.showCutPaste)
                Toggle("自定义文件(夹)图标", isOn: $store.config.showCustomIcon)
            }

            Section {
                Text("修改会立即保存,在 Finder 中重新右键即可看到最新菜单。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { store.config.apps.contains(name) },
            set: { on in
                if on {
                    if !store.config.apps.contains(name) { store.config.apps.append(name) }
                } else {
                    store.config.apps.removeAll { $0 == name }
                }
            }
        )
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            for u in panel.urls where !store.config.folders.contains(u.path) {
                store.config.folders.append(u.path)
            }
        }
    }
}

// MARK: - 截图与录屏设置

struct CaptureSettingsTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section("全局快捷键(点击后按下新的组合键,Esc 取消)") {
                ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                    HStack {
                        Text(action.label)
                        Spacer()
                        HotkeyRecorderButton(hotkey: hotkeyBinding(for: action))
                        Button("清除") {
                            store.config.hotkeys.removeValue(forKey: action.rawValue)
                        }
                        .disabled(store.config.hotkeys[action.rawValue] == nil)
                    }
                }
            }

            Section("截图后") {
                Toggle("打开贴图窗口(可标注、另存为)", isOn: $store.config.pinAfterCapture)
                Toggle("复制到剪贴板", isOn: $store.config.copyAfterCapture)
                Toggle("保存图片文件", isOn: $store.config.saveAfterCapture)
                HStack {
                    Text("保存位置")
                    Text(store.config.saveDir)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("选择…") { chooseSaveDir() }
                }
            }

            Section("录屏默认参数(开始录制前还可以再改)") {
                Picker("帧率", selection: $store.config.recordFPS) {
                    Text("60 FPS").tag(60)
                    Text("30 FPS").tag(30)
                    Text("24 FPS").tag(24)
                    Text("15 FPS").tag(15)
                }
                Picker("格式", selection: $store.config.recordFormat) {
                    Text("MP4(H.264,通用)").tag("mp4")
                    Text("MOV(HEVC,体积更小)").tag("mov")
                }
            }

            Section("使用说明") {
                Text("""
                • 首次截图 / 录屏时,系统会请求「屏幕录制」权限;重新安装应用后需要移除并重新添加授权。
                • 录屏:快捷键 → 框选范围(可拖动 / 拖手柄调整)→ 选帧率 / 格式 → 开始;再按快捷键或点「停止」结束,控制条和红框不会被录进去。
                • 长截图:框选并调整范围 → 点「开始」→ 自动滚动或自己滚动页面,应用持续监控拼接 → 点「停止并保存」。
                • 贴图:鼠标移入出现工具栏,可画笔 / 直线 / 箭头 / 矩形 / 文字标注,⌘Z 撤销;拖动移动、滚轮缩放、双击原始大小;⌫ 或 Esc 直接删除贴图。
                """)
                .font(.footnote)
                .foregroundColor(.secondary)
                HStack {
                    Button("屏幕录制权限设置") {
                        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    }
                    Button("辅助功能权限设置") {
                        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func hotkeyBinding(for action: HotkeyAction) -> Binding<HotkeyConfig?> {
        Binding(
            get: { store.config.hotkeys[action.rawValue] },
            set: { store.config.hotkeys[action.rawValue] = $0 }
        )
    }

    private func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            store.config.saveDir = url.path
        }
    }

    private func openURL(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - 快捷键录入按钮

struct HotkeyRecorderButton: View {
    @Binding var hotkey: HotkeyConfig?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "请按下快捷键…" : (hotkey.map(hotkeyDisplay) ?? "未设置")) {
            recording ? stopRecording() : startRecording()
        }
        .frame(minWidth: 110)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = carbonModifiers(event.modifierFlags)
            // Esc(无修饰键)= 取消录入
            if event.keyCode == 53, mods == 0 {
                stopRecording()
                return nil
            }
            let isFKey = (96...122).contains(event.keyCode)
            guard mods != 0 || isFKey else {
                NSSound.beep() // 必须带修饰键(F 键除外)
                return nil
            }
            hotkey = HotkeyConfig(keyCode: event.keyCode, modifiers: mods)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }
}
