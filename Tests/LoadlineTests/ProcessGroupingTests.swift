import Foundation
import Testing
@testable import Loadline

/// A made-up process table: who launched whom, and who macOS says is responsible for whom.
private struct FakeSystem {
    var parent: [pid_t: pid_t] = [:]
    var responsibleFor: [pid_t: pid_t] = [:]

    var responsible: ProcessGrouping.ResponsibleLookup {
        let table = responsibleFor
        return { table[$0] ?? $0 }
    }

    func groups(apps: [AppSeed], hasResponsibilitySPI: Bool = true) -> [pid_t: Set<pid_t>] {
        let lookup = hasResponsibilitySPI ? responsible : nil
        let foldedInto = ProcessGrouping.foldTargets(for: apps, responsible: lookup)
        let appPIDs = Set(apps.filter { foldedInto[$0.pid] == nil }.map(\.pid))
        let groups = ProcessGrouping.groups(
            appPIDs: appPIDs, foldedInto: foldedInto, parent: parent, responsible: lookup
        )
        return groups.mapValues(Set.init)
    }
}

private func app(_ pid: pid_t, _ name: String, regular: Bool = true) -> AppSeed {
    AppSeed(pid: pid, name: name, bundleID: nil, isRegular: regular)
}

private let launchd: pid_t = 1

@Suite struct ProcessGroupingTests {
    @Test func safariWebContentGroupsUnderSafariViaResponsibility() {
        // WebContent and Networking are XPC services: launchd is their parent, Safari is responsible.
        var system = FakeSystem()
        system.parent = [100: launchd, 101: launchd, 102: launchd, 103: launchd]
        system.responsibleFor = [101: 100, 102: 100, 103: 100]

        let groups = system.groups(apps: [app(100, "Safari")])

        #expect(groups == [100: [100, 101, 102, 103]])
    }

    @Test func electronRenderersGroupUnderAppViaParentChain() {
        // Electron's main process spawns the GPU helper, which spawns nothing; renderers are
        // children of the main process, and a utility process is a grandchild.
        var system = FakeSystem()
        system.parent = [200: launchd, 201: 200, 202: 200, 203: 200, 204: 203]

        let groups = system.groups(apps: [app(200, "Slack")])

        #expect(groups == [200: [200, 201, 202, 203, 204]])
    }

    @Test func parentChainWorksWithoutResponsibilitySPI() {
        var system = FakeSystem()
        system.parent = [200: launchd, 201: 200, 202: 201]
        system.responsibleFor = [300: 200]
        system.parent[300] = launchd

        let groups = system.groups(apps: [app(200, "Slack")], hasResponsibilitySPI: false)

        // Without the SPI, launchd-parented XPC services can't be attributed and are left out.
        #expect(groups == [200: [200, 201, 202]])
    }

    @Test func accessoryAppFoldsIntoResponsibleApp() {
        // Claude's virtualization service registers as its own accessory app.
        var system = FakeSystem()
        system.parent = [400: launchd, 401: launchd, 402: 401]
        system.responsibleFor = [401: 400]

        let apps = [app(400, "Claude"), app(401, "Virtual Machine Service for Claude", regular: false)]
        let foldedInto = ProcessGrouping.foldTargets(for: apps, responsible: system.responsible)

        #expect(foldedInto == [401: 400])
        // The folded app's own children follow it into the owning app.
        #expect(system.groups(apps: apps) == [400: [400, 401, 402]])
    }

    @Test func regularAppsAreNeverFolded() {
        // A Dock app launched by another app stays listed on its own.
        var system = FakeSystem()
        system.parent = [500: launchd, 501: launchd]
        system.responsibleFor = [501: 500]

        let apps = [app(500, "Xcode"), app(501, "Simulator")]

        #expect(ProcessGrouping.foldTargets(for: apps, responsible: system.responsible).isEmpty)
        #expect(system.groups(apps: apps) == [500: [500], 501: [501]])
    }

    @Test func foldChainsResolveToTopLevelApp() {
        var system = FakeSystem()
        system.parent = [600: launchd, 601: launchd, 602: launchd]
        system.responsibleFor = [601: 600, 602: 601]

        let apps = [
            app(600, "Host"),
            app(601, "Agent", regular: false),
            app(602, "Sub-agent", regular: false),
        ]

        #expect(ProcessGrouping.foldTargets(for: apps, responsible: system.responsible) == [601: 600, 602: 600])
    }

    @Test func foldCyclesAreDropped() {
        // Two accessory apps each claiming the other must not hang or fold into each other.
        var system = FakeSystem()
        system.responsibleFor = [701: 702, 702: 701]

        let apps = [app(701, "A", regular: false), app(702, "B", regular: false)]

        #expect(ProcessGrouping.foldTargets(for: apps, responsible: system.responsible).isEmpty)
    }

    @Test func noFoldingWithoutResponsibilitySPI() {
        let apps = [app(400, "Claude"), app(401, "VM Service", regular: false)]

        #expect(ProcessGrouping.foldTargets(for: apps, responsible: nil).isEmpty)
    }

    @Test func unownedProcessesAreLeftOut() {
        // Daemons and processes of apps that aren't listed don't show up anywhere.
        var system = FakeSystem()
        system.parent = [100: launchd, 900: launchd, 901: 900]

        #expect(system.groups(apps: [app(100, "Safari")]) == [100: [100]])
    }

    @Test func nearestAppWinsWhenAppsAreNested() {
        // A listed app launched by another listed app keeps its own children.
        var system = FakeSystem()
        system.parent = [800: launchd, 801: 800, 802: 801, 803: 800]

        let groups = system.groups(apps: [app(800, "Terminal"), app(801, "Editor")])

        #expect(groups == [800: [800, 803], 801: [801, 802]])
    }

    @Test func parentCyclesTerminate() {
        // A corrupt table where two processes are each other's parent must not loop forever.
        var system = FakeSystem()
        system.parent = [100: launchd, 950: 951, 951: 950]

        #expect(system.groups(apps: [app(100, "Safari")]) == [100: [100]])
    }
}
