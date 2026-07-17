import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 长截图期间复用一个 ScreenCaptureKit 流，只保留最新完整帧。
final class LongshotFrameSource: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "com.diy.easyright.longshot.capture", qos: .userInitiated)
    private let condition = NSCondition()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var latestImage: CGImage?
    private var generation = 0
    private var stopped = false

    func start(cgRect: CGRect) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: {
            CGDisplayBounds($0.displayID).contains(CGPoint(x: cgRect.midX, y: cgRect.midY))
        }) ?? content.displays.first else {
            throw NSError(
                domain: "EasyRight.Longshot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "找不到要截取的显示器"]
            )
        }

        let displayBounds = CGDisplayBounds(display.displayID)
        let localRect = CGRect(
            x: cgRect.minX - displayBounds.minX,
            y: cgRect.minY - displayBounds.minY,
            width: cgRect.width,
            height: cgRect.height
        )
        let displayMode = CGDisplayCopyDisplayMode(display.displayID)
        let scale = displayBounds.width > 0
            ? CGFloat(displayMode?.pixelWidth ?? Int(displayBounds.width)) / displayBounds.width
            : 1

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = max(1, Int(localRect.width * scale))
        configuration.height = max(1, Int(localRect.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        resetState()

        try await newStream.startCapture()
        stream = newStream
    }

    func nextFrame(after previousGeneration: Int, timeout: TimeInterval) -> (image: CGImage, generation: Int)? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while generation <= previousGeneration && !stopped {
            if !condition.wait(until: deadline) { break }
        }
        guard generation > previousGeneration, let latestImage else { return nil }
        return (latestImage, generation)
    }

    func stop() async {
        let currentStream = stream
        stream = nil
        if let currentStream {
            do {
                try await currentStream.stopCapture()
            } catch {
                NSLog("EasyRight: longshot stream stop failed: %@", error.localizedDescription)
            }
        }
        markStopped(clearImage: true)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        condition.lock()
        latestImage = image
        generation += 1
        condition.broadcast()
        condition.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("EasyRight: longshot stream stopped: %@", error.localizedDescription)
        markStopped(clearImage: false)
    }

    private func resetState() {
        condition.lock()
        stopped = false
        latestImage = nil
        generation = 0
        condition.unlock()
    }

    private func markStopped(clearImage: Bool) {
        condition.lock()
        stopped = true
        if clearImage { latestImage = nil }
        condition.broadcast()
        condition.unlock()
    }
}

/// 把已接受的拼接片段压缩到临时目录，避免同时常驻全部位图和最终画布。
final class LongshotSliceStore {
    private struct Slice {
        let url: URL
        let height: Int
    }

    private let directory: URL
    private var slices: [Slice] = []
    private(set) var width = 0
    private(set) var totalHeight = 0
    var count: Int { slices.count }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("easyright-longshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { cleanup() }

    func append(_ image: CGImage) throws {
        if width == 0 { width = image.width }
        guard image.width == width else {
            throw NSError(
                domain: "EasyRight.Longshot",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "长截图帧宽度发生变化"]
            )
        }
        let url = directory.appendingPathComponent(String(format: "%04d.png", slices.count))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "EasyRight.Longshot",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "无法创建长截图临时片段"]
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "EasyRight.Longshot",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法写入长截图临时片段"]
            )
        }
        slices.append(Slice(url: url, height: image.height))
        totalHeight += image.height
    }

    func compose() -> CGImage? {
        guard width > 0, totalHeight > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        var yFromTop = 0
        for slice in slices {
            let loaded: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(slice.url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            guard let loaded else { return nil }
            let y = totalHeight - yFromTop - slice.height
            context.draw(loaded, in: CGRect(x: 0, y: y, width: width, height: slice.height))
            yFromTop += slice.height
        }
        return context.makeImage()
    }

    func cleanup() {
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            NSLog("EasyRight: failed to remove longshot temp data: %@", error.localizedDescription)
        }
    }
}
