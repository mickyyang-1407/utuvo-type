import XCTest
@testable import UTUVOTypeApp

final class CleanupResourceLatencyTests: XCTestCase {
    func testRepeatedRequestsReuseSessionAndKeepCredentialsPerRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CleanupFixtureProtocol.self]
        let transport = StrictCleanupSession(configuration: configuration)
        let identity = ObjectIdentifier(transport.session)
        for credential in ["fixture-a", "fixture-b"] {
            var request = URLRequest(url: URL(string: "https://synthetic.invalid/cleanup")!)
            request.setValue(credential, forHTTPHeaderField: "Authorization")
            let (data, _) = try await transport.send(request)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), credential)
            XCTAssertEqual(ObjectIdentifier(transport.session), identity)
        }
        XCTAssertNil(transport.session.configuration.httpCookieStorage)
        XCTAssertNil(transport.session.configuration.urlCache)
        XCTAssertNil(transport.session.configuration.urlCredentialStorage)
        XCTAssertNil(transport.session.configuration.httpAdditionalHeaders?["Authorization"])
    }

    func testTransportDoesNotRetainItselfThroughDelegate() {
        weak var weakTransport: StrictCleanupSession?
        autoreleasepool {
            let transport = StrictCleanupSession(configuration: .ephemeral)
            weakTransport = transport
        }
        XCTAssertNil(weakTransport)
    }

    func testLocalFormatterDrainsLargePipesAndPreservesOutput() async throws {
        let fixture = try ProcessFixture(body: """
        import sys
        incoming = sys.stdin.read()
        sys.stderr.write('diagnostic' * 200000)
        sys.stderr.flush()
        sys.stdout.write(incoming + ' ' * 200000)
        """)
        defer { fixture.remove() }
        let result = try await fixture.client.format(prompt: "synthetic unchanged", model: "fixture")
        XCTAssertEqual(result, "synthetic unchanged")
    }

    func testLocalFormatterCancellationReturnsPromptlyAndReapsIgnoringTerm() async throws {
        let fixture = try ProcessFixture(body: """
        import os, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(os.environ['FIXTURE_PID'], 'w') as f: f.write(str(os.getpid()))
        while True: time.sleep(0.1)
        """)
        defer { fixture.remove() }
        let task = Task { try await fixture.client.format(prompt: "synthetic", model: "fixture") }
        let ready = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: fixture.pid.path), ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        let pid = Int32(try String(contentsOf: fixture.pid, encoding: .utf8))!
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled formatter returned output") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
        let reaped = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(pid, 0) == 0, ContinuousClock.now < reaped { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(kill(pid, 0), -1, "Synthetic child must be terminated and reaped")
    }
}

private final class CleanupFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((request.value(forHTTPHeaderField: "Authorization") ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private struct ProcessFixture: Sendable {
    let directory: URL
    let pid: URL
    let client: LocalFormatterProcessClient
    init(body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("utuvo-cleanup-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pid = directory.appendingPathComponent("pid")
        let executable = directory.appendingPathComponent("synthetic.py")
        try ("#!/usr/bin/python3\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = LocalFormatterProcessClient(command: executable.path, environment: ["PATH": "/usr/bin:/bin", "FIXTURE_PID": pid.path])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
