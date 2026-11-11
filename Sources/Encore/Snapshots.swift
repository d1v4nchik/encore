import AppKit
import CoreGraphics
import SwiftUI

/// `Encore --snapshots [dir]` photographs Encore's own windows (popover, settings window and
/// connection pop-up, in dark and light mode) for the README. Capturing an app's own windows
/// needs no Screen Recording permission.
@MainActor
enum Snapshots {
    static var outputDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshots") else { return nil }
        let path = i + 1 < args.count && !args[i + 1].hasPrefix("-")
            ? args[i + 1]
            : NSHomeDirectory() + "/Library/Logs/Encore/Screenshots"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static var didRun = false

    /// Runs once, then quits Encore so screenshot mode can never linger (it switches the app
    /// between dark and light appearance while it works).
    static func run(model: AppModel) {
        guard let dir = outputDirectory, !didRun else { return }
        didRun = true
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                NSApp.appearance = NSAppearance(named: name)
                try? await Task.sleep(for: .seconds(1))

                // Menu bar popover content, shown in a stand-in glass panel (the real status
                // item may be hidden by the user, and can't be opened reliably from code).
                let stand = makePopoverStandIn(model: model)
                stand.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(2.5))
                save(stand, to: dir, name: "popover-\(suffix)")
                stand.orderOut(nil)

                // Settings window
                model.openSettings()
                try? await Task.sleep(for: .seconds(3))
                if let w = settingsWindow { save(w, to: dir, name: "settings-\(suffix)") }
                settingsWindow?.orderOut(nil)

                // Connection pop-up
                model.showPopupPreview()
                try? await Task.sleep(for: .seconds(1.6))
                if let w = hudWindow { save(w, to: dir, name: "popup-\(suffix)") }
                try? await Task.sleep(for: .seconds(1))
            }
            NSApp.appearance = nil
            EncoreLog.shared("Snapshots written to \(dir.path)")
            try? await Task.sleep(for: .seconds(0.5))
            NSApp.terminate(nil)
        }
    }

    private static func makePopoverStandIn(model: AppModel) -> NSPanel {
        let content = MenuBarPanel()
            .environment(model)
            .clipShape(.rect(cornerRadius: 22, style: .continuous))   // keep the glow inside, like the real popover
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
            .padding(24)                          // room for the shadow
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 40, y: screen.maxY - 10))
        }
        return panel
    }

    // MARK: Finding windows

    private static func isStatusBarWindow(_ w: NSWindow) -> Bool {
        String(describing: type(of: w)).contains("StatusBar")
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("settings") == true }
    }

    private static var hudWindow: NSWindow? {
        NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.level == .statusBar && !isStatusBarWindow($0) }
    }

    // MARK: Capturing

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage is hidden from the macOS 15+ SDK but still works for an app's own windows.
    private static let createImage: CreateImage? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImage.self)
    }()

    private static func save(_ window: NSWindow, to dir: URL, name: String) {
        let includingWindow: UInt32 = 1 << 3     // kCGWindowListOptionIncludingWindow
        let bestResolution: UInt32 = 1 << 3      // kCGWindowImageBestResolution
        guard let createImage,
              let image = createImage(.null, includingWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue()
        else {
            EncoreLog.shared("Snapshot \(name): capture failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let url = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        EncoreLog.shared("Snapshot \(name): \(image.width)×\(image.height)")
    }
}
