import Foundation
import AppKit

// MARK: - 已知可打开的 App

public struct KnownApp: Sendable {
    public let name: String
    public let bundleIds: [String]
    /// true = 终端类,只打开文件夹(文件则打开其所在目录);false = 编辑器类,直接打开选中项
    public let opensFolderOnly: Bool

    public init(name: String, bundleIds: [String], opensFolderOnly: Bool) {
        self.name = name
        self.bundleIds = bundleIds
        self.opensFolderOnly = opensFolderOnly
    }
}

public let kKnownApps: [KnownApp] = [
    KnownApp(name: "终端", bundleIds: ["com.apple.Terminal"], opensFolderOnly: true),
    KnownApp(name: "iTerm2", bundleIds: ["com.googlecode.iterm2"], opensFolderOnly: true),
    KnownApp(name: "Warp", bundleIds: ["dev.warp.Warp-Stable"], opensFolderOnly: true),
    KnownApp(name: "VSCode", bundleIds: ["com.microsoft.VSCode"], opensFolderOnly: false),
    KnownApp(name: "Cursor", bundleIds: ["com.todesktop.230313mzl4w4u92"], opensFolderOnly: false),
    KnownApp(name: "Sublime Text", bundleIds: ["com.sublimetext.4", "com.sublimetext.3"], opensFolderOnly: false),
    KnownApp(name: "Zed", bundleIds: ["dev.zed.Zed"], opensFolderOnly: false),
    KnownApp(name: "Emacs", bundleIds: ["org.gnu.Emacs"], opensFolderOnly: false),
]

public func appURL(for known: KnownApp) -> URL? {
    for bid in known.bundleIds {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) { return u }
    }
    return nil
}

// MARK: - 路径(扩展在沙盒里,必须用真实家目录而非容器路径)

public func realHomePath() -> String {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return String(cString: dir)
    }
    return NSHomeDirectory()
}

public let kConfigDirPath = realHomePath() + "/Library/Application Support/EasyRight"
public let kConfigFilePath = kConfigDirPath + "/config.json"
public let kStateFilePath = kConfigDirPath + "/state.json"
public let kCommandTokenFilePath = kConfigDirPath + "/command-token"

