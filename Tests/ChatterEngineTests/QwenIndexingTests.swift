import Foundation
import Testing
import Cmlx
@preconcurrency import MLX
import MLXNN
@testable import Qwen3Speech

/// Opt-in MLX tests: they need Apple-silicon Metal, which CI runners lack, so they run only with
/// `CHATTER_TEST_MLX=1`. MLX finds its metallib through the loaded bundles; this test bundle's
/// resources hold `mlx-swift_Cmlx.bundle`, but it is registered only once `Bundle.module` is touched.
/// Without that, the first MLX array aborts the whole test process.
enum MLXTests {
    static let enabled = ProcessInfo.processInfo.environment["CHATTER_TEST_MLX"] == "1"
    static func prepare() { _ = Bundle.module.bundleURL }

    static func floats(_ count: Int, in range: ClosedRange<Float>, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0 ..< count).map { _ in Float.random(in: range, using: &generator) }
    }

    /// Whether MLX holds the array's data already, rather than a graph still to run.
    static func isAvailable(_ array: MLXArray) -> Bool {
        var available = false
        _ = _mlx_array_is_available(&available, array.ctx)
        return available
    }

    /// Whether an evaluated array's rows are contiguous in memory.
    static func isRowContiguous(_ array: MLXArray) -> Bool {
        var contiguous = false
        _ = _mlx_array_is_row_contiguous(&contiguous, array.ctx)
        return contiguous
    }

    /// How one logical axis of a `HostView` maps onto its host buffer.
    enum AxisLayout: CaseIterable { case plain, everyOther, reversed, broadcast }

    /// A seeded view of a host buffer with logical shape `shape`: host axes in a random order, each
    /// axis plain, every other element from an offset, reversed or broadcast (stride 0), and
    /// optionally evaluated so MLX holds it as a strided array rather than a lazy graph.
    struct HostView<T: HasDType> {
        let host: [T]
        let view: MLXArray
        let shape: [Int]
        let description: String
        private let axisStrides: [Int]
        private let layouts: [AxisLayout]
        private let offsets: [Int]

        init(shape: [Int], layouts allowed: [AxisLayout] = AxisLayout.allCases, evaluate: Bool,
             using generator: inout SeededGenerator, value: (inout SeededGenerator) -> T) {
            let rank = shape.count
            let layouts = shape.map { _ in allowed.randomElement(using: &generator)! }
            let offsets = layouts.map { $0 == .everyOther ? Int.random(in: 0 ... 1, using: &generator) : 0 }
            let full = zip(shape, layouts).map { size, layout in
                switch layout {
                case .plain, .reversed: size
                case .everyOther: 2 * size + 1
                case .broadcast: 1
                }
            }
            let order = Array(0 ..< rank).shuffled(using: &generator) // host axis i holds logical axis order[i]
            let hostShape = order.map { full[$0] }
            var hostStrides = [Int](repeating: 1, count: rank)
            for i in stride(from: rank - 2, through: 0, by: -1) { hostStrides[i] = hostStrides[i + 1] * hostShape[i + 1] }
            var axisStrides = [Int](repeating: 0, count: rank)
            var inverse = [Int](repeating: 0, count: rank)
            for (i, axis) in order.enumerated() {
                axisStrides[axis] = hostStrides[i]
                inverse[axis] = i
            }
            let host = (0 ..< hostShape.reduce(1, *)).map { _ in value(&generator) }

            var view = MLXArray(host, hostShape).transposed(axes: inverse)
            let slices: [any MLXArrayIndex] = zip(shape, zip(layouts, offsets)).map { size, pair in
                switch pair.0 {
                case .plain: stride(from: 0, to: size, by: 1)
                case .everyOther: stride(from: pair.1, to: pair.1 + 2 * size, by: 2)
                case .reversed: stride(by: -1)
                case .broadcast: stride(from: 0, to: 1, by: 1)
                }
            }
            view = view[slices]
            if layouts.contains(.broadcast) { view = broadcast(view, to: shape) }
            if evaluate { eval(view) }

            self.host = host
            self.view = view
            self.shape = shape
            self.axisStrides = axisStrides
            self.layouts = layouts
            self.offsets = offsets
            self.description = "shape \(shape), host order \(order), layouts \(layouts), offsets \(offsets), evaluated \(evaluate)"
        }

        /// The host element behind logical position `index`.
        subscript(_ index: [Int]) -> T {
            var flat = 0
            for axis in index.indices {
                let i = index[axis]
                let hostIndex = switch layouts[axis] {
                case .plain: i
                case .everyOther: offsets[axis] + 2 * i
                case .reversed: shape[axis] - 1 - i
                case .broadcast: 0
                }
                flat += hostIndex * axisStrides[axis]
            }
            return host[flat]
        }
    }
}

