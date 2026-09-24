import AppKit
import Diagnostics
import Foundation
import SessionStore

/// `--preflight` starts from `applicationDidFinishLaunching`, not from a view.
/// A SwiftUI `.task` runs only once a window is realized, and a LaunchServices
/// launch is not guaranteed one; without it preflight never ran and never quit.
@MainActor
final class CatcherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PreflightLaunch.startIfRequested()
    }
}

@MainActor
enum PreflightLaunch {
    private static var started = false

    /// Safe to call from every entry point. Only the first call in a
    /// `--preflight` process runs the checks.
    static func startIfRequested() {
        let launch = LaunchConfiguration.resolve()
        guard launch.preflight, !started else { return }
        started = true
        let environment = launch.mergedEnvironment(ProcessInfo.processInfo.environment)
        let sessionRoot = SessionPaths.root(environment: environment)
        StageMirror.note("preflight start root=\(sessionRoot.path)")
        Task {
            await runAndQuit(environment: environment, sessionRoot: sessionRoot)
        }
    }

    private static func runAndQuit(environment: [String: String], sessionRoot: URL) async {
        do {
            try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        } catch {
            StageMirror.note("preflight mkdir \(ErrorDetail.sentence(error))")
        }
        let reportURL = sessionRoot.appendingPathComponent("preflight.txt")
        let prior: String
        if FileManager.default.fileExists(atPath: reportURL.path) {
            do {
                prior = try String(contentsOf: reportURL, encoding: .utf8)
            } catch {
                StageMirror.note("preflight read \(ErrorDetail.sentence(error))")
                prior = ""
            }
        } else {
            prior = ""
        }
        let lines = await Preflight.run(environment: environment, dependencies: PreflightHost.dependencies())
        let result = Preflight.result(checks: lines, priorFails: Preflight.failCount(in: prior))
        let preflightSink = FileStageSink(directory: sessionRoot, fileName: "preflight.txt")
        let launchSink = FileStageSink(directory: sessionRoot, fileName: "launch-stages.log")
        for line in lines + [result] {
            preflightSink.write(line, fsync: true)
            launchSink.write(line, fsync: line.verdict == PreflightVerdict.fail.rawValue || line.name == "RESULT")
        }
        NSApp.terminate(nil)
    }
}
