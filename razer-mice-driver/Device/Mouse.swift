import Foundation
import Observation

struct ButtonRow: Identifiable, Equatable {
    let slot: UInt8
    var block: FunctionBlock
    /// Set once the firmware rejects a write to this slot.
    var isUnsupported = false

    var id: UInt8 { slot }
    var action: ButtonAction { ButtonAction(block: block) }
    var isLocked: Bool { slot == ButtonSlot.leftClick }
}

/// The connected mouse: what the device reports, plus the bindings this app owns.
@Observable
final class Mouse {
    private(set) var link: LinkState = .searching
    private(set) var batteryPercent: Int?
    private(set) var dpi: DPITable?
    private(set) var buttons: [ButtonRow] = []
    private(set) var isBusy = false
    /// Button slot to the Apple Shortcut it runs.
    private(set) var shortcuts: [UInt8: String] = Store.shortcuts
    /// Every shortcut in the Shortcuts app, for the picker.
    private(set) var availableShortcuts: [String] = []
    var lastError: String?

    let log = DiagnosticsLog()

    @ObservationIgnored private lazy var vendor = VendorLink(log: log)
    @ObservationIgnored private var batteryTimer: Timer?
    @ObservationIgnored private var dpiPoll: Task<Void, Never>?
    @ObservationIgnored private let hotKeys = HotKeys()
    /// Standard Battery Service reading; only used when the vendor read fails.
    @ObservationIgnored private var standardBattery: Int?

    var isReady: Bool {
        if case .ready = link { true } else { false }
    }

    var deviceName: String {
        switch link {
        case .ready(let name), .connecting(let name), .unsupported(let name):
            name == "DA V2 X" ? "DeathAdder V2 X HyperSpeed" : name
        default:
            "DeathAdder V2 X HyperSpeed"
        }
    }