private func writePrivateData(_ data: Data, to path: String) throws {
    try FileManager.default.createDirectory(
        atPath: kConfigDirPath,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let url = URL(fileURLWithPath: path)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

// MARK: - 全局快捷键(modifiers 为 Carbon 修饰键位:⌘256 ⇧512 ⌥2048 ⌃4096)

public struct HotkeyConfig: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt32

    public init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

// MARK: - 配置

public struct EasyConfig: Codable, Equatable, Sendable {
    public var folders: [String]
    public var apps: [String]
    public var showNewFile: Bool
    public var showCopyPath: Bool
    public var showCutPaste: Bool
    public var showCustomIcon: Bool
    public var saveDir: String
    public var copyAfterCapture: Bool
    public var saveAfterCapture: Bool
    public var pinAfterCapture: Bool
    public var recordFPS: Int
    public var recordFormat: String // "mp4" / "mov"
    public var hotkeys: [String: HotkeyConfig]

    public static func defaultHotkeys() -> [String: HotkeyConfig] {
        // ⌃⇧ 前缀,避免和系统/常用 App 冲突;A=0 D=2 V=9 R=15 L=37
        let cs: UInt32 = 4096 | 512
        return [
            "capture":      HotkeyConfig(keyCode: 0, modifiers: cs),
            "capturePin":   HotkeyConfig(keyCode: 2, modifiers: cs),
            "pinClipboard": HotkeyConfig(keyCode: 9, modifiers: cs),
            "record":       HotkeyConfig(keyCode: 15, modifiers: cs),
            "longshot":     HotkeyConfig(keyCode: 37, modifiers: cs),
        ]
    }

    public static func defaultConfig() -> EasyConfig {
        let home = realHomePath()
        return EasyConfig(
            folders: [home + "/Desktop", home + "/Downloads", home + "/Documents"],
            apps: kKnownApps.map { $0.name },
            showNewFile: true,
            showCopyPath: true,
            showCutPaste: true,
            showCustomIcon: true,
            saveDir: home + "/Pictures/EasyRight",
            copyAfterCapture: true,
            saveAfterCapture: true,
            pinAfterCapture: true,
            recordFPS: 30,
            recordFormat: "mp4",
            hotkeys: defaultHotkeys()
        )
    }

    public static func load() -> EasyConfig {
        guard let data = FileManager.default.contents(atPath: kConfigFilePath) else {
            return defaultConfig()
        }
        struct Raw: Codable {
            var folders: [String]?
            var apps: [String]?
            var showNewFile: Bool?
            var showCopyPath: Bool?
            var showCutPaste: Bool?
            var showCustomIcon: Bool?
            var saveDir: String?
            var copyAfterCapture: Bool?
            var saveAfterCapture: Bool?
            var pinAfterCapture: Bool?
            var recordFPS: Int?
            var recordFormat: String?
            var hotkeys: [String: HotkeyConfig]?
        }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            NSLog("EasyRight: invalid config file, using defaults: %@", error.localizedDescription)
            return defaultConfig()
        }
        let d = defaultConfig()
        return EasyConfig(
            folders: raw.folders ?? d.folders,
            apps: raw.apps ?? d.apps,
            showNewFile: raw.showNewFile ?? true,
            showCopyPath: raw.showCopyPath ?? true,
            showCutPaste: raw.showCutPaste ?? true,
            showCustomIcon: raw.showCustomIcon ?? true,
            saveDir: raw.saveDir ?? d.saveDir,
            copyAfterCapture: raw.copyAfterCapture ?? true,
            saveAfterCapture: raw.saveAfterCapture ?? true,
            pinAfterCapture: raw.pinAfterCapture ?? true,
            recordFPS: raw.recordFPS ?? 30,
            recordFormat: raw.recordFormat ?? "mp4",
            hotkeys: raw.hotkeys ?? d.hotkeys
        )
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try writePrivateData(data, to: kConfigFilePath)
    }
}

// MARK: - 剪切状态

public struct CutState: Codable, Sendable {
    public var paths: [String]

    public init(paths: [String]) { self.paths = paths }

    public static func load() -> CutState? {
        guard let data = FileManager.default.contents(atPath: kStateFilePath) else { return nil }
        let state: CutState
        do {
            state = try JSONDecoder().decode(CutState.self, from: data)
        } catch {
            NSLog("EasyRight: invalid cut state: %@", error.localizedDescription)
            return nil
        }
        guard !state.paths.isEmpty else { return nil }
        return state
    }

    public func save() throws {
        let data = try JSONEncoder().encode(self)
        try writePrivateData(data, to: kStateFilePath)
    }

    public static func clear() throws {
        guard FileManager.default.fileExists(atPath: kStateFilePath) else { return }
        try FileManager.default.removeItem(atPath: kStateFilePath)
    }
}

// MARK: - 扩展 → 主应用 的指令(经 easyright:// URL 传递)

public enum CommandAuthentication {
    /// 主应用首次启动时创建；Finder 扩展只有读取权限。
    public static func ensureToken() throws -> String {
        if let existing = loadToken() { return existing }
        let token = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        try writePrivateData(Data(token.utf8), to: kCommandTokenFilePath)
        return token
    }

    public static func loadToken() -> String? {
        guard let data = FileManager.default.contents(atPath: kCommandTokenFilePath),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= 32 else { return nil }
        return token
    }

    public static func matches(_ candidate: String, expected: String) -> Bool {
        let lhs = Array(candidate.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

public enum NewFileKind: String, Codable, CaseIterable, Sendable {
    case txt
    case md
    case json

    public var defaultFileName: String {
        switch self {
        case .txt:  return "未命名.txt"
        case .md:   return "未命名.md"
        case .json: return "未命名.json"
        }
    }

    public var initialContents: String {
        switch self {
        case .txt, .md: return ""
        case .json:     return "{}\n"
        }
    }
}

public enum CommandAction: String, Codable, CaseIterable, Sendable {
    case createFile
    case copyTo
    case moveTo
    case copyChoose
    case moveChoose
    case cut
    case paste
    case copyPath
    case iconChoose
    case iconReset
    case open
    case screenshot
    case screenshotPin
    case pinClipboard
    case record
    case longshot
    case closePins
    case settings
}

public struct Command: Codable, Sendable {
    public var action: CommandAction
    public var targets: [String]
    public var dest: String?
    public var app: String?
    public var fileKind: NewFileKind?

    public init(
        action: CommandAction,
        targets: [String],
        dest: String? = nil,
        app: String? = nil,
        fileKind: NewFileKind? = nil
    ) {
        self.action = action
        self.targets = targets
        self.dest = dest
        self.app = app
        self.fileKind = fileKind
    }
}

private struct CommandEnvelope: Codable {
    let token: String
    let command: Command
}

public func encodeCommandURL(_ cmd: Command, token: String) -> URL? {
    let envelope = CommandEnvelope(token: token, command: cmd)
    guard let data = try? JSONEncoder().encode(envelope) else { return nil }
    let b64 = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return URL(string: "easyright://cmd?d=\(b64)")
}

public func commandBootstrapURL() -> URL {
    URL(string: "easyright://bootstrap")!
}

public func isCommandBootstrapURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "easyright" && url.host?.lowercased() == "bootstrap"
}

public func decodeCommand(from url: URL, expectedToken: String) -> Command? {
    guard url.scheme?.lowercased() == "easyright",
          url.host?.lowercased() == "cmd",
          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let d = comps.queryItems?.first(where: { $0.name == "d" })?.value else { return nil }
    var b64 = d
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64) else { return nil }
    guard let envelope = try? JSONDecoder().decode(CommandEnvelope.self, from: data),
          CommandAuthentication.matches(envelope.token, expected: expectedToken) else { return nil }
    return envelope.command
}
