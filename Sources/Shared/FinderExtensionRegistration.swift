import Foundation

/// `pluginkit -m -A -D -v` 输出中的单条 Finder 扩展注册记录。
public struct FinderExtensionRegistration: Equatable, Sendable {
    public let enabled: Bool
    public let path: String

    public init(enabled: Bool, path: String) {
        self.enabled = enabled
        self.path = path
    }
}

public enum FinderExtensionRegistrationParser {
    /// 只解析包含绝对路径的概要行，忽略后续详细字段和汇总文本。
    public static func parse(
        _ output: String,
        identifier: String
    ) -> [FinderExtensionRegistration] {
        output.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let identifierRange = line.range(of: "\(identifier)(") else { return nil }
            let fields = line.components(separatedBy: "\t")
            guard let rawPath = fields.last else { return nil }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { return nil }

            let election = line[..<identifierRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            return FinderExtensionRegistration(enabled: election.hasPrefix("+"), path: path)
        }
    }
}
