import Foundation
import SessionStore
import Testing

@Test func sidecarAppendsOneObjectPerLineAndFlushesTheBuffer() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidecar-\(UUID().uuidString).jsonl")
    let sidecar = SessionSidecar(url: url)
    #expect(sidecar.failed == false)
    sidecar.write(Data("{\"t\":\"clock\"}".utf8), flush: false)
    sidecar.write(Data("{\"t\":\"start\"}".utf8), flush: true)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == "{\"t\":\"clock\"}\n{\"t\":\"start\"}\n")
}

@Test func sidecarFailureDisablesItselfAndDoesNotThrow() {
    let sidecar = SessionSidecar(url: URL(fileURLWithPath: "/dev/null/catcher-latency.jsonl"))
    #expect(sidecar.failed)
    sidecar.write(Data("{\"t\":\"clock\"}\n".utf8), flush: true)
    sidecar.flush()
}
