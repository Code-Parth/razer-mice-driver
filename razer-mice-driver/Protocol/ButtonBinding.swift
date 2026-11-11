import Foundation

/// The 7-byte action the firmware stores per button: `[class][length][data...]`.
struct FunctionBlock: Hashable, Codable {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = Array((bytes + [UInt8](repeating: 0, count: 7)).prefix(7))
    }

    var hex: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    /// Button readbacks come in two shapes: the 10-byte write echo
    /// `[target][slot][layer][block]`, or `[slot][00]` followed by the block with
    /// every byte doubled (current and previous value interleaved).
    init?(readback: [UInt8], slot: UInt8) {
        if readback.count >= 10, readback[0] == 0x01, readback[1] == slot {
            self.init(Array(readback[3..<10]))
            return
        }
        guard readback.count >= 9, readback[0] == slot else { return nil }
        let tail = Array(readback.dropFirst(2))
        if tail.count >= 14 {
            self.init(stride(from: 0, to: 14, by: 2).map { tail[$0] })
        } else {
            self.init(Array(tail.prefix(7)))
        }
    }

    /// Live-profile write payload for `08 04 01 <slot>`.
    func bindPayload(slot: UInt8) -> [UInt8] { [0x01, slot, 0x00] + bytes }
}

enum MouseFunction: UInt8, CaseIterable, Identifiable {
    case leftClick = 0x01
    case rightClick = 0x02
    case middleClick = 0x03
    case back = 0x04
    case forward = 0x05
    case scrollUp = 0x09
    case scrollDown = 0x0A

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .leftClick: "Left Click"
        case .rightClick: "Right Click"
        case .middleClick: "Middle Click"
        case .back: "Back"
        case .forward: "Forward"
        case .scrollUp: "Scroll Up"
        case .scrollDown: "Scroll Down"
        }
    }
}

struct KeyModifiers: OptionSet, Hashable {
    let rawValue: UInt8

    static let control = KeyModifiers(rawValue: 0x01)
    static let shift = KeyModifiers(rawValue: 0x02)
    static let option = KeyModifiers(rawValue: 0x04)
    static let command = KeyModifiers(rawValue: 0x08)
    static let all: KeyModifiers = [.control, .shift, .option, .command]

    var symbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

enum ButtonAction: Hashable {
    case mouse(MouseFunction)
    case key(modifiers: KeyModifiers, usage: UInt8)
    case dpiCycle
    case dpiUp
    case dpiDown
    case disabled
    /// A block this app does not model; kept verbatim so it can be shown and restored.
    case raw(FunctionBlock)

    init(block: FunctionBlock) {
        let b = block.bytes
        switch (b[0], b[1]) {
        case (0x00, _) where b.allSatisfy({ $0 == 0 }):
            self = .disabled
        case (0x01, 0x01):
            self = MouseFunction(rawValue: b[2]).map(ButtonAction.mouse) ?? .raw(block)
        case (0x02, 0x02):
            self = .key(modifiers: KeyModifiers(rawValue: b[2]), usage: b[3])
        case (0x06, 0x01) where b[2] == 0x06:
            self = .dpiCycle
        case (0x06, 0x01) where b[2] == 0x01:
            self = .dpiUp
        case (0x06, 0x01) where b[2] == 0x02:
            self = .dpiDown
        default:
            self = .raw(block)
        }
    }

    var block: FunctionBlock {
        switch self {
        case .mouse(let function): FunctionBlock([0x01, 0x01, function.rawValue])
        case .key(let modifiers, let usage): FunctionBlock([0x02, 0x02, modifiers.rawValue, usage])
        case .dpiCycle: FunctionBlock([0x06, 0x01, 0x06])
        case .dpiUp: FunctionBlock([0x06, 0x01, 0x01])
        case .dpiDown: FunctionBlock([0x06, 0x01, 0x02])
        case .disabled: FunctionBlock([])
        case .raw(let block): block
        }
    }

    var title: String {
        switch self {
        case .mouse(let function): function.title
        case .key(let modifiers, let usage):
            MacShortcut.named(modifiers: modifiers, usage: usage)?.title
                ?? modifiers.symbols + String(format: " key 0x%02X", usage)
        case .dpiCycle: "DPI Cycle"
        case .dpiUp: "DPI Stage Up"
        case .dpiDown: "DPI Stage Down"
        case .disabled: "Disabled"
        case .raw(let block): "Custom (\(block.hex))"
        }
    }
}

/// macOS actions that are plain keyboard shortcuts, so the mouse can fire them
/// from firmware with no helper process or Accessibility permission.
struct MacShortcut: Identifiable, Hashable {
    let title: String
    let modifiers: KeyModifiers
    let usage: UInt8

