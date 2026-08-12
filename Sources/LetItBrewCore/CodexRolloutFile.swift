import Darwin
import Foundation

/// Identity and ordering metadata captured from the same descriptor used to
/// scan a Codex rollout. Path metadata is deliberately not trusted for cache
/// identity because a rollout can be atomically replaced at the same path.
struct CodexRolloutFileSnapshot: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    var modifiedAt: Date {
        Date(
            timeIntervalSince1970: TimeInterval(modifiedSeconds)
                + TimeInterval(modifiedNanoseconds) / 1_000_000_000
        )
    }

    func hasSameFileIdentity(as other: CodexRolloutFileSnapshot) -> Bool {
        device == other.device && inode == other.inode
    }
}

/// A capability-confined rollout reader. Every path component beneath `/` is
/// opened with `O_NOFOLLOW`, the final descriptor is verified as a regular file
/// beneath the opened sessions-root descriptor, and all metadata and bytes are
/// then obtained from that same descriptor.
final class CodexRolloutFile: @unchecked Sendable {
    let url: URL
    let snapshot: CodexRolloutFileSnapshot

    private let descriptor: Int32

    init?(
        sessionsRoot: URL,
        candidate: URL,
        beforeOpening: @Sendable (URL) -> Void = { _ in }
    ) {
        let root = sessionsRoot
        let file = candidate
        guard root.path.hasPrefix("/"), file.path.hasPrefix("/") else { return nil }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPrefix) else { return nil }

        let relativePath = String(file.path.dropFirst(rootPrefix.count))
        let relativeComponents = relativePath.split(separator: "/").map(String.init)
        guard !relativeComponents.isEmpty,
              relativeComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }

        guard let rootDescriptor = Self.openDirectoryWithoutSymlinks(root.path) else {
            return nil
        }
        defer { Darwin.close(rootDescriptor) }

        beforeOpening(file)

        var parentDescriptor = Darwin.dup(rootDescriptor)
        guard parentDescriptor >= 0 else { return nil }
        for component in relativeComponents.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            Darwin.close(parentDescriptor)
            guard nextDescriptor >= 0 else { return nil }
            parentDescriptor = nextDescriptor
        }

        let openedDescriptor = relativeComponents.last!.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        Darwin.close(parentDescriptor)
        guard openedDescriptor >= 0 else { return nil }

        var status = stat()
        // Containment is established by construction: the root descriptor is
        // opened component-by-component without following symlinks, and every
        // candidate component is then opened relative to that descriptor with
        // `openat` and `O_NOFOLLOW`. A second path lookup is both redundant and
        // unsafe because Darwin's variadic `fcntl(F_GETPATH)` has no sound
        // direct Swift declaration.
        guard Darwin.fstat(openedDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0
        else {
            Darwin.close(openedDescriptor)
            return nil
        }

        descriptor = openedDescriptor
        url = file
        snapshot = CodexRolloutFileSnapshot(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            size: UInt64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    deinit {
        Darwin.close(descriptor)
    }

    func read(from offset: UInt64, upToCount requestedCount: Int) -> Data? {
        guard requestedCount >= 0,
              offset <= UInt64(Int64.max),
              requestedCount > 0
        else { return requestedCount == 0 ? Data() : nil }

        var data = Data(count: requestedCount)
        var totalRead = 0
        let succeeded = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            while totalRead < requestedCount {
                let amount = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: totalRead),
                    requestedCount - totalRead,
                    off_t(offset) + off_t(totalRead)
                )
                if amount == 0 { break }
                if amount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                totalRead += amount
            }
            return true
        }
        guard succeeded else { return nil }
        if totalRead < data.count {
            data.removeSubrange(totalRead..<data.count)
        }
        return data
    }

    private static func openDirectoryWithoutSymlinks(_ absolutePath: String) -> Int32? {
        guard absolutePath.hasPrefix("/") else { return nil }
        let components = absolutePath.split(separator: "/").map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }

        for component in components {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            Darwin.close(descriptor)
            guard nextDescriptor >= 0 else { return nil }
            descriptor = nextDescriptor
        }
        return descriptor
    }

}
