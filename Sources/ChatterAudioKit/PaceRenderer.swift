// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import AVFoundation
import Foundation

/// Changes speech pace without changing pitch, offline, using AVAudioUnitTimePitch.
public enum PaceRenderer {
    /// Accepted pace factors (2 = twice as fast).
    public static let acceptedRates: ClosedRange<Float> = 0.5...2
    private static let maximumFrameCount: AVAudioFrameCount = 4096

    /// Renders `input` at `rate` into a 24-bit PCM file at `output` (same sample rate and channels).
    /// When `|rate − 1| < 1e-4` the input is copied byte-for-byte. The output is replaced atomically.
    public static func render(input: URL, output: URL, rate: Float) throws {
        try validate(rate)
        if isUnity(rate) {
            try AtomicFile.copy(input, to: output)
            return
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: input)
        } catch {
            throw ChatterAudioError.undecodable(reason: error.localizedDescription)
        }
        let format = file.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let temporary = AtomicFile.temporaryURL(beside: output)
        let writer: AVAudioFile
        do {
            writer = try AVAudioFile(forWriting: temporary, settings: settings)
        } catch {
            throw ChatterAudioError.writeFailed(reason: error.localizedDescription)
        }
        do {
            try renderOffline(format: format, inputFrames: file.length, rate: rate,
                              schedule: { $0.scheduleFile(file, at: nil) },
                              consume: { try writer.write(from: $0) })
            writer.close()
        } catch {
            writer.close()
            AtomicFile.discard(temporary)
            if let failure = error as? ChatterAudioError { throw failure }
            throw ChatterAudioError.writeFailed(reason: error.localizedDescription)
        }
        try AtomicFile.rename(temporary, to: output)
    }

    /// Renders 44.1 kHz mono samples at `rate`; returns the input unchanged when `|rate − 1| < 1e-4`.
    public static func render(samples: [Float], rate: Float) throws -> [Float] {
        try validate(rate)
        if isUnity(rate) || samples.isEmpty { return samples }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: AudioIO.sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = input.floatChannelData?[0] else {
            throw ChatterAudioError.renderingFailed(reason: "Cannot allocate an audio buffer.")
        }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: samples.count)
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        var result: [Float] = []
        try renderOffline(format: format, inputFrames: AVAudioFramePosition(samples.count), rate: rate,
                          schedule: { $0.scheduleBuffer(input, at: nil) },
                          consume: { buffer in
                              guard let data = buffer.floatChannelData?[0] else {
                                  throw ChatterAudioError.renderingFailed(reason: "Unexpected render format.")
                              }
                              result.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
                          })
        return result
    }

    private static func validate(_ rate: Float) throws {
        guard rate.isFinite, acceptedRates.contains(rate) else { throw ChatterAudioError.invalidPace(rate) }
    }

    private static func isUnity(_ rate: Float) -> Bool { abs(rate - 1) < 1e-4 }

    /// Offline player → time-pitch (overlap 32) → main mixer, rendering exactly
    /// `ceil(inputFrames / rate)` frames in 4096-frame slices, as the former chatter-audio tool did.
    private static func renderOffline(format: AVAudioFormat, inputFrames: AVAudioFramePosition, rate: Float,
                                      schedule: (AVAudioPlayerNode) -> Void,
                                      consume: (AVAudioPCMBuffer) throws -> Void) throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), tempo = AVAudioUnitTimePitch()
        tempo.rate = rate
        tempo.overlap = 32
        engine.attach(player)
        engine.attach(tempo)
        engine.connect(player, to: tempo, format: format)
        engine.connect(tempo, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrameCount)
            schedule(player)
            try engine.start()
        } catch {
            throw ChatterAudioError.renderingFailed(reason: error.localizedDescription)
        }
        player.play()
        defer {
            player.stop()
            engine.stop()
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrameCount) else {
            throw ChatterAudioError.renderingFailed(reason: "Cannot allocate an audio buffer.")
        }
        let frames = AVAudioFramePosition((Double(inputFrames) / Double(rate)).rounded(.up))
        var written: AVAudioFramePosition = 0
        var retries = 0
        while written < frames {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(maximumFrameCount), frames - written))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(count, to: buffer)
            } catch {
                throw ChatterAudioError.renderingFailed(reason: error.localizedDescription)
            }
            switch status {
            case .success, .insufficientDataFromInputNode:
                if buffer.frameLength > 0 {
                    try consume(buffer)
                    written += AVAudioFramePosition(buffer.frameLength)
                    retries = 0
                } else {
                    retries += 1
                }
            case .cannotDoInCurrentContext:
                retries += 1
            case .error:
                throw ChatterAudioError.renderingFailed(reason: "Offline audio rendering failed.")
            @unknown default:
                throw ChatterAudioError.renderingFailed(reason: "Unexpected rendering status.")
            }
            if retries > 100 { throw ChatterAudioError.renderingFailed(reason: "Audio renderer made no progress.") }
        }
    }
}
