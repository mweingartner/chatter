import AVFoundation
import Observation
import ChatterCore

@MainActor @Observable
final class VoiceRecorder {
    var recording = false
    var seconds = 0.0
    var level = 0.0
    var url: URL?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Task<Void, Never>?
    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ChatterError.invalid("Allow microphone access in System Settings → Privacy & Security → Microphone.") }
        let target = ChatterPaths.root.appending(path: "recording-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:44100.0, AVNumberOfChannelsKey:1,
                                      AVLinearPCMBitDepthKey:24, AVLinearPCMIsFloatKey:false, AVLinearPCMIsBigEndianKey:false]
        let r = try AVAudioRecorder(url: target, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw ChatterError.unavailable("The microphone could not start recording.") }
        recorder = r; url = target; recording = true; seconds = 0
        meter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let r = self.recorder else { return }
                r.updateMeters(); self.seconds = r.currentTime; self.level = max(0, min(1, (Double(r.averagePower(forChannel: 0)) + 60) / 60))
                if r.currentTime >= 120 { self.stop(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    func stop() { recorder?.stop(); recorder = nil; recording = false; meter?.cancel(); level = 0 }
}
