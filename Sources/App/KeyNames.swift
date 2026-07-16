import AppKit

// MARK: - keyCode → 显示名称(ANSI 布局常用键)

let kKeyNames: [UInt16: String] = [
    0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
    38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
    15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
    18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    49: "空格", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 117: "⌦",
    115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
    41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
]

// Carbon 修饰键位
let kCarbonCmd: UInt32 = 256
let kCarbonShift: UInt32 = 512
let kCarbonOption: UInt32 = 2048
let kCarbonControl: UInt32 = 4096

func hotkeyDisplay(_ hk: HotkeyConfig) -> String {
    var s = ""
    if hk.modifiers & kCarbonControl != 0 { s += "⌃" }
    if hk.modifiers & kCarbonOption != 0 { s += "⌥" }
    if hk.modifiers & kCarbonShift != 0 { s += "⇧" }
    if hk.modifiers & kCarbonCmd != 0 { s += "⌘" }
    s += kKeyNames[hk.keyCode] ?? "键\(hk.keyCode)"
    return s
}

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var r: UInt32 = 0
    if flags.contains(.command) { r |= kCarbonCmd }
    if flags.contains(.shift) { r |= kCarbonShift }
    if flags.contains(.option) { r |= kCarbonOption }
    if flags.contains(.control) { r |= kCarbonControl }
    return r
}

func nsModifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if carbon & kCarbonCmd != 0 { f.insert(.command) }
    if carbon & kCarbonShift != 0 { f.insert(.shift) }
    if carbon & kCarbonOption != 0 { f.insert(.option) }
    if carbon & kCarbonControl != 0 { f.insert(.control) }
    return f
}
