import Darwin
import Foundation

public struct DaemonSleepDebt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let priorValue: Bool
    public let setAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        priorValue: Bool,
        setAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.priorValue = priorValue
        self.setAt = setAt
    }
}

public enum DaemonSleepDebtState: Equatable, Sendable {
    case none
    case valid(DaemonSleepDebt)
    case unreadable
}

public protocol DaemonSleepDebtStoring: AnyObject {
    func load() -> DaemonSleepDebtState
    func save(_ debt: DaemonSleepDebt) -> Bool
    func remove() -> Bool
}

/// Root-owned persistence for the one system setting Let It Brew may need to
/// restore. The daemon writes this before touching pmset and removes it only
/// after a read-back confirms the prior value.
public final class FileDaemonSleepDebtStore: DaemonSleepDebtStoring {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> DaemonSleepDebtState {
        do {
            let data = try Data(contentsOf: url)
            let debt = try JSONDecoder().decode(DaemonSleepDebt.self, from: data)
            guard debt.schemaVersion == DaemonSleepDebt.currentSchemaVersion else {
                return .unreadable
            }
            return .valid(debt)
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileReadNoSuchFileError {
                return .none
            }
            return .unreadable
        }
    }

    public func save(_ debt: DaemonSleepDebt) -> Bool {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            let data = try JSONEncoder().encode(debt)
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    public func remove() -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            let cocoa = error as NSError
            return cocoa.domain == NSCocoaErrorDomain
                && cocoa.code == NSFileNoSuchFileError
        }
    }
}
