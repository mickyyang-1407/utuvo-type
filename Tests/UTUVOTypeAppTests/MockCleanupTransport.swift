import Foundation
@testable import UTUVOTypeApp

final class MockCleanupTransport: CleanupTransport, @unchecked Sendable {
    struct Entry {
        let host: String
        let body: Data
        let status: Int
        init(host: String, body: Data, status: Int = 200) {
            self.host = host
            self.body = body
            self.status = status
        }
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var entries: [Entry] = []
    nonisolated(unsafe) private(set) var lastRequest: URLRequest?
    nonisolated(unsafe) private(set) var callCount: Int = 0

    init() {}

    func register(host: String, status: Int = 200, bodyJSON: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: bodyJSON)) ?? Data()
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(host: host, body: data, status: status))
    }

    func registerFailure(host: String, error: URLError) {
        // 失敗模擬走另一條路徑（throws），由 caller 自行呼叫 trigger URLError。
        // 簡化：直接 status=503。
        register(host: host, status: 503, bodyJSON: ["error": "unavailable"])
    }

    nonisolated private func snapshot(for request: URLRequest) -> [Entry] {
        lock.lock()
        callCount += 1
        lastRequest = request
        let copy = entries
        lock.unlock()
        return copy
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = await Task { @Sendable [weak self] in
            self?.snapshot(for: request) ?? []
        }.value
        guard let url = request.url, let host = url.host else {
            throw URLError(.badURL)
        }
        guard let entry = snapshot.first(where: { $0.host == host }) else {
            throw URLError(.cannotConnectToHost)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: entry.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (entry.body, response)
    }
}
