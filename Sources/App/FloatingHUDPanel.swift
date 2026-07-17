import AppKit

enum FloatingHUDPlacement {
    /// 优先放在选区下方；空间不足时贴屏幕底部。
    case belowOrScreenBottom
    /// 优先放在选区下方；空间不足时移到选区上方。
    case belowOrAbove
}
/// 录屏和长截图共用的非激活 HUD 窗口外壳。
final class FloatingHUDPanel: NSPanel {
    private let effectView = NSVisualEffectView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 108),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true

        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        contentView = effectView
    }

    func setHUDContent(_ view: NSView) {
        for oldView in effectView.subviews { oldView.removeFromSuperview() }
        effectView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            view.topAnchor.constraint(equalTo: effectView.topAnchor),
            view.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        fitContent()
    }

    func fitContent() {
        setContentSize(effectView.fittingSize)
    }

    func position(relativeTo rect: NSRect, placement: FloatingHUDPlacement) {
        let size = frame.size
        var x = rect.midX - size.width / 2
        var y = rect.minY - size.height - 10
        let targetScreen = NSScreen.screens.first {
            NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false)
        } ?? NSScreen.main
        if let visibleFrame = targetScreen?.visibleFrame {
            if y < visibleFrame.minY {
                switch placement {
                case .belowOrScreenBottom:
                    y = visibleFrame.minY + 12
                case .belowOrAbove:
                    y = rect.maxY + 10
                    if y + size.height > visibleFrame.maxY { y = visibleFrame.minY + 12 }
                }
            }
            x = max(visibleFrame.minX + 8, min(x, visibleFrame.maxX - size.width - 8))
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
