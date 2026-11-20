
import AppKit
import ApplicationServices
import Foundation

// DockOutline 0.3 — bottom-edge status indicators for Dock apps.
// Build: swiftc -parse-as-library DockOutline.swift -o DockOutline -framework AppKit -framework ApplicationServices
// Run, then grant Accessibility access when prompted in System Settings.

private enum IndicatorState: Equatable {
    case foregroundRunning
    case backgroundRunning
}

private struct DockIcon {
    let key: String
    let rect: CGRect
    let state: IndicatorState
}

private final class OutlineView: NSView {
    var outlineColor: NSColor = .systemRed
    var lineWidth: CGFloat = 4

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let y = lineWidth / 2 + 1
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 1, y: y))
        path.line(to: NSPoint(x: bounds.width - 1, y: y))

        outlineColor.setStroke()
        path.stroke()
    }
}

private final class OutlineWindow: NSWindow {
    let outlineView: OutlineView

    init(rect: NSRect, state: IndicatorState) {
        outlineView = OutlineView(frame: NSRect(origin: .zero, size: rect.size))
        super.init(contentRect: rect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = outlineView
        update(state: state, rect: rect)
    }

    func update(state: IndicatorState, rect: NSRect) {
        setFrame(rect, display: false)
        outlineView.frame = NSRect(origin: .zero, size: rect.size)
        outlineView.outlineColor = (state == .foregroundRunning) ? .systemRed : .systemYellow
        outlineView.needsDisplay = true
        orderFrontRegardless()
    }
}

@MainActor
private final class DockOutlineController: NSObject {
    private var windows: [String: OutlineWindow] = [:]
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var lastPermissionWarning = false

    func start() {
        setupMenu()
        requestAccessibilityIfNeeded()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▣"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh indicators", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DockOutline", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func refreshNow() { refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        guard AXIsProcessTrusted() else {
            if !lastPermissionWarning {
                NSLog("DockOutline: enable Accessibility for DockOutline in System Settings → Privacy & Security → Accessibility")
                lastPermissionWarning = true
            }
            hideAll()
            return
        }
        lastPermissionWarning = false

        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            hideAll()
            return
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &value) == .success,
              let roots = value as? [AXUIElement] else {
            hideAll()
            return
        }

        let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let appByPath = Dictionary(grouping: runningApps.compactMap { app -> (String, NSRunningApplication)? in
            guard let url = app.bundleURL else { return nil }
            return (url.standardizedFileURL.path, app)
        }, by: { $0.0 })

        var found: [String: (CGRect, IndicatorState)] = [:]
        for root in roots {
            walk(root, depth: 0, appByPath: appByPath, into: &found)
        }

        // AX coordinates use a top-left origin. Convert to AppKit's screen coordinates.
        let primaryTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY ?? 0

        var liveKeys = Set<String>()
        for (key, item) in found {
            let r = item.0
            guard r.width > 12, r.height > 12 else { continue }

            let cocoaRect = NSRect(x: r.minX,
                                   y: primaryTop - r.maxY,
                                   width: r.width,
                                   height: r.height).insetBy(dx: -2, dy: -2)

            liveKeys.insert(key)
            if let window = windows[key] {
                window.update(state: item.1, rect: cocoaRect)
            } else {
                windows[key] = OutlineWindow(rect: cocoaRect, state: item.1)
            }
        }

        let staleKeys = windows.keys.filter { !liveKeys.contains($0) }
        for key in staleKeys {
            windows[key]?.orderOut(nil)
            windows.removeValue(forKey: key)
        }
    }

    private func walk(_ element: AXUIElement,
                      depth: Int,
                      appByPath: [String: [(String, NSRunningApplication)]],
                      into found: inout [String: (CGRect, IndicatorState)]) {
        guard depth < 12 else { return }

        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        let title = stringAttribute(element, kAXTitleAttribute) ?? ""

        // Dock app tiles generally expose their bundle URL as AXURL.
        if role == "AXListItem" ||
           (role?.localizedCaseInsensitiveContains("DockItem") == true) ||
           subrole.localizedCaseInsensitiveContains("DockItem") {
            if let url = urlAttribute(element), url.isFileURL {
                let path = url.standardizedFileURL.path
                if let matches = appByPath[path], let app = matches.first?.1,
                   let rect = rectOf(element) {
                    let state = stateFor(app: app, dockElement: element)
                    found[path] = (rect, state)
                }
            }
        }

        // A few macOS releases expose the application URL on the tile's parent/child
        // differently. Keep walking and use the first matching URL we encounter.
        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                walk(child, depth: depth + 1, appByPath: appByPath, into: &found)
            }
        }

        _ = title // retained for easy local debugging of Dock's AX tree
    }

    private func stateFor(app: NSRunningApplication, dockElement: AXUIElement) -> IndicatorState {
        // Best available first-pass signals. macOS versions may expose an explicit
        // background flag on the Dock item; activation policy is the fallback.
        for name in ["AXIsBackground", "AXBackgroundRunning", "AXIsRunningInBackground"] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(dockElement, name as CFString, &value) == .success,
               let number = value as? NSNumber, number.boolValue {
                return .backgroundRunning
            }
        }

        return app.activationPolicy == .regular ? .foregroundRunning : .backgroundRunning
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func urlAttribute(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(string: text) }
        return nil
    }

    private func rectOf(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }

        return CGRect(origin: point, size: size)
    }

    private func hideAll() {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

@main
private struct DockOutlineApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = DockOutlineController()
        let delegate = AppDelegate(controller: controller)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: DockOutlineController

    init(controller: DockOutlineController) {
        self.controller = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}
