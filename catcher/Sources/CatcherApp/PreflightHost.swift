import AudioCapture
import AVFoundation
import CoreGraphics
import Diagnostics
import Foundation
import GrokEngine
import TranscriptionEngine
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// Real preflight checks. Diagnostics stays free of ScreenCaptureKit; this file
/// is the only place those calls are bound, and only `Catcher.app` launched
/// through `open` runs them.
enum PreflightHost {
    static func dependencies() -> PreflightDependencies {
        PreflightDependencies(
            screenGranted: { screenGranted() },
            microphone: { microphone() },
            micDevice: { micDevice() },
            displayID: { await displayID() },
            captureProbe: { await captureProbe() },
            apiReach: { await reach() },
            apiAuth: { key in await auth(key) },
            apiSTT: { key in await stt(key) }
        )
    }

    private static func screenGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static func microphone() -> PreflightMicrophone {
        let authority = PermissionGate.readMicrophoneAuthority()
        return PreflightMicrophone(
            status: authority.authorizationStatus,
            owns: authority.ownsTCCIdentity,
            entitlement: authority.audioInputEntitlement,
            responsible: authority.responsibleName ?? "unknown"
        )
    }

    private static func micDevice() -> PreflightDevice? {
        guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
        return PreflightDevice(uniqueID: device.uniqueID, name: device.localizedName)
    }

    private static func displayID() async -> UInt32? {
        #if canImport(ScreenCaptureKit)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            StageMirror.note("preflight display \(ErrorDetail.sentence(error))")
            return nil
        }
        let ranked = content.displays.map { display -> SystemAudioDisplay in
            let id = display.displayID
            return SystemAudioDisplay(
                id: id,
                active: CGDisplayIsActive(id) != 0,
                asleep: CGDisplayIsAsleep(id) != 0,
                isMain: id == CGMainDisplayID()
            )
        }
        return SystemAudioDisplayChoice.preferred(ranked)
        #else
        return nil
        #endif
    }

    private static func captureProbe() async -> PreflightCaptureResult {
        #if canImport(ScreenCaptureKit)
        let session = SCKCaptureSession()
        do {
            try await session.start()
            try? await Task.sleep(for: .seconds(1))
            let counters = session.counters()
            await session.stop()
            return PreflightCaptureResult(
                started: true,
                system: counters.system,
                microphone: counters.microphone,
                error: nil
            )
        } catch {
            return PreflightCaptureResult(
                started: false,
                system: 0,
                microphone: 0,
                error: ErrorDetail.sentence(error)
            )
        }
        #else
        return PreflightCaptureResult(started: false, system: 0, microphone: 0, error: "ScreenCaptureKit unavailable")
        #endif
    }

    private static func reach() async -> PreflightHTTPResult {
        guard let url = URL(string: "https://api.x.ai/") else {
            return PreflightHTTPResult(ok: false, body: "bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode
            return PreflightHTTPResult(ok: true, http: http)
        } catch {
            let ns = error as NSError
            return PreflightHTTPResult(
                ok: false,
                body: ErrorDetail.sentence(error),
                errorCode: ns.code,
                errorDomain: ns.domain
            )
        }
    }

    private static func auth(_ key: String) async -> PreflightHTTPResult {
        let result = await GrokProbe.fetchAuthStatus(apiKey: key)
        let ok = (200..<300).contains(result.http ?? 0)
        return PreflightHTTPResult(ok: ok, http: result.http, body: result.body)
    }

    private static func stt(_ key: String) async -> PreflightSTTResult {
        let engine = GrokEngine(track: .system, configuration: GrokEngineConfiguration(
            apiKey: key,
            url: GrokWebSocket.url(),
            makeTransport: { URLSessionGrokTransport() },
            handshakeTimeout: .seconds(5)
        ))
        let started = ContinuousClock.now
        do {
            try await engine.connect(track: .system)
            let parts = started.duration(to: .now).components
            let milliseconds = Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
            await engine.finish()
            return PreflightSTTResult(created: true, milliseconds: milliseconds, close: nil, http: nil, error: nil)
        } catch {
            let snap = await engine.snapshot()
            return PreflightSTTResult(
                created: false,
                milliseconds: nil,
                close: snap.lastCloseReason,
                http: snap.httpStatus,
                error: snap.lastError ?? ErrorDetail.sentence(error)
            )
        }
    }
}
