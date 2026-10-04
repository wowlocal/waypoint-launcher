import Darwin

/// The process's memory as Activity Monitor and `footprint` report it.
public enum ProcessMemory {
    public static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    public static var footprintMB: Int { Int(footprint >> 20) }
}

extension ProcessMemory {
    /// Hands memory that big jobs (install plans, updates) freed back to the
    /// system right away, so the app drops back to its idle footprint
    /// instead of keeping the freed pages around for reuse.
    ///
    /// This covers malloc's small and medium regions. Freed large blocks sit
    /// in malloc's large cache, which this doesn't empty; the app's
    /// Info.plist turns that cache off (`MallocLargeCache=0` in
    /// LSEnvironment, see scripts/bundle.sh).
    public static func releaseFreed() {
        malloc_zone_pressure_relief(nil, 0)
    }
}
