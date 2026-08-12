import Darwin
import Foundation

/// Walks up the process tree from a hook invocation to find the agent that
/// spawned it, recording its pid so the app can evict the session the instant
/// that process dies.
public enum ProcessAncestry {
    public struct ProcessNode: Equatable, Sendable {
        public var pid: Int32
        public var ppid: Int32
        /// The kernel's short process name (`p_comm`), truncated to 16
        /// bytes. Some agents (Claude Code) overwrite this with their own
        /// version string ("2.1.220"), so it is NOT a reliable way to
        /// identify the agent — it is kept only as a cheap fallback and for
        /// diagnostics. See `argv0Name`.
        public var command: String
        /// The last path component of argv[0] (e.g. "claude" or "codex"),
        /// whether the raw argv[0] was a bare name or a full executable
        /// path. This is the primary signal for agent identification,
        /// because unlike `command` it survives an agent rewriting its own
        /// process name. Nil if argv[0] could not be read.
        public var argv0Name: String?

        public init(pid: Int32, ppid: Int32, command: String, argv0Name: String? = nil) {
            self.pid = pid
            self.ppid = ppid
            self.command = command
            self.argv0Name = argv0Name.map(ProcessAncestry.lastPathComponent)
        }

        /// The recognized agent name for this node, preferring argv[0]'s
        /// basename over `command` since some agents rewrite `p_comm`.
        public var agentName: String? {
            if let argv0Name, agentNames.contains(argv0Name) { return argv0Name }
            if agentNames.contains(command) { return command }
            return nil
        }
    }

    /// Agent process names recognized in v1.
    public static let agentNames: Set<String> = ["claude", "codex"]

    static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Reads one process's parent, short name, and argv[0] via `sysctl`.
    /// Returns nil if the process is gone or unreadable.
    public static func info(for pid: Int32) -> ProcessNode? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0)
        // A dead pid returns 0 with a zeroed struct, so check the echo too.
        guard result == 0, size > 0, proc.kp_proc.p_pid == pid else { return nil }

        let command = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return ProcessNode(
            pid: pid, ppid: proc.kp_eproc.e_ppid, command: command, argv0Name: rawArgv0(for: pid)
        )
    }

    /// Reads the raw argv[0] of `pid` via `sysctl(KERN_PROCARGS2)`. Returns
    /// nil on any failure — permissions, a dead/zombie pid, or a malformed
    /// buffer. Never crashes: every index is bounds-checked before use,
    /// because this runs inside a hook on every agent tool call.
    ///
    /// The payload size can change between the sizing call and the fetch
    /// call (a process can exec/exit concurrently), which either makes the
    /// fetch call fail with ENOMEM (grew) or leaves the tail of the
    /// over-allocated buffer as untouched zero bytes (shrank). One retry
    /// with a freshly probed size covers both: if the fetch still fails, or
    /// still returns something malformed, we give up rather than loop.
    static func rawArgv0(for pid: Int32) -> String? {
        func attempt() -> (buffer: [UInt8], length: Int)? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0,
                  size > 0, size <= buffer.count
            else { return nil }
            return (buffer, size)
        }

        guard let result = attempt() ?? attempt() else { return nil }
        return parseArgv0(from: result.buffer, length: result.length)
    }

    /// Parses the KERN_PROCARGS2 layout to extract argv[0]. `length` is the
    /// number of bytes `sysctl` actually reported as valid — everything
    /// from `length` to `buffer.count` may be stale or zero-filled padding
    /// from over-allocation and must never be read as data.
    ///
    /// Layout (see `sysctl.3`, KERN_PROCARGS2): a 4-byte `argc`, then the
    /// NUL-terminated executable path, then one or more padding NUL bytes,
    /// then NUL-terminated argv[0], then the remaining argv entries.
    static func parseArgv0(from buffer: [UInt8], length: Int) -> String? {
        let argcSize = MemoryLayout<Int32>.size
        guard length > argcSize, length <= buffer.count else { return nil }
        let valid = buffer[0..<length]

        // Host byte order: both arm64 and x86_64 Macs are little-endian.
        let argc =
            Int32(valid[0]) | Int32(valid[1]) << 8 | Int32(valid[2]) << 16 | Int32(valid[3]) << 24
        guard argc > 0 else { return nil }
        var offset = argcSize

        // Skip the NUL-terminated executable path.
        guard let execPathEnd = valid[offset...].firstIndex(of: 0) else { return nil }
        offset = execPathEnd

        // Skip the padding NULs that follow it.
        while offset < length, valid[offset] == 0 { offset += 1 }
        guard offset < length else { return nil }

        // Read argv[0] up to its terminating NUL — never past `length`.
        guard let argv0End = valid[offset...].firstIndex(of: 0) else { return nil }
        let argv0Bytes = valid[offset..<argv0End]
        guard !argv0Bytes.isEmpty else { return nil }
        return String(decoding: argv0Bytes, as: UTF8.self)
    }

    /// Walks up from `start` looking for a known agent process.
    ///
    /// `lookup` is injected so the walk is testable against a scripted table.
    /// Visited pids are tracked because a recycled or malformed table could
    /// otherwise loop, and a hook that hangs stalls the agent it serves.
    ///
    /// A node matches if EITHER its argv[0] basename or its `p_comm`
    /// (`command`) is a recognized agent name. argv[0] is the primary
    /// signal; `command` is a cheap fallback for agents that do not
    /// overwrite their process name.
    public static func findAgent(
        from start: Int32,
        maxDepth: Int = 8,
        lookup: (Int32) -> ProcessNode? = ProcessAncestry.info(for:)
    ) -> ProcessNode? {
        var current = start
        var seen: Set<Int32> = []
        for _ in 0..<maxDepth {
            guard !seen.contains(current), let node = lookup(current) else { return nil }
            seen.insert(current)
            if node.agentName != nil { return node }
            guard node.ppid > 1 else { return nil }
            current = node.ppid
        }
        return nil
    }
}