/// Every MLX suite nests here, so the parent's `.serialized` keeps them off each other's threads:
/// MLX's default GPU stream is shared, and Swift Testing otherwise runs sibling suites in parallel.
@Suite(.serialized, .enabled(if: MLXTests.enabled))
enum QwenMLXTests {}

extension QwenMLXTests {
    /// The upstream dbe5eaac indexing fixes (docs/QWEN_PORT.md): slicing a transposed view must give
    /// exactly what scalar indexing meant, on lazy and on evaluated (strided) views.
    @Suite(.serialized)
    struct QwenIndexingTests {
        init() { MLXTests.prepare() }

        /// Band of each frequency slot for an mrope_section (the official interleaved layout): H on
        /// j % 3 == 1 below 3 * section[1], W on j % 3 == 2 below 3 * section[2], T everywhere else.
        static func band(_ j: Int, section: [Int] = [24, 20, 20]) -> Int {
            if j % 3 == 1, j < 3 * section[1] { return 1 }
            if j % 3 == 2, j < 3 * section[2] { return 2 }
            return 0
        }

        @Test(arguments: [false, true])
        func interleavedMropeSelectsBandsFromATransposedView(evaluateViewFirst: Bool) {
            let length = 37, half = 64
            // Host layout [3, 1, 64, length]; the talker transposes it to [3, 1, length, 64].
            let host = MLXTests.floats(3 * half * length, in: -50 ... 50, seed: 0x6D72)
            let freqs = swappedAxes(MLXArray(host).reshaped(3, 1, half, length), 2, 3)
            if evaluateViewFirst {
                eval(freqs)
                #expect(!MLXTests.isRowContiguous(freqs), "the case must exercise a strided view")
            }
            let rope = TalkerRotaryEmbedding(dim: 128, base: 1_000_000, mropeSection: [24, 20, 20])
            let combined = rope.applyInterleavedMrope(freqs, mropeSection: [24, 20, 20])
            #expect(combined.shape == [1, length, half])
            let actual = combined.asArray(Float.self)
            for position in 0 ..< length {
                for j in 0 ..< half {
                    let expected = host[(Self.band(j) * half + j) * length + position]
                    #expect(actual[position * half + j] == expected, "position \(position), slot \(j)")
                }
            }
        }

        /// Seeded fuzz: any section split, batch, length (1 to long) and any view of the frequencies
        /// (permuted, strided, reversed, broadcast; lazy or evaluated) selects exactly the host values.
        @Test func interleavedMropeMatchesTheHostSelectionOnRandomViews() {
            let rope = TalkerRotaryEmbedding(dim: 128, base: 1_000_000)
            var strided = 0
            for seed in UInt64(0) ..< 64 {
                var generator = SeededGenerator(seed: 0x4D52_0000 &+ seed)
                let half = [1, 2, 3, 8, 32, 64].randomElement(using: &generator)!
                let limit = half / 3 + 2
                let section = [Int.random(in: 0 ... limit, using: &generator),
                               Int.random(in: 0 ... limit, using: &generator),
                               Int.random(in: 0 ... limit, using: &generator)]
                let batch = Int.random(in: 1 ... 3, using: &generator)
                let length = seed % 16 == 0 ? 700 : [1, Int.random(in: 2 ... 40, using: &generator)].randomElement(using: &generator)!
                let evaluate = Bool.random(using: &generator)
                let freqs = MLXTests.HostView(shape: [3, batch, length, half], evaluate: evaluate, using: &generator) {
                    Float.random(in: -100 ... 100, using: &$0)
                }
                if evaluate, !MLXTests.isRowContiguous(freqs.view) { strided += 1 }
                let context = "seed \(seed), section \(section), \(freqs.description)"

                let combined = rope.applyInterleavedMrope(freqs.view, mropeSection: section)
                #expect(combined.shape == [batch, length, half], "\(context)")
                guard combined.shape == [batch, length, half] else { continue }
                let actual = combined.asArray(Float.self)
                var mismatches = 0
                for b in 0 ..< batch {
                    for position in 0 ..< length {
                        for j in 0 ..< half where actual[(b * length + position) * half + j]
                            != freqs[[Self.band(j, section: section), b, position, j]] {
                            mismatches += 1
                        }
                    }
                }
                #expect(mismatches == 0, "\(context)")
                #expect(rope.applyInterleavedMrope(freqs.view, mropeSection: section).asArray(Float.self) == actual,
                        "deterministic, \(context)")
            }
            #expect(strided > 10, "the fuzz must reach evaluated, strided views")
        }

