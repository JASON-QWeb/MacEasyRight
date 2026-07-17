import Foundation
import Darwin

enum NewFileCreationError: LocalizedError {
    case invalidDestination(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination(let path):
            return "目标文件夹不存在或不是文件夹：\(path)"
        }
    }
}

struct NewFileCreator {
    private let fm: FileManager

    init(fileManager: FileManager = .default) {
        fm = fileManager
    }

    func create(_ kind: NewFileKind, inDirectoryPath path: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NewFileCreationError.invalidDestination(path)
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let data = Data(kind.initialContents.utf8)
        let name = kind.defaultFileName
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var index = 1

        while true {
            let candidateName = index == 1 ? name : "\(base) \(index).\(ext)"
            let destination = directory.appendingPathComponent(candidateName)
            if try write(data, exclusivelyTo: destination) { return destination }
            else {
                index = index == 1 ? 2 : index + 1
            }
        }
    }

    /// 以 O_EXCL 创建,确保不会覆盖同名文件;写入失败时删除由本次调用创建的残缺文件。
    private func write(_ data: Data, exclusivelyTo destination: URL) throws -> Bool {
        let descriptor = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o666))
        }
        if descriptor < 0 {
            let errorCode = errno
            if errorCode == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }

        let writeError: Int32 = data.withUnsafeBytes { buffer in
            var pointer = buffer.baseAddress
            var remaining = buffer.count
            while remaining > 0 {
                guard let current = pointer else { return EIO }
                let written = Darwin.write(descriptor, current, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if written == 0 { return EIO }
                pointer = current.advanced(by: written)
                remaining -= written
            }
            return 0
        }
        let closeError: Int32 = Darwin.close(descriptor) == 0 ? 0 : errno
        let errorCode = writeError != 0 ? writeError : closeError
        if errorCode != 0 {
            destination.path.withCString { _ = Darwin.unlink($0) }
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
        return true
    }
}
