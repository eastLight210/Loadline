import Foundation

/// Decides which app each process belongs to. Kept free of libproc calls so the rules can be
/// unit tested against a made-up process table; `ProcessSampler` supplies the real one.
enum ProcessGrouping {
    /// Maps a pid to the pid responsible for it (itself when nothing else is). Callers pass nil
    /// when the responsibility SPI isn't available.
    typealias ResponsibleLookup = @Sendable (pid_t) -> pid_t

    /// Non-regular apps whose responsible process is another listed app — e.g. Claude's
    /// Virtualization XPC service, which registers as its own accessory app — map to that app.
    static func foldTargets(for apps: [AppSeed], responsible: ResponsibleLookup?) -> [pid_t: pid_t] {
        guard let responsible else { return [:] }
        let seeds = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var direct: [pid_t: pid_t] = [:]
        for seed in apps where !seed.isRegular {
            let owner = responsible(seed.pid)
            if owner != seed.pid, seeds[owner] != nil { direct[seed.pid] = owner }
        }
        // Follow chains (A folded into B folded into C) to the top-level app.
        var resolved: [pid_t: pid_t] = [:]
        for pid in direct.keys {
            var target = direct[pid]!
            var hops = 0
            while let next = direct[target], hops < 8 {
                target = next
                hops += 1
            }
            if direct[target] == nil { resolved[pid] = target }
        }
        return resolved
    }

    /// Groups every pid in `parent` under the top-level app that owns it. Each app's own pid
    /// is included in its group; processes no app owns are left out.
    static func groups(
        appPIDs: Set<pid_t>, foldedInto: [pid_t: pid_t], parent: [pid_t: pid_t], responsible: ResponsibleLookup?
    ) -> [pid_t: [pid_t]] {
        var groups: [pid_t: [pid_t]] = [:]
        for pid in parent.keys {
            if appPIDs.contains(pid) {
                groups[pid, default: []].append(pid)
            } else if let owner = owner(
                of: pid, appPIDs: appPIDs, foldedInto: foldedInto, parent: parent, responsible: responsible
            ) {
                groups[owner, default: []].append(pid)
            }
        }
        return groups
    }

    static func owner(
        of pid: pid_t, appPIDs: Set<pid_t>, foldedInto: [pid_t: pid_t], parent: [pid_t: pid_t],
        responsible: ResponsibleLookup?
    ) -> pid_t? {
        if let target = foldedInto[pid] { return target }
        if let responsible {
            let owner = responsible(pid)
            if owner != pid {
                if appPIDs.contains(owner) { return owner }
                if let target = foldedInto[owner] { return target }
            }
        }
        var current = parent[pid] ?? 0
        var depth = 0
        while current > 1, depth < 64 {
            if appPIDs.contains(current) { return current }
            if let target = foldedInto[current] { return target }
            current = parent[current] ?? 0
            depth += 1
        }
        return nil
    }
}
