import AppKit
import CoreGraphics
import Foundation

// Raise Catcher's content window before a gate continues.
// usage: ensure_window <pid> <session-dir>
// stdout: raise=OK | raise=NO_PROCESS | raise=NOT_FRONTMOST | raise=NOT_VISIBLE
//
// This binary is not Catcher.app, so Screen Recording does not let it list
// Catcher's windows. Catcher writes <session>/window_front when its own
// content window is key, on a screen, and the app is active. Frontmost is
// still read here from NSWorkspace.

let arguments = CommandLine.arguments
guard arguments.count == 3, let pid = Int32(arguments[1]) else {
    fputs("usage: ensure_window <pid> <session-dir>\n", stderr)
    exit(2)
}
let session = arguments[2]

func finish(_ token: String, _ detail: String = "") -> Never {
    if detail.isEmpty {
        print("raise=\(token) pid=\(pid)")
    } else {
        print("raise=\(token) pid=\(pid) \(detail)")
    }
    fflush(stdout)
    exit(token == "OK" ? 0 : 1)
}

guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
    finish("NO_PROCESS")
}

func processAlive() -> Bool {
    guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
    return !running.isTerminated
}

func frontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
}

func listedOnScreen() -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    for window in info {
        let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let bounds = window[kCGWindowBounds as String] as? [String: Any]
        let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
        if owner == pid && layer == 0 && height >= 20 {
            return true
        }
    }
    return false
}

func stamp() -> String {
    let url = URL(fileURLWithPath: session, isDirectory: true).appendingPathComponent("window_front")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "missing" }
    let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    if let modified, Date().timeIntervalSince(modified) > 2 {
        return "stale"
    }
    let fresh = text.contains("pid=\(pid)") && text.contains("frontmost=1") && text.contains("visible=1")
    return fresh ? "fresh" : "mismatch"
}

func raised() -> Bool {
    guard processAlive(), frontmost() else { return false }
    if listedOnScreen() { return true }
    return stamp() == "fresh"
}

func reopen() {
    guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { return }
    if running.isHidden {
        running.unhide()
    }
    running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
}

reopen()
let deadline = Date().addingTimeInterval(8)
var nextReopen = Date().addingTimeInterval(1)
while Date() < deadline {
    if !processAlive() {
        finish("NO_PROCESS")
    }
    if raised() {
        finish("OK", "window_front=\(stamp())")
    }
    if Date() >= nextReopen {
        reopen()
        nextReopen = Date().addingTimeInterval(1)
    }
    Thread.sleep(forTimeInterval: 0.1)
}

if !processAlive() {
    finish("NO_PROCESS")
}
let mark = stamp()
if !frontmost() {
    finish("NOT_FRONTMOST", "window_front=\(mark)")
}
finish("NOT_VISIBLE", "window_front=\(mark)")
