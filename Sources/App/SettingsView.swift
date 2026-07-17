import SwiftUI
import AppKit

final class ConfigStore: ObservableObject {
    @Published var config: EasyConfig {
        didSet {
            config.save()
            NotificationCenter.default.post(name: .easyConfigChanged, object: nil)
        }
    }
    init() { config = EasyConfig.load() }
}

struct SettingsView: View {
    @StateObject private var store = ConfigStore()

    var body: some View {
        TabView {
            RightMenuSettingsTab(store: store)
                .tabItem { Label("右键菜单", systemImage: "cursorarrow.click.2") }
            CaptureSettingsTab(store: store)
                .tabItem { Label("截图与录屏", systemImage: "camera.viewfinder") }
        }
        .frame(width: 580, height: 640)
    }
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
