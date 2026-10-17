import Foundation

/// Maps running Claude processes to profiles.
public struct InstanceMap {
    public let processes: [ClaudeProcess]
    private let byProfile: [String: [ClaudeProcess]]
    /// Claude processes whose `--user-data-dir` belongs to no profile (started by hand).
    public let unmanaged: [ClaudeProcess]

    public init(profiles: [Profile], processes: [ClaudeProcess]) {
        self.processes = processes
        var dirToName: [String: String] = [:]
        for profile in profiles {
            dirToName[profile.dataDir.canonicalPath] = profile.name
        }
        var map: [String: [ClaudeProcess]] = [:]
        var unknown: [ClaudeProcess] = []
        for process in processes {
            let name: String?
            if let dir = process.userDataDir {
                name = dirToName[canonicalPath(dir)]
            } else {
                name = Profile.defaultName
            }
            if let name { map[name, default: []].append(process) } else { unknown.append(process) }
        }
        byProfile = map
        unmanaged = unknown
    }

    public func processes(for profile: Profile) -> [ClaudeProcess] {
        byProfile[profile.name] ?? []
    }

    public func pid(for profile: Profile) -> Int32? {
        processes(for: profile).first?.pid
    }

    /// Two processes on one userData folder corrupt it
    /// (Claude has no single-instance lock, see docs/RESEARCH.md).
    public var conflicts: [(String, [ClaudeProcess])] {
        byProfile.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

extension ProfileStore {
    public func instanceMap(app: ClaudeApp?) -> InstanceMap {
        InstanceMap(profiles: allProfiles(), processes: ProcessScanner.claudeProcesses(app: app))
    }
}