        static let length = 300
        static let bandPositions: [[Int32]] = [
            (0 ..< length).map { Int32($0) },
            (0 ..< length).map { Int32(($0 * 7 + 3) % 211) },
            (0 ..< length).map { Int32(($0 * 13 + 5) % 97) },
        ]

        static func rotary(_ bands: [[Int32]]) -> (cos: [Float], sin: [Float]) {
            let rope = TalkerRotaryEmbedding(dim: 128, base: 1_000_000, mropeSection: [24, 20, 20])
            let positions = MLXArray(bands.flatMap { $0 }).reshaped(3, 1, length)
            let (cos, sin) = rope(MLXArray.zeros([1, length, 8], dtype: .float32), positionIds: positions)
            #expect(cos.shape == [1, length, 128])
            return (cos.asArray(Float.self), sin.asArray(Float.self))
        }

        @Test func eachSlotTakesItsOwnBandsPositions() {
            let half = 64
            let mixed = Self.rotary(Self.bandPositions)
            // The same band in all three rows goes through the same arithmetic, so it is bit-exact.
            let single = (0 ..< 3).map { band in Self.rotary([[Int32]](repeating: Self.bandPositions[band], count: 3)) }
            for position in 0 ..< Self.length {
                let row = position * 128
                for j in 0 ..< half {
                    let expected = single[Self.band(j)]
                    #expect(mixed.cos[row + j] == expected.cos[row + j], "position \(position), slot \(j)")
                    #expect(mixed.sin[row + j] == expected.sin[row + j], "position \(position), slot \(j)")
                    // emb = [combined, combined]: both halves carry the same angle.
                    #expect(mixed.cos[row + j + half] == mixed.cos[row + j])
                    #expect(mixed.sin[row + j + half] == mixed.sin[row + j])
                }
            }
        }

        @Test func rotaryAnglesFollowTheOfficialFrequencies() {
            let rotary = Self.rotary(Self.bandPositions)
            var checked = 0
            for position in 0 ..< Self.length {
                for j in 0 ..< 64 {
                    let angle = Double(Self.bandPositions[Self.band(j)][position]) / pow(1_000_000.0, Double(2 * j) / 128)
                    // Below pi, so a cos/sin difference bounds the angle error. MLX's float32 GPU matmul
                    // keeps only about 11 significant bits on M5 GPUs, so allow 2e-3 of the angle.
                    guard angle < 3 else { continue }
                    let tolerance = 2e-3 * angle + 1e-5
                    let index = position * 128 + j
                    #expect(abs(Double(rotary.cos[index]) - Foundation.cos(angle)) <= tolerance, "position \(position), slot \(j)")
                    #expect(abs(Double(rotary.sin[index]) - Foundation.sin(angle)) <= tolerance, "position \(position), slot \(j)")
                    checked += 1
                }
            }
            #expect(checked > 5000)
        }

        @Test func identicalPositionBandsMatchTheTwoDimensionalPath() {
            let length = 64
            let positions = MLXArray(Int32(37) ..< Int32(37 + length)).reshaped(1, length)
            let rope = TalkerRotaryEmbedding(dim: 128, base: 1_000_000, mropeSection: [24, 20, 20])
            for dtype in [DType.float32, .bfloat16] {
                let x = MLXArray.zeros([1, length, 8], dtype: dtype)
                let (stackedCos, stackedSin) = rope(x, positionIds: stacked([positions, positions, positions], axis: 0))
                let (flatCos, flatSin) = rope(x, positionIds: positions)
                #expect(stackedCos.dtype == dtype)
                #expect(stackedCos.asType(.float32).asArray(Float.self) == flatCos.asType(.float32).asArray(Float.self))
                #expect(stackedSin.asType(.float32).asArray(Float.self) == flatSin.asType(.float32).asArray(Float.self))
            }
        }

