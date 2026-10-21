import AVFoundation
import XCTest
@testable import UTUVOTypeApp

/// 為了對齊輸入格式而臨時接上去的節點，其生命週期（mac-input-repair1 #1）。
///
/// 用 `AVAudioSourceNode` 當「input」：graph 的接／拆邏輯跟節點種類無關，
/// 這樣測試不需要麥克風權限，也不需要真的啟動 engine。
final class AudioEngineGraphDetachTests: XCTestCase {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
    )!

    private func makeSource() -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in abl { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return noErr
        }
    }

    /// 連續 10 次「接上去 → 拆掉」，節點數必須回到原值。這是 attach 漏拆時最直接會看到的證據。
    func testTenAttachDetachCyclesLeaveNoNodesBehind() {
        let engine = AVAudioEngine()
        let source = makeSource()
        engine.attach(source)
        let baseline = engine.attachedNodes.count

        for _ in 0 ..< 10 {
            let mixer = AVAudioMixerNode()
            engine.attach(mixer)
            engine.connect(source, to: mixer, format: Self.format)
            XCTAssertEqual(engine.attachedNodes.count, baseline + 1)
            XCTAssertTrue(AudioEngineGraph.detach(mixer, from: engine, input: source))
            XCTAssertEqual(engine.attachedNodes.count, baseline, "attach 漏拆了：節點只增不減")
        }
    }

    /// 已經拆掉的節點再拆一次必須是安全的 no-op（stop 路徑與啟動失敗路徑會各走一次）。
    func testDetachingTwiceIsSafe() {
        let engine = AVAudioEngine()
        let source = makeSource()
        engine.attach(source)
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(source, to: mixer, format: Self.format)

        XCTAssertTrue(AudioEngineGraph.detach(mixer, from: engine, input: source))
        XCTAssertFalse(AudioEngineGraph.detach(mixer, from: engine, input: source))
        XCTAssertFalse(AudioEngineGraph.detach(nil, from: engine, input: source))
        XCTAssertEqual(engine.attachedNodes.count, 1)
    }

    /// 「只 disconnect 真的有接的節點」：input 已經沒有出線時（stop 之後）再拆，
    /// 不能去踩一個沒有接線的節點。
    func testDetachWithoutAnyConnectionIsSafe() {
        let engine = AVAudioEngine()
        let source = makeSource()
        engine.attach(source)
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)                                  // attach 了，但沒接任何線

        XCTAssertTrue(engine.outputConnectionPoints(for: source, outputBus: 0).isEmpty)
        XCTAssertTrue(AudioEngineGraph.detach(mixer, from: engine, input: source))
        XCTAssertEqual(engine.attachedNodes.count, 1)
    }

    /// 拆掉之後節點確實離開 graph，source 也能再接到別的節點上（graph 沒卡死）。
    func testGraphStaysUsableAfterDetach() {
        let engine = AVAudioEngine()
        let source = makeSource()
        engine.attach(source)
        for _ in 0 ..< 3 {
            let mixer = AVAudioMixerNode()
            engine.attach(mixer)
            engine.connect(source, to: mixer, format: Self.format)
            AudioEngineGraph.detach(mixer, from: engine, input: source)
        }
        let next = AVAudioMixerNode()
        engine.attach(next)
        engine.connect(source, to: next, format: Self.format)
        XCTAssertEqual(engine.outputConnectionPoints(for: source, outputBus: 0).count, 1)
        XCTAssertEqual(engine.attachedNodes.count, 2)
    }
}
