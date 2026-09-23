import Foundation
import SessionStore

public enum BriefStopAdapter {
    /// Builds the Phase 1 `SessionEnded` from the session directory after `end` is on disk.
    public static func sessionEnded(
        directory: URL,
        stopRequestedWallMs: Int,
        assembledWallMs: Int,
        trigger: StopTrigger
    ) throws -> SessionEnded {
        let data = try Data(contentsOf: SessionPaths.summaryFile(in: directory))
        let summary = try JSONDecoder().decode(SessionSummary.self, from: data)
        let id = summary.id.isEmpty ? directory.lastPathComponent : summary.id
        return SessionEnded(
            sessionID: id,
            directory: directory,
            stopRequestedWallMs: stopRequestedWallMs,
            assembledWallMs: assembledWallMs,
            clean: summary.clean,
            recovered: summary.recovered,
            trigger: trigger
        )
    }

    /// Automatic notes after a live stop. Recovered sessions and harness runs stay off.
    public static func shouldAutoRun(
        _ ended: SessionEnded,
        environment: [String: String]
    ) -> Bool {
        guard BriefLaunchPolicy.notesEnabled(environment: environment) else { return false }
        return BriefLaunchPolicy.runMode(recoveredAtLaunch: ended.recovered) == .automatic
    }
}

public enum BriefSignalPolicy {
    /// SIGUSR1 means "stop recording, stay up". Installed only for a brief harness run.
    /// SIGTERM stays the v0 quit path and is not handled here.
    public static func installsStopAndStayUp(environment: [String: String]) -> Bool {
        environment["CATCHER_HARNESS"] == "1" && environment["CATCHER_BRIEF"] == "1"
    }
}