        /// Each batch row of a batched call, through the 3-D and the 2-D (broadcast) position paths,
        /// gets exactly the embedding of that row alone: no row reads another row's positions.
        @Test func batchedPositionsKeepEachRowsOwnEmbedding() {
            let batch = 3, length = 41, width = 128
            let rope = TalkerRotaryEmbedding(dim: width, base: 1_000_000, mropeSection: [24, 20, 20])
            var generator = SeededGenerator(seed: 0xBA7C)
            // [3 bands][batch][length]
            let bands = (0 ..< 3).map { _ in (0 ..< batch).map { _ in (0 ..< length).map { _ in Int32.random(in: 0 ..< 500, using: &generator) } } }
            let x = MLXArray.zeros([batch, length, 8], dtype: .float32)
            let (cos3, sin3) = rope(x, positionIds: MLXArray(bands.flatMap { $0.flatMap { $0 } }).reshaped(3, batch, length))
            let (cos2, sin2) = rope(x, positionIds: MLXArray(bands[0].flatMap { $0 }).reshaped(batch, length))
            #expect(cos3.shape == [batch, length, width])
            #expect(cos2.shape == [batch, length, width])
            let (c3, s3, c2, s2) = (cos3.asArray(Float.self), sin3.asArray(Float.self), cos2.asArray(Float.self), sin2.asArray(Float.self))
            let x1 = MLXArray.zeros([1, length, 8], dtype: .float32)
            for b in 0 ..< batch {
                let rows = MLXArray((0 ..< 3).flatMap { bands[$0][b] }).reshaped(3, 1, length)
                let (cos, sin) = rope(x1, positionIds: rows)
                let (flatCos, flatSin) = rope(x1, positionIds: MLXArray(bands[0][b]).reshaped(1, length))
                let range = (b * length * width) ..< ((b + 1) * length * width)
                #expect(Array(c3[range]) == cos.asArray(Float.self), "3-D cos, row \(b)")
                #expect(Array(s3[range]) == sin.asArray(Float.self), "3-D sin, row \(b)")
                #expect(Array(c2[range]) == flatCos.asArray(Float.self), "2-D cos, row \(b)")
                #expect(Array(s2[range]) == flatSin.asArray(Float.self), "2-D sin, row \(b)")
            }
        }

        /// A quantizer whose codebook q holds `tables[q]` exactly (cluster usage 1).
        static func quantizer(quantizers: Int, dim: Int, bins: Int, seed: UInt64) throws -> (ResidualVectorQuantization, [[Float]]) {
            let rvq = ResidualVectorQuantization(numQuantizers: quantizers, dim: dim, codebookSize: bins)
            var tables: [[Float]] = []
            var pairs: [(String, MLXArray)] = []
            for q in 0 ..< quantizers {
                let table = MLXTests.floats(bins * dim, in: -4 ... 4, seed: seed &+ UInt64(q))
                tables.append(table)
                pairs.append(("layers.\(q).codebook.embedding_sum", MLXArray(table).reshaped(bins, dim)))
                pairs.append(("layers.\(q).codebook.cluster_usage", MLXArray.ones([bins], dtype: .float32)))
            }
            try rvq.update(parameters: ModuleParameters.unflattened(pairs), verify: .noUnusedKeys)
            return (rvq, tables)
        }

        static func expectedDecode(_ codes: [Int32], tables: [[Float]], batch: Int, time: Int, quantizers: Int, dim: Int) -> [Float] {
            // codes host layout [batch, time, quantizers]; result [batch, dim, time], summed in layer order.
            expectedDecode(tables: tables, batch: batch, time: time, dim: dim) { q, b, t in Int(codes[(b * time + t) * quantizers + q]) }
        }

        /// The decode of `code(q, b, t)`: [batch, dim, time], summed from zero in layer order as the decoder does.
        static func expectedDecode(tables: [[Float]], batch: Int, time: Int, dim: Int, code: (Int, Int, Int) -> Int) -> [Float] {
            var out = [Float](repeating: 0, count: batch * dim * time)
            for b in 0 ..< batch {
                for t in 0 ..< time {
                    for q in tables.indices {
                        let row = code(q, b, t) * dim
                        for d in 0 ..< dim { out[(b * dim + d) * time + t] += tables[q][row + d] }
                    }
                }
            }
            return out
        }

        @Test(arguments: [false, true])
        func residualQuantizationDecodesTransposedCodes(evaluateViewFirst: Bool) throws {
            let quantizers = 5, dim = 6, bins = 16, batch = 2, time = 11
            let (rvq, tables) = try Self.quantizer(quantizers: quantizers, dim: dim, bins: bins, seed: 0x5251)
            var generator = SeededGenerator(seed: 0xC0DE)
            let codes = (0 ..< batch * time * quantizers).map { _ in Int32.random(in: 0 ..< Int32(bins), using: &generator) }
            // [batch, time, quantizers] -> [quantizers, batch, time], as the decoder's quantizer sees it.
            let view = MLXArray(codes).reshaped(batch, time, quantizers).transposed(2, 0, 1)
            if evaluateViewFirst {
                eval(view)
                #expect(!MLXTests.isRowContiguous(view), "the case must exercise a strided view")
            }
            let decoded = rvq.decode(view)
            #expect(decoded.shape == [batch, dim, time])
            #expect(decoded.asArray(Float.self) == Self.expectedDecode(codes, tables: tables, batch: batch, time: time, quantizers: quantizers, dim: dim))
        }

