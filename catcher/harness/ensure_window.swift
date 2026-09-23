import AppKit
import CoreGraphics
import Foundation

// Raise Catcher's content window before the harness plays fixture audio.
// usage: ensure_window <pid>
// stdout: raise=OK | raise=NO_PROCESS | raise=NOT_FRONTMOST | raise=NOT_VISIBLE

let arguments = CommandLine.arguments
guard arguments.count == 2, let pid = Int32(arguments[1]) else {
    fputs("usage: ensure_window <pid>\n", stderr)
    exit(2)
}

func finish(_ token: String) -> Never {
    print("raise=\(token) pid=\(pid)")
    fflush(stdout)
    exit(token == "OK" ? 0 : 1)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
    finish("NO_PROCESS")
}

func onScreenContentWindow() -> Bool {
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

func raised() -> Bool {
    if app.isTerminated {
        return false
    }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    return front && onScreenContentWindow()
}

func reopen() {
    if app.isHidden {
        app.unhide()
    }
    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
}

reopen()
let deadline = Date().addingTimeInterval(2.0)
var reopened = false
while Date() < deadline {
    if app.isTerminated {
        finish("NO_PROCESS")
    }
    if raised() {
        finish("OK")
    }
    if !reopened && Date().addingTimeInterval(1.0) > deadline {
        reopen()
        reopened = true
    }
    Thread.sleep(forTimeInterval: 0.1)
}

if app.isTerminated {
    finish("NO_PROCESS")
}
if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
    finish("NOT_FRONTMOST")
}
finish("NOT_VISIBLE")
