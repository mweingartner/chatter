import Foundation
@preconcurrency import MLX

/// MLX memory policy. MLX's default keeps up to ~121 GiB of freed Metal buffers on this class of
/// Mac and only trims near ~102 GiB, which is why the Python runtime grew to ~100 GB.
enum MemoryPolicy {
    static func apply(_ configuration: EngineConfiguration) {
        Memory.cacheLimit = configuration.cacheLimitBytes
        Memory.memoryLimit = configuration.memoryLimitBytes
    }

    /// Returns cached buffers to the system (after loading, warm-up and every job).
    static func relax() { Memory.clearCache() }

    static func snapshot() -> [String: Any] {
        ["footprintBytes": physicalFootprint(), "activeBytes": Memory.activeMemory, "cacheBytes": Memory.cacheMemory,
         "peakBytes": Memory.peakMemory, "cacheLimitBytes": Memory.cacheLimit]
    }

    /// Process physical footprint (the figure Activity Monitor and `footprint` report, including Metal buffers).
    static func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : -1
    }
}
