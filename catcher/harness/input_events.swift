import CoreGraphics
import Foundation

/// Posts one harness input. Accessibility must be granted to the process that
/// runs this tool, or the event is dropped and B4 measures a click that never
/// landed.
///
///   input_events click-point <x> <y>     CGEvent points, y downward from the
///                                        top of the primary display
///   input_events click-frame <json>      {"x","y"} already in those points
///   input_events hotkey                  control-option-command-R (reserved;
///                                        S0 has no hotkey handler)

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: input_events click-point <x> <y> | click-frame <json> | hotkey\n", stderr)
    exit(2)
}

switch arguments[1] {
case "click-point":
    guard arguments.count == 4, let x = Double(arguments[2]), let y = Double(arguments[3]) else {
        fputs("click-point needs two numbers\n", stderr)
        exit(2)
    }
    click(x: x, y: y)
case "click-frame":
    guard arguments.count == 3 else {
        fputs("click-frame needs a json path\n", stderr)
        exit(2)
    }
    let url = URL(fileURLWithPath: arguments[2])
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        fputs("cannot read \(url.path): \(error)\n", stderr)
        exit(1)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let x = object["x"] as? Double, let y = object["y"] as? Double else {
        fputs("frame file needs numeric x and y\n", stderr)
        exit(1)
    }
    click(x: x, y: y)
case "hotkey":
    hotkey()
default:
    fputs("unknown command \(arguments[1])\n", stderr)
    exit(2)
}

func click(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
        fputs("cannot create a mouse event\n", stderr)
        exit(1)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func hotkey() {
    let key: CGKeyCode = 15
    let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
        fputs("cannot create a key event\n", stderr)
        exit(1)
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}
