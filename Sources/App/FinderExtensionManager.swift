import AppKit
import FinderSync

struct FinderExtensionStatus: Sendable {
    let bundlePath: String
    let extensionPath: String
    let registrations: [FinderExtensionRegistration]
    let queryError: String?

    private var normalizedExtensionPath: String {
        URL(fileURLWithPath: extensionPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    var currentRegistration: FinderExtensionRegistration? {
        registrations.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path
                == normalizedExtensionPath
        }
    }

    var duplicatePaths: [String] {
        registrations.compactMap { registration in
            let normalized = URL(fileURLWithPath: registration.path)
                .standardizedFileURL.resolvingSymlinksInPath().path
            return normalized == normalizedExtensionPath ? nil : registration.path
        }
    }

    var isRunningFromDiskImage: Bool { bundlePath.hasPrefix("/Volumes/") }

    var isInstalledLocation: Bool {
        bundlePath.hasPrefix("/Applications/") ||
            bundlePath.hasPrefix(realHomePath() + "/Applications/")
    }

    var isEnabled: Bool { currentRegistration?.enabled == true }
    var isHealthy: Bool { isEnabled && duplicatePaths.isEmpty && queryError == nil }
    var needsRepair: Bool {
        isInstalledLocation && (currentRegistration == nil || !duplicatePaths.isEmpty)
    }
}

struct FinderExtensionRepairResult: Sendable {
    let changed: Bool
    let errors: [String]
    let status: FinderExtensionStatus
}

enum FinderExtensionManager {
    static let identifier = "com.diy.easyright.app.ext"

    private struct ToolResult: Sendable {
        let status: Int32
        let output: String
        let launchError: String?

        var succeeded: Bool { launchError == nil && status == 0 }
    }

    static func status() async -> FinderExtensionStatus {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let extensionPath = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("EasyRightExt.appex", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
            ?? Bundle.main.bundleURL
                .appendingPathComponent("Contents/PlugIns/EasyRightExt.appex", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path

        let result = await run(
            executable: "/usr/bin/pluginkit",
            arguments: ["-m", "-A", "-D", "-v", "-i", identifier]
        )
        let records = FinderExtensionRegistrationParser.parse(result.output, identifier: identifier)
        let error: String?
        if result.succeeded {
            error = nil
        } else {
            error = result.launchError ?? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return FinderExtensionStatus(
            bundlePath: bundlePath,
            extensionPath: extensionPath,
            registrations: records,
            queryError: error
        )
    }

    /// 修复 DMG 与已安装应用的重复注册，保留用户已经在系统设置中做出的启用选择。
    static func repairIfNeeded(reloadFinder: Bool) async -> FinderExtensionRepairResult {
        let initial = await status()
        guard initial.isInstalledLocation else {
            return FinderExtensionRepairResult(changed: false, errors: [], status: initial)
        }
        if let queryError = initial.queryError {
            return FinderExtensionRepairResult(
                changed: false,
                errors: ["读取扩展注册失败：\(queryError)"],
                status: initial
            )
        }

        let wasEnabled = initial.registrations.contains(where: \.enabled)
        var changed = false
        var errors: [String] = []

        for duplicatePath in initial.duplicatePaths {
            let removal = await run(
                executable: "/usr/bin/pluginkit",
                arguments: ["-r", duplicatePath]
            )
            if removal.succeeded {
                changed = true
            } else {
                errors.append("注销重复扩展失败：\(toolError(removal))")
            }

            if let volume = easyRightVolumeRoot(containing: duplicatePath) {
                let detach = await run(executable: "/usr/bin/hdiutil", arguments: ["detach", volume])
                if !detach.succeeded {
                    _ = await run(executable: "/usr/bin/pkill", arguments: ["-x", "EasyRightExt"])
                    let forced = await run(
                        executable: "/usr/bin/hdiutil",
                        arguments: ["detach", "-force", volume]
                    )
                    if !forced.succeeded {
                        errors.append("推出安装镜像失败：\(toolError(forced))")
                    }
                }
            }
        }

        if initial.currentRegistration == nil || changed {
            let registration = await run(
                executable: "/usr/bin/pluginkit",
                arguments: ["-a", initial.extensionPath]
            )
            if registration.succeeded {
                changed = true
            } else {
                errors.append("注册已安装扩展失败：\(toolError(registration))")
            }
        }

        if wasEnabled {
            let election = await run(
                executable: "/usr/bin/pluginkit",
                arguments: ["-e", "use", "-i", identifier]
            )
            if !election.succeeded {
                errors.append("恢复扩展启用状态失败：\(toolError(election))")
            }
        }

        if reloadFinder, changed, wasEnabled {
            _ = await run(executable: "/usr/bin/pkill", arguments: ["-x", "EasyRightExt"])
            _ = await run(executable: "/usr/bin/killall", arguments: ["Finder"])
        }

        let final = await status()
        return FinderExtensionRepairResult(changed: changed, errors: errors, status: final)
    }

    private static func easyRightVolumeRoot(containing path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes",
              components[2].hasPrefix("EasyRight") else { return nil }
        return "/Volumes/\(components[2])"
    }

    private static func toolError(_ result: ToolResult) -> String {
        if let launchError = result.launchError { return launchError }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "错误码 \(result.status)" : output
    }

    private static func run(executable: String, arguments: [String]) async -> ToolResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return ToolResult(status: -1, output: "", launchError: error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ToolResult(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? "",
                launchError: nil
            )
        }.value
    }
}
