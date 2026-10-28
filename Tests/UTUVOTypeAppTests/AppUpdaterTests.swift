import XCTest
@testable import UTUVOTypeApp

private actor SuspendedCleanup {
    private var continuation: CheckedContinuation<String?, Never>?
    func run(started: @Sendable () -> Void) async -> String? {
        await withCheckedContinuation { continuation = $0; started() }
    }
    func finish() { continuation?.resume(returning: "明天先確認資料再開會"); continuation = nil }
}

@MainActor
private final class UpdateDestination: DictationDestination {
    var supportsCorrection: Bool { true }
    func insert(_ text: String) async -> Bool { true }
    func replaceInsertedText(with text: String) -> Bool { true }
    func invalidate() {}
}

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testRestartWaitsForBusyWorkAndRunsOnlyOnce() async {
        var busy = true
        var preparations = 0
        var restarts = 0
        let restarted = expectation(description: "restart")
        let gate = UpdateRestartGate(busy: { busy }, prepare: { preparations += 1; return true })
        gate.postpone { restarts += 1; restarted.fulfill() }
        await Task.yield()
        XCTAssertEqual(preparations, 0)
        XCTAssertTrue(gate.isWaiting)
        busy = false
        gate.resumeIfIdle()
        gate.resumeIfIdle()
        await fulfillment(of: [restarted], timeout: 1)
        gate.resumeIfIdle()
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(gate.isWaiting)
    }

    func testNewRecordingDuringPreparationDefersRestartAgain() async {
        var busy = false
        var continuation: CheckedContinuation<Bool, Never>?
        var preparations = 0
        var restarts = 0
        let preparing = expectation(description: "preparing")
        let restarted = expectation(description: "restart")
        let gate = UpdateRestartGate(busy: { busy }, prepare: {
            preparations += 1
            if preparations == 1 {
                return await withCheckedContinuation { continuation = $0; preparing.fulfill() }
            }
            return true
        })
        gate.postpone { restarts += 1; restarted.fulfill() }
        await fulfillment(of: [preparing], timeout: 1)
        busy = true
        continuation?.resume(returning: true)
        // Let the suspended preparation return on the same actor.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(restarts, 0)
        XCTAssertTrue(gate.isWaiting)
        busy = false
        gate.resumeIfIdle()
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(restarts, 1)
    }

    func testRealModelBarrierWaitsForBackgroundCleanupAndRejectsANewTurn() async throws {
        let context = try IsolatedContext.make()
        defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = true
        let model = AppModel(preferences: preferences)
        let destination = UpdateDestination()
        model.captureDestination = { _ in destination }
        let cleanupStarted = expectation(description: "synthetic cleanup started")
        let cleanup = SuspendedCleanup()
        model.cleanupRunner = { _, _ in
            await cleanup.run { cleanupStarted.fulfill() }
        }
        model.prepareDictation(mode: .smart)
        await model.completeSyntheticDictation("明天先確認資料再開會")
        await fulfillment(of: [cleanupStarted], timeout: 1)
        var barrierReturned = false
        let barrierEntered = expectation(description: "barrier entered")
        let ready = Task { @MainActor in
            barrierEntered.fulfill()
            let result = await model.readyForUpdateRestart()
            barrierReturned = true
            return result
        }
        await fulfillment(of: [barrierEntered], timeout: 1)
        XCTAssertFalse(barrierReturned, "An idle UI must still wait for background cleanup")
        model.prepareDictation(mode: .smart) // A newer turn invalidates the earlier idle decision.
        await cleanup.finish()
        let mayRestart = await ready.value
        XCTAssertFalse(mayRestart)
        let nowIdle = await model.readyForUpdateRestart()
        XCTAssertTrue(nowIdle)
        model.setProcessingForTesting(true)
        let processing = await model.readyForUpdateRestart()
        XCTAssertFalse(processing)
        model.setProcessingForTesting(false)
    }
}
