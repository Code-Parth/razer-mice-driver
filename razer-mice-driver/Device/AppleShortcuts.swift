import AppKit
import Carbon.HIToolbox

/// The Shortcuts app, through its command-line tool.
nonisolated enum AppleShortcuts {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Names of every shortcut in the user's library.
    static func names() async -> [String] {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = tool
            process.arguments = ["list"]
            process.standardOutput = output
            guard (try? process.run()) != nil else { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }.value
    }

    static func run(_ name: String) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["run", name]
        try process.run()
    }
}

/// System-wide hotkeys for the key combinations the mouse sends on behalf of a
/// shortcut. Carbon's hotkey API is used because it is the one way to hear a
/// key press in another app without Accessibility or Input Monitoring permission.
final class HotKeys {
    /// Called with the button slot whose reserved combination was pressed.
    var onPress: ((UInt8) -> Void)?

    private var registered: [UInt8: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4144_4452  // "ADDR"

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), hotKeyPressed, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
    }

    /// Registers exactly these slots' combinations and releases the rest, so a
    /// combination is only taken from other apps while a button uses it.
    func listen(for slots: Set<UInt8>) {
        for (slot, reference) in registered where !slots.contains(slot) {
            UnregisterEventHotKey(reference)
            registered[slot] = nil
        }
        for slot in slots where registered[slot] == nil {
            guard let key = ButtonSlot.triggerKey(slot) else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                key.keyCode, UInt32(cmdKey | optionKey | controlKey | shiftKey),
                EventHotKeyID(signature: Self.signature, id: UInt32(slot)),
                GetApplicationEventTarget(), 0, &reference
            )
            if status == noErr, let reference { registered[slot] = reference }
        }
    }

    fileprivate func pressed(slot: UInt8) {
        onPress?(slot)
    }
}

/// Carbon wants a C function; it hands back the `HotKeys` instance as user data.
private func hotKeyPressed(_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard let userData else { return noErr }
    let slot = UInt8(truncatingIfNeeded: id.id)
    // Carbon delivers application events on the main thread.
    MainActor.assumeIsolated {
        Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().pressed(slot: slot)
    }
    return noErr
}
