import Cocoa
import FinderSync

@objc(EasyRightFinderSync)
class EasyRightFinderSync: FIFinderSync {

    override init() {
        super.init()
        // 监视整个磁盘,让所有目录的右键菜单都出现我们的菜单项
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: - 菜单构建

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        let cfg = EasyConfig.load()
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
        let copyItem = makeItem("复制文件到 ...", nil, symbol: "doc.on.doc")
        copyItem.submenu = folderSubmenu(
            action: #selector(copyToFolder(_:)),
            chooseAction: #selector(copyToChosen(_:)),
            cfg: cfg
        )
        menu.addItem(copyItem)

        let moveItem = makeItem("移动文件到 ...", nil, symbol: "arrowshape.turn.up.right")
        moveItem.submenu = folderSubmenu(
            action: #selector(moveToFolder(_:)),
            chooseAction: #selector(moveToChosen(_:)),
            cfg: cfg
        )
        menu.addItem(moveItem)

        if cfg.showCutPaste {
            menu.addItem(makeItem("剪切", #selector(cutItems(_:)), symbol: "scissors"))
            // 只选中了一个文件夹且有剪切内容时,提供"粘贴到此文件夹"
            let selection = FIFinderSyncController.default().selectedItemURLs() ?? []
            if selection.count == 1, selection[0].hasDirectoryPath, let state = CutState.load() {
                menu.addItem(makeItem(
                    "粘贴到此文件夹(\(state.paths.count) 项)",
                    #selector(pasteIntoSelectedFolder(_:)),
                    symbol: "doc.on.clipboard"
                ))
            }
        }

        if cfg.showCopyPath {
            menu.addItem(makeItem("拷贝路径", #selector(copyPath(_:)), symbol: "link"))
        }

        if cfg.showCustomIcon {
            let iconItem = makeItem("自定义文件(夹)图标", nil, symbol: "star")
            let sub = NSMenu(title: "")
            sub.autoenablesItems = false
            sub.addItem(makeItem("选择图片…", #selector(customIcon(_:)), symbol: "photo"))
            sub.addItem(makeItem("恢复默认图标", #selector(resetIcon(_:)), symbol: "arrow.uturn.backward"))
            iconItem.submenu = sub
            menu.addItem(iconItem)
        }

        addAppItems(into: menu, cfg: cfg)
    }

    /// 右键窗口空白处(当前文件夹背景)时的菜单
    private func buildContainerMenu(into menu: NSMenu, cfg: EasyConfig) {
        if cfg.showCutPaste, let state = CutState.load() {
            menu.addItem(makeItem(
                "粘贴到此处(\(state.paths.count) 项)",
                #selector(pasteHere(_:)),
                symbol: "doc.on.clipboard"
            ))
        }
        if cfg.showCopyPath {
            menu.addItem(makeItem("拷贝当前文件夹路径", #selector(copyContainerPath(_:)), symbol: "link"))
        }
        addAppItems(into: menu, cfg: cfg)
    }

    /// "进入终端 / 进入 VSCode …" 一类菜单项
    private func addAppItems(into menu: NSMenu, cfg: EasyConfig) {
        for known in kKnownApps where cfg.apps.contains(known.name) {
            guard let url = appURL(for: known) else { continue }
            let needSpace = known.name.first?.isASCII == true
            let title = needSpace ? "进入 \(known.name)" : "进入\(known.name)"
            let item = makeItem(title, #selector(openWithApp(_:)), represented: known.name)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
    }

    private func folderSubmenu(action: Selector, chooseAction: Selector, cfg: EasyConfig) -> NSMenu {
        let sub = NSMenu(title: "")
        sub.autoenablesItems = false
        for path in cfg.folders {
            let name = (path as NSString).lastPathComponent
            sub.addItem(makeItem(name, action, symbol: "folder", represented: path))
        }
        if !cfg.folders.isEmpty { sub.addItem(.separator()) }
        sub.addItem(makeItem("选择其他文件夹…", chooseAction, symbol: "folder.badge.plus"))
        return sub
    }

    private func makeItem(_ title: String, _ action: Selector?, symbol: String? = nil, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        item.representedObject = represented
        return item
    }

    // MARK: - 动作:全部转发给主应用执行

    private func selectedPaths() -> [String] {
        (FIFinderSyncController.default().selectedItemURLs() ?? []).map { $0.path }
    }

    private func containerPath() -> String? {
        FIFinderSyncController.default().targetedURL()?.path
    }

    private func send(_ cmd: Command) {
        guard let url = encodeCommandURL(cmd) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copyToFolder(_ sender: NSMenuItem) {
        guard let dest = sender.representedObject as? String else { return }
        send(Command(action: "copyTo", targets: selectedPaths(), dest: dest))
    }

    @objc func moveToFolder(_ sender: NSMenuItem) {
        guard let dest = sender.representedObject as? String else { return }
        send(Command(action: "moveTo", targets: selectedPaths(), dest: dest))
    }

    @objc func copyToChosen(_ sender: NSMenuItem) {
        send(Command(action: "copyChoose", targets: selectedPaths()))
    }

    @objc func moveToChosen(_ sender: NSMenuItem) {
        send(Command(action: "moveChoose", targets: selectedPaths()))
    }

    @objc func cutItems(_ sender: NSMenuItem) {
        send(Command(action: "cut", targets: selectedPaths()))
    }

    @objc func pasteHere(_ sender: NSMenuItem) {
        guard let dest = containerPath() else { return }
        send(Command(action: "paste", targets: [], dest: dest))
    }

    @objc func pasteIntoSelectedFolder(_ sender: NSMenuItem) {
        guard let dest = selectedPaths().first else { return }
        send(Command(action: "paste", targets: [], dest: dest))
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        send(Command(action: "copyPath", targets: selectedPaths()))
    }

    @objc func copyContainerPath(_ sender: NSMenuItem) {
        guard let dest = containerPath() else { return }
        send(Command(action: "copyPath", targets: [dest]))
    }

    @objc func customIcon(_ sender: NSMenuItem) {
        send(Command(action: "iconChoose", targets: selectedPaths()))
    }

    @objc func resetIcon(_ sender: NSMenuItem) {
        send(Command(action: "iconReset", targets: selectedPaths()))
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var targets = selectedPaths()
        if targets.isEmpty, let container = containerPath() { targets = [container] }
        send(Command(action: "open", targets: targets, app: name))
    }
}
