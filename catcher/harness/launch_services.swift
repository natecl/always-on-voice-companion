import AppKit
import Foundation

// Stock open(1) has no --env. Executing Catcher.app/Contents/MacOS/CatcherApp
// from the shell bills TCC to the terminal (or the agent host), not to
// com.catcher.app. NSWorkspace.openApplication is LaunchServices: Catcher is
// its own responsible process, and this process's environment — including
// CATCHER_SESSION_ROOT, CATCHER_HARNESS, CATCHER_AUTO_RECORD, CATCHER_ENGINE,
// and XAI_API_KEY — is handed through. Arguments repeat those switches.
//
// usage: launch_services <Catcher.app> [args...]

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: launch_services <Catcher.app> [args...]\n", stderr)
    exit(2)
}

let app = URL(fileURLWithPath: arguments[1])
let childArguments = Array(arguments.dropFirst(2))
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = true
configuration.arguments = childArguments
configuration.environment = ProcessInfo.processInfo.environment
configuration.promptsUserIfNeeded = false

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
    if let error {
        fputs("LaunchServices failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    if running == nil {
        fputs("LaunchServices returned no application for \(app.path)\n", stderr)
        exit(1)
    }
    exit(0)
}

dispatchMain()
