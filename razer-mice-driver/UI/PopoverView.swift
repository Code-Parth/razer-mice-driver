import SwiftUI

extension Color {
    static let adder = Color(red: 0.27, green: 0.84, blue: 0.17)

    /// For filled controls with white text on them, where the full-strength
    /// green is too bright to read against.
    var softened: Color { opacity(0.45) }
}

/// The whole app: status, the lettered diagram, and the two things it configures.
struct PopoverView: View {
    @Environment(Mouse.self) private var mouse
    @State private var section: Section = .buttons
    /// Slot of the row under the pointer. Rows are tracked by slot, not letter:
    /// the three wheel rows share the letter E and must not light up together.
    @State private var hoveredSlot: UInt8?
    @State private var isConfirmingReset = false

    enum Section: String, CaseIterable, Identifiable {
        case buttons = "Buttons"
        case dpi = "DPI"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            StatusHeader()

            MouseDiagram(highlighted: hoveredSlot.flatMap { ButtonSlot.letter($0) })
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .animation(.snappy(duration: 0.2), value: hoveredSlot)

            if !mouse.isReady && mouse.buttons.isEmpty {
                NotConnectedNotice()
            } else {
                sectionBar
                    .padding(.horizontal, 8)

                Group {
                    switch section {
                    case .buttons: ButtonList(hoveredSlot: $hoveredSlot)
                    case .dpi: DPIEditor()
                    }
                }
                .disabled(!mouse.isReady)
            }

            if let error = mouse.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { mouse.lastError = nil }
            }
        }
        .padding(14)
        .frame(width: 430)
        .tint(.adder)
    }

    /// Tabs, with the reset for the tab on show at the trailing edge. The
    /// question takes over the bar in place, because an alert on a transient
    /// popover would close it.
    @ViewBuilder private var sectionBar: some View {
        if isConfirmingReset {
            HStack(spacing: 8) {
                Text(resetQuestion)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Button("Reset", role: .destructive) {
                    isConfirmingReset = false
                    Task {
                        switch section {
                        case .buttons: await mouse.resetButtons()
                        case .dpi: await mouse.resetDPI()
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(.red.opacity(0.55))
                Button("Cancel", role: .cancel) { isConfirmingReset = false }
                    .buttonStyle(.glass)
                    .tint(Color.adder.softened)
            }
            .controlSize(.small)
        } else {
            ZStack(alignment: .trailing) {
                PillTabs(items: Section.allCases, selection: $section)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Built by hand: the stock glass button style takes the app tint
                // and comes out as a green capsule, not a neutral circle.
                Button {
                    isConfirmingReset = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Reset \(section.rawValue)")
                .help("Reset \(section.rawValue)")
                .disabled(!mouse.isReady)
            }
        }
    }

    private var resetQuestion: String {
        switch section {
        case .buttons: "Reset all buttons to default?"
        case .dpi: "Reset DPI to default?"
        }
    }
}

/// Hand-built tabs: the system segmented control blends its tint differently,
/// so it never matches the Cancel button's green.
private struct PillTabs<Item: Hashable & Identifiable & RawRepresentable>: View where Item.RawValue == String {
    let items: [Item]
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                if item == selection {
                    Button(item.rawValue) {}
                        .buttonStyle(.glass)
                        .tint(Color.adder.softened)
                        .accessibilityAddTraits(.isSelected)
                } else {
                    Button(item.rawValue) { selection = item }
                        .buttonStyle(.glass)
                        .tint(.clear)
                }
            }
        }
        .controlSize(.small)
    }
}