    var id: String { title }
    var action: ButtonAction { .key(modifiers: modifiers, usage: usage) }

    static let all: [MacShortcut] = [
        MacShortcut(title: "Back (⌘[)", modifiers: .command, usage: 0x2F),
        MacShortcut(title: "Forward (⌘])", modifiers: .command, usage: 0x30),
        MacShortcut(title: "Next Tab", modifiers: .control, usage: 0x2B),
        MacShortcut(title: "Previous Tab", modifiers: [.control, .shift], usage: 0x2B),
        MacShortcut(title: "Mission Control", modifiers: .control, usage: 0x52),
        MacShortcut(title: "App Exposé", modifiers: .control, usage: 0x51),
        MacShortcut(title: "Desktop Left", modifiers: .control, usage: 0x50),
        MacShortcut(title: "Desktop Right", modifiers: .control, usage: 0x4F),
        MacShortcut(title: "Switch to Last App", modifiers: .command, usage: 0x2B),
        MacShortcut(title: "Spotlight", modifiers: .command, usage: 0x2C),
        MacShortcut(title: "Copy", modifiers: .command, usage: 0x06),
        MacShortcut(title: "Paste", modifiers: .command, usage: 0x19),
        MacShortcut(title: "Undo", modifiers: .command, usage: 0x1D),
        MacShortcut(title: "Close Tab", modifiers: .command, usage: 0x1A),
        MacShortcut(title: "Screenshot Selection", modifiers: [.command, .shift], usage: 0x21),
        MacShortcut(title: "Lock Screen", modifiers: [.control, .command], usage: 0x14),
    ]

    static func named(modifiers: KeyModifiers, usage: UInt8) -> MacShortcut? {
        all.first { $0.modifiers == modifiers && $0.usage == usage }
    }
}

/// Firmware button slots, lettered as in Razer's guide for this mouse.
enum ButtonSlot {
    static let leftClick: UInt8 = 0x01
    // The two index-finger edge buttons. Slots and factory blocks follow Razer's
    // other two-edge-button mice; this firmware cannot read them back to confirm.
    static let dpiUp: UInt8 = 0x0B
    static let dpiDown: UInt8 = 0x0C
    static let sideFront: UInt8 = 0x05
    static let sideRear: UInt8 = 0x04

    static let fixed: [UInt8] = [dpiUp, dpiDown, 0x01, 0x02, 0x03, 0x09, 0x0A, sideFront, sideRear]
    static let scanned: [UInt8] = Array(0x01...0x0F) + [0x34, 0x35] + Array(0x60...0x6F)

    static func name(_ slot: UInt8) -> String {
        switch slot {
        case dpiUp: "DPI stage up"
        case dpiDown: "DPI stage down"
        case 0x01: "Left mouse button"
        case 0x02: "Right mouse button"
        case 0x03: "Scroll wheel click"
        case 0x09: "Scroll up"
        case 0x0A: "Scroll down"
        case sideFront: "Mouse button 5"
        case sideRear: "Mouse button 4"
        default: String(format: "Button 0x%02X", slot)
        }
    }

    /// The guide's letter for the part this slot belongs to. There is no F: that
    /// is the status light, which has no slot. Nil for slots found by scanning.
    static func letter(_ slot: UInt8) -> String? {
        switch slot {
        case dpiUp: "A"
        case dpiDown: "B"
        case 0x01: "C"
        case 0x02: "D"
        case 0x03, 0x09, 0x0A: "E"
        case sideFront: "G"
        case sideRear: "H"
        default: nil
        }
    }

    /// The key a button sends to stand for "run my Apple Shortcut": all four
    /// modifiers with F13 to F20, one per remappable button. Nothing else uses
    /// these, so the app can listen for them system-wide. `usage` is what the
    /// mouse sends; `keyCode` is the macOS key code the hotkey is registered on.
    static func triggerKey(_ slot: UInt8) -> (usage: UInt8, keyCode: UInt32)? {
        let keys: [(usage: UInt8, keyCode: UInt32)] = [
            (0x68, 105), (0x69, 107), (0x6A, 113), (0x6B, 106), (0x6C, 64), (0x6D, 79), (0x6E, 80), (0x6F, 90),
        ]
        guard let index = fixed.filter({ $0 != leftClick }).firstIndex(of: slot), index < keys.count else { return nil }
        return keys[index]
    }

    /// Factory binding, per the guide's button table.
    static func factoryBlock(_ slot: UInt8) -> FunctionBlock? {
        switch slot {
        case dpiUp: ButtonAction.dpiUp.block
        case dpiDown: ButtonAction.dpiDown.block
        default: MouseFunction(rawValue: slot).map { ButtonAction.mouse($0).block }
        }
    }
}
