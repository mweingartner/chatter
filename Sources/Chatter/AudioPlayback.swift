import AVFoundation
import ChatterCore

@MainActor
final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let tempo = AVAudioUnitTimePitch()
    // Keep Qwen chunks at their native rate. Resampling each chunk independently to 44.1 kHz
    // restarts converter priming at every join; the mixer can resample the continuous stream.
    private let sampleRate = 24_000.0
    private var pending = 0
    private var generation = 0
    private var failure: String?
    private var waiter: CheckedContinuation<Void, Never>?
    var isPlaying: Bool { pending > 0 }
    var onError: ((String) -> Void)?
    init() {
        engine.attach(player); engine.attach(tempo)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.connect(player, to: tempo, format: format)
        engine.connect(tempo, to: engine.mainMixerNode, format: format)
        tempo.overlap = 32
    }
    /// Starts the output engine ahead of the first chunk so its start-up latency is hidden.
    func prepare(pace: Float) {
        tempo.rate = pace
        if !engine.isRunning { try? engine.start() }
    }
    func enqueue(_ url: URL, pace: Float = 1) {
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw ChatterError.unavailable("Audio buffer allocation failed") }
            try file.read(into: buffer)
            guard file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == sampleRate else {
                // Original recordings can use another format; convert through AVAudioConverter.
                try enqueueConverted(buffer, pace: pace); return
            }
            try schedule(buffer, pace: pace)
        } catch { failure = error.localizedDescription; onError?(error.localizedDescription) }
    }
    private func enqueueConverted(_ input: AVAudioPCMBuffer, pace: Float) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength)*sampleRate/input.format.sampleRate)+1024) else { throw ChatterError.unavailable("Unsupported audio format") }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        try schedule(output, pace: pace)
    }
    private func schedule(_ buffer: AVAudioPCMBuffer, pace: Float) throws {
        tempo.rate = pace
        if !engine.isRunning { try engine.start() }
        let ticket = generation; pending += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.pending -= 1
                if self.pending == 0 { self.waiter?.resume(); self.waiter = nil }
            }
        }
        if !player.isPlaying { player.play() }
    }
    func finish() async throws {
        if isPlaying { await withCheckedContinuation { waiter = $0 } }
        if let failure { throw ChatterError.unavailable("Playback failed: \(failure)") }
    }
    func stop() { generation += 1; player.stop(); pending = 0; waiter?.resume(); waiter = nil; failure = nil }
}