private struct StatusHeader: View {
    @Environment(Mouse.self) private var mouse

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "computermouse.fill")
                .font(.title2)
                .foregroundStyle(Color.adder)

            VStack(alignment: .leading, spacing: 1) {
                Text(mouse.deviceName).font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(mouse.isReady ? Color.adder : .orange).frame(width: 7, height: 7)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if mouse.isReady {
                VStack(alignment: .trailing, spacing: 1) {
                    if let dpi = mouse.dpi, dpi.stages.indices.contains(dpi.activeIndex) {
                        Text("\(dpi.stages[dpi.activeIndex].x) DPI")
                            .font(.headline.monospacedDigit())
                            .contentTransition(.numericText())
                            .animation(.snappy, value: dpi.activeIndex)
                    }
                    if let battery = mouse.batteryPercent {
                        Label("\(battery)%", systemImage: "battery.75percent")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var status: String {
        switch mouse.link {
        case .ready: "Connected over Bluetooth"
        case .connecting: "Connecting"
        case .searching: "Searching"
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "No Bluetooth access"
        case .unsupported: "Not configurable"
        }
    }
}

private struct NotConnectedNotice: View {
    @Environment(Mouse.self) private var mouse

    var body: some View {
        Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var detail: String {
        switch mouse.link {
        case .bluetoothOff:
            "Turn Bluetooth on to configure the mouse."
        case .unauthorized:
            "Allow Adder under System Settings, Privacy & Security, Bluetooth, then reopen it."
        case .unsupported:
            "The mouse is connected, but it does not expose Razer's Bluetooth configuration service."
        case .searching, .connecting, .ready:
            "Set the switch under the mouse to Bluetooth and move it to wake it. The 2.4 GHz dongle mode is not supported."
        }
    }
}

// MARK: Buttons

private struct ButtonList: View {
    @Environment(Mouse.self) private var mouse
    @Binding var hoveredSlot: UInt8?

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(mouse.buttons) { row in
                    ButtonRowView(row: row, isSelected: hoveredSlot == row.slot)
                        .onHover { inside in
                            if inside { hoveredSlot = row.slot } else if hoveredSlot == row.slot { hoveredSlot = nil }
                        }
                }
            }
        }
    }
}

private struct ButtonRowView: View {
    @Environment(Mouse.self) private var mouse
    let row: ButtonRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            LetterBadge(letter: ButtonSlot.letter(row.slot), isFilled: isSelected)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(ButtonSlot.name(row.slot))
                if row.isUnsupported {
                    Text("Not remappable on this mouse").font(.caption).foregroundStyle(.orange)
                }
            }

            Spacer()

            if row.isLocked {
                // Remapping the left button can leave the mouse unusable.
                Text(row.action.title).foregroundStyle(.secondary)
            } else {
                actionMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(isSelected ? .regular.tint(Color.adder.opacity(0.18)) : .regular, in: .rect(cornerRadius: 14))
    }

    private var actionMenu: some View {
        Menu(mouse.shortcuts[row.slot] ?? row.action.title) {
            if let factory = mouse.defaultBlock(for: row.slot) {
                Button("Default (\(ButtonAction(block: factory).title))") { bind(ButtonAction(block: factory)) }
                Divider()
            }
            SwiftUI.Section("Mouse") {
                ForEach(MouseFunction.allCases) { function in
                    Button(function.title) { bind(.mouse(function)) }
                }
            }
            SwiftUI.Section("Sensitivity") {
                Button(ButtonAction.dpiUp.title) { bind(.dpiUp) }
                Button(ButtonAction.dpiDown.title) { bind(.dpiDown) }
                Button(ButtonAction.dpiCycle.title) { bind(.dpiCycle) }
            }
            SwiftUI.Section("macOS") {
                ForEach(MacShortcut.all) { shortcut in
                    Button(shortcut.title) { bind(shortcut.action) }
                }
            }
            Menu("Run Shortcut") {
                if mouse.availableShortcuts.isEmpty {
                    Text("No shortcuts in the Shortcuts app")
                }
                ForEach(mouse.availableShortcuts, id: \.self) { name in
                    Button(name) { Task { await mouse.bind(slot: row.slot, toShortcut: name) } }
                }
            }
            Divider()
            Button(ButtonAction.disabled.title) { bind(.disabled) }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
    }

    private func bind(_ action: ButtonAction) {
        Task { await mouse.bind(slot: row.slot, to: action) }
    }
}

// MARK: DPI

private struct DPIEditor: View {
    @Environment(Mouse.self) private var mouse
    @State private var draft: DPITable?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let table = draft {
                ForEach(Array(table.stages.enumerated()), id: \.element.id) { index, stage in
                    stageRow(index: index, stage: stage, table: table)
                }
            } else {
                Text("The mouse has not reported its DPI stages yet.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onChange(of: mouse.dpi, initial: true) { _, table in draft = table }
    }

    private func stageRow(index: Int, stage: DPIStage, table: DPITable) -> some View {
        HStack(spacing: 10) {
            Button {
                draft?.activeIndex = index
                commit()
            } label: {
                Image(systemName: table.activeIndex == index ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(table.activeIndex == index ? Color.adder : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use stage \(index + 1)")

            Slider(
                value: Binding(
                    get: { Double(stage.x) },
                    set: { value in
                        draft?.stages[index].x = Int(value)
                        draft?.stages[index].y = Int(value)
                    }
                ),
                in: Double(DPITable.range.lowerBound)...Double(DPITable.range.upperBound),
                step: 100
            ) { editing in
                if !editing { commit() }
            }
            .accessibilityLabel("Stage \(index + 1) DPI")

            Text("\(stage.x)")
                .font(.body.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func commit() {
        guard let draft, draft != mouse.dpi else { return }
        Task { await mouse.setDPI(draft) }
    }
}
