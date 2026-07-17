// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EasyRight",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "EasyRightShared",
            path: "Sources/Shared",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(
            name: "EasyRightStitching",
            path: "Sources/App",
            exclude: [
                "AppDelegate.swift",
                "CommandHandler.swift",
                "FloatingHUDPanel.swift",
                "FinderExtensionManager.swift",
                "HotkeyManager.swift",
                "KeyNames.swift",
                "LongScreenshot.swift",
                "LongshotCaptureSupport.swift",
                "NewFileCreator.swift",
                "PinWindow.swift",
                "Recorder.swift",
                "RegionAdjust.swift",
                "RegionSelector.swift",
                "ScreenRecorder.swift",
                "ScreenshotController.swift",
                "SettingsView.swift",
                "main.swift",
            ],
            sources: ["Stitcher.swift"]
        ),
        .executableTarget(
            name: "EasyRightTests",
            dependencies: ["EasyRightShared", "EasyRightStitching"],
            path: "Tests/EasyRightStitchingTests"
        ),
    ]
)
