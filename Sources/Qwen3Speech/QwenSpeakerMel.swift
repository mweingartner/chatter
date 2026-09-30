// Qwen speaker frontend adapted to Swift/MLX by Chatter, 2026.
// Based on QwenLM/Qwen3-TTS (Apache-2.0); see docs/licenses/Qwen3-TTS-LICENSE.
// This implementation is modified; numerical parity details are in docs/QWEN_PORT.md.
import Foundation
import MLX

/// Matches Qwen's official speaker frontend: Slaney filters, periodic Hann,
/// reflect padding of (FFT-hop)/2, magnitude with epsilon, and natural log.
/// Returns [time, mel], as expected by Qwen's speaker encoder.
public func computeMelSpectrogram(audio: MLXArray, sampleRate: Int = 24000,
                                  nFft: Int = 1024, hopLength: Int = 256, nMels: Int = 128) -> MLXArray {
    let samples = audio.asType(.float32).asArray(Float.self)
    let padding = (nFft - hopLength) / 2
    precondition(samples.count > padding, "Qwen references must contain at least one audio frame")
    let padded = Array(samples[1...padding].reversed()) + samples + Array(samples[(samples.count-padding-1)..<(samples.count-1)].reversed())
    let count = (padded.count-nFft)/hopLength+1
    let window = (0..<nFft).map { Float(0.5-0.5*cos(2 * Double.pi * Double($0)/Double(nFft))) }
    var frames = [Float](); frames.reserveCapacity(count*nFft)
    for frame in 0..<count { for bin in 0..<nFft { frames.append(padded[frame*hopLength+bin]*window[bin]) } }
    let spectrum = rfft(MLXArray(frames).reshaped(count,nFft), axis: 1)
    let magnitude = sqrt(abs(spectrum)*abs(spectrum)+Float(1e-9))
    func toMel(_ hz: Double) -> Double { hz < 1000 ? hz/(200.0/3) : 15+log(hz/1000)/(log(6.4)/27) }
    func toHz(_ mel: Double) -> Double { mel < 15 ? mel*(200.0/3) : 1000*exp((mel-15)*(log(6.4)/27)) }
    let points = (0..<(nMels+2)).map { toHz(Double($0)*toMel(Double(sampleRate)/2)/Double(nMels+1)) }
    var filters = [Float](); filters.reserveCapacity((nFft/2+1)*nMels)
    for bin in 0...nFft/2 {
        let hz=Double(bin)*Double(sampleRate)/Double(nFft)
        for m in 0..<nMels {
            let triangle=max(0,min((hz-points[m])/(points[m+1]-points[m]),(points[m+2]-hz)/(points[m+2]-points[m+1])))
            filters.append(Float(triangle*2/(points[m+2]-points[m])))
        }
    }
    return log(maximum(matmul(magnitude,MLXArray(filters).reshaped(nFft/2+1,nMels)),Float(1e-5)))
}
