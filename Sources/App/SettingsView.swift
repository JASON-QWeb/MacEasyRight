import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import FinderSync

final class ConfigStore: ObservableObject, @unchecked Sendable {
    @Published var config: EasyConfig {
        didSet {
            guard !isApplyingExternalConfig, config != oldValue else { return }
            do {
                try config.save()
                saveError = nil
                NotificationCenter.default.post(
                    name: .easyConfigChanged,
                    object: self,
                    userInfo: ["hotkeysChanged": config.hotkeys != oldValue.hotkeys]
                )
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
    @Published private(set) var saveError: String?

    private var isApplyingExternalConfig = false
    private var configObserver: NSObjectProtocol?

    init() {
        config = EasyConfig.load()
        configObserver = NotificationCenter.default.addObserver(
            forName: .easyConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let comesFromThisStore = (note.object as AnyObject?) === self
            DispatchQueue.main.async { [weak self] in
                guard let self, !comesFromThisStore else { return }
                self.isApplyingExternalConfig = true
                self.config = EasyConfig.load()
                self.isApplyingExternalConfig = false
            }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func clearSaveError() { saveError = nil }
}

final class SystemStatusStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var finderExtensionEnabled = false
    @Published private(set) var finderExtensionNeedsRepair = false
    @Published private(set) var finderExtensionDetail = "正在读取 Finder 扩展状态…"
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var screenRecordingRequiresRestart = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var isChecking = false

    private var pendingRefreshes: [DispatchWorkItem] = []
    private var finderCheckTask: Task<Void, Never>?
    private var checkGeneration = 0
    private var screenPermissionAcceptedInCurrentProcess = false
    private var finderRepairError: String?

    init() { refresh() }

    deinit {
        pendingRefreshes.forEach { $0.cancel() }
        finderCheckTask?.cancel()
    }

    func refresh() {
        // Finder Sync 的公开布尔 API 在重复注册时会误报，先作为回退值，
        // 再异步读取 PlugInKit 的具体路径和用户选择状态。
        let finderEnabled = FIFinderSyncController.isExtensionEnabled
        let screenGranted = CGPreflightScreenCaptureAccess()
        let axGranted = AXIsProcessTrusted()

        finderExtensionEnabled = finderEnabled
        refreshFinderExtensionStatus(fallbackEnabled: finderEnabled)
        screenRecordingGranted = screenGranted
        accessibilityGranted = axGranted
        if screenGranted {
            screenRecordingRequiresRestart = false
            screenPermissionAcceptedInCurrentProcess = false
        } else if screenPermissionAcceptedInCurrentProcess {
            // macOS 可能已经接受授权，但要求退出并重新打开应用后才对进程生效。
            screenRecordingRequiresRestart = true
        }
    }

    func checkNow() {
        startRefreshBurst(delays: [0, 0.35, 1, 2])
    }

    func checkAfterReturningToApp() {
        startRefreshBurst(delays: [0, 0.5, 1.5, 3])
    }

    func cancelPendingChecks() {
        checkGeneration &+= 1
        pendingRefreshes.forEach { $0.cancel() }
        pendingRefreshes.removeAll()
        finderCheckTask?.cancel()
        finderCheckTask = nil
        isChecking = false
    }

    func performFinderExtensionAction() {
        if finderExtensionNeedsRepair {
            repairFinderExtension()
            return
        }
        openFinderExtensionSettings()
    }

    func openFinderExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
        checkAfterPermissionAction()
    }

    func requestScreenRecordingPermission() {
        if CGPreflightScreenCaptureAccess() {
            screenRecordingGranted = true
            openScreenRecordingSettings()
            return
        }

        let accepted = CGRequestScreenCaptureAccess()
        screenPermissionAcceptedInCurrentProcess = accepted
        screenRecordingRequiresRestart = accepted && !CGPreflightScreenCaptureAccess()
        refresh()
        checkAfterPermissionAction()
    }

    func requestAccessibilityPermission() {
        if AXIsProcessTrusted() {
            accessibilityGranted = true
            openAccessibilitySettings()
            return
        }

        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
        checkAfterPermissionAction()
    }

    func openScreenRecordingSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func refreshFinderExtensionStatus(fallbackEnabled: Bool) {
        finderCheckTask?.cancel()
        finderCheckTask = Task { [weak self] in
            let status = await FinderExtensionManager.status()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applyFinderExtensionStatus(status, fallbackEnabled: fallbackEnabled)
            }
        }
    }

    @MainActor
    private func applyFinderExtensionStatus(
        _ status: FinderExtensionStatus,
        fallbackEnabled: Bool
    ) {
        if status.isRunningFromDiskImage {
            finderExtensionEnabled = false
            finderExtensionNeedsRepair = false
            finderExtensionDetail = "当前正在从 DMG 中运行。请先把 EasyRight 拖到“应用程序”，再从应用程序目录打开。"
        } else if let queryError = status.queryError, !queryError.isEmpty {
            finderExtensionEnabled = fallbackEnabled
            finderExtensionNeedsRepair = false
            finderExtensionDetail = fallbackEnabled
                ? "扩展已启用，但详细状态读取失败：\(queryError)"
                : "无法读取 Finder 扩展状态：\(queryError)"
        } else if !status.duplicatePaths.isEmpty {
            finderExtensionEnabled = false
            finderExtensionNeedsRepair = status.isInstalledLocation
            finderExtensionDetail = "检测到 DMG 与已安装应用的重复扩展注册，Finder 无法稳定加载。点击“修复并重载 Finder”。"
        } else if status.currentRegistration == nil {
            finderExtensionEnabled = false
            finderExtensionNeedsRepair = status.isInstalledLocation
            finderExtensionDetail = status.isInstalledLocation
                ? "没有找到当前安装位置的扩展注册。点击“修复并重载 Finder”。"
                : "当前构建不在标准应用程序目录中，Finder 扩展不会作为正式安装版本加载。"
        } else {
            finderExtensionEnabled = status.isHealthy
            finderExtensionNeedsRepair = false
            finderExtensionDetail = status.isHealthy
                ? "扩展已启用，并且只注册了“应用程序”目录中的有效实例。"
                : "扩展已正确注册，但尚未在系统扩展管理界面启用。"
        }

        if let finderRepairError {
            finderExtensionDetail += "\n修复提示：\(finderRepairError)"
        }
    }

    private func repairFinderExtension() {
        finderRepairError = nil
        isChecking = true
        finderExtensionDetail = "正在清理重复注册并重载 Finder…"
        finderCheckTask?.cancel()
        finderCheckTask = Task { [weak self] in
            let result = await FinderExtensionManager.repairIfNeeded(reloadFinder: true)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finderRepairError = result.errors.isEmpty
                    ? nil
                    : result.errors.joined(separator: "；")
                self.applyFinderExtensionStatus(
                    result.status,
                    fallbackEnabled: FIFinderSyncController.isExtensionEnabled
                )
                self.isChecking = false
            }
        }
    }

    private func checkAfterPermissionAction() {
        startRefreshBurst(delays: [0, 0.5, 1.5, 3, 6, 10])
    }

    private func startRefreshBurst(delays: [TimeInterval]) {
        cancelPendingChecks()
        guard !delays.isEmpty else {
            refresh()
            return
        }

        let generation = checkGeneration
        isChecking = true

        for (index, delay) in delays.enumerated() {
            let isLast = index == delays.count - 1
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.checkGeneration == generation else { return }
                self.refresh()
                if isLast {
                    self.pendingRefreshes.removeAll()
                    self.isChecking = false
                }
            }
            pendingRefreshes.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
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
    @State private var destination: SettingsDestination = .overview

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $destination)
                .frame(width: 190)

            Divider()

            Group {
                switch destination {
                case .overview:
                    OverviewDashboard(status: systemStatus)
                case .rightMenu:
                    RightMenuSettingsTab(store: store)
                case .capture:
                    CaptureSettingsTab(store: store, systemStatus: systemStatus)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { systemStatus.refresh() }
        .onDisappear { systemStatus.cancelPendingChecks() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemStatus.checkAfterReturningToApp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .finderExtensionRegistrationChanged)) { note in
            if let errors = note.userInfo?["errors"] as? [String], !errors.isEmpty {
                NSLog("EasyRight: Finder repair completed with %d warning(s)", errors.count)
            }
            systemStatus.checkNow()
        }
        .alert(
            "保存设置失败",
            isPresented: Binding(
                get: { store.saveError != nil },
                set: { if !$0 { store.clearSaveError() } }
            )
        ) {
            Button("好", role: .cancel) { store.clearSaveError() }
        } message: {
            Text(store.saveError ?? "未知错误")
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EasyRight")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)

            ForEach(SettingsDestination.allCases) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.symbol)
                            .frame(width: 20)
                        Text(item.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 15, weight: selection == item ? .semibold : .regular))
                    .foregroundColor(selection == item ? .accentColor : .primary)
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selection == item ? Color.accentColor.opacity(0.14) : Color.clear)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
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
                    detail: status.finderExtensionDetail,
                    isReady: status.finderExtensionEnabled,
                    readyText: "已启用",
                    notReadyText: status.finderExtensionNeedsRepair ? "需要修复" : "未启用",
                    actionTitle: status.finderExtensionNeedsRepair
                        ? "修复并重载 Finder"
                        : status.finderExtensionEnabled ? "管理 Finder 扩展" : "启用 Finder 扩展",
                    action: status.performFinderExtensionAction,
                    secondaryActionTitle: status.finderExtensionNeedsRepair ? "打开扩展管理" : nil,
                    secondaryAction: status.finderExtensionNeedsRepair ? status.openFinderExtensionSettings : nil
                )

                HStack(alignment: .top, spacing: 14) {
                    StatusCard(
                        title: "屏幕录制",
                        detail: status.screenRecordingGranted
                            ? "截图、录屏和长截图所需权限已授权。"
                            : status.screenRecordingRequiresRestart
                                ? "系统已接受授权，但当前进程尚未生效。请退出并重新打开 EasyRight。"
                                : "当前进程没有可用权限。点击“请求授权”；若设置中已经勾选，请退出并重新打开 EasyRight。",
                        isReady: status.screenRecordingGranted,
                        readyText: "已授权",
                        notReadyText: status.screenRecordingRequiresRestart ? "需要重启" : "未生效",
                        actionTitle: status.screenRecordingGranted ? "管理权限" : "请求授权",
                        action: status.requestScreenRecordingPermission,
                        secondaryActionTitle: status.screenRecordingGranted ? nil : "打开系统设置",
                        secondaryAction: status.screenRecordingGranted ? nil : status.openScreenRecordingSettings
                    )
                    StatusCard(
                        title: "辅助功能",
                        detail: status.accessibilityGranted
                            ? "自动滚动长截图所需权限已授权。"
                            : "点击“请求授权”触发系统弹窗；如果此前拒绝过，请手动打开设置。",
                        isReady: status.accessibilityGranted,
                        readyText: "已授权",
                        notReadyText: "未授权",
                        actionTitle: status.accessibilityGranted ? "管理权限" : "请求授权",
                        action: status.requestAccessibilityPermission,
                        secondaryActionTitle: status.accessibilityGranted ? nil : "打开系统设置",
                        secondaryAction: status.accessibilityGranted ? nil : status.openAccessibilitySettings
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
                    Button {
                        status.checkNow()
                    } label: {
                        HStack(spacing: 6) {
                            if status.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(status.isChecking ? "正在检查…" : "重新检查状态")
                        }
                    }
                    .disabled(status.isChecking)
                    Button("在 Finder 中查看主目录") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: realHomePath(), isDirectory: true))
                    }
                    Spacer()
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
    let notReadyText: String
    let actionTitle: String
    let action: () -> Void
    let secondaryActionTitle: String?
    let secondaryAction: (() -> Void)?

    init(
        title: String,
        detail: String,
        isReady: Bool,
        readyText: String,
        notReadyText: String = "需要设置",
        actionTitle: String,
        action: @escaping () -> Void,
        secondaryActionTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.isReady = isReady
        self.readyText = readyText
        self.notReadyText = notReadyText
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryActionTitle = secondaryActionTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(isReady ? .green : .orange)
                    Text(title).font(.headline)
                    Spacer()
                    Text(isReady ? readyText : notReadyText)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(isReady ? .green : .orange)
                }
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if isReady {
                        Button(actionTitle, action: action)
                            .buttonStyle(.bordered)
                    } else {
                        Button(actionTitle, action: action)
                            .buttonStyle(.borderedProminent)
                    }

                    if let secondaryActionTitle, let secondaryAction {
                        Button(secondaryActionTitle, action: secondaryAction)
                            .buttonStyle(.bordered)
                    }
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
    @ObservedObject var systemStatus: SystemStatusStore
    @State private var hotkeyError: String?

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
                • 截图:框选后在选区下方点击「贴图」即可把图片固定在屏幕上，贴图会一直保留到手动关闭。
                • 录屏:快捷键 → 框选范围(可拖动 / 拖手柄调整)→ 选帧率 / 格式 → 开始;再按快捷键或点「停止」结束,控制条和红框不会被录进去。
                • 长截图:框选并调整范围 → 点「开始」→ 自动滚动或自己滚动页面,应用持续监控拼接 → 点「停止并保存」。
                • 贴图:鼠标移入出现工具栏,可画笔 / 直线 / 箭头 / 矩形 / 文字标注,⌘Z 撤销;拖动移动、滚轮缩放、双击原始大小;⌫ 或 Esc 直接删除贴图。
                """)
                .font(.footnote)
                .foregroundColor(.secondary)
                HStack {
                    Button(systemStatus.screenRecordingGranted ? "屏幕录制权限设置" : "请求屏幕录制权限") {
                        systemStatus.requestScreenRecordingPermission()
                    }
                    Button(systemStatus.accessibilityGranted ? "辅助功能权限设置" : "请求辅助功能权限") {
                        systemStatus.requestAccessibilityPermission()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let failures = HotkeyManager.shared.lastFailures
            if !failures.isEmpty {
                hotkeyError = failures.map(\.userMessage).joined(separator: "\n")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeyRegistrationFailed)) { note in
            hotkeyError = note.userInfo?["message"] as? String
        }
        .alert(
            "快捷键不可用",
            isPresented: Binding(
                get: { hotkeyError != nil },
                set: { if !$0 { hotkeyError = nil } }
            )
        ) {
            Button("好", role: .cancel) { hotkeyError = nil }
        } message: {
            Text(hotkeyError ?? "未知错误")
        }
    }

    private func hotkeyBinding(for action: HotkeyAction) -> Binding<HotkeyConfig?> {
        Binding(
            get: { store.config.hotkeys[action.rawValue] },
            set: { newValue in
                if let newValue,
                   let duplicate = HotkeyAction.allCases.first(where: {
                       $0 != action && store.config.hotkeys[$0.rawValue] == newValue
                   }) {
                    hotkeyError = "\(hotkeyDisplay(newValue)) 已分配给“\(duplicate.label)”，请换一个组合键。"
                    return
                }
                store.config.hotkeys[action.rawValue] = newValue
            }
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
