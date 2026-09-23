import AppKit
import Foundation

// Prints the general pasteboard's type names as JSON.
// usage: pasteboard_probe
// stdout: {"types":["public.utf8-plain-text","public.html"],"html":"..."}

let board = NSPasteboard.general
let types = (board.types ?? []).map(\.rawValue)
let html = board.string(forType: NSPasteboard.PasteboardType("public.html")) ?? ""
let payload: [String: Any] = ["types": types, "html": html]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
