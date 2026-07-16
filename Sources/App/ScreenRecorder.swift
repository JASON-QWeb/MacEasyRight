import AppKit
import ScreenCaptureKit
import AVFoundation

// MARK: - 录屏引擎:ScreenCaptureKit 抓帧 → AVAssetWriter 编码
// 支持任意区域、自定义帧率、MP4(H.264)/MOV(HEVC),并把本 App 的窗口(控制条、红框、贴图工具栏)从画面中排除

final class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?
    private var onFinished: ((URL?) -> Void)?
    private let sampleQueue = DispatchQueue(label: "com.diy.easyright.record")

    private(set) var isRecording = false

    func start(cocoaRect: NSRect, fps: Int, format: String,
               onStarted: @escaping () -> Void,
               onFailed: @escaping (String) -> Void,
               onFinished: @escaping (URL?) -> Void) {
        guard !isRecording else { return }
        self.onFinished = onFinished
        let cgRect = cocoaToCG(cocoaRect)
        Task { @MainActor in
            do {
                try await self.begin(cgRect: cgRect, fps: fps, format: format)
                onStarted()
            } catch {
                self.abortAfterFailure()
                onFailed(error.localizedDescription)
            }
        }
    }

    private func begin(cgRect: CGRect, fps: Int, format: String) async throws {
        // 找到区域所在显示器(权限未授予时这一步会抛错并触发系统引导)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: {
            CGDisplayBounds($0.displayID).contains(CGPoint(x: cgRect.midX, y: cgRect.midY))
        }) ?? content.displays.first else {
            throw NSError(domain: "EasyRight", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到可录制的显示器"])
        }
        let dispBounds = CGDisplayBounds(display.displayID)
        let local = CGRect(x: cgRect.minX - dispBounds.minX,
                           y: cgRect.minY - dispBounds.minY,
                           width: cgRect.width, height: cgRect.height)
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
        let scale = screen?.backingScaleFactor ?? 2
        var pw = Int(local.width * scale)
        var ph = Int(local.height * scale)
        pw -= pw % 2 // 编码器要求偶数尺寸
        ph -= ph % 2
        guard pw >= 16, ph >= 16 else {
            throw NSError(domain: "EasyRight", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "录制区域太小"])
        }

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = local
        cfg.width = pw
        cfg.height = ph
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 8

        // 把本 App 自己的窗口(录制控制条、红框、贴图等 UI)从画面中排除
        let myWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: myWindows)

        // 输出文件与编码器
        let c = EasyConfig.load()
        try? FileManager.default.createDirectory(atPath: c.saveDir, withIntermediateDirectories: true)
        let isMP4 = format == "mp4"
        let url = URL(fileURLWithPath: c.saveDir + "/录屏 \(ScreenshotController.shared.timestamp()).\(isMP4 ? "mp4" : "mov")")
        let w = try AVAssetWriter(url: url, fileType: isMP4 ? .mp4 : .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: isMP4 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: pw,
            AVVideoHeightKey: ph,
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        w.add(inp)
        guard w.startWriting() else {
            throw w.error ?? NSError(domain: "EasyRight", code: 3,
                                     userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()

        stream = s
        writer = w
        input = inp
        outputURL = url
        sessionStarted = false
        isRecording = true
        NSLog("EasyRight: SCK recording started %dx%d @%dfps -> %@", pw, ph, fps, url.lastPathComponent)
    }

    // MARK: 帧回调

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isRecording,
              let writer, let input else { return }
        // 只写完整帧
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = atts.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("EasyRight: SCK stream stopped with error %@", error.localizedDescription)
        DispatchQueue.main.async { self.stop(stopStream: false) }
    }

    // MARK: 停止

    func stop(stopStream: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        let s = stream
        let w = writer
        let inp = input
        let url = outputURL
        let started = sessionStarted
        let cb = onFinished
        stream = nil
        writer = nil
        input = nil
        outputURL = nil
        onFinished = nil

        Task {
            if stopStream { try? await s?.stopCapture() }
            inp?.markAsFinished()
            if let w, started, w.status == .writing {
                await w.finishWriting()
                await MainActor.run {
                    NSLog("EasyRight: recording saved %@", url?.path ?? "?")
                    cb?(url)
                }
            } else {
                w?.cancelWriting()
                if let url { try? FileManager.default.removeItem(at: url) }
                await MainActor.run { cb?(nil) }
            }
        }
    }

    private func abortAfterFailure() {
        if let w = writer, w.status == .writing { w.cancelWriting() }
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        stream = nil
        writer = nil
        input = nil
        outputURL = nil
        onFinished = nil
        isRecording = false
    }
}