        @Test func singleQuantizerAndSingleFrameDecode() throws {
            let (rvq, tables) = try Self.quantizer(quantizers: 1, dim: 3, bins: 4, seed: 0x1)
            let codes: [Int32] = [3]
            let view = MLXArray(codes).reshaped(1, 1, 1).transposed(2, 0, 1)
            #expect(rvq.decode(view).asArray(Float.self) == Self.expectedDecode(codes, tables: tables, batch: 1, time: 1, quantizers: 1, dim: 3))
        }

        /// Seeded fuzz: 1 to 16 quantizers, batch 1 to 3, time 1 to 64, codes that include both codebook
        /// bounds, in any host layout and view (permuted, strided, reversed, broadcast; lazy or evaluated).
        @Test func residualQuantizationMatchesTheHostReferenceOnRandomViews() throws {
            var strided = 0
            for seed in UInt64(0) ..< 48 {
                var generator = SeededGenerator(seed: 0x5256_0000 &+ seed)
                let quantizers = seed == 0 ? 1 : Int.random(in: 1 ... 16, using: &generator)
                let batch = Int.random(in: 1 ... 3, using: &generator)
                let time = seed % 8 == 1 ? 1 : Int.random(in: 1 ... 64, using: &generator)
                let dim = Int.random(in: 1 ... 8, using: &generator)
                let bins = Int.random(in: 2 ... 64, using: &generator)
                let evaluate = Bool.random(using: &generator)
                let (rvq, tables) = try Self.quantizer(quantizers: quantizers, dim: dim, bins: bins, seed: 0x7AB0 &+ seed &* 64)
                let codes = MLXTests.HostView(shape: [quantizers, batch, time], evaluate: evaluate, using: &generator) { g -> Int32 in
                    switch Int.random(in: 0 ..< 4, using: &g) {
                    case 0: 0
                    case 1: Int32(bins - 1)
                    default: Int32.random(in: 0 ..< Int32(bins), using: &g)
                    }
                }
                if evaluate, !MLXTests.isRowContiguous(codes.view) { strided += 1 }
                let context = "seed \(seed), \(quantizers) quantizers, dim \(dim), bins \(bins), \(codes.description)"

                let decoded = rvq.decode(codes.view)
                #expect(decoded.shape == [batch, dim, time], "\(context)")
                let expected = Self.expectedDecode(tables: tables, batch: batch, time: time, dim: dim) { q, b, t in Int(codes[[q, b, t]]) }
                let actual = decoded.asArray(Float.self)
                #expect(actual == expected, "\(context)")
                #expect(rvq.decode(codes.view).asArray(Float.self) == actual, "deterministic, \(context)")
            }
            #expect(strided > 8, "the fuzz must reach evaluated, strided views")
        }

        /// The production shape: 16 quantizers, a 2048-entry codebook used at both of its ends, two
        /// batch rows and 1500 frames (two minutes of audio at 12.5 Hz), from [batch, time, quantizers].
        @Test func manyQuantizersLongSequenceAndCodebookBounds() throws {
            let quantizers = 16, dim = 4, bins = 2048, batch = 2, time = 1500
            let (rvq, tables) = try Self.quantizer(quantizers: quantizers, dim: dim, bins: bins, seed: 0xB16)
            var generator = SeededGenerator(seed: 0x10_0000)
            let codes = (0 ..< batch * time * quantizers).map { i -> Int32 in
                switch i % 5 {
                case 0: 0
                case 1: Int32(bins - 1)
                default: Int32.random(in: 0 ..< Int32(bins), using: &generator)
                }
            }
            for evaluate in [false, true] {
                let view = MLXArray(codes).reshaped(batch, time, quantizers).transposed(2, 0, 1)
                if evaluate { eval(view) }
                let started = ContinuousClock.now
                let decoded = rvq.decode(view).asArray(Float.self)
                let elapsed = ContinuousClock.now - started
                #expect(decoded == Self.expectedDecode(codes, tables: tables, batch: batch, time: time, quantizers: quantizers, dim: dim), "evaluated \(evaluate)")
                // A generous ceiling: 16 small gathers, milliseconds on any Apple-silicon GPU.
                #expect(elapsed < .seconds(5), "decode took \(elapsed)")
            }
        }

