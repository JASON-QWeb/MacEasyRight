import Darwin
import EasyRightShared
import EasyRightStitching
import Foundation

private struct TestRunner {
    private(set) var failures = 0

    mutating func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            print("✓ \(name)")
        } else {
            failures += 1
            print("✗ \(name)")
        }
    }
}

private func makeFrame(
    width: Int,
    height: Int,
    sourceRow: (Int) -> Int
) -> StitchFrame {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for row in 0..<height {
        let source = sourceRow(row)
        for x in 0..<width {
            let index = (row * width + x) * 4
            pixels[index] = UInt8(truncatingIfNeeded: source &* 17 + x &* 3)
            pixels[index + 1] = UInt8(truncatingIfNeeded: source &* 29 + x &* 5)
            pixels[index + 2] = UInt8(truncatingIfNeeded: source &* 43 + x &* 7)
            pixels[index + 3] = 255
        }
    }
    return StitchFrame(width: width, height: height, pixels: pixels)
}

private var tests = TestRunner()

let identical = makeFrame(width: 320, height: 240) { $0 }
tests.expect(
    Stitcher.scrollOffset(prev: identical, cur: identical) == 0,
    "identical frames return zero"
)

let knownOffset = 60
let knownPrevious = makeFrame(width: 320, height: 240) { $0 }
let knownCurrent = makeFrame(width: 320, height: 240) { $0 + knownOffset }
tests.expect(
    Stitcher.scrollOffset(prev: knownPrevious, cur: knownCurrent) == knownOffset,
    "known downward scroll offset"
)

let stickyOffset = 54
let stickyPrevious = makeFrame(width: 360, height: 260) { $0 }
let stickyCurrent = makeFrame(width: 360, height: 260) { row in
    row < 35 ? 10_000 + row : row + stickyOffset
}
tests.expect(
    Stitcher.scrollOffset(prev: stickyPrevious, cur: stickyCurrent) == stickyOffset,
    "sticky header changes are ignored"
)

let unrelated = makeFrame(width: 320, height: 240) { 20_000 + $0 * $0 * 11 }
tests.expect(
    Stitcher.scrollOffset(prev: knownPrevious, cur: unrelated) == nil,
    "unrelated frames return nil"
)

let mismatched = makeFrame(width: 321, height: 240) { $0 }
tests.expect(
    Stitcher.scrollOffset(prev: knownPrevious, cur: mismatched) == nil,
    "mismatched dimensions return nil"
)

let commandToken = String(repeating: "a", count: 64)
let command = Command(
    action: .moveTo,
    targets: ["/tmp/source"],
    dest: "/tmp/destination"
)
let commandURL = encodeCommandURL(command, token: commandToken)
tests.expect(commandURL != nil, "authenticated command URL encodes")
tests.expect(
    commandURL.flatMap { decodeCommand(from: $0, expectedToken: commandToken) }?.action == .moveTo,
    "authenticated command URL round-trips"
)
tests.expect(
    commandURL.flatMap { decodeCommand(from: $0, expectedToken: String(repeating: "b", count: 64)) } == nil,
    "command with wrong token is rejected"
)

if let legacyData = try? JSONEncoder().encode(command) {
    let legacyPayload = legacyData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    if let legacyURL = URL(string: "easyright://cmd?d=\(legacyPayload)") {
        tests.expect(
            decodeCommand(from: legacyURL, expectedToken: commandToken) == nil,
            "legacy unauthenticated command is rejected"
        )
    } else {
        tests.expect(false, "legacy command URL fixture is valid")
    }
} else {
    tests.expect(false, "legacy command fixture encodes")
}
tests.expect(
    isCommandBootstrapURL(commandBootstrapURL()),
    "bootstrap URL is recognized separately"
)

if tests.failures > 0 {
    print("\n\(tests.failures) test(s) failed")
    exit(1)
}
print("\nAll EasyRight tests passed")
