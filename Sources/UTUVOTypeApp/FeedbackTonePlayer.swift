import AVFoundation

@MainActor
final class FeedbackTonePlayer {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var stopTask: Task<Void, Never>?

    func play(outputDeviceUID: String?, frequency: Double, volume: Double = 0.16) {
        stop()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleRate * 0.09)
        ), let samples = buffer.floatChannelData?.pointee else {
            return
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if let outputDeviceUID, !outputDeviceUID.isEmpty {
            _ = AudioDeviceCatalog.setCurrentOutputDevice(
                uid: outputDeviceUID,
                on: engine.outputNode.audioUnit
            )
        }

        let frameCount = AVAudioFrameCount(sampleRate * 0.09)
        buffer.frameLength = frameCount
        let amplitude = Float(max(0.0, min(volume, 1.0)))
        for index in 0 ..< Int(frameCount) {
            let time = Double(index) / sampleRate
            let envelope = min(1.0, Double(index) / (sampleRate * 0.008))
                * min(1.0, Double(frameCount - AVAudioFrameCount(index)) / (sampleRate * 0.018))
            samples[index] = amplitude * Float(sin(2.0 * .pi * frequency * time) * envelope)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            return
        }

        player.scheduleBuffer(buffer)
        player.play()
        self.engine = engine
        self.player = player
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
