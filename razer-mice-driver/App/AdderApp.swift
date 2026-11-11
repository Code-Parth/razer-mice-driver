import AppKit
import SwiftUI

@main
struct AdderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Menu bar only: the whole UI is the popover AppDelegate hangs off the status item.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let mouse = Mouse()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "Adder")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView().environment(mouse))

        mouse.start()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Assigning a menu makes every click open it, so it is attached only
            // for the duration of this right-click.
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Adder", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) has no window to bring
    /// forward, so it shows the popover instead of appearing to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPopover()
        return false
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // An accessory app is not active by default, and a transient popover
        // only dismisses on an outside click once its app is active.
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillShow(_ notification: Notification) {
        mouse.followDPI(true)
        Task { await mouse.loadShortcuts() }
    }

    func popoverDidClose(_ notification: Notification) {
        mouse.followDPI(false)
    }
}
