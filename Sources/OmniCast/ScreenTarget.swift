import AppKit
import AVFoundation
import CoreGraphics
import OmniEngine

/// What the screen slot shows: a display, one window, an app's windows, or a
/// capture device such as a capture card.
struct ScreenTarget: Codable, Hashable, Identifiable {
    enum Kind: Int, Codable {
        case display, window, app, device

        var c: omni_screen_kind {
            switch self {
            case .display: OMNI_SCREEN_DISPLAY
            case .window: OMNI_SCREEN_WINDOW
            case .app: OMNI_SCREEN_APP
            case .device: OMNI_SCREEN_DEVICE
            }
        }

        var icon: String {
            switch self {
            case .display: "display"
            case .window: "macwindow"
            case .app: "app"
            case .device: "rectangle.connected.to.line.below"
            }
        }
    }

    var kind: Kind
    /// Display UUID, window number, bundle identifier or capture device uniqueID.
    var id: String
    var name: String
    /// Windows only: the owning app's bundle id and the window title. Window
    /// numbers change between launches, so these find the window again.
    var appBundle: String?
    var windowTitle: String?

    static var mainDisplay: ScreenTarget? { displays().first }

    static func displays() -> [ScreenTarget] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return ScreenTarget(kind: .display, id: text, name: screen.localizedName)
        }
    }

    /// Normal app windows on screen, front to back. Titles are only visible to
    /// apps with Screen Recording access; without it windows show the app name.
    static func windows() -> [ScreenTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  // Normal apps only: skips system helpers such as permission alerts.
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 120, (bounds["Height"] ?? 0) >= 80 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "Window"
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ScreenTarget(kind: .window, id: String(number),
                                name: title.map { "\(owner) — \($0)" } ?? owner,
                                appBundle: app.bundleIdentifier,
                                windowTitle: title)
        }
    }

    static func apps() -> [ScreenTarget] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in
                guard let bundle = app.bundleIdentifier else { return nil }
                return ScreenTarget(kind: .app, id: bundle, name: app.localizedName ?? bundle)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Capture cards and other video devices. Virtual cameras are left out: they
    /// would loop OmniCast's own virtual camera back in.
    static func devices() -> [ScreenTarget] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
            .filter { !$0.localizedName.lowercased().contains("virtual") }
            .map { ScreenTarget(kind: .device, id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The same target in this session: windows are matched by app and title,
    /// then by app; other kinds must still exist. Nil when it's gone.
    func resolved() -> ScreenTarget? {
        switch kind {
        case .display: return Self.displays().first { $0.id == id }
        case .app: return NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty ? nil : self
        case .device: return Self.devices().first { $0.id == id }
        case .window:
            let windows = Self.windows()
            return windows.first { $0.id == id && $0.appBundle == appBundle }
                ?? windows.first { $0.appBundle == appBundle && $0.windowTitle == windowTitle && windowTitle != nil }
                ?? windows.first { $0.appBundle == appBundle }
        }
    }
}
