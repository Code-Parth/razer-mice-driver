# Adder

Menu bar only app that configures a Razer DeathAdder V2 X HyperSpeed over Bluetooth on
macOS. It does two things: button bindings and DPI stages. Native Swift, SwiftUI, Liquid Glass.

## Layout

| Path | What lives there |
|---|---|
| `razer-mice-driver/App/AdderApp.swift` | `@main`, `AppDelegate`: status item and the one popover. No window |
| `razer-mice-driver/Protocol/` | Pure wire format: frames, response reassembly, DPI table, button function blocks. No I/O |
| `razer-mice-driver/Device/VendorLink.swift` | CoreBluetooth transport, one serialized exchange at a time |
| `razer-mice-driver/Device/Mouse.swift` | `@Observable` model the UI reads; owns saved bindings |
| `razer-mice-driver/Device/DiagnosticsLog.swift` | Session log, written to `~/Library/Logs/Adder/adder.log`. No UI |
| `razer-mice-driver/UI/PopoverView.swift` | The whole UI: status header, diagram, Buttons list, DPI editor, each with a confirmed reset |
| `razer-mice-driver/Device/AppleShortcuts.swift` | Lists and runs Apple Shortcuts (`/usr/bin/shortcuts`); Carbon hotkeys that hear the mouse's reserved keys |
| `razer-mice-driver/UI/MouseDiagram.swift` | Outline drawing (top and left side) with the guide's A-H badges |
| `razer-mice-driver/Resources/MouseLineArt.json` | Strokes for the diagram, generated from a third-party mesh (see invariant 9) |
| `razer-mice-driver.xcodeproj/project.xcproj` | Xcode 27 JSON project. The source folder is synced: new files need no project edit |

## Invariants

1. **Config goes over the vendor GATT service, never HID.** In Bluetooth mode the mouse
   exposes no HID feature reports (`MaxFeatureReportSize = 1`). Service
   `52401523-F97C-7F90-0E7F-6C6F4E36DB1C`, write `...1524`, notify `...1525`.
2. **One exchange at a time.** The only correlation token is a one-byte request ID and
   replies span several notifications. `VendorLink.send` chains every call; do not
   write to the characteristic from anywhere else.
3. **Bindings are firmware actions, not event taps.** A button is remapped by writing a
   7-byte function block to the mouse, so the app needs only Bluetooth permission: no
   Accessibility, no Input Monitoring. A feature that needs to see clicks would change that.
   Apple Shortcuts are the one indirect case: the button is bound to a reserved key
   (all four modifiers with F13 to F20, `ButtonSlot.triggerKey`), and the app runs the
   shortcut when its Carbon hotkey fires. Carbon hotkeys need no permission, but those
   buttons only work while the app is running.
4. **The app is the source of truth for bindings.** This firmware cannot read bindings
   back and may drop them on power cycle, so `Mouse.loadButtons` rewrites the saved ones
   on every connect.
5. **Slot `0x01` (left click) is never written.** Remapping it can leave the mouse unusable.
6. **DPI writes are always the 38-byte, five-entry form** and echo the stage IDs and
   marker from the last read. The active byte is a stage ID, not an index.
7. **No App Sandbox, no hardened runtime.** Turning either on requires the
   `com.apple.security.device.bluetooth` entitlement first.
8. **Menu bar only.** `LSUIElement` is on and there is no window: left-click the status
   item for the popover, right-click to quit. Anything modal (the reset confirmation) is
   drawn inline, because a sheet on a transient popover closes it.
9. **`MouseLineArt.json` is derived from a CC BY-NC-SA 4.0 model** ("Mouse - Razer
   DeathAdder" by gimora, Sketchfab), so the app is for personal use and cannot be
   shipped commercially with that file. The model itself is no longer in the repo.
10. **Button letters follow Razer's guide** (A DPI up, B DPI down, C left, D right,
    E wheel, G mouse button 5, H mouse button 4; the guide's F is the status light and
    is not shown). `ButtonSlot.letter`
    is the one place that maps firmware slots to those letters.
11. **Scope is buttons and DPI.** Sleep timeout, diagnostics UI, login item, the 3D
    view, and a hold-fn second layer (swapping bindings over Bluetooth was too slow to
    feel right) were removed on purpose; do not add features back without being asked.

12. **DPI is polled, not pushed.** The mouse sends no notification when its own DPI
    buttons change the stage, but `0B 84 01 00` returns the new active stage ID. So
    `Mouse.followDPI` re-reads back to back (20 to 200 ms each), only while the popover
    is open, and those polls are kept out of the log.

## Commands

```bash
xcodebuild -scheme razer-mice-driver -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
```

```bash
open build/Build/Products/Debug/Adder.app
```

```bash
tail -f ~/Library/Logs/Adder/adder.log
```

## Protocol reference

Wire format comes from the OpenSnek project's notes (Apache-2.0):
https://github.com/gh123man/OpenSnek/blob/main/docs/protocol/BLE_PROTOCOL.md.
The DeathAdder V2 X HyperSpeed (Bluetooth `068E:009D`) is not on its validated list;
check the session log before trusting a key that page documents for another model.

Seen on the real mouse (2026-11-10): 20-byte notify headers, frames padded with stale
bytes past `payload_length`; battery `05 81 00 01` on a 0-255 scale (matches the standard
Battery Service); DPI read returns 36 bytes, five stages
400/800/1600/3200/6400. Button read `08 84 01 <slot>` is rejected (status `0x03`) for
every slot. Writes are acknowledged (status `0x02`): a button bind on slot `0x04` and a
DPI table rewrite. The firmware also acknowledges a nonsense action class, so an ACK
proves the slot was written, not that the action is valid. Still unconfirmed by a
physical press: that the edge DPI buttons are slots `0x0B` / `0x0C` with factory blocks
`06 01 01` / `06 01 02` (taken from Razer's other mice with two index-finger buttons).
