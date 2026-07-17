import Cocoa
import FinderSync

@objc(EasyRightFinderSync)
class EasyRightFinderSync: FIFinderSync, @unchecked Sendable {
    private struct NewFileRequest {
        let kind: NewFileKind
        let destination: String
    }

    private var newFileRequests: [Int: NewFileRequest] = [:]
    private var nextNewFileRequestID = 1
    private var cachedConfig: EasyConfig?
    private var cachedConfigModificationDate: Date?
    private var cachedAvailableApps = Set<String>()
    private var appCacheDate = Date.distantPast

    override init() {
        super.init()
        updateMonitoredDirectories()
    }

    private func updateMonitoredDirectories() {
        // Finder Sync 会递归覆盖 directoryURLs 的全部子目录；根目录已经包含
        // /Users、/Applications、/Volumes 和 /private，无需维护重复集合。
        let root = URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL
        FIFinderSyncController.default().directoryURLs = [root]
        NSLog("EasyRightExt: monitoring root directory")
    }

    // MARK: - 菜单构建

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        newFileRequests.removeAll()
        nextNewFileRequestID = 1
        let cfg = currentConfig()
        switch menuKind {
        case .contextualMenuForItems:
            buildItemsMenu(into: menu, cfg: cfg)
        case .contextualMenuForContainer:
            buildContainerMenu(into: menu, cfg: cfg)
        default:
            break
        }
        return menu
    }

    /// 右键选中了文件/文件夹时的菜单
    private func buildItemsMenu(into menu: NSMenu, cfg: EasyConfig) {
        let selection = FIFinderSyncController.default().selectedItemURLs() ?? []

        // 常用入口固定在最前：拷贝路径 → 新建内容 → 进入 App。
        if cfg.showCopyPath {
            menu.addItem(makeItem(
                "拷贝路径",
                #selector(copyPath(_:)),
                systemSymbol: "link"
            ))
        }
        if cfg.showNewFile, selection.count == 1, isFolder(selection[0]) {
            addNewFileItems(into: menu, destination: selection[0].path)
        }
        addAppItems(into: menu, cfg: cfg)
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        let copyItem = makeItem("复制文件到 ...", nil, systemSymbol: "doc.on.doc")
        copyItem.submenu = folderSubmenu(
            action: #selector(copyToFolder(_:)),
            chooseAction: #selector(copyToChosen(_:)),
            cfg: cfg
        )
        menu.addItem(copyItem)

        let moveItem = makeItem("移动文件到 ...", nil)
        moveItem.submenu = folderSubmenu(
            action: #selector(moveToFolder(_:)),
            chooseAction: #selector(moveToChosen(_:)),
            cfg: cfg
        )
        menu.addItem(moveItem)

        if cfg.showCutPaste {
            menu.addItem(makeItem("剪切", #selector(cutItems(_:))))
            // 只选中了一个文件夹且有剪切内容时,提供"粘贴到此文件夹"
            if selection.count == 1, isFolder(selection[0]), let state = CutState.load() {
                menu.addItem(makeItem(
                    "粘贴到此文件夹(\(state.paths.count) 项)",
                    #selector(pasteIntoSelectedFolder(_:))
                ))
            }
        }

        if cfg.showCustomIcon {
            let iconItem = makeItem("自定义文件(夹)图标", nil)
            let sub = NSMenu(title: "")
            sub.autoenablesItems = false
            sub.addItem(makeItem("选择图片…", #selector(customIcon(_:))))
            sub.addItem(makeItem("恢复默认图标", #selector(resetIcon(_:))))
            iconItem.submenu = sub
            menu.addItem(iconItem)
        }
    }

    /// 右键窗口空白处(当前文件夹背景)时的菜单
    private func buildContainerMenu(into menu: NSMenu, cfg: EasyConfig) {
        if cfg.showCopyPath {
            menu.addItem(makeItem(
                "拷贝当前文件夹路径",
                #selector(copyContainerPath(_:)),
                systemSymbol: "link"
            ))
        }
        if cfg.showNewFile, let destination = containerPath() {
            addNewFileItems(into: menu, destination: destination)
        }
        addAppItems(into: menu, cfg: cfg)
        if cfg.showCutPaste, let state = CutState.load() {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(makeItem(
                "粘贴到此处(\(state.paths.count) 项)",
                #selector(pasteHere(_:))
            ))
        }
    }

    /// "进入终端 / 进入 VSCode …" 一类菜单项
    private func addAppItems(into menu: NSMenu, cfg: EasyConfig) {
        refreshAvailableAppsIfNeeded()
        for known in kKnownApps where cfg.apps.contains(known.name) {
            guard cachedAvailableApps.contains(known.name) else { continue }
            let needSpace = known.name.first?.isASCII == true
            let title = needSpace ? "进入 \(known.name)" : "进入\(known.name)"
            let item = makeItem(
                title,
                #selector(openWithApp(_:)),
                represented: known.name,
                systemSymbol: "arrow.up.forward.app"
            )
            menu.addItem(item)
        }
    }

    private func currentConfig() -> EasyConfig {
        let url = URL(fileURLWithPath: kConfigFilePath)
        let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cachedConfig, modificationDate == cachedConfigModificationDate { return cachedConfig }
        let loaded = EasyConfig.load()
        cachedConfig = loaded
        cachedConfigModificationDate = modificationDate
        return loaded
    }

    private func refreshAvailableAppsIfNeeded() {
        guard Date().timeIntervalSince(appCacheDate) >= 60 || cachedAvailableApps.isEmpty else { return }
        cachedAvailableApps = Set(kKnownApps.compactMap { appURL(for: $0) == nil ? nil : $0.name })
        appCacheDate = Date()
    }

    private func folderSubmenu(action: Selector, chooseAction: Selector, cfg: EasyConfig) -> NSMenu {
        let sub = NSMenu(title: "")
        sub.autoenablesItems = false
        for path in cfg.folders {
            let name = (path as NSString).lastPathComponent
            sub.addItem(makeItem(name, action, represented: path))
        }
        if !cfg.folders.isEmpty { sub.addItem(.separator()) }
        sub.addItem(makeItem("选择其他文件夹…", chooseAction))
        return sub
    }

    private func addNewFileItems(into menu: NSMenu, destination: String) {
        let items: [(String, NewFileKind)] = [
            ("新建 TXT 文件", .txt),
            ("新建 Markdown 文件", .md),
            ("新建 JSON 文件", .json),
        ]
        for (title, kind) in items {
            let requestID = nextNewFileRequestID
            nextNewFileRequestID += 1
            newFileRequests[requestID] = NewFileRequest(kind: kind, destination: destination)
            let item = makeItem(
                title,
                #selector(createFile(_:)),
                systemSymbol: "doc.badge.plus"
            )
            item.tag = requestID
            menu.addItem(item)
        }
    }

    private func makeItem(
        _ title: String,
        _ action: Selector?,
        represented: Any? = nil,
        systemSymbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        // Finder 会跨 XPC 序列化此菜单，并把 action 发送给扩展 principal object。
        // 显式设置进程内 target 会让项目在 Finder 端失去可解析的 action 目标。
        item.representedObject = represented
        if let systemSymbol {
            item.image = NSImage(
                systemSymbolName: systemSymbol,
                accessibilityDescription: title
            )
        }
        return item
    }

    // MARK: - 动作:全部转发给主应用执行

    private func selectedPaths() -> [String] {
        (FIFinderSyncController.default().selectedItemURLs() ?? []).map { $0.path }
    }

    private func containerPath() -> String? {
        FIFinderSyncController.default().targetedURL()?.path
    }

    private func isFolder(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
            return values.isDirectory == true && values.isPackage != true
        }
        return url.hasDirectoryPath
    }

    private func send(_ cmd: Command, attemptsRemaining: Int = 20) {
        if let token = CommandAuthentication.loadToken() {
            guard let url = encodeCommandURL(cmd, token: token) else {
                NSLog("EasyRightExt: failed to encode %@ command", cmd.action.rawValue)
                return
            }
            NSWorkspace.shared.open(url)
            return
        }

        guard attemptsRemaining > 0 else {
            NSLog("EasyRightExt: command token unavailable; command dropped")
            return
        }
        if attemptsRemaining == 20 {
            // 主应用尚未运行过时，先让它创建仅本机可读的认证令牌。
            NSWorkspace.shared.open(commandBootstrapURL())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.send(cmd, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    @objc func createFile(_ sender: NSMenuItem) {
        guard let request = newFileRequests[sender.tag] else { return }
        NSLog("EasyRightExt: createFile %@ in %@", request.kind.rawValue, request.destination)
        send(Command(
            action: .createFile,
            targets: [],
            dest: request.destination,
            fileKind: request.kind
        ))
    }

    @objc func copyToFolder(_ sender: NSMenuItem) {
        guard let dest = sender.representedObject as? String else { return }
        send(Command(action: .copyTo, targets: selectedPaths(), dest: dest))
    }

    @objc func moveToFolder(_ sender: NSMenuItem) {
        guard let dest = sender.representedObject as? String else { return }
        send(Command(action: .moveTo, targets: selectedPaths(), dest: dest))
    }

    @objc func copyToChosen(_ sender: NSMenuItem) {
        send(Command(action: .copyChoose, targets: selectedPaths()))
    }

    @objc func moveToChosen(_ sender: NSMenuItem) {
        send(Command(action: .moveChoose, targets: selectedPaths()))
    }

    @objc func cutItems(_ sender: NSMenuItem) {
        send(Command(action: .cut, targets: selectedPaths()))
    }

    @objc func pasteHere(_ sender: NSMenuItem) {
        guard let dest = containerPath() else { return }
        send(Command(action: .paste, targets: [], dest: dest))
    }

    @objc func pasteIntoSelectedFolder(_ sender: NSMenuItem) {
        guard let dest = selectedPaths().first else { return }
        send(Command(action: .paste, targets: [], dest: dest))
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        send(Command(action: .copyPath, targets: selectedPaths()))
    }

    @objc func copyContainerPath(_ sender: NSMenuItem) {
        guard let dest = containerPath() else { return }
        send(Command(action: .copyPath, targets: [dest]))
    }

    @objc func customIcon(_ sender: NSMenuItem) {
        send(Command(action: .iconChoose, targets: selectedPaths()))
    }

    @objc func resetIcon(_ sender: NSMenuItem) {
        send(Command(action: .iconReset, targets: selectedPaths()))
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var targets = selectedPaths()
        if targets.isEmpty, let container = containerPath() { targets = [container] }
        send(Command(action: .open, targets: targets, app: name))
    }
}
