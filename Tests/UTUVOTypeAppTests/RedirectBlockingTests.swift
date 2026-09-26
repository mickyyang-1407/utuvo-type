import Foundation
import XCTest
@testable import UTUVOTypeApp

final class RedirectBlockingTests: XCTestCase {
    func testProductionDelegateRejectsSameHostCrossHostPortAndSchemeRedirects() {
        let transport = StrictCleanupSession()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "https://fixture.invalid/completions")!
        let task = session.dataTask(with: origin) // Never resume: no network IO.
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for target in ["https://fixture.invalid/other", "https://other.invalid/", "https://fixture.invalid:8443/", "http://fixture.invalid/"] {
            var called = false
            var request = URLRequest(url: URL(string: target)!)
            request.setValue("Bearer synthetic-key", forHTTPHeaderField: "Authorization")
            transport.redirectDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { allowed in
                called = true
                XCTAssertNil(allowed, "Delegate must deny redirect before sending any credential")
            }
            XCTAssertTrue(called)
        }
    }
}
