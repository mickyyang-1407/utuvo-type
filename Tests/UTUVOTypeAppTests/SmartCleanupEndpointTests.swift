import XCTest
@testable import UTUVOTypeApp

/// Custom endpoint 驗證：https 強制、loopback 可走 http、URL 不可帶 credentials。
final class SmartCleanupEndpointTests: XCTestCase {

    func testEmptyThrows() {
        XCTAssertThrowsError(try SmartCleanup.validateCustomEndpoint("")) { error in
            XCTAssertEqual(error as? SmartCleanup.EndpointError, .empty)
        }
    }

    func testInvalidURLThrows() {
        XCTAssertThrowsError(try SmartCleanup.validateCustomEndpoint("not a url with spaces")) { error in
            XCTAssertEqual(error as? SmartCleanup.EndpointError, .invalidURL)
        }
    }

    func testHttpsAllowed() throws {
        XCTAssertNoThrow(try SmartCleanup.validateCustomEndpoint("https://api.example.com/v1/chat"))
    }

    func testLoopbackHttpAllowed() throws {
        XCTAssertNoThrow(try SmartCleanup.validateCustomEndpoint("http://127.0.0.1:11434/api/chat"))
        XCTAssertNoThrow(try SmartCleanup.validateCustomEndpoint("http://localhost:8080/v1"))
    }

    func testNonLoopbackHttpRejected() {
        XCTAssertThrowsError(try SmartCleanup.validateCustomEndpoint("http://api.example.com/v1/chat")) { error in
            XCTAssertEqual(error as? SmartCleanup.EndpointError,
                           .unsupportedScheme(allowed: ["https"]))
        }
    }

    func testCredentialsInURLRejected() {
        var endpoint = URLComponents(string: "https://fixture.invalid/v1")!
        endpoint.user = "synthetic-user"
        endpoint.password = "synthetic-password"
        XCTAssertThrowsError(try SmartCleanup.validateCustomEndpoint(endpoint.string!)) { error in
            XCTAssertEqual(error as? SmartCleanup.EndpointError, .credentialsInURL)
        }
    }

    func testFileSchemeRejected() {
        XCTAssertThrowsError(try SmartCleanup.validateCustomEndpoint("file:///tmp/fixture"))
    }
}