        /// The decoder's real call path: [batch, time, quantizers] transposed to [batch, quantizers, time],
        /// split into the semantic and the acoustic quantizers by slicing, and each transposed again,
        /// before the output projections. Grid values keep the projection exact on any float32 matmul.
        @Test(arguments: [false, true])
        func splitQuantizerDecodesSlicedTransposedCodes(evaluateViewFirst: Bool) throws {
            let quantizers = 6, semantic = 1, dimension = 3, output = 4, bins = 8, batch = 2, time = 9
            let split = SplitResidualVectorQuantizer(nQ: quantizers, nQSemantic: semantic, dimension: dimension,
                                                     inputDimension: output, outputDimension: output, bins: bins)
            var generator = SeededGenerator(seed: 0x5917)
            func grid(_ count: Int, _ scale: Float) -> [Float] { (0 ..< count).map { _ in Float(Int.random(in: -16 ... 16, using: &generator)) / scale } }
            var tables: [[Float]] = []
            var pairs: [(String, MLXArray)] = []
            for q in 0 ..< quantizers {
                let (group, layer) = q < semantic ? ("rvq_first", q) : ("rvq_rest", q - semantic)
                let table = grid(bins * dimension, 8)
                tables.append(table)
                pairs.append(("\(group).vq.layers.\(layer).codebook.embedding_sum", MLXArray(table).reshaped(bins, dimension)))
                pairs.append(("\(group).vq.layers.\(layer).codebook.cluster_usage", MLXArray.ones([bins], dtype: .float32)))
            }
            // Conv1d weights are [out, kernel 1, in].
            let firstProjection = grid(output * dimension, 1), restProjection = grid(output * dimension, 1)
            for (group, weights) in [("rvq_first", firstProjection), ("rvq_rest", restProjection)] {
                pairs.append(("\(group).output_proj.weight", MLXArray(weights).reshaped(output, 1, dimension)))
                pairs.append(("\(group).input_proj.weight", MLXArray.zeros([dimension, 1, output])))
            }
            try split.update(parameters: ModuleParameters.unflattened(pairs), verify: .noUnusedKeys)

            let codes = (0 ..< batch * time * quantizers).map { _ in Int32.random(in: 0 ..< Int32(bins), using: &generator) }
            let view = MLXArray(codes).reshaped(batch, time, quantizers).transposed(0, 2, 1)
            if evaluateViewFirst { eval(view) }
            let decoded = split.decode(view)
            #expect(decoded.shape == [batch, output, time])

            func code(_ q: Int, _ b: Int, _ t: Int) -> Int { Int(codes[(b * time + t) * quantizers + q]) }
            let first = Self.expectedDecode(tables: Array(tables[..<semantic]), batch: batch, time: time, dim: dimension) { code($0, $1, $2) }
            let rest = Self.expectedDecode(tables: Array(tables[semantic...]), batch: batch, time: time, dim: dimension) { code($0 + semantic, $1, $2) }
            var expected = [Float](repeating: 0, count: batch * output * time)
            for b in 0 ..< batch {
                for o in 0 ..< output {
                    for t in 0 ..< time {
                        for d in 0 ..< dimension {
                            let at = (b * dimension + d) * time + t
                            expected[(b * output + o) * time + t] += firstProjection[o * dimension + d] * first[at] + restProjection[o * dimension + d] * rest[at]
                        }
                    }
                }
            }
            // Codes from a wrong row or quantizer move a value by at least 1/8; the bound is far below that.
            let actual = decoded.asArray(Float.self)
            let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? .infinity
            #expect(worst <= 1e-3, "worst difference \(worst)")
        }
    }

    /// The streaming decoder step evaluates its own output (dbe5eaac), so a chunk never depends on
    /// when its consumer evaluates it, and a reset replays the same audio.
    @Suite(.serialized)
    struct QwenStreamingStepTests {
        init() { MLXTests.prepare() }

        static func decoder(zeroing zeroed: (String) -> Bool = { _ in false }) throws -> Qwen3TTSSpeechTokenizerDecoder {
            let json = """
            {"latent_dim": 16, "codebook_dim": 8, "codebook_size": 32, "decoder_dim": 16, "hidden_size": 16,
             "intermediate_size": 32, "head_dim": 8, "num_attention_heads": 2, "num_key_value_heads": 2,
             "num_hidden_layers": 2, "num_quantizers": 4, "num_semantic_quantizers": 1, "semantic_codebook_size": 32,
             "sliding_window": 8, "upsample_rates": [2, 2], "upsampling_ratios": [2],
             "vector_quantization_hidden_dimension": 8}
            """
            let config = try JSONDecoder().decode(Qwen3TTSTokenizerDecoderConfig.self, from: Data(json.utf8))
            let decoder = Qwen3TTSSpeechTokenizerDecoder(config: config)
            var seed: UInt64 = 0xDEC0
            let pairs = decoder.parameters().flattened().map { key, value -> (String, MLXArray) in
                seed &+= 1
                let range: ClosedRange<Float> = key.hasSuffix("cluster_usage") ? 0.5 ... 1.5 : -0.3 ... 0.3
                if zeroed(key) { return (key, MLXArray.zeros(value.shape)) }
                return (key, MLXArray(MLXTests.floats(value.size, in: range, seed: seed)).reshaped(value.shape))
            }
            try decoder.update(parameters: ModuleParameters.unflattened(pairs), verify: .all)
            return decoder
        }

        /// Random codes, [batch, time, quantizers] as the talker produces them.
        static func codes(batch: Int = 1, time: Int, seed: UInt64) -> MLXArray {
            var generator = SeededGenerator(seed: seed)
            return MLXArray((0 ..< batch * time * 4).map { _ in Int32.random(in: 0 ..< 32, using: &generator) }).reshaped(batch, time, 4)
        }

        /// Evaluated [batch, quantizers, size] views of consecutive chunks, as the talker hands them over.
        static func chunks(_ codes: MLXArray, every size: Int) -> [MLXArray] {
            chunks(codes, sizes: Array(repeating: size, count: (codes.dim(1) + size - 1) / size))
        }

        static func chunks(_ codes: MLXArray, sizes: [Int]) -> [MLXArray] {
            var start = 0
            return sizes.compactMap { size in
                guard start < codes.dim(1) else { return nil }
                let view = codes[0..., start ..< min(start + size, codes.dim(1)), 0...].transposed(0, 2, 1)
                eval(view)
                start += size
                return view
            }
        }

        /// One stream from a fresh state, each chunk read as soon as it is returned. Leaves the state reset.
        static func stream(_ decoder: Qwen3TTSSpeechTokenizerDecoder, _ pieces: [MLXArray]) -> [[Float]] {
            decoder.resetStreamingState()
            defer { decoder.resetStreamingState() }
            return pieces.map { decoder.streamingStep($0).asArray(Float.self) }
        }

        @Test func chunksDoNotDependOnWhenTheConsumerEvaluatesThem() throws {
            let decoder = try Self.decoder()
            let pieces = Self.chunks(Self.codes(time: 23, seed: 0x5EED), every: 5)

            let eager = Self.stream(decoder, pieces)

            // Hold every chunk unread until the last step has run, as a consumer on another thread might.
            decoder.resetStreamingState()
            let held = pieces.map { decoder.streamingStep($0) }
            let deferred = held.map { $0.asArray(Float.self) }

            let replay = Self.stream(decoder, pieces)

            #expect(eager.count == pieces.count)
            #expect(eager.map(\.count) == pieces.map { $0.dim(2) * decoder.totalUpsample })
            #expect(eager.allSatisfy { chunk in chunk.allSatisfy { $0.isFinite && abs($0) <= 1 } })
            #expect(eager.joined().contains { $0 != 0 }, "random weights should produce non-silent audio")
            #expect(deferred == eager)
            #expect(replay == eager)
        }

        /// The step itself completes its graph: the array it returns already holds its samples.
        @Test func streamingStepReturnsAnEvaluatedChunk() throws {
            #expect(!MLXTests.isAvailable(MLXArray(Float(1)) + 1), "the probe must see a lazy array as unavailable")
            let decoder = try Self.decoder()
            decoder.resetStreamingState()
            defer { decoder.resetStreamingState() }
            for (index, piece) in Self.chunks(Self.codes(time: 9, seed: 0xA7A1), sizes: [1, 5, 3]).enumerated() {
                let chunk = decoder.streamingStep(piece)
                #expect(MLXTests.isAvailable(chunk), "chunk \(index) was returned unevaluated")
                #expect(chunk.shape == [1, 1, piece.dim(2) * decoder.totalUpsample], "chunk \(index)")
            }
        }

        static let cuts: [[Int]] = [[1], [2], [3], [7], [23], [10, 1, 7, 5], [22, 1], [1, 22], [4, 4, 4, 4, 4, 3]]

        /// The worst sample difference between each cut's joined stream and the whole-utterance decode.
        static func worstJoinErrors(_ decoder: Qwen3TTSSpeechTokenizerDecoder, seed: UInt64) -> [(sizes: [Int], worst: Float)] {
            let time = 23
            let codes = Self.codes(time: time, seed: seed)
            let whole = decoder(codes.transposed(0, 2, 1)).asArray(Float.self)
            #expect(whole.count == time * decoder.totalUpsample)
            // A tolerance is meaningful only if the decode does not collapse to a constant.
            let spread = (whole.max() ?? 0) - (whole.min() ?? 0)
            #expect(spread > 0.25, "spread \(spread)")
            return cuts.map { sizes in
                let pieces = sizes.count == 1 ? Self.chunks(codes, every: sizes[0]) : Self.chunks(codes, sizes: sizes)
                let chunks = Self.stream(decoder, pieces)
                #expect(chunks.map(\.count) == pieces.map { $0.dim(2) * decoder.totalUpsample }, "sizes \(sizes)")
                let joined = Array(chunks.joined())
                guard joined.count == whole.count else { return (sizes, .infinity) }
                return (sizes, zip(joined, whole).map { abs($0 - $1) }.max() ?? .infinity)
            }
        }

        /// Metamorphic: however the codes are cut (one frame at a time, uneven sizes, one chunk), the
        /// joined stream is the whole-utterance decode, and every chunk has exactly its frames' samples.
        /// The decoder blocks' transposed-conv biases are zero here; see the known issue below for why.
        @Test func anyChunkingJoinsToTheWholeDecode() throws {
            let decoder = try Self.decoder { $0.hasSuffix("block.1.conv.bias") }
            for (sizes, worst) in Self.worstJoinErrors(decoder, seed: 0xC4A1) {
                // Different chunk shapes reach different GPU kernels (float32 matmul keeps ~10 bits on
                // M5), so this is close, not bit-exact: about 4e-3 at worst, against errors near 1 below.
                #expect(worst <= 1e-2, "sizes \(sizes): worst difference \(worst)")
            }
        }

        /// Pre-existing defect, not from dbe5eaac: `DecoderBlockUpsample.step` overlap-adds the previous
        /// chunk's overflow, and both halves carry the transposed conv's bias, so the first `rate`
        /// samples of every later chunk get the bias twice. Recorded as a known issue so the suite stays
        /// green; it starts failing ("known issue was not recorded") once the step adds the bias once.
        @Test func streamedChunkBoundariesCountTheUpsampleBiasOnce() throws {
            let decoder = try Self.decoder()
            let errors = Self.worstJoinErrors(decoder, seed: 0xC4A1)
            #expect(errors.first { $0.sizes == [23] }.map { $0.worst <= 1e-2 } == true, "a single chunk has no boundary")
            let off = errors.filter { $0.sizes != [23] && !($0.worst <= 1e-2) }.map { "\($0.sizes): \($0.worst)" }
            withKnownIssue("DecoderBlockUpsample.step counts its ConvTransposed1d bias twice in each chunk overlap") {
                #expect(off.isEmpty, "worst difference by cut: \(off.joined(separator: ", "))")
            }
        }

        /// A reset in the middle of a stream, or after an uneven final chunk, forgets everything: the next
        /// stream is bit-identical to one from a fresh decoder.
        @Test func resetMidStreamReplaysFromAFreshState() throws {
            let decoder = try Self.decoder()
            let pieces = Self.chunks(Self.codes(time: 17, seed: 0x2E5E), every: 4) // 4, 4, 4, 4, 1
            let fresh = Self.stream(try Self.decoder(), pieces)

            decoder.resetStreamingState()
            _ = decoder.streamingStep(pieces[0])
            _ = decoder.streamingStep(pieces[1])
            decoder.resetStreamingState()
            #expect(pieces.map { decoder.streamingStep($0).asArray(Float.self) } == fresh, "after a reset two chunks in")

            // The stream above ended on its uneven final chunk; a reset after it forgets that too.
            decoder.resetStreamingState()
            #expect(pieces.map { decoder.streamingStep($0).asArray(Float.self) } == fresh, "after a reset following the final chunk")

            // Without a reset the state carries over, so the same codes must not give the same audio.
            let continued = pieces.map { decoder.streamingStep($0).asArray(Float.self) }
            decoder.resetStreamingState()
            #expect(continued != fresh, "streaming state should carry across steps until reset")
        }

        /// Batch rows stream independently: each row of a batched stream is that row streamed alone.
        @Test func batchedStreamKeepsRowsIndependent() throws {
            let decoder = try Self.decoder()
            let batch = 3, time = 12
            let codes = Self.codes(batch: batch, time: time, seed: 0xBA7D)
            let batched = Self.stream(decoder, Self.chunks(codes, sizes: [5, 1, 6]))
            for b in 0 ..< batch {
                let alone = Self.stream(decoder, Self.chunks(codes[b ..< (b + 1)], sizes: [5, 1, 6]))
                for (index, chunk) in batched.enumerated() {
                    let samples = chunk.count / batch
                    #expect(samples == alone[index].count, "row \(b), chunk \(index)")
                    guard samples == alone[index].count else { continue }
                    let row = Array(chunk[(b * samples) ..< ((b + 1) * samples)])
                    let worst = zip(row, alone[index]).map { abs($0 - $1) }.max() ?? .infinity
                    // Batched and single-row shapes reach different GPU kernels: close, not bit-exact.
                    #expect(worst <= 1e-2, "row \(b), chunk \(index): worst difference \(worst)")
                }
            }
        }
    }
}
