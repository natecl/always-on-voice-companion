import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if os(macOS)
import UserNotifications
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loud surfacing is four channels, every time: banner, notification, annotation, log line.
public struct LoudChannels: Sendable, Equatable {
    public var banner: String
    public var notificationBody: String
    public var annotation: Annotation
    public var logLine: String

    public init(banner: String, notificationBody: String, annotation: Annotation, logLine: String) {
        self.banner = banner
        self.notificationBody = notificationBody
        self.annotation = annotation
        self.logLine = logLine
    }
}

public enum Loud {
    public static func channels(annotation: Annotation, status: VerifierStatus) -> LoudChannels {
        let detail = annotation.detail.map(describe) ?? status.human
        let banner = "\(status.pill): \(detail)"
        return LoudChannels(
            banner: banner,
            notificationBody: banner,
            annotation: annotation,
            logLine: "catcher verifier \(status.pill) \(annotation.kind) \(detail)"
        )
    }

    public static func deliver(
        _ channels: LoudChannels,
        log: @escaping @Sendable (String) -> Void = defaultLog,
        notify: @escaping @Sendable (String) -> Void = defaultNotify
    ) {
        log(channels.logLine)
        notify(channels.notificationBody)
    }

    public static func prepare() {
        #if os(macOS)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    public static func defaultLog(_ line: String) {
        #if canImport(OSLog)
        Logger(subsystem: "com.catcher.app", category: "verifier").error("\(line, privacy: .public)")
        #else
        writeStandardError("catcher log: \(line)")
        #endif
    }

    public static func defaultNotify(_ body: String) {
        #if os(macOS)
        let content = UNMutableNotificationContent()
        content.title = "Catcher"
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        #else
        writeStandardError("catcher notify: \(body)")
        #endif
    }

    private static func writeStandardError(_ line: String) {
        var text = line
        text.append("\n")
        text.withCString { pointer in
            _ = write(STDERR_FILENO, pointer, strlen(pointer))
        }
    }

    private static func describe(_ detail: VerifierDetail) -> String {
        switch detail {
        case .text(let text):
            return text
        case .gap(let fromMs, let toMs, let track):
            return "gap \(fromMs)-\(toMs) ms on \(track)"
        }
    }
}
