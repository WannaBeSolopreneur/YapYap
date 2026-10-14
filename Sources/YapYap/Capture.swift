import AppKit
import ScreenCaptureKit

struct TargetWindow {
    let id: CGWindowID
    /// Global coordinates, top-left origin (CoreGraphics).
    let frame: CGRect
}

/// One-shot SCScreenshotManager captures only, never a stream, so idle CPU stays at zero.
enum Capture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Switched on in System Settings since launch, but not in effect until YapYap restarts.
    /// The preflight check keeps its launch-time answer; other apps' window titles show up at once.
    static var needsRestart: Bool {
        guard !hasPermission,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let me = getpid()
        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) != me
                && (info[kCGWindowLayer as String] as? Int) == 0
                && !((info[kCGWindowName as String] as? String) ?? "").isEmpty
        }
    }

    /// Frontmost normal window of an app. The window list is ordered front to back.
    static func frontWindow(of pid: pid_t) -> TargetWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let frame = bounds(from: info),
                  frame.width > 80, frame.height > 40
            else { continue }
            return TargetWindow(id: id, frame: frame)
        }
        return nil
    }

    /// Current frame of a window, or nil once it is closed, minimized or on another Space.
    static func frame(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = list.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true
        else { return nil }
        return bounds(from: info)
    }

    /// The window at full backing resolution. `done` runs on the main queue.
    static func image(of id: CGWindowID, done: @escaping (CGImage?) -> Void) {
        shoot(done) { content in
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return (filter, config(size: window.frame.size, scale: filter.pointPixelScale))
        }
    }

    /// Everything on screen in `rect` (global, top-left origin), minus `excluding` (our own panels).
    static func image(of rect: CGRect, excluding windows: [CGWindowID] = [], done: @escaping (CGImage?) -> Void) {
        shoot(done) { content in
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { return nil }
            let excluded = content.windows.filter { windows.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let local = rect.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let c = config(size: local.size, scale: filter.pointPixelScale)
            c.sourceRect = local
            return (filter, c)
        }
    }

    private static func config(size: CGSize, scale: Float) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(size.width * CGFloat(scale))
        c.height = Int(size.height * CGFloat(scale))
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        return c
    }

    private static func capture(_ make: (SCShareableContent) -> (SCContentFilter, SCStreamConfiguration)?) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let (filter, config) = make(content) else { return nil }
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func shoot(_ done: @escaping (CGImage?) -> Void,
                              _ make: @escaping (SCShareableContent) -> (SCContentFilter, SCStreamConfiguration)?) {
        Task {
            let image = await capture(make)
            await MainActor.run { done(image) }
        }
    }

    private static func bounds(from info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }
}

enum Geometry {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// CoreGraphics (top-left origin) ↔ AppKit (bottom-left of the primary screen).
    /// The flip is its own inverse.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