    func start() {
        vendor.onStateChange = { [weak self] state in
            guard let self else { return }
            self.link = state
            if case .ready = state { Task { await self.refresh() } }
        }
        vendor.onStandardBattery = { [weak self] level in
            guard let self else { return }
            self.standardBattery = level
            if self.batteryPercent == nil { self.batteryPercent = level }
        }
        vendor.start()
        hotKeys.onPress = { [weak self] slot in self?.runShortcut(for: slot) }
        hotKeys.listen(for: Set(shortcuts.keys))
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.readBattery() }
        }
    }

    func refresh() async {
        guard isReady, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await readBattery()
        await readDPI()
        await loadButtons()
    }

    // MARK: Battery

    private func readBattery() async {
        guard isReady else { return }
        do {
            // AA-powered Razer Bluetooth mice report charge on a 0...255 scale.
            let payload = try await vendor.send(.batteryRaw)
            guard let raw = payload.first else { return }
            batteryPercent = Int((Double(raw) / 255 * 100).rounded())
        } catch {
            batteryPercent = standardBattery
        }
    }

    // MARK: DPI

    func resetDPI() async {
        await setDPI(.factory(replacing: dpi))
    }

    /// The mouse sends nothing when its own DPI buttons change the stage, but a
    /// read does return the new active stage. So the table is re-read back to
    /// back (a read takes 20 to 200 ms), and only while the popover is showing it.
    func followDPI(_ follow: Bool) {
        dpiPoll?.cancel()
        dpiPoll = nil
        guard follow else { return }
        dpiPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let changed = await self.readDPI(quiet: true)
                if changed, let dpi = self.dpi {
                    self.log.add("DPI changed on the mouse: stage \(dpi.activeIndex + 1), \(dpi.stages[dpi.activeIndex].x)")
                }
                // Short breather so a write queued from the UI is never starved,
                // and a disconnected mouse is not polled in a tight loop.
                try? await Task.sleep(for: .milliseconds(self.isReady ? 60 : 1000))
            }
        }
    }

    /// Returns whether the table differs from the one already held.
    @discardableResult
    private func readDPI(quiet: Bool = false) async -> Bool {
        guard let payload = try? await vendor.send(.dpiStagesGet, quiet: quiet) else { return false }
        guard let table = DPITable(payload: payload) else {
            log.add("unreadable DPI table: \(payload.hex)")
            return false
        }
        guard table != dpi else { return false }
        dpi = table
        return true
    }

    func setDPI(_ table: DPITable) async {
        await write("DPI") {
            _ = try await self.vendor.send(.dpiStagesSet, payload: table.payload)
            self.dpi = table
        }
        // The firmware may reassign stage IDs; later writes must echo what it holds.
        await readDPI()
    }

    // MARK: Buttons

    private func loadButtons() async {
        var readbacks: [UInt8: FunctionBlock] = [:]
        for slot in ButtonSlot.scanned {
            do {
                let payload = try await vendor.send(.buttonGet(slot: slot))
                if let block = FunctionBlock(readback: payload, slot: slot) { readbacks[slot] = block }
            } catch LinkError.rejected where slot != ButtonSlot.leftClick {
                continue
            } catch {
                // Every mouse has a left button, so a refusal there means the firmware
                // has no button read at all (the DeathAdder V2 X does not). Stop asking;
                // the saved bindings stand in.
                log.add("button readback unavailable: \(error.localizedDescription)")
                break
            }
        }
        guard isReady else { return }

        var originals = Store.originals
        for (slot, block) in readbacks where ButtonSlot.factoryBlock(slot) == nil && originals[slot] == nil {
            originals[slot] = block
        }
        Store.originals = originals

        let saved = Store.bindings
        let extras = readbacks.keys.filter { !ButtonSlot.fixed.contains($0) }.sorted()
        var rows: [ButtonRow] = []
        for slot in ButtonSlot.fixed + extras {
            let fallback = readbacks[slot] ?? defaultBlock(for: slot) ?? ButtonAction.disabled.block
            var row = ButtonRow(slot: slot, block: saved[slot] ?? fallback)
            // The mouse can forget live bindings across a power cycle, so the saved
            // ones are written back whenever the device disagrees or cannot say.
            if let wanted = saved[slot], wanted != readbacks[slot], !row.isLocked {
                do {
                    _ = try await vendor.send(.buttonSet(slot: slot), payload: wanted.bindPayload(slot: slot))
                } catch {
                    row.block = fallback
                    row.isUnsupported = true
                }
            }
            rows.append(row)
        }
        buttons = rows
    }

    func defaultBlock(for slot: UInt8) -> FunctionBlock? {
        ButtonSlot.factoryBlock(slot) ?? Store.originals[slot]
    }

    func bind(slot: UInt8, to action: ButtonAction) async {
        guard slot != ButtonSlot.leftClick, let index = buttons.firstIndex(where: { $0.slot == slot }) else { return }
        let block = action.block
        await write(ButtonSlot.name(slot)) {
            do {
                _ = try await self.vendor.send(.buttonSet(slot: slot), payload: block.bindPayload(slot: slot))
            } catch let error as LinkError {
                if case .rejected = error { self.buttons[index].isUnsupported = true }
                throw error
            }
            self.buttons[index].block = block
            self.buttons[index].isUnsupported = false
            var saved = Store.bindings
            saved[slot] = block == self.defaultBlock(for: slot) ? nil : block
            Store.bindings = saved
            self.setShortcut(nil, for: slot)
        }
    }

    // MARK: Apple Shortcuts

    func loadShortcuts() async {
        availableShortcuts = await AppleShortcuts.names()
    }

    /// The mouse cannot run a shortcut itself. It is bound to a reserved key
    /// combination instead, and this app runs the shortcut when it hears it,
    /// so these buttons only work while the app is running.
    func bind(slot: UInt8, toShortcut name: String) async {
        guard let key = ButtonSlot.triggerKey(slot) else { return }
        await bind(slot: slot, to: .key(modifiers: .all, usage: key.usage))
        if lastError == nil { setShortcut(name, for: slot) }
    }

    private func setShortcut(_ name: String?, for slot: UInt8) {
        guard shortcuts[slot] != name else { return }
        shortcuts[slot] = name
        Store.shortcuts = shortcuts
        hotKeys.listen(for: Set(shortcuts.keys))
    }

    private func runShortcut(for slot: UInt8) {
        guard let name = shortcuts[slot] else { return }
        log.add("\(ButtonSlot.name(slot)) pressed: running shortcut \(name)")
        do {
            try AppleShortcuts.run(name)
        } catch {
            lastError = "Could not run the shortcut \(name). \(error.localizedDescription)"
        }
    }

    /// Writes every remappable button's factory action back and forgets the saved ones.
    func resetButtons() async {
        var failures: [String] = []
        for row in buttons where !row.isLocked {
            guard let block = defaultBlock(for: row.slot) else { continue }
            await bind(slot: row.slot, to: ButtonAction(block: block))
            if lastError != nil { failures.append(ButtonSlot.name(row.slot)) }
        }
        // `bind` keeps only the last error; a reset should name every button it missed.
        if !failures.isEmpty { lastError = "Could not reset: \(failures.joined(separator: ", "))." }
    }

    private func write(_ what: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            lastError = nil
        } catch {
            lastError = "Could not change \(what). \(error.localizedDescription)"
        }
    }
}

/// Bindings live in UserDefaults because the device cannot be trusted to keep them.
private enum Store {
    static var bindings: [UInt8: FunctionBlock] {
        get { load("bindings") }
        set { save(newValue, "bindings") }
    }

    /// First-seen blocks for slots with no known factory default.
    static var originals: [UInt8: FunctionBlock] {
        get { load("originals") }
        set { save(newValue, "originals") }
    }

    /// Slot to the name of the Apple Shortcut its reserved key runs.
    static var shortcuts: [UInt8: String] {
        get { load("shortcuts") }
        set { save(newValue, "shortcuts") }
    }

    private static func load<Value: Codable>(_ key: String) -> [UInt8: Value] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([UInt8: Value].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save<Value: Codable>(_ value: [UInt8: Value], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
