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
    /// Streamed speech arrives in chunks while earlier ones play. A chunk that arrives after the
    /// player has run dry leaves a hole in the middle of a word, so playback starts, and starts again
    /// after running dry, only once `StreamPacing` says enough audio is waiting.
    /// What has been learned about the engine's pace is kept from one job to the next, so the first
    /// chunk of a reply is judged by how the engine has been running.
    private var pacing = StreamPacing()
    private var streaming = false
    private var held: [AVAudioPCMBuffer] = []
    /// Times the player ran dry in the middle of streamed speech since launch.
    private(set) var underruns = 0
    var isPlaying: Bool { pending > 0 || !held.isEmpty }
    var onError: ((String) -> Void)?
    init() {
        engine.attach(player); engine.attach(tempo)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.connect(player, to: tempo, format: format)
        engine.connect(tempo, to: engine.mainMixerNode, format: format)
        tempo.overlap = 32
    }
    /// Starts the output engine ahead of the first chunk so its start-up latency is hidden, and
    /// begins a streamed job: `enqueue` paces its chunks until `finish`.
    func prepare(pace: Float) {
        setPace(pace)
        if !engine.isRunning { try? engine.start() }
        held.removeAll()
        pacing.restart(); streaming = true
    }
    /// The time-pitch unit colours speech slightly even at rate 1, so it is bypassed there.
    private func setPace(_ pace: Float) {
        tempo.rate = pace
        tempo.bypass = abs(pace - 1) < 0.001
    }
    func enqueue(_ url: URL, pace: Float = 1) {
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw ChatterError.unavailable("Audio buffer allocation failed") }
            try file.read(into: buffer)
            guard file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == sampleRate else {
                // Original recordings can use another format; convert through AVAudioConverter.
                try accept(converted(buffer), pace: pace); return
            }
            try accept(buffer, pace: pace)
        } catch { failure = error.localizedDescription; onError?(error.localizedDescription) }
    }
    private func converted(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
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
        return output
    }
    /// A whole file plays at once; a streamed chunk waits until playing it cannot leave a hole.
    private func accept(_ buffer: AVAudioPCMBuffer, pace: Float) throws {
        guard streaming else { try schedule(buffer, pace: pace); return }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let decision = pacing.arrived(seconds: seconds, at: ContinuousClock.now, playerIsDry: pending == 0)
        if decision.underrun { underruns += 1 }
        held.append(buffer)
        if decision.play { try flush(pace: pace) }
    }
    private func flush(pace: Float) throws {
        let ready = held; held.removeAll()
        for buffer in ready { try schedule(buffer, pace: pace) }
    }
    private func schedule(_ buffer: AVAudioPCMBuffer, pace: Float) throws {
        setPace(pace)
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
    /// The streamed job has sent its last chunk: play whatever is still held, and wait for the end.
    func finish() async throws {
        streaming = false
        do { try flush(pace: tempo.rate) } catch { failure = error.localizedDescription }
        if pending > 0 { await withCheckedContinuation { waiter = $0 } }
        if let failure { throw ChatterError.unavailable("Playback failed: \(failure)") }
    }
    func stop() {
        generation += 1; player.stop(); pending = 0; held.removeAll(); streaming = false
        waiter?.resume(); waiter = nil; failure = nil
    }
}
