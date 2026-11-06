import Cocoa

@main
struct RegressionTests {
    static func main() throws {
        let cpu = CPUMonitor.usage(previous: [100, 100, 100, 100], current: [110, 110, 180, 100])
        precondition(cpu == 20, "CPU load must use the change in system ticks")
        precondition(CPUMonitor.usage(previous: [1, 1, 1, 1], current: [1, 1, 1, 1]) == nil)
        let wrapped = CPUMonitor.usage(previous: [UInt32.max - 4, 0, 0, 0], current: [5, 0, 10, 0])
        precondition(wrapped == 50, "Tick wraparound must not overflow")

        var first = Listener(port: 3000, pid: 10, command: "node", addr: "127.0.0.1",
                             cwd: NSHomeDirectory() + "/Projects/one", args: "node server.js --port 3000", project: "app")
        var restarted = first
        restarted.pid = 20
        restarted.port = 4000
        restarted.args = "node server.js --port 4000"
        precondition(first.fingerprint == restarted.fingerprint, "Restarts on another port must reuse descriptions")
        var sibling = restarted
        sibling.cwd = "/projects/two"
        precondition(first.fingerprint != sibling.fingerprint, "Equal package names must not merge different projects")
        sibling = first
        sibling.args = "node worker.js --port 3000"
        precondition(first.fingerprint != sibling.fingerprint, "Different services in the same folder need distinct descriptions")
        var secondPort = first
        secondPort.port = 3001
        first.rssKB = 1024
        secondPort.rssKB = 1024
        precondition(Listener.uniqueProcesses([first, secondPort, restarted]).count == 2)
        precondition(Listener.uniqueProcesses([first, secondPort]).reduce(0) { $0 + $1.rssKB } == 1024)

        first.startedAt = Date().addingTimeInterval(-4 * 86400)
        let dev = PortDesc(label: "Development server", description: "Local app preview.", confidence: "high", safeToKill: true)
        let system = PortDesc(label: "System service", description: "macOS service.", confidence: "high", safeToKill: false)
        precondition(first.looksForgotten(dev))
        precondition(!first.looksForgotten(system))
        precondition(!first.looksForgotten(nil))
        var vendor = first
        vendor.args = "/Applications/Vendor.app/Contents/MacOS/node"
        precondition(!vendor.looksForgotten(dev), "Vendor background helpers must never be marked forgotten")
        first.connections = 1
        precondition(!first.looksForgotten(dev))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cacheURL = folder.appendingPathComponent("cache.json")
        try JSONEncoder().encode([first.legacyFingerprint: dev]).write(to: cacheURL)
        let describer = Describer(cacheURL: cacheURL)
        describer.voice = .technical
        precondition(describer.desc(for: first) == dev, "Old cache entries must stay readable")
        describer.describe(first)
        precondition(describer.desc(for: restarted) == dev, "Portable old descriptions must migrate across ports")
        let reloaded = Describer(cacheURL: cacheURL)
        reloaded.voice = .technical
        precondition(reloaded.desc(for: restarted) == dev, "Migrated descriptions must persist")

        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        var calls = 0
        let reply = String(decoding: try JSONEncoder().encode(dev), as: UTF8.self)
        let onDemand = Describer(cacheURL: folder.appendingPathComponent("on-demand.json")) { _ in
            calls += 1
            started.signal()
            finish.wait()
            return reply
        }
        onDemand.setActive(false)
        onDemand.describe(first)
        precondition(onDemand.pending.isEmpty, "A closed panel must not queue descriptions")
        precondition(calls == 0)
        onDemand.setActive(true)
        onDemand.describe(first)
        precondition(started.wait(timeout: .now() + 2) == .success)
        onDemand.describe(sibling)
        precondition(onDemand.isPending(sibling))
        onDemand.setActive(false)
        precondition(!onDemand.isPending(sibling), "Closing the panel must discard queued requests")
        finish.signal()
        pumpUntil { !onDemand.isPending(first) }
        precondition(calls == 1, "Only the already-started request may finish after closing")
        precondition(onDemand.desc(for: first) == dev)
        onDemand.setActive(true)
        onDemand.describe(first)
        precondition(!onDemand.isPending(first), "Reopening must reuse the completed answer")
        onDemand.describe(sibling)
        precondition(started.wait(timeout: .now() + 2) == .success)
        finish.signal()
        pumpUntil { !onDemand.isPending(sibling) }
        precondition(calls == 2, "Discarded requests must be available on the next open")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let identity = ProcessIdentity.read(child.processIdentifier)
        precondition(identity != nil)
        var target = Listener(port: 1234, pid: child.processIdentifier, command: "sleep", addr: "127.0.0.1", identity: identity)
        precondition(ProcessControl.matches(target, current: identity))
        precondition(!ProcessControl.matches(target, current: nil))
        target.identity = ProcessIdentity(seconds: 1, microseconds: 1)
        precondition(ProcessControl.terminate(target).hasPrefix("Skipped"))
        precondition(child.isRunning, "A stale identity must never signal the live PID")
        target.identity = identity
        let result = ProcessControl.terminate(target)
        precondition(result.hasPrefix("Quit"))
        child.waitUntilExit()
        precondition(!child.isRunning, "A verified target must receive the quit request")
        print("Passed on-demand descriptions, CPU, process deduplication, cache migration, forgotten labels, and safe-quit regressions.")
    }

    static func pumpUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), "Timed out waiting for a description to commit")
    }
}
