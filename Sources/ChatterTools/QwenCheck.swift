import Foundation
import Qwen3Speech
import ChatterAudioKit
import MLX

enum QwenCheck {
    static func run(_ args:[String]) throws {
        guard args.count==3,args[0]=="mel" else { throw ToolError.usage("qwen-check mel input.wav output.json") }
        let samples=try AudioIO.readMono(URL(filePath:args[1]),sampleRate:24000)
        let result=computeMelSpectrogram(audio:MLXArray(samples))
        eval(result)
        let data=try JSONSerialization.data(withJSONObject:["shape":result.shape,"values":result.asArray(Float.self)])
        try data.write(to:URL(filePath:args[2]))
    }
}
