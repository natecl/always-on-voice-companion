import AppKit
import CoreGraphics
import Foundation

// Raise and observe Catcher's content window from outside the app.
// usage: window_probe <pid> <session-dir> [--raise]
// stdout is one token: RAISE OK | NO_PROCESS | NOT_VISIBLE | NOT_FRONTMOST | MULTI_INSTANCE
//
// The helper is not Catcher.app. It does not read kCGWindowName (that needs
// Screen Recording). Owner pid, layer, alpha, and bounds do not. The stamp
// it writes is the harness's observation, source=harness-cgwindowlist.

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = Int32(arguments[1]) else {
    fputs("usage: window_probe <pid> <session-dir> [--raise]\n", stderr)
    exit(2)
}
let session = arguments[2]
let shouldRaise = arguments.contains("--raise")

let minWidth = CGFloat(Int(ProcessInfo.processInfo.environment["CATCHER_WINDOW_MIN_W"] ?? "720") ?? 720)
let minHeight = CGFloat(Int(ProcessInfo.processInfo.environment["CATCHER_WINDOW_MIN_H"] ?? "520") ?? 520)

// An accessory policy keeps this helper from taking the front itself.
NSApplication.shared.setActivationPolicy(.accessory)

struct SeenWindow {
    var bounds: CGRect
    var layer: Int
    var alpha: Double
}

func running() -> NSRunningApplication? {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
    return app
}

func catcherInstances() -> Int {
    NSWorkspace.shared.runningApplications.filter { app in
        let path = app.executableURL?.path ?? ""
        return path.hasSuffix("/Contents/MacOS/CatcherApp") && !app.isTerminated
    }.count
}

func isFront() -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
}

func windows() -> [SeenWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    var found: [SeenWindow] = []
    for item in info {
        let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
        if owner != pid { continue }
        let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        var bounds = CGRect.zero
        if let dict = item[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: dict) ?? .zero
        }
        found.append(SeenWindow(bounds: bounds, layer: layer, alpha: alpha))
    }
    return found
}

func contentVisible(_ wins: [SeenWindow]) -> Bool {
    wins.contains { win in
        win.layer == 0 && win.alpha > 0 && win.bounds.width >= minWidth && win.bounds.height >= minHeight
    }
}

func writeStamp(method: String, wins: [SeenWindow]) {
    let bounds = wins.filter { $0.layer == 0 }.map { win -> [String: Double] in
        [
            "x": Double(win.bounds.origin.x),
            "y": Double(win.bounds.origin.y),
            "w": Double(win.bounds.width),
            "h": Double(win.bounds.height),
        ]
    }
    let record: [String: Any] = [
        "pid": pid,
        "frontmost": isFront(),
        "windowCount": wins.count,
        "bounds": bounds,
        "raiseMethod": method,
        "wallMs": Int(Date().timeIntervalSince1970 * 1000),
        "source": "harness-cgwindowlist",
    ]
    let url = URL(fileURLWithPath: session, isDirectory: true).appendingPathComponent("window_front")
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]) else { return }
    try? data.write(to: url)
}

func finish(_ token: String, method: String, wins: [SeenWindow]) -> Never {
    writeStamp(method: method, wins: wins)
    print(token)
    fflush(stdout)
    exit(token == "RAISE OK" ? 0 : 1)
}

func snapshot() -> (Bool, [SeenWindow]) {
    let wins = windows()
    return (isFront() && contentVisible(wins), wins)
}

var method = "observe"
if running() == nil {
    finish("NO_PROCESS", method, [])
}

if shouldRaise {
    method = "activate"
    running()?.activate(options: [.activateAllWindows])
    let activateUntil = Date().addingTimeInterval(1)
    while Date() < activateUntil {
        if running() == nil { finish("NO_PROCESS", method, windows()) }
        let (ok, wins) = snapshot()
        if ok { finish("RAISE OK", method, wins) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if !isFront() {
        if catcherInstances() > 1 {
            finish("MULTI_INSTANCE", method, windows())
        }
        if let appPath = ProcessInfo.processInfo.environment["CATCHER_APP"], !appPath.isEmpty {
            method = "launchservices"
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            configuration.activates = true
            // The callback is delivered on the main run loop. Waiting on a
            // semaphore here would block that loop, so this pumps it instead.
            final class Flag: @unchecked Sendable {
                var opened = false
            }
            let flag = Flag()
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: appPath),
                configuration: configuration
            ) { _, _ in
                flag.opened = true
            }
            let pumpUntil = Date().addingTimeInterval(2)
            while !flag.opened && Date() < pumpUntil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
    }
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if running() == nil { finish("NO_PROCESS", method, windows()) }
        let (ok, wins) = snapshot()
        if ok { finish("RAISE OK", method, wins) }
        if !isFront() {
            running()?.activate(options: [.activateAllWindows])
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

if running() == nil {
    finish("NO_PROCESS", method, [])
}
let wins = windows()
if !contentVisible(wins) {
    finish("NOT_VISIBLE", method, wins)
}
if !isFront() {
    finish("NOT_FRONTMOST", method, wins)
}
finish("RAISE OK", method, wins)
