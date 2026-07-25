// Tugboat — a macOS menubar utility that tells you what is actually running
// on every listening port, in English.
//
// Three layers, cheapest first:
//   1. lsof + ps, batched into three calls total, for the hard facts
//      (pid, cwd, argv, uptime, memory, cpu, live connections).
//   2. the filesystem — cwd gives package.json name and git origin for free.
//   3. one cached Sonnet call per distinct server for the last mile, plus a
//      second pass that sees every port at once and groups them.
//
// Descriptions are cached per fingerprint (port|command|project), so a given
// server is described exactly once — not on every poll. Volatile facts
// (connections, cpu) are deliberately NOT in the prompt: they'd invalidate the
// cache every few seconds. They're measured live and combined at render time.
//
// Build: ./build.sh   Run: ./Tugboat   Verify headlessly: ./Tugboat --scan --describe

import Cocoa
import SwiftUI
import Combine

// MARK: - Model

struct PortDesc: Codable, Hashable {
    var label: String
    var description: String
    var confidence: String
    /// Optional so entries cached before this field existed still decode.
    var safeToKill: Bool?
    /// Set by us, never by the model: which model actually answered, and only
    /// when it wasn't the first choice. nil means the primary one — the common
    /// case, and the one not worth saying anything about.
    var fallbackModel: String?

    enum CodingKeys: String, CodingKey {
        case label, description, confidence
        case safeToKill = "safe_to_kill"
        case fallbackModel = "fallback_model"
    }
}

struct PortGroup: Codable, Hashable {
    var name: String
    var note: String
    var ports: [Int]
}

private struct GroupResult: Codable { var groups: [PortGroup] }

struct Listener: Identifiable, Hashable {
    var port: Int
    var pid: Int32
    var command: String
    var addr: String
    var cwd: String = ""
    var args: String = ""
    var project: String = ""     // package.json name, if any
    var remote: String = ""      // git origin, if any
    var startedAt: Date?
    var rssKB: Int = 0
    var cpuPercent: Double = 0
    var connections: Int = 0     // established sockets on this pid right now

    var id: String { "\(port)-\(pid)" }

    /// Identity only — no pid, no volatile metrics. Restarting a dev server on
    /// the same port must not re-pay for a description.
    var fingerprint: String {
        "\(port)|\(command)|\(project.isEmpty ? cwd : project)"
    }

    var isLocalOnly: Bool { addr.hasPrefix("127.0.0.1") || addr.hasPrefix("[::1]") }

    /// "2:03pm" if it started today, "Jul 21" if not.
    var startedLabel: String {
        guard let startedAt else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(startedAt) ? "h:mma" : "MMM d"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f.string(from: startedAt)
    }

    var memoryLabel: String {
        guard rssKB > 0 else { return "" }
        let mb = Double(rssKB) / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024)
                          : String(format: "%.0f MB", mb)
    }

    /// Someone has an open socket, or it's burning CPU. Either way it's in use.
    var inUse: Bool { connections > 0 || cpuPercent > 5 }

    var activityLabel: String {
        if connections > 0 { return connections == 1 ? "1 conn" : "\(connections) conns" }
        if cpuPercent > 5 { return String(format: "%.0f%% cpu", cpuPercent) }
        return "idle"
    }

    /// Days since it started, for the "you forgot about this" signal.
    var ageDays: Int {
        guard let startedAt else { return 0 }
        return Calendar.current.dateComponents([.day], from: startedAt, to: Date()).day ?? 0
    }

    /// The model judges the *class* of process; the live facts decide whether
    /// right now is a good moment. Both have to agree.
    func freeToKill(_ d: PortDesc?) -> Bool { d?.safeToKill == true && !inUse }
}

// MARK: - Shell

enum Shell {
    /// Run a binary directly. Returns stdout, or "" on failure.
    @discardableResult
    static func run(_ path: String, _ args: [String], cwd: String? = nil,
                    timeout: TimeInterval? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }

        // A hung child must not become a permanently resident child. Read on a
        // background thread so the pipe keeps draining while we watch the clock.
        if let timeout {
            var data = Data()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                data = out.fileHandleForReading.readDataToEndOfFile()
                done.signal()
            }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                p.terminate()
                _ = done.wait(timeout: .now() + 2)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                return ""
            }
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Run through a login shell so PATH resolution matches the user's terminal
    /// (the `claude` CLI lives wherever their version manager put it).
    static func login(_ command: String, cwd: String, timeout: TimeInterval? = nil) -> String {
        run("/bin/zsh", ["-lc", command], cwd: cwd, timeout: timeout)
    }
}

// MARK: - Scanner

enum Scanner {
    /// `lsof -F` field output: a `p<pid>` line opens a process block, `c<cmd>`
    /// names it, and each `n<addr>` line is one socket. Parsing lsof's column
    /// format instead would break on commands containing spaces.
    static func scan() -> [Listener] {
        let raw = Shell.run("/usr/sbin/lsof",
                            ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "+c", "0", "-F", "pcn"])
        var found: [String: Listener] = [:]
        var pid: Int32 = 0
        var command = ""

        for line in raw.split(separator: "\n") {
            let body = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(body) ?? 0
            case "c": command = body
            case "n":
                // "127.0.0.1:3000", "*:5173", "[::1]:5432"
                guard let colon = body.lastIndex(of: ":"),
                      let port = Int(body[body.index(after: colon)...]) else { continue }
                let l = Listener(port: port, pid: pid, command: command,
                                 addr: String(body[..<colon]))
                // IPv4 and IPv6 rows for one server collapse to a single entry.
                if found[l.id] == nil { found[l.id] = l }
            default: break
            }
        }

        var listeners = Array(found.values)
        enrich(&listeners)
        return listeners.sorted { $0.port < $1.port }
    }

    /// Everything knowable for free, before spending a model call. Batched: one
    /// ps and two lsofs for the whole set, not three calls per process — that
    /// difference is ~7s vs well under 1s on a machine with 30 listeners.
    private static func enrich(_ listeners: inout [Listener]) {
        let pids = Array(Set(listeners.map { $0.pid })).map(String.init)
        guard !pids.isEmpty else { return }
        let pidList = pids.joined(separator: ",")

        // --- ps: uptime, memory, cpu, argv -------------------------------
        // lstart is a fixed 5 tokens ("Mon Jul 21 14:03:12 2026"), so command
        // must come last — it's the only field that can contain spaces.
        var meta: [Int32: (Date?, Int, Double, String)] = [:]
        let psOut = Shell.run("/bin/ps",
                              ["-p", pidList, "-o", "pid=,lstart=,rss=,%cpu=,command="])
        let stamp = DateFormatter()
        stamp.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        for line in psOut.split(separator: "\n") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            guard t.count > 8, let p = Int32(t[0]) else { continue }
            meta[p] = (stamp.date(from: t[1..<6].joined(separator: " ")),
                       Int(t[6]) ?? 0,
                       Double(t[7]) ?? 0,
                       t[8...].joined(separator: " "))
        }

        // --- lsof: working directory per pid ------------------------------
        var cwds: [Int32: String] = [:]
        var cur: Int32 = 0
        for line in Shell.run("/usr/sbin/lsof", ["-a", "-p", pidList, "-d", "cwd", "-F", "pn"])
            .split(separator: "\n") {
            if line.hasPrefix("p") { cur = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { cwds[cur] = String(line.dropFirst()) }
        }

        // --- lsof: is anything actually talking to it right now? -----------
        // The strongest "is this in use" signal available without per-socket
        // idle times, which macOS doesn't expose.
        var conns: [Int32: Int] = [:]
        cur = 0
        for line in Shell.run("/usr/sbin/lsof",
                              ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-a", "-p", pidList, "-F", "pn"])
            .split(separator: "\n") {
            if line.hasPrefix("p") { cur = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { conns[cur, default: 0] += 1 }
        }

        // --- filesystem: project identity ---------------------------------
        var projects: [String: (String, String)] = [:]   // cwd -> (name, remote)
        for i in listeners.indices {
            var l = listeners[i]
            if let m = meta[l.pid] {
                l.startedAt = m.0; l.rssKB = m.1; l.cpuPercent = m.2; l.args = m.3
            }
            l.connections = conns[l.pid] ?? 0
            l.cwd = cwds[l.pid] ?? ""

            if !l.cwd.isEmpty, FileManager.default.fileExists(atPath: l.cwd) {
                if let cached = projects[l.cwd] {
                    l.project = cached.0; l.remote = cached.1
                } else {
                    var name = ""
                    if let data = FileManager.default.contents(atPath: l.cwd + "/package.json"),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let n = json["name"] as? String {
                        name = n
                    }
                    let remote = Shell.run("/usr/bin/git", ["remote", "get-url", "origin"], cwd: l.cwd)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    projects[l.cwd] = (name, remote)
                    l.project = name; l.remote = remote
                }
            }
            listeners[i] = l
        }
    }
}

// MARK: - App icons

/// The real icon of the app a port belongs to, pulled from the running process
/// itself rather than guessed from its name.
///
/// The expensive half is NOT the image — NSWorkspace reads it from a local
/// bundle in microseconds. It's deciding WHICH bundle a pid belongs to, and the
/// answer is already in argv[0] from the ps call the scanner makes anyway, so
/// this costs no extra shell work at all. What the cache buys is not repeating
/// the icon decode on every 4-second refresh: keyed on bundle path, so Figma's
/// three ports share one lookup, and a negative cache stops non-app processes
/// (node, bun, postgres binaries outside a bundle) from re-walking every tick.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    /// Walk the command line for the FIRST ".app" — first, not last, because a
    /// helper nested inside a bundle (Arc's Browser, Figma's agent) should wear
    /// the icon of the app you'd recognise, not its own.
    static func bundlePath(inCommandLine args: String) -> String? {
        guard args.hasPrefix("/") else { return nil }
        if let r = args.range(of: ".app/") {
            return String(args[args.startIndex..<r.lowerBound]) + ".app"
        }
        return nil
    }

    static func icon(for listener: Listener) -> NSImage? {
        guard let path = bundlePath(inCommandLine: listener.args) else { return nil }
        if let hit = cache[path] { return hit }
        if misses.contains(path) { return nil }
        guard FileManager.default.fileExists(atPath: path) else {
            misses.insert(path); return nil
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        cache[path] = image
        return image
    }

    /// A group wears the icon of its first member that has one — groups are named
    /// after a concrete app, so that member is the app the group is about.
    static func icon(forGroup members: [Listener]) -> NSImage? {
        members.lazy.compactMap { icon(for: $0) }.first
    }
}

// MARK: - Claude CLI

/// Descriptions go through the already-authenticated `claude` CLI rather than a
/// raw API key — nothing to configure, and it bills to the existing plan.
enum Claude {
    /// Neutral cwd: spawning the CLI inside a project makes it inherit that
    /// project's CLAUDE.md and answer as that project's assistant instead of
    /// doing the job asked.
    static let scratch = NSTemporaryDirectory() + "ports-describe"

    /// First choice, and the one to fall back to when it's unreachable. A model
    /// outage shouldn't take the whole app's judgement offline — haiku's answer
    /// for "what is this server" is worth far more than no answer, as long as
    /// the row says which one it came from.
    static let primary = "claude-sonnet-5"
    static let backup = "claude-haiku-4-5-20251001"

    static func ask(_ prompt: String, tag: String, model: String = primary) -> String? {
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let file = scratch + "/prompt-\(tag).txt"
        guard (try? prompt.write(toFile: file, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(atPath: file) }

        // A default `claude -p` is a full interactive session in miniature: it
        // boots every MCP server in the user's global config (node, browser
        // drivers — hundreds of MB and a live network connection each), fires
        // every session hook, and writes a transcript to disk. Multiply that by
        // one call per port and a menubar utility becomes the heaviest thing
        // running. We want one model answer, so we ask for exactly that:
        //   --strict-mcp-config      no MCP servers (none are passed)
        //   --no-session-persistence no transcript per description
        //   AGENT_MONITOR_IGNORE     stay out of the agent monitor panel
        // (--bare would also do this but it skips the keychain read, so the CLI
        // comes back not-logged-in. Don't reach for it.)
        let out = Shell.login(
            "AGENT_MONITOR_IGNORE=1 claude -p --model \(model) "
            + "--strict-mcp-config --no-session-persistence "
            + "\"$(cat '\(file)')\" 2>/dev/null",
            cwd: scratch, timeout: 90)
        // The CLI can wrap JSON in a fence or a sentence; take the object.
        guard let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}") else {
            return nil
        }
        return String(out[start...end])
    }
}

// MARK: - Voice

/// Who the sentence is written for. Same facts, same judgement, different
/// register — this changes only the wording instruction in the prompt, never
/// what counts as safe to kill.
enum Voice: String, CaseIterable, Identifiable {
    case simple, technical
    var id: String { rawValue }
    var title: String { self == .simple ? "Simple" : "Technical" }

    var instruction: String {
        switch self {
        case .technical:
            return """
            Write for a developer. Use the real names of tools, frameworks and \
            runtimes — say "Vite dev server for arrusted-development", not "a \
            preview of a website". Precision beats friendliness.
            """
        case .simple:
            return """
            Write for someone who is not a programmer. No jargon: no "daemon", \
            "localhost", "process", "server", "runtime", "instance". Name the \
            app or the work it belongs to and say what it is doing in ordinary \
            words, then what would happen if it stopped — "Part of Figma. \
            Closing it just means Figma reopens it next time." Short and calm, \
            never condescending. The label may still be a product's real name.
            """
        }
    }

    static var current: Voice {
        Voice(rawValue: UserDefaults.standard.string(forKey: "voice") ?? "") ?? .technical
    }
}

// MARK: - Description engine (pass 1: each port on its own)

/// One Sonnet call per distinct server, cached to disk. Calls are serialized on
/// a single queue — thirty listeners appearing at once should be a queue, not
/// thirty concurrent CLI processes.
final class Describer: ObservableObject {
    @Published private(set) var cache: [String: PortDesc] = [:]
    @Published private(set) var pending: Set<String> = []
    /// Keys whose last lookup came back empty — model outage, no login, a CLI
    /// that timed out. Deliberately NOT persisted: it's a fact about right now,
    /// and the next launch deserves a fresh try.
    @Published private(set) var failed: Set<String> = []
    /// Not persisted here — Store.setVoice saves it. Headless runs override this
    /// per-invocation and must not rewrite her setting.
    @Published var voice: Voice = .current

    private let queue = DispatchQueue(label: "ports.describe")
    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/ports-cache-v2.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: PortDesc].self, from: data) {
            cache = decoded
        }
    }

    /// Descriptions are cached per voice as well as per fingerprint, so switching
    /// register is paid for once and switching back is instant. Technical keeps
    /// the bare fingerprint as its key on purpose: every entry written before
    /// voices existed was written in that register, so they all stay valid.
    private func key(_ l: Listener, _ v: Voice) -> String {
        v == .technical ? l.fingerprint : "\(l.fingerprint)|\(v.rawValue)"
    }

    func desc(for l: Listener) -> PortDesc? { cache[key(l, voice)] }
    func isPending(_ l: Listener) -> Bool { pending.contains(key(l, voice)) }
    /// The last attempt for this port didn't reach the model. The row still shows
    /// the fallback text, but it has to SAY so — an unreachable model that quietly
    /// writes "Running in /some/path" looks exactly like an answer, and the button
    /// looks like it did nothing.
    func didFail(_ l: Listener) -> Bool { failed.contains(key(l, voice)) }

    /// Descriptions in the current voice, keyed by plain fingerprint, for the
    /// grouping pass — which doesn't need to know voices exist.
    func snapshot(_ listeners: [Listener]) -> [String: PortDesc] {
        listeners.reduce(into: [:]) { out, l in out[l.fingerprint] = desc(for: l) }
    }

    func describe(_ l: Listener) {
        let v = voice
        let key = key(l, v)
        if cache[key] != nil || pending.contains(key) { return }
        pending.insert(key)
        failed.remove(key)
        queue.async { [weak self] in
            guard let self else { return }
            let answer = self.request(l, v)
            DispatchQueue.main.async {
                self.cache[key] = answer ?? self.fallback(l)
                self.pending.remove(key)
                if answer == nil { self.failed.insert(key) }
                // Only a real answer earns a place on disk. Caching a fallback
                // would make one bad minute permanent: the port would never be
                // asked about again, because `describe` skips anything cached.
                if answer != nil { self.persist() }
            }
        }
    }

    /// Wipe one entry so a wrong description can be re-asked. Only the current
    /// voice's copy — the other one wasn't what she was looking at.
    func forget(_ l: Listener) {
        cache.removeValue(forKey: key(l, voice))
        persist()
        describe(l)
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL) }
    }

    private func prompt(_ l: Listener, _ voice: Voice) -> String {
        var facts = ["port: \(l.port)", "process: \(l.command)"]
        if !l.args.isEmpty { facts.append("argv: \(l.args.prefix(300))") }
        if !l.cwd.isEmpty { facts.append("cwd: \(l.cwd)") }
        if !l.project.isEmpty { facts.append("package.json name: \(l.project)") }
        if !l.remote.isEmpty { facts.append("git origin: \(l.remote)") }
        return """
        You identify servers listening on a developer's localhost. Facts:
        \(facts.joined(separator: "\n"))

        Reply with ONLY a JSON object, no prose, no code fence:
        {"label": "<=24 chars, what to call it", \
        "description": "one sentence, in the register described below, that \
        the reader can act on", \
        "confidence": "high|medium|low", \
        "safe_to_kill": true|false}

        Say what it plainly is. If the facts do not identify it, say so and set \
        confidence low — do not invent a project.

        \(voice.instruction)

        safe_to_kill describes the KIND of process, not whether it is busy right \
        now (the app measures that separately and combines the two). It is true \
        only for something the developer started that they can restart at will \
        with nothing at stake: dev servers, watchers, build tools, throwaway \
        preview or PR checkouts, especially ones running out of a temp directory. \
        It is false for OS daemons, vendor background agents (Adobe, Logitech, \
        Figma, Dropbox), databases, message brokers, anything holding state that \
        could be lost, and anything you could not identify. When unsure, false.
        """
    }

    /// Sonnet, then haiku, then nothing. Both failing is a real outage (or no
    /// login), which is the case the row has to admit to rather than paper over.
    private func request(_ l: Listener, _ voice: Voice) -> PortDesc? {
        let p = prompt(l, voice)
        if let d = decode(Claude.ask(p, tag: "p\(l.port)", model: Claude.primary)) { return d }
        guard var d = decode(Claude.ask(p, tag: "p\(l.port)-b", model: Claude.backup))
        else { return nil }
        d.fallbackModel = "haiku"
        return d
    }

    private func decode(_ json: String?) -> PortDesc? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(PortDesc.self, from: Data(json.utf8))
    }

    /// Never leave a row blank because a call failed.
    private func fallback(_ l: Listener) -> PortDesc {
        PortDesc(label: l.project.isEmpty ? l.command : l.project,
                 description: l.cwd.isEmpty ? "Running as \(l.command)." : "Running in \(l.cwd).",
                 confidence: "low",
                 safeToKill: false)
    }
}

// MARK: - Grouping (pass 2: every port at once)

/// Pass 1 sees each port in isolation, which is why five ports out of one
/// monorepo all end up labelled with the monorepo's name. This pass sees the
/// whole board — the only way to say which is which is to compare them.
final class Grouper: ObservableObject {
    @Published private(set) var groups: [PortGroup] = []
    @Published private(set) var working = false
    /// Group notes sit above the rows, so they follow the same register.
    var voice: Voice = .current

    private var lastKey = ""
    private var lastAttempt: Date?
    /// Cheapest possible ceiling on pass 2: at most one call per this window,
    /// no matter how much the port set thrashes.
    private static let minInterval: TimeInterval = 120
    private let queue = DispatchQueue(label: "ports.group")
    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/ports-groups.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: [PortGroup]].self, from: data),
           let entry = decoded.first {
            lastKey = entry.key
            groups = entry.value
        }
    }

    /// Re-groups only when the SET of ports changes, not when metrics move.
    func group(_ listeners: [Listener], descs: [String: PortDesc], force: Bool = false) {
        // Voice is part of the key: relaunching in simple mode must not restore
        // notes that were written for a developer.
        let key = voice.rawValue + ";"
            + listeners.map { $0.fingerprint }.sorted().joined(separator: ";")
        guard force || key != lastKey, !working, !listeners.isEmpty else { return }
        // Killing something is not a reason to re-group. The remaining ports
        // belong exactly where they already were, and asking again mid-cleanup
        // rewrites the list under her hands while she's working down it. Only
        // an ARRIVAL — a port nothing currently accounts for — needs the model.
        if !force, !groups.isEmpty,
           listeners.allSatisfy({ l in groups.contains { $0.ports.contains(l.port) } }) {
            lastKey = key
            return
        }
        // Wait until pass 1 has something to say before asking pass 2.
        guard force || listeners.allSatisfy({ descs[$0.fingerprint] != nil }) else { return }
        // A floor between calls. Without it, a machine whose port set churns —
        // a watcher cycling, a build opening an ephemeral port — asks the model
        // to re-group every poll, and each ask is a fresh CLI process.
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < Self.minInterval {
            return
        }
        lastAttempt = Date()

        working = true
        let prompt = self.prompt(listeners, descs: descs)
        queue.async { [weak self] in
            let result = Claude.ask(prompt, tag: "groups").flatMap {
                try? JSONDecoder().decode(GroupResult.self, from: Data($0.utf8))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                // Claim the key even on failure. Leaving it unclaimed meant a
                // failed or slow call was retried on the very next 4s poll,
                // forever — one ~500MB CLI process after another, each one
                // uploading the whole board. That is a leak, not a retry.
                self.lastKey = key
                guard let result else { return }
                self.groups = result.groups
                if let data = try? JSONEncoder().encode([key: result.groups]) {
                    try? data.write(to: self.cacheURL)
                }
            }
        }
    }

    private func prompt(_ listeners: [Listener], descs: [String: PortDesc]) -> String {
        let rows = listeners.map { l -> String in
            var bits = ["port \(l.port)", l.command]
            if let d = descs[l.fingerprint] { bits.append(d.label) }
            if !l.project.isEmpty { bits.append("pkg:\(l.project)") }
            if !l.cwd.isEmpty { bits.append("cwd:\(l.cwd)") }
            if !l.args.isEmpty { bits.append("argv:\(l.args.prefix(160))") }
            bits.append(l.connections > 0 ? "\(l.connections) open connections" : "no connections")
            bits.append(String(format: "%.0f%% cpu", l.cpuPercent))
            bits.append("up \(l.ageDays)d")
            return "- " + bits.joined(separator: " | ")
        }.joined(separator: "\n")

        return """
        Here is every port listening on one developer's mac, with what each was \
        individually identified as, plus live activity:

        \(rows)

        Sort these into a few groups that would make sense in a menubar list.

        HOW THE NOTES MUST BE WORDED (this is the part most often got wrong — \
        the facts above are written for a developer, the note is not):
        \(voice.instruction)

        Reply with ONLY JSON, no prose, no code fence:
        {"groups": [{"name": "<=28 chars", "note": "one short line about the \
        group as a whole", "ports": [3000, 3001]}]}

        Rules:
        - Every port appears in exactly one group. Do not drop any.
        - Group by what the developer would think of as one thing: a single \
        monorepo's dev servers, one PR preview checkout, macOS system services, \
        helper processes belonging to other installed apps, databases.
        - NAME GROUPS AFTER THE CONCRETE THING, using the actual app or repo \
        names in the rows — "Figma & Logitech helpers", not "Vendor Agents". \
        Abstract business words (vendor, client, service, platform, agent) are \
        very likely to also be the name of something the developer is building, \
        and a group called Vendor next to their own vendor code reads as a \
        mistake. Prefer the proper noun; it is never ambiguous.
        - Order groups so the ones the developer might want to clean up come \
        first and untouchable system things come last.
        - In the note, say what distinguishes this group, and call out anything \
        that looks forgotten: nothing is connected to it, it is doing no work, \
        and it has been running for days. Describe that condition in words that \
        fit the register — do not paste the raw metrics back out.

        Reminder, because it is the easiest thing to drop: the notes are read in \
        the \(voice.title.lowercased()) register described above.
        """
    }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var listeners: [Listener] = []
    @Published var lastScan = Date()

    /// True while a scan SHE asked for is running. Deliberately not the same as
    /// `scanning`: the 4s background sweep must never light the button up, or
    /// the panel looks permanently busy doing nothing she asked for.
    @Published private(set) var rescanning = false

    /// Bumped every time the panel is shown, so the entrance can replay. The
    /// hosting view outlives the window, so `onAppear` fires exactly once ever.
    @Published var opens = 0

    let describer = Describer()
    let grouper = Grouper()
    private var timer: Timer?
    private var scanning = false
    private var bag = Set<AnyCancellable>()

    init() {
        // Republish so rows redraw when a description or grouping lands.
        describer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        grouper.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        // A scan shells out. If one ever runs long, a 4s timer would stack a
        // second on top of it, then a third — load makes scans slower, which
        // stacks more of them. Never more than one in flight.
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let found = Scanner.scan()
            defer { DispatchQueue.main.async { self.scanning = false } }
            DispatchQueue.main.async {
                self.listeners = found
                self.lastScan = Date()
                for l in found { self.describer.describe(l) }
                self.grouper.group(found, descs: self.describer.snapshot(found))
            }
        }
    }

    /// The rescan button's entry point, as opposed to the timer's.
    ///
    /// An lsof sweep often finishes in under 100ms, and a spinner that appears
    /// and vanishes inside two frames reads as a flicker or a bug rather than
    /// as work — so the indicator is held for a beat even when the scan beats
    /// it. Showing the state for longer than the work took is the honest
    /// choice here: the alternative is showing nothing at all.
    func rescan() {
        guard !rescanning else { return }
        rescanning = true
        let floor = DispatchTime.now() + .milliseconds(500)
        refresh()
        DispatchQueue.main.asyncAfter(deadline: floor) { [weak self] in
            self?.rescanning = false
        }
    }

    func regroup() {
        grouper.group(listeners, descs: describer.snapshot(listeners), force: true)
    }

    /// Switching voice re-asks for every description in the new register (once —
    /// they cache per voice) and re-groups, so the group notes don't stay in the
    /// old register above the new rows.
    func setVoice(_ v: Voice) {
        guard v != describer.voice else { return }
        describer.voice = v
        grouper.voice = v
        UserDefaults.standard.set(v.rawValue, forKey: "voice")
        for l in listeners { describer.describe(l) }
        grouper.group(listeners, descs: describer.snapshot(listeners), force: true)
    }

    func kill(_ l: Listener) {
        Shell.run("/bin/kill", ["-TERM", "\(l.pid)"])
        refresh()
    }

    /// Quit every process in one group. Distinct pids only — sibling ports can
    /// share a pid (one server listening twice), and sending TERM to the same pid
    /// twice is how you turn a clean shutdown into a race.
    func killGroup(_ members: [Listener]) {
        for pid in Set(members.map { $0.pid }) {
            Shell.run("/bin/kill", ["-TERM", "\(pid)"])
        }
        refresh()
    }

    func killAllFree() {
        for l in freeToKill { Shell.run("/bin/kill", ["-TERM", "\(l.pid)"]) }
        refresh()
    }

    var freeToKill: [Listener] {
        listeners.filter { $0.freeToKill(describer.desc(for: $0)) }
    }

    /// Grouped view, falling back to one flat group until pass 2 lands.
    var sections: [(PortGroup, [Listener])] {
        guard !grouper.groups.isEmpty else {
            return [(PortGroup(name: "All ports", note: "", ports: []), listeners)]
        }
        var claimed = Set<Int>()
        var out: [(PortGroup, [Listener])] = []
        for g in grouper.groups {
            let members = listeners.filter { g.ports.contains($0.port) }
            claimed.formUnion(members.map { $0.port })
            if !members.isEmpty { out.append((g, members)) }
        }
        // A port the grouping missed must still be visible.
        let rest = listeners.filter { !claimed.contains($0.port) }
        if !rest.isEmpty {
            out.append((PortGroup(name: "Ungrouped", note: "", ports: []), rest))
        }
        return out
    }
}

// MARK: - UI

/// Straight from the Figma spec (port-monitor-design-spec.md, frame 40).
/// One surface hue — #EEEEFF — at different alphas, and three text greys.
/// Deliberately fixed rather than semantic: this is a light, warm-lavender
/// design that sits on her wallpaper, and it should look the same in dark mode.
enum T {
    static let surface = Color(red: 238/255, green: 238/255, blue: 255/255)
    static let card = surface.opacity(0.50)
    static let headerFill = surface.opacity(0.20)
    static let headerLine = surface.opacity(0.55)
    static let rowLine = surface.opacity(0.44)
    static let footerFill = surface.opacity(0.05)

    /// The same hue, much weaker, for the glass surface. Liquid Glass supplies
    /// its own depth — refraction, the specular edge, the shadow — so the tint
    /// only has to keep the cards lavender rather than build the surface. At
    /// the tinted variant's 0.50 the glass reads as frosted plastic instead.
    static let glassTint = surface.opacity(0.16)

    static let heading = Color(red: 0x4E/255, green: 0x52/255, blue: 0x53/255)
    static let subheading = Color(red: 0xA9/255, green: 0xAD/255, blue: 0xAF/255)
    static let paragraph = Color(red: 0x74/255, green: 0x77/255, blue: 0x78/255)
    static let dim = paragraph.opacity(0.44)
    static let highlight = Color(red: 0xF8/255, green: 0xF8/255, blue: 0xF9/255)

    static let cardWidth: CGFloat = 356
    static let cardGap: CGFloat = 16
    static let radius: CGFloat = 32
    /// The collapsed card is a pill, per the spec's last frame.
    static let collapsedRadius: CGFloat = 40

    /// A tight shadow, not a soft halo: it should read as the card sitting a
    /// couple of millimetres off the desktop, not glowing at it.
    static let shadowRadius: CGFloat = 6
    static let shadowDrop: CGFloat = 3
    static let shadowInk = Color.black.opacity(0.22)

    /// Breathing room the shadow needs on every side. Any container tighter
    /// than this slices the shadow off, and a sliced shadow makes floating
    /// cards look printed on a rectangle again.
    ///
    /// Not derived from `shadowRadius` any more. Liquid Glass casts a shadow of
    /// its own that we don't set and can't measure, and it spreads noticeably
    /// wider than ours — deriving the padding from our numbers sized the gutter
    /// for the tinted variant and clipped the glass one. This is one generous
    /// figure that clears both. It costs nothing but transparent margin.
    ///
    /// 48, measured rather than guessed. At 22 a pixel scan of the panel still
    /// found a hard step of ~1.5 grey levels exactly on the window boundary —
    /// faint, but perfectly straight over 1500px, and the eye is very good at
    /// straight. Liquid Glass's ambient shadow has a much longer tail than its
    /// visible core, so this is about where the tail dies, not where the shadow
    /// looks like it ends.
    static let shadowPad: CGFloat = 48

    /// Empty reserved band under the last row. Was 36 straight from the spec,
    /// which left the last item stranded above a hole.
    static let footerHeight: CGFloat = 14

    /// Icon boxes, spec sizes: 16 in a group header, 14 in a row.
    /// See ActionIcon for why the glyph inside is drawn smaller than the box.
    static let groupIcon: CGFloat = 16
    static let rowIcon: CGFloat = 14
    /// The spec's 2px/4px icon gaps assume heroicons' 24px boxes, which carry
    /// their own internal padding. SF Symbols don't, so a literal 2 reads as
    /// touching — this is that gap measured optically instead of numerically.
    static let iconGap: CGFloat = 6

    /// Hit-target padding around each action glyph, as a fraction of its box.
    /// This is also what sets the gap between adjacent icons — they sit at
    /// spacing 0 and their own padding is the space. Tightened from 0.28: the
    /// glyphs are small and delicate, and at 0.28 they read as three unrelated
    /// buttons instead of one cluster of related verbs.
    static let iconPadRatio: CGFloat = 0.16

    /// The spec calls for Geist / Geist Mono. Neither is installed, so this is
    /// SF at Geist's metrics — same sizes, same tracking. Swapping in the real
    /// face later is two lines here and nothing anywhere else.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// heroicons (24/outline) → the closest SF Symbols, in the spec's order.
enum Icon {
    static let open = "macwindow"
    static let refetch = "arrow.triangle.2.circlepath"
    static let kill = "xmark.circle"
    static let armed = "exclamationmark.octagon.fill"
}

/// One action glyph, sized by its BOX rather than its point size.
///
/// `.font(.system(size: 16))` on an SF Symbol does not produce a 16pt mark — the
/// point size is a type metric, so the drawn glyph overshoots its nominal box by
/// a quarter or more. Setting the box and drawing the glyph at ~0.72 of it puts
/// the mark at the size the spec actually asks for, and makes the gaps between
/// icons mean what they say.
struct ActionIcon: View {
    let name: String
    let box: CGFloat
    var tint: Color = T.heading
    /// Bumped on every click. The glyph bounces when this changes — the
    /// confirmation that the press actually fired something, which the press
    /// scale alone can't give you (it happens whether or not anything ran).
    var bounce: Int = 0
    /// Work is in flight for this control.
    var busy: Bool = false

    @State private var hovering = false

    var body: some View {
        Image(systemName: name)
            .font(.system(size: box * 0.72, weight: .light))
            .foregroundStyle(tint)
            .symbolEffect(.bounce.down, options: .speed(1.8), value: bounce)
            .modifier(Spinning(active: busy))
            .frame(width: box, height: box)
            // A hit target you can feel. The glyph stays the spec size; the
            // pad around it is what your cursor actually lands on, and the
            // backing appearing under it is the only thing telling you this
            // is a control at all before you commit to clicking it.
            .padding(box * T.iconPadRatio)
            .background {
                RoundedRectangle(cornerRadius: box * 0.45, style: .continuous)
                    .fill(T.heading.opacity(hovering ? 0.10 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}

/// Turns a glyph while work is in flight, and finishes the turn on the way out.
///
/// Snapping back to 0 the instant the work lands reads as a glitch — the eye
/// sees the reversal, not the completion. Running on to the next whole
/// revolution costs at most a few hundred ms and reads as "done" instead.
struct Spinning: ViewModifier {
    let active: Bool
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            // One finite turn at a time in a loop, NOT `.repeatForever`. A
            // repeating animation in SwiftUI outlives the value that started
            // it — a later `withAnimation` on the same property doesn't cancel
            // it, so the glyph kept turning after the answer landed. Here the
            // loop is the repetition: cancelling the task stops the next turn
            // and the current one finishes on its own, which is also exactly
            // the "land on a whole revolution" ending we wanted anyway.
            .task(id: active) {
                guard active, !Motion.reduced else { return }
                while !Task.isCancelled {
                    withAnimation(.linear(duration: 0.85)) { angle += 360 }
                    try? await Task.sleep(for: .milliseconds(850))
                }
            }
            // Reduce-motion still needs to say "busy", just not by moving.
            .opacity(Motion.reduced && active ? 0.45 : 1)
    }
}

/// One action glyph wired as a button: click bounce, in-flight spin, tooltip,
/// press feedback. Everything actionable in the panel goes through this, so the
/// six verbs can't drift apart in behaviour.
struct ActionButton: View {
    let icon: String
    let tip: String
    let action: () -> Void
    var box: CGFloat = T.groupIcon
    var tint: Color = T.heading
    var busy: Bool = false

    @State private var fired = 0

    var body: some View {
        Button {
            fired &+= 1
            action()
        } label: {
            ActionIcon(name: icon, box: box, tint: tint, bounce: fired, busy: busy)
        }
        .buttonStyle(ActionButtonStyle())
        .tip(tip)
    }
}

/// Press feedback for the six action glyphs.
///
/// `.borderless` gives none on macOS: the icon sits there while the click
/// happens somewhere out of sight, and you can't tell a working button from a
/// dead one. This is the smallest honest answer — it moves under your finger.
struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.55 : 1)
            // Down and up are NOT the same curve. Down snaps because you're
            // waiting on it; up springs because nothing is.
            .animation(configuration.isPressed ? Motion.press : Motion.release,
                       value: configuration.isPressed)
    }
}

struct Row: View {
    let listener: Listener
    @ObservedObject var describer: Describer
    let onKill: () -> Void
    let onRefetch: () -> Void

    @State private var hovering = false
    @State private var armed = false

    private var desc: PortDesc? { describer.desc(for: listener) }
    private var loading: Bool { describer.isPending(listener) }
    private var failed: Bool { describer.didFail(listener) }

    /// command · started · memory — everything except the activity word, which is
    /// drawn separately because its colour carries meaning (dim = idle,
    /// bright = something is actually connected).
    /// pid is not in here; it moved under the port number in the left rail. It's
    /// an identifier, not a status, and it reads as one when it sits with the port.
    private var meta: String {
        var parts = [listener.command]
        if !listener.startedLabel.isEmpty { parts.append(listener.startedLabel) }
        if !listener.memoryLabel.isEmpty { parts.append(listener.memoryLabel) }
        return parts.joined(separator: "  ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // verbatim: SwiftUI's "\(int)" interpolation applies locale grouping
            // and renders port 45623 as "45,623".
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: String(listener.port))
                    .font(T.mono(11, .medium))
                    .tracking(-0.11)
                    .foregroundStyle(T.heading)
                    .frame(width: 42, alignment: .leading)
                Text(verbatim: "pid \(listener.pid)")
                    .font(T.ui(8))
                    .tracking(-0.08)
                    .foregroundStyle(T.paragraph)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(desc?.label ?? listener.command)
                        .font(T.ui(11, .semibold))
                        .tracking(-0.11)
                        .foregroundStyle(T.heading)
                        .lineLimit(1)

                    if failed {
                        Pill("no answer", .red)
                            .tip("Couldn't reach either model — this line is guessed from the process itself. Click the refetch arrow to try again.")
                    } else if let m = desc?.fallbackModel {
                        // Grey, not orange. This isn't a warning, it's a
                        // footnote about where the sentence came from.
                        Pill(m, T.paragraph)
                            .tip("Sonnet was unreachable, so \(m) answered this one. Refetch to ask again.")
                    }
                    if desc?.confidence == "low" {
                        Text("?").font(T.ui(10, .bold)).foregroundStyle(.orange)
                    }
                    if listener.freeToKill(desc) {
                        Pill("free to kill", .green)
                    } else if desc?.safeToKill == true {
                        // Killable in principle, but something is using it now.
                        Pill("in use", .blue)
                    }
                    if listener.connections == 0, listener.cpuPercent < 1, listener.ageDays >= 2 {
                        Pill("forgotten?", .purple)
                    }
                    if !listener.isLocalOnly {
                        Pill("network", .orange)
                    }

                    Spacer(minLength: 4)

                    // Always laid out, only faded — revealing controls on hover
                    // was making every row jump.
                    actions
                }

                Text(loading ? "identifying…" : (desc?.description ?? " "))
                    .font(T.ui(11))
                    .tracking(-0.11)
                    .lineSpacing(3)
                    .foregroundStyle(T.heading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(verbatim: meta)
                        .foregroundStyle(T.paragraph)
                    Text(verbatim: listener.activityLabel)
                        .foregroundStyle(listener.connections > 0 ? T.highlight : T.dim)
                }
                .font(T.ui(10))
                .tracking(-0.1)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(hovering ? T.surface.opacity(0.18) : .clear)
        .onHover { hovering = $0; if !$0 { armed = false } }
    }

    /// Same three verbs as the group header, one size down (14px vs 16px).
    private var actions: some View {
        // Spacing 0 — each glyph carries its own hit-target padding, which is
        // the gap. See ActionIcon.
        HStack(spacing: 0) {
            ActionButton(icon: Icon.open,
                         tip: "Open http://localhost:\(listener.port) in your browser",
                         action: {
                             NSWorkspace.shared.open(URL(string: "http://localhost:\(listener.port)")!)
                         },
                         box: T.rowIcon)

            ActionButton(icon: Icon.refetch,
                         tip: "Ask again what this is (throws away the cached description)",
                         action: onRefetch,
                         box: T.rowIcon,
                         busy: loading)

            ActionButton(icon: armed ? Icon.armed : Icon.kill,
                         tip: armed ? "Click again to kill pid \(listener.pid)"
                                    : "Quit this process (asks twice)",
                         action: { if armed { onKill() } else { armed = true } },
                         box: T.rowIcon,
                         tint: armed ? .red : T.heading)
        }
        .padding(.trailing, -T.rowIcon * T.iconPadRatio)
        .opacity(hovering ? 1 : 0.35)
    }
}

struct Pill: View {
    let text: String
    let tint: Color
    init(_ text: String, _ tint: Color) { self.text = text; self.tint = tint }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Tooltips
//
// Our own, not AppKit's. `.tip()` sets an NSView tooltip, and AppKit only
// shows those for the ACTIVE application — this is an accessory app that
// deliberately never activates, so every tooltip in here was silently doing
// nothing no matter how long you hovered. Making the panel key wasn't enough;
// key and active are different things.
//
// Doing it ourselves also means it can look like the rest of the app instead
// of a yellow system rectangle over the glass, and appear as fast as we want.

/// One live tooltip: its text and where the control is on screen.
struct TipItem: Equatable {
    let text: String
    let anchor: Anchor<CGRect>
}

struct TipKey: PreferenceKey {
    static let defaultValue: [TipItem] = []
    static func reduce(value: inout [TipItem], nextValue: () -> [TipItem]) {
        value += nextValue()
    }
}

/// Marks a control as having a tooltip, and reports its frame upward when the
/// cursor has rested on it long enough.
struct Tip: ViewModifier {
    let text: String
    @State private var showing = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                guard inside else { showing = false; return }
                pending = Task {
                    // Short enough to feel like an answer, long enough that
                    // sweeping the cursor across the row doesn't strobe.
                    try? await Task.sleep(for: .milliseconds(180))
                    if !Task.isCancelled { showing = true }
                }
            }
            .anchorPreference(key: TipKey.self, value: .bounds) {
                showing ? [TipItem(text: text, anchor: $0)] : []
            }
            .onDisappear { pending?.cancel() }
    }
}

extension View {
    /// Our tooltip. Replaces `.help` everywhere inside the panel.
    func tip(_ text: String) -> some View { modifier(Tip(text: text)) }
}

/// Puts the bubble under the control it belongs to — or above it, if it would
/// fall off the bottom of the panel — and never lets it hang off either side.
struct TipPlacement: ViewModifier {
    let over: CGRect
    let within: CGSize
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let gap: CGFloat = 6
        let fitsBelow = over.maxY + gap + size.height <= within.height
        let y = fitsBelow ? over.maxY + gap + size.height / 2
                          : over.minY - gap - size.height / 2
        let half = size.width / 2
        let x = min(max(over.midX, half + 6), max(half + 6, within.width - half - 6))

        return content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .position(x: x, y: y)
            // One frame of nothing rather than one frame in the wrong place:
            // the position can't be computed until the bubble has been measured.
            .opacity(size == .zero ? 0 : 1)
    }
}

/// The bubble itself.
struct TipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(T.ui(10))
            .tracking(-0.1)
            .foregroundStyle(T.heading)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 210)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(T.headerLine, lineWidth: 1))
            .shadow(color: T.shadowInk.opacity(0.5), radius: 5, y: 2)
    }
}

/// Every animation in the app, in one place.
///
/// Centralised because motion has to be consistent to read as deliberate — a
/// press that settles differently in two places reads as a bug, not a style.
/// The values follow animations.dev's standards: everything under 300ms,
/// ease-out or spring (never ease-in), and asymmetric on press-and-release.
enum Motion {
    /// macOS's own reduce-motion switch. Honoured by damping the animations
    /// rather than deleting them — motion that vanishes entirely loses the
    /// state information it was carrying.
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Folding a card open or shut.
    static var fold: Animation {
        reduced ? .easeOut(duration: 0.08) : .easeOut(duration: 0.16)
    }

    /// Finger goes down: the system answering you, so it snaps.
    static var press: Animation { .easeOut(duration: 0.05) }

    /// Finger comes up: nothing is waiting on it, so it's allowed to settle.
    /// Asymmetric with `press` on purpose — matching them makes a button feel
    /// like a switch instead of something you pushed.
    static var release: Animation {
        reduced ? .easeOut(duration: 0.09)
                : .spring(response: 0.28, dampingFraction: 0.72)
    }

    /// Hover backing fading in under the cursor.
    static var hover: Animation { .easeOut(duration: reduced ? 0.06 : 0.12) }

    /// One card arriving. A spring rather than a curve, and deliberately
    /// underdamped: at 0.76 the card travels a hair past its resting place and
    /// comes back, which is the whole difference between a card that STOPS and
    /// a card that SETTLES. That tiny return is what reads as "clicked into
    /// place" — it's the only part of this animation doing emotional work.
    /// Response 0.32 keeps it quick enough that it never feels like waiting.
    /// Written in the duration/bounce form rather than response/damping because
    /// bounce is the knob that actually controls the feeling: 0 lands dead, 0.5
    /// wobbles like jelly. 0.26 is one clean overshoot and done — the recoil you
    /// feel when something seats into a slot, not the wobble of something hung
    /// on a spring. Shorter, too (0.26 from 0.32): "tchk" is mostly about how
    /// FAST the deceleration is, and a long spring can only decelerate gently.
    static var entrance: Animation {
        reduced ? .easeOut(duration: 0.12)
                : .spring(duration: 0.28, bounce: 0.28)
    }

    /// Gap between one card starting and the next. The stagger is what makes it
    /// a list falling into place rather than a slab appearing — but it's capped
    /// (see `Entrance`) so a 20-group machine doesn't wait a second and a half
    /// for its own panel. 95ms — a third attempt, and the reason the first two
    /// failed is the card COUNT, not the gap. She has four or five groups. Four
    /// cards at 55ms is a 165ms spread against a 280ms spring: the last card
    /// starts before the first has finished, so there is no moment when only
    /// one card is moving, and without that moment there is nothing to read as
    /// individual. At 95 each card lands roughly as the next one leaves, which
    /// is the rate you'd say "thock thock thock" at.
    static let stagger: Double = 0.095
    static let staggerCap = 7
}

/// The panel's open: content travels down from the menubar and fades in, one
/// card slightly after the last.
///
/// Transform and opacity only — no layout property is animated, so this costs
/// nothing to run and can't reflow the list mid-flight. The whole sequence
/// lands inside ~310ms even on the deepest stack, which matters for something
/// opened twenty times a day: past about a third of a second an entrance stops
/// being pleasure and starts being a wait.
struct Entrance: ViewModifier {
    let shown: Bool
    let index: Int

    private var step: Int { min(index, Motion.staggerCap) }
    private var delay: Double { Double(step) * Motion.stagger }

    /// Cards further down travel further. Physically it's what you'd expect of
    /// a stack settling — the bottom of it has more room to fall — and it's the
    /// second thing that separates the cards from each other, independent of
    /// timing. Capped with the stagger, so the movement never gets big.
    private var travel: CGFloat { 22 + CGFloat(step) * 4 }

    func body(content: Content) -> some View {
        content
            // 16pt, one card gap. Deliberately small: a long slide is a card
            // ARRIVING from somewhere, and these were always here — the panel
            // just opened. Short travel plus the spring's overshoot reads as
            // taking a seat rather than flying in.
            .offset(y: shown ? 0 : -travel)
            // 2.2%. Not a zoom — you can't see it as scale, only as the card
            // gaining its last bit of weight as it lands. It's carried by the
            // same spring as the offset, so it overshoots past 1 and comes
            // back on landing: that momentary press-out is most of the "tchk".
            // Removing it makes the whole thing noticeably flatter.
            .scaleEffect(shown ? 1 : 0.978, anchor: .top)
            .opacity(shown ? 1 : 0)
            .animation(shown ? Motion.entrance.delay(delay) : nil, value: shown)
    }
}

/// What the cards are made of.
///
/// Two complete treatments rather than one with the other commented out, so
/// switching is a click at runtime and neither has to be dug back out of git.
enum Surface: String, CaseIterable, Identifiable {
    /// The Figma spec as drawn: flat lavender at 50% over a thin blur.
    case tinted
    /// macOS 26 Liquid Glass — real refraction of the desktop underneath, a lit
    /// edge, and its own shadow. The tint drops to 16% because the material is
    /// already doing the work the opacity was doing.
    case glass

    var id: String { rawValue }
    var title: String { self == .tinted ? "Tinted" : "Glass" }
}

extension View {
    /// Puts a card on the chosen surface. Everything that differs between the
    /// two variants is in here and nowhere else.
    @ViewBuilder
    func surface(_ s: Surface, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch s {
        case .tinted:
            self.background(T.card)
                .background(.ultraThinMaterial)
                .clipShape(shape)
                .shadow(color: T.shadowInk, radius: T.shadowRadius, y: T.shadowDrop)
        case .glass:
            if #available(macOS 26.0, *) {
                self.clipShape(shape)
                    .glassEffect(.regular.tint(T.glassTint), in: shape)
                    // Tighter AND darker than the tinted card's. Liquid Glass
                    // casts a wide soft one already, so ours has exactly one
                    // job left: put a crisp contact shadow right under the
                    // edge so the card reads as sitting on the desktop rather
                    // than hovering in a haze. Widening it just adds to the
                    // glow that's already there.
                    .shadow(color: T.shadowInk.opacity(0.34), radius: 3, y: 2)
            } else {
                self.background(T.card)
                    .background(.ultraThinMaterial)
                    .clipShape(shape)
                    .shadow(color: T.shadowInk, radius: T.shadowRadius, y: T.shadowDrop)
            }
        }
    }
}

/// Which groups are open, remembered between launches.
///
/// It stores the OPEN ones, not the shut ones, because shut is the default —
/// so a group the grouping pass has never produced before arrives folded, and a
/// group she opened last week is still open even after a re-group renamed
/// nothing. Names are the key; a renamed group is a new group, correctly.
enum CollapseMemory {
    private static let key = "expandedGroups"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ open: Set<String>) {
        UserDefaults.standard.set(Array(open), forKey: key)
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    /// Observed directly, not through `store`. A nested ObservableObject doesn't
    /// republish through its owner, so the busy glyphs in the headers would only
    /// have redrawn when something else on the store happened to change.
    @ObservedObject var describer: Describer
    @ObservedObject var grouper: Grouper
    /// The window is borderless and doesn't size itself, so the layout reports
    /// its own size back up and the panel follows it.
    var onSize: ((CGSize) -> Void)? = nil
    @State private var armedKillAll = false
    /// Name of the group whose kill button is armed — only ever one at a time.
    @State private var armedGroupKill: String?
    /// Groups she has explicitly opened, by name, remembered across launches.
    /// Everything defaults to shut, so this stores the exceptions — which also
    /// means a group that disappears and comes back is still open.
    @State private var expanded: Set<String> = CollapseMemory.load()

    /// Tinted or glass, remembered. Stored as the raw string so the value
    /// survives adding a third treatment later.
    @AppStorage("surface") private var surfaceRaw = Surface.glass.rawValue
    private var skin: Surface { Surface(rawValue: surfaceRaw) ?? .tinted }

    /// Card + the room its shadow needs on each side.
    static let width: CGFloat = T.cardWidth + T.shadowPad * 2

    /// Measured, not guessed — the header's height depends on its font metrics.
    @State private var headerHeight: CGFloat = 0

    /// False for one frame every time the panel is shown, so the entrance replays.
    /// The hosting view outlives the window — `onAppear` fires exactly once ever —
    /// which is why this hangs off `store.opens` rather than the view lifecycle.
    @State private var entered = false

    var body: some View {
        // The header floats OVER the list rather than stacking above it. In a
        // VStack the gap below it was the scroll view's own top padding, which
        // has to be big enough to clear the glass shadow (48) — so the gap to
        // the first card was 48 instead of the 16 every other gap uses. Here
        // the scroll content keeps its full padding and simply starts lower,
        // and the header is drawn last so it still takes its own clicks.
        ZStack(alignment: .top) {
            ScrollView {
                // One card per group, floating with real gaps between them, so a
                // group reads as an object you can act on rather than a label
                // sitting above a list.
                LazyVStack(alignment: .leading, spacing: T.cardGap) {
                    ForEach(Array(store.sections.enumerated()), id: \.element.0.name) { i, section in
                        card(section.0, members: section.1)
                            .modifier(Entrance(shown: entered, index: i))
                    }
                }
                // The padding lives INSIDE the scroll view, not around it. A
                // scroll view clips to its own bounds, so if it were only as
                // wide as a card the shadows would be shaved off at both edges
                // — which is exactly what was happening.
                .padding(.horizontal, T.shadowPad)
                .padding(.bottom, T.shadowPad)
                // Clears the floating header, then one ordinary card gap. The
                // shadow gutter is still in there — it's just above the first
                // card's own top rather than added on to it.
                .padding(.top, headerHeight + T.cardGap)
                .background(ScrollerSuppressor())
            }
            // Hidden, not narrowed. If "show scroll bars: always" is set in system
            // settings, macOS uses legacy scrollers that take real layout width —
            // so the rows reflow the moment the list gets long enough to scroll,
            // which is the jitter. An overlay scroller can't do that and a hidden
            // one certainly can't. Trackpad and wheel scrolling are unaffected.
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)

            header
                .surface(skin, radius: 24)
                .padding(.horizontal, T.shadowPad)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    headerHeight = $0
                }
                // Fades, never moves. This is the third reason the entrance read
                // as "the whole panel opening": if the header travels too, then
                // every single thing on screen is moving at once and there's no
                // fixed reference to measure the cards against. Holding it still
                // makes it the frame the cards drop INTO.
                .opacity(entered ? 1 : 0)
                .animation(Motion.entrance, value: entered)
        }
        // The panel comes from the menubar, so everything in it travels DOWN
        // from above — origin-aware, and the same direction as the click that
        // opened it. Reset to false first so the next open replays the move
        // instead of the content just being there.
        .onChange(of: store.opens) { _, _ in
            entered = false
            DispatchQueue.main.async { entered = true }
        }
        // Drawn above everything, outside every card's clip shape, so a tooltip
        // on a collapsed pill isn't sliced off by the pill it belongs to.
        .overlayPreferenceValue(TipKey.self) { tips in
            GeometryReader { proxy in
                if let tip = tips.last {
                    let box = proxy[tip.anchor]
                    TipBubble(text: tip.text)
                        .fixedSize()
                        .modifier(TipPlacement(over: box, within: proxy.size))
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
            .animation(Motion.hover, value: tips.last)
        }
        .padding(.vertical, 10)
        // The window is exactly one screen tall and hands that height down; the
        // list takes whatever is left after the header. No self-sizing, no
        // resize grip — it always opens to the bottom of the screen.
        .frame(width: PanelView.width, alignment: .top)
    }

    /// Group totals, for reading a shut card without opening it. Same tone rule
    /// as a row's status: bright means something is actually connected.
    private func totals(_ members: [Listener]) -> (text: String, active: Bool) {
        var parts: [String] = []
        let kb = members.reduce(0) { $0 + $1.rssKB }
        if kb > 0 {
            let mb = Double(kb) / 1024
            parts.append(mb >= 1024 ? String(format: "%.1f GB", mb / 1024)
                                    : String(format: "%.0f MB", mb))
        }
        let conns = members.reduce(0) { $0 + $1.connections }
        parts.append(conns == 0 ? "idle" : (conns == 1 ? "1 conn" : "\(conns) conns"))
        return (parts.joined(separator: "  "), conns > 0)
    }

    private func card(_ group: PortGroup, members: [Listener]) -> some View {
        let isCollapsed = !expanded.contains(group.name)
        return VStack(alignment: .leading, spacing: 0) {
            groupHeader(group, members: members, collapsed: isCollapsed)

            if !isCollapsed {
                Rectangle().fill(T.headerLine).frame(height: 1)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { i, l in
                        Row(listener: l,
                            describer: store.describer,
                            onKill: { store.kill(l) },
                            onRefetch: { store.describer.forget(l) })
                        if i < members.count - 1 {
                            Rectangle().fill(T.rowLine).frame(height: 1)
                        }
                    }
                }
                .padding(.vertical, 8)

                // Reserved band from the spec. Nothing lives here yet; it's what
                // gives the card weight below the last row.
                Rectangle().fill(T.rowLine).frame(height: 1)
                T.footerFill.frame(height: T.footerHeight)
            }
        }
        .frame(width: T.cardWidth, alignment: .leading)
        // The window casts no shadow of its own (it would draw a rectangle
        // around the whole panel), so each card casts its own — that's what
        // makes them read as floating. Both variants do it; see `surface`.
        .surface(skin, radius: isCollapsed ? T.collapsedRadius : T.radius)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Listening").font(T.ui(11, .bold)).tracking(-0.11)
                .foregroundStyle(T.heading)
            Text(verbatim: String(store.listeners.count))
                .font(T.ui(11)).tracking(-0.11)
                .foregroundStyle(T.subheading)

            Spacer()

            if !store.freeToKill.isEmpty {
                Button {
                    if armedKillAll { store.killAllFree(); armedKillAll = false }
                    else { armedKillAll = true }
                } label: {
                    Text(armedKillAll
                         ? "kill \(store.freeToKill.count)? click again"
                         : "kill \(store.freeToKill.count) free")
                        .font(T.ui(10, .medium))
                        .foregroundStyle(armedKillAll ? .red : .green)
                }
                .buttonStyle(.borderless)
                .tip("Quit every process tagged free to kill")
            }

            // Spacing 0 — the four universal actions are one cluster, and the
            // gap between them is each glyph's own padding. The HStack's 8pt
            // was landing on top of that and pushing them apart.
            HStack(spacing: 0) {
            Menu {
                // A Picker, not two buttons, so the current register is readable
                // without hovering — she can forget which mode she left it in.
                Picker("Wording", selection: Binding(
                    get: { store.describer.voice },
                    set: { store.setVoice($0) })) {
                    ForEach(Voice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)

                Divider()

                // Live, so the two treatments can be compared against the same
                // desktop instead of from memory.
                Picker("Surface", selection: Binding(
                    get: { skin },
                    set: { surfaceRaw = $0.rawValue })) {
                    ForEach(Surface.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                ActionIcon(name: "textformat", box: T.groupIcon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // A borderless Menu tints its own label with the system accent
            // colour, which overrode the foregroundStyle inside ActionIcon —
            // that's why this one glyph was blue while its four neighbours
            // weren't. The tint has to be set on the Menu itself.
            .tint(T.heading)
            .tip("Wording and surface — how descriptions are written, and what the cards are made of")

            ActionButton(icon: "rectangle.3.group",
                         tip: store.grouper.working
                              ? "Re-grouping now — waiting on the model"
                              : "Re-group everything — asks the model to sort all \(store.listeners.count) ports again in one pass",
                         action: { store.regroup() },
                         busy: store.grouper.working)

            ActionButton(icon: "arrow.clockwise",
                         tip: "Rescan the ports right now, instead of waiting for the next sweep",
                         action: { store.rescan() },
                         busy: store.rescanning)

            ActionButton(icon: "power",
                         tip: "Quit Tugboat — the menubar icon goes away, nothing else is touched",
                         action: { NSApp.terminate(nil) })
            }
        }
        .foregroundStyle(T.heading)
        // The glyph padding already pads the right edge; this pulls the cluster
        // back onto the card's 24pt margin.
        .padding(.horizontal, 24).padding(.vertical, 12)
        .padding(.trailing, -T.groupIcon * T.iconPadRatio)
    }

    private func groupHeader(_ g: PortGroup, members: [Listener],
                             collapsed isCollapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: T.iconGap) {
                // The disclosure half of the header, and ONLY this half, is the
                // fold target. It used to be the whole header with the buttons
                // relying on winning the gesture against their own parent —
                // which is a coin toss in SwiftUI and made the three actions
                // feel dead. Two adjacent regions with two jobs, no overlap.
                HStack(spacing: T.iconGap) {
                // Always drawn, never hidden on hover — a control that only
                // exists once you've already found it isn't an affordance.
                // Only the ROTATION changes with state: nothing in this row may
                // move or resize when the card folds, or the header appears to
                // jump as it opens.
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(T.subheading)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 8)

                if let icon = AppIcons.icon(forGroup: members) {
                    Image(nsImage: icon).resizable()
                        .frame(width: 14, height: 14)
                }
                // One line, always. A wrapping title makes that one card taller
                // than its neighbours and drags the totals down with it, so a
                // long group name silently breaks the rhythm of the stack.
                // The full name is on hover instead.
                Text(g.name)
                    .font(T.ui(11, .bold)).tracking(-0.11)
                    .foregroundStyle(T.heading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tip(g.name)
                    .padding(.trailing, 2)
                Text(verbatim: String(members.count))
                    .font(T.ui(11)).tracking(-0.11)
                    .foregroundStyle(T.subheading)

                Spacer(minLength: 8)

                // The whole point of a shut card: memory and live connections
                // for the group, so she can read it without opening it.
                let sum = totals(members)
                Text(verbatim: sum.text)
                    .font(T.ui(10)).tracking(-0.1)
                    .foregroundStyle(sum.active ? T.paragraph : T.dim)
                    .lineLimit(1)
                    .padding(.trailing, 2)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Motion.fold) {
                        if expanded.contains(g.name) { expanded.remove(g.name) }
                        else { expanded.insert(g.name) }
                    }
                    CollapseMemory.save(expanded)
                }
                // No tooltip here on purpose. A `.help` on this cluster wins the
                // whole region, including the title inside it — and the title's
                // own tooltip is the one that's load-bearing now that long names
                // truncate. A chevron doesn't need explaining; a cut-off name
                // does.

                // Two verbs here, not the row's three. "Open" is deliberately
                // absent: a group has no single URL, so the button had to guess
                // one — it opened the FIRST member's port and silently ignored
                // the rest, which is a control that lies about its own scope.
                // Spacing 0: the gap is each glyph's own hit-target padding.
                HStack(spacing: 0) {
                // Busy for as long as ANY member is still being described — one
                // click here fires N lookups, so the glyph has to keep turning
                // until the last of them lands, not the first.
                ActionButton(icon: Icon.refetch,
                             tip: "Ask again what all \(members.count) of these are",
                             action: { for l in members { store.describer.forget(l) } },
                             busy: members.contains { store.describer.isPending($0) })

                ActionButton(icon: armedGroupKill == g.name ? Icon.armed : Icon.kill,
                             tip: armedGroupKill == g.name
                                  ? "Click again to quit all \(members.count)"
                                  : "Quit every process in this group (asks twice)",
                             action: {
                                 if armedGroupKill == g.name {
                                     store.killGroup(members); armedGroupKill = nil
                                 } else {
                                     armedGroupKill = g.name
                                 }
                             },
                             tint: armedGroupKill == g.name ? .red : T.heading)
                }
                // The padding pushed the cluster off the card's right margin.
                .padding(.trailing, -T.groupIcon * T.iconPadRatio)
            }
            .foregroundStyle(T.heading)

            if armedGroupKill == g.name {
                // Naming them is the whole safety mechanism: a group kill is one
                // click from taking out a database she forgot was in here.
                Text("quit \(members.map { store.describer.desc(for: $0)?.label ?? $0.command }.joined(separator: ", "))?")
                    .font(T.ui(10, .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !g.note.isEmpty, !isCollapsed {
                Text(g.note).font(T.ui(10)).tracking(-0.1)
                    .foregroundStyle(T.paragraph)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // IDENTICAL in both states, deliberately. The spec's collapsed variant
        // insets further (px-32, py-8) and drops the title to semibold, and
        // that is exactly what made the header slide and shrink as it folded.
        // The card's radius still changes; the content does not.
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
        // No header tint when shut: with no body under it there is nothing for
        // the tint to be distinct FROM, so it just reads as a paler card.
        .background(isCollapsed ? Color.clear : T.headerFill)
        .onHover { if !$0 { armedGroupKill = nil } }
    }
}

/// `.scrollIndicators(.hidden)` is the documented way to do this and it does not
/// survive being hosted inside an NSPopover — the scroller comes back. So we walk
/// up to the real NSScrollView and turn it off there, which SwiftUI can't undo.
/// Re-applied on every update because the scroll view is recreated as rows change.
private struct ScrollerSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async { suppress(from: probe) }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { suppress(from: view) }
    }

    private func suppress(from view: NSView) {
        var next = view.superview
        while let current = next {
            if let scrollView = current as? NSScrollView {
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                scrollView.scrollerStyle = .overlay
                return
            }
            next = current.superview
        }
    }
}

// MARK: - App

/// A borderless panel that will still accept key status.
///
/// `NSWindow.canBecomeKey` is false for borderless windows, and no tooltip in
/// the panel will ever appear while it isn't key — AppKit only tracks the key
/// window for those. Overriding it is the whole fix; because the style mask is
/// `.nonactivatingPanel`, taking key still doesn't activate the app or steal
/// focus from whatever's behind it.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - The boat
//
// The menubar icon is drawn frame by frame rather than being a symbol, because
// it carries a reading: the sea it sits on gets choppier the more CPU the
// listening processes are using between them. That means a glance at the
// menubar tells you something woke up — before you've opened anything.
//
// Everything here is one template image: pure black at varying alpha, with
// `isTemplate = true`, so macOS recolours it for a light or dark menubar and
// for the highlighted state. Nothing in here picks a colour.

enum BoatIcon {
    /// Bigger than the filled version needed. Outline art costs you a pixel of
    /// stroke on every edge, so the shape inside has to be given it back.
    static let size = NSSize(width: 22, height: 18)

    /// How rough the sea is, 0…1. Not linear in CPU: the interesting range is
    /// the bottom of it. Going from nothing to one busy process is the change
    /// worth seeing; 300% to 400% is not, and a linear map would spend almost
    /// all its resolution up there where it means nothing.
    static func swell(cpu: Double) -> Double {
        min(1, pow(max(0, cpu) / 120, 0.6))
    }

    /// Frames are drawn once and kept. Redrawing every tick measured at 4.4% of
    /// a core sustained — which for THIS app is a self-refuting number: the
    /// icon telling you nothing is eating your CPU would have been eating your
    /// CPU, and would have made its own sea choppy. Quantised to a 24-step loop
    /// across 12 swell levels, so the whole animation is at most 288 tiny
    /// bitmaps generated lazily and then just handed to the button.
    static let phaseSteps = 60
    private static let swellSteps = 12
    private static var cache: [Int: NSImage] = [:]

    /// The loop has to CLOSE or there's a visible jolt where it wraps. The two
    /// sine terms advance at rates 1 and 1.4, so the smallest phase span both
    /// come home on is 10π — 6π looks like it should work and leaves the second
    /// wave 0.8π out of place.
    private static let phaseSpan = 10 * Double.pi

    static func frame(step: Int, level: Int) -> NSImage {
        let s = ((step % phaseSteps) + phaseSteps) % phaseSteps
        let key = level * phaseSteps + s
        if let hit = cache[key] { return hit }
        let img = image(phase: Double(s) / Double(phaseSteps) * phaseSpan,
                        swell: Double(level) / Double(swellSteps - 1))
        cache[key] = img
        return img
    }

    static func level(for swell: Double) -> Int {
        Int((swell * Double(swellSteps - 1)).rounded())
    }

    /// One frame. `phase` advances with time, `swell` with load.
    static func image(phase: Double, swell s: Double) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        let w = size.width, h = size.height
        let ink = NSColor.black

        // Sea. Two sine waves rather than one — a single sine reads as a
        // mechanical ripple, and their beat against each other is what makes it
        // look like water. Amplitude and speed both ride the swell; a calm sea
        // is nearly flat, which is the whole point of the reading.
        let amp = 0.5 + s * 1.9
        let base = h * 0.30
        func surface(_ x: Double) -> Double {
            base
            + sin(x / 3.1 + phase) * amp
            + sin(x / 1.7 - phase * 1.4) * amp * 0.4
        }

        // Her logo is line art, so the sea is a LINE, not a filled mass. The
        // filled version read as a grey block with a boat on it; hers reads as
        // a boat on a squiggle, which is the whole charm of the thing.
        let crest = NSBezierPath()
        crest.move(to: NSPoint(x: 0, y: surface(0)))
        for x in stride(from: 0.0, through: Double(w), by: 0.5) {
            crest.line(to: NSPoint(x: x, y: surface(x)))
        }
        crest.lineWidth = 1.1
        crest.lineCapStyle = .round
        ink.setStroke()
        crest.stroke()

        // The boat sits ON the water it's floating on: its height and its tilt
        // both come from sampling the same wave function, so it rises with the
        // crests and leans down the slope instead of being pasted on top.
        let cx = w * 0.5
        let lift = surface(Double(cx)) - base
        let slope = surface(Double(cx) + 2) - surface(Double(cx) - 2)
        // Damped and then clamped. Taking the raw slope of a rough sea heels the
        // boat past 40° — at which point it reads as capsizing rather than as a
        // busy machine, which is the wrong message from a status icon.
        let tilt = min(max(atan2(slope, 4) * 0.45, -0.26), 0.26)

        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        // Rides ON the line, not through it: the keel sits just under the
        // surface and the hull's full silhouette stays above it, because the
        // hull shape is the only thing that says "tug" at 20 pixels.
        t.translateX(by: cx, yBy: base + lift + 2.6)
        t.rotate(byRadians: CGFloat(tilt))
        t.concat()

        // Traced from her logo, not invented: bow high and rounded on the LEFT,
        // hull curving down to a flat keel, stern stepping up on the right.
        // Outline, because hers is outline — a filled silhouette at this size is
        // a different drawing wearing the same shape.
        //
        // Everything is knocked out to transparent first (`.clear` fill with
        // .copy) so the sea line doesn't show through the hull. That's what
        // makes the boat sit ON the water instead of the water running through
        // it, and it's the one thing outline art needs that filled art doesn't.
        ink.setStroke()

        let hull = NSBezierPath()
        hull.move(to: NSPoint(x: -6.2, y: 3.4))
        hull.curve(to: NSPoint(x: -3.6, y: -2.2),
                   controlPoint1: NSPoint(x: -6.4, y: 0.4),
                   controlPoint2: NSPoint(x: -5.6, y: -1.8))
        hull.line(to: NSPoint(x: 3.4, y: -2.2))
        hull.curve(to: NSPoint(x: 5.6, y: 1.0),
                   controlPoint1: NSPoint(x: 4.8, y: -2.0),
                   controlPoint2: NSPoint(x: 5.6, y: -0.6))
        hull.line(to: NSPoint(x: 6.4, y: 1.0))
        hull.line(to: NSPoint(x: 6.4, y: 2.0))
        hull.line(to: NSPoint(x: -6.2, y: 2.0))
        hull.close()
        NSColor.clear.setFill()
        NSGraphicsContext.current?.compositingOperation = .copy
        hull.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        hull.lineWidth = 1.1
        hull.lineJoinStyle = .round
        hull.stroke()

        // Wheelhouse and funnel. Same knock-out trick, same order as hers:
        // house forward of the stack, stack tall and slightly proud of it.
        for r in [NSRect(x: -2.8, y: 2.0, width: 4.0, height: 3.4),
                  NSRect(x: 1.4, y: 2.0, width: 2.0, height: 4.8)] {
            let p = NSBezierPath(roundedRect: r, xRadius: 0.5, yRadius: 0.5)
            NSColor.clear.setFill()
            NSGraphicsContext.current?.compositingOperation = .copy
            p.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            p.lineWidth = 1.1
            p.lineJoinStyle = .round
            p.stroke()
        }

        NSGraphicsContext.restoreGraphicsState()

        img.isTemplate = true
        return img
    }
}

/// Drives the icon. Kept out of the view layer entirely — it's an AppKit image
/// on a status item, and it has to keep moving whether the panel is open or not.
final class BoatAnimator {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    /// Position in the cached loop, kept as a Double so speed can vary smoothly
    /// even though the frames themselves are a fixed set.
    private var pos: Double = 0
    private var lastKey = (-1, -1)
    /// Eased toward the real figure rather than set to it, so a spike doesn't
    /// snap the sea from flat to violent in one frame.
    private var swell: Double = 0
    private var target: Double = 0

    /// 12fps, not 60. This is an app about not wasting the machine's resources —
    /// an icon that burns a core to show you that nothing is burning a core
    /// would be a joke at its own expense. At this size 12 is plenty: the water
    /// reads as water and the whole thing costs a rounding error.
    private static let fps = 12.0

    init(button: NSStatusBarButton?) {
        self.button = button
        let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common, or the sea freezes solid the entire time a menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func report(cpu: Double) { target = BoatIcon.swell(cpu: cpu) }

    private func tick() {
        swell += (target - swell) * 0.08
        // Calm water still moves, just slowly — a dead-still sea looks like a
        // frozen app rather than an idle machine. Busy water moves about three
        // times faster, which carries as much of the reading as the amplitude
        // does.
        // 0.18/tick at rest is a new frame roughly every 5 ticks — calm water
        // lapping at ~2fps. That's not a compromise, it's the point: measured
        // against a no-animation build (0.0% CPU), pushing a new image to the
        // status item costs 3.5% of a core at 12fps, and it's the menubar
        // redraw that costs it, not the drawing — caching the frames barely
        // moved the number. An app that exists to tell you what's eating your
        // machine does not get to sit there eating 3.5% of it to look nice.
        // So the frame RATE carries the reading too: still-ish water when
        // nothing's happening, and it only spends the CPU when there's
        // something to say.
        pos += 0.18 + swell * 1.6
        let step = Int(pos) % BoatIcon.phaseSteps
        let level = BoatIcon.level(for: swell)
        // Assigning the same image again still makes AppKit redraw the status
        // item, so don't. At rest this makes most ticks free.
        guard (step, level) != lastKey else { return }
        lastKey = (step, level)
        button?.image = BoatIcon.frame(step: step, level: level)
    }

    deinit { timer?.invalidate() }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: KeyablePanel!
    private var clickAway: Any?
    private let store = Store()
    private var bag = Set<AnyCancellable>()
    private var boat: BoatAnimator?

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.retireOlderInstances()
        NSApp.setActivationPolicy(.accessory)

        // AppKit's default tooltip delay is roughly a second and a half, which
        // is far too long for a panel you open, read, and dismiss in three. By
        // the time the label appeared you'd already given up and clicked. This
        // is the only knob for it, and it's per-process — it doesn't touch her
        // tooltip timing anywhere else on the machine.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 220])

        // A borderless transparent NSPanel, NOT an NSPopover. The popover paints
        // its own rounded slab and arrow BELOW the content and there is no
        // supported way to turn that off — so cards sitting on it read as one
        // container with lines drawn on it rather than as separate objects. A
        // clear window is the only way the gaps between the cards can actually
        // be the desktop. It also drops the whole class of popover-hosting bugs
        // (the scroller that came back, the wrong-display placement, the
        // focus-shift closes) because none of that chrome exists any more.
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Off deliberately: a window shadow is drawn around the window's RECT,
        // so it would outline the empty gaps too. Each card casts its own.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: PanelView(store: store,
                                                        describer: store.describer,
                                                        grouper: store.grouper))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.action = #selector(toggle)
        item.button?.target = self
        item.button?.setAccessibilityLabel("Tugboat")
        boat = BoatAnimator(button: item.button)

        store.$listeners
            .sink { [weak self] ls in
                self?.item.button?.title = " \(ls.count)"
                // Total CPU across everything that's listening — the one figure
                // here that actually moves minute to minute. Memory barely
                // changes and would leave the sea looking painted on.
                self?.boat?.report(cpu: ls.reduce(0) { $0 + $1.cpuPercent })
            }
            .store(in: &bag)
    }

    /// With two displays, NSPopover doesn't reliably place itself relative to the
    /// status item — for an accessory app it can land on whichever screen holds
    /// the focused window, which is the monitor with no menubar on it. The button
    /// always knows where it really is, so we take its rect in screen coordinates
    /// and put the popover under it ourselves. (Animation off first, or the
    /// popover animates out from the wrong screen before it gets moved.)
    /// Full height, every time: top edge under the menubar, bottom edge at the
    /// bottom of the screen (above the Dock — that's what visibleFrame means).
    /// No self-sizing off the content, so the panel is the same shape whether
    /// two ports are listening or twenty; only the list inside it changes.
    ///
    /// Horizontally it still follows the status item, because with two displays
    /// nothing else knows which screen the menubar is on — the button always
    /// knows where it really is, so we take its rect in screen coordinates.
    private func anchorUnderStatusItem() {
        guard let button = item.button, let buttonWindow = button.window else { return }

        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }

        var frame = NSRect.zero
        frame.size = CGSize(width: PanelView.width, height: bounds.height)
        frame.origin.y = bounds.minY
        // Centred on the menubar icon, but never hanging off either edge.
        frame.origin.x = min(max(rect.midX - frame.width / 2, bounds.minX),
                             bounds.maxX - frame.width)

        panel.setFrame(frame, display: true)
    }

    /// A rebuild that doesn't cleanly stop the old copy leaves it running — same
    /// menubar, same 4s poll, same model calls, silently doubled. It happened
    /// four deep before anyone noticed, so the newest copy now clears the field
    /// itself rather than trusting whoever launched it to have done the kill.
    private static func retireOlderInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let out = Shell.run("/usr/bin/pgrep", ["-x", "Tugboat"])
        for pid in out.split(separator: "\n").compactMap({ Int32($0.trimmingCharacters(in: .whitespaces)) })
        where pid != me {
            kill(pid, SIGTERM)
        }
    }

    /// Replaces what .transient used to do, but on a signal that can't be
    /// confused by a process dying: an actual click somewhere else. Global
    /// monitors don't fire for events routed to our own app, so clicking inside
    /// the panel — or on the status icon — never reaches this.
    private func watchForClickAway() {
        guard clickAway == nil else { return }
        clickAway = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.closePanel()
        }
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let clickAway { NSEvent.removeMonitor(clickAway) }
        clickAway = nil
    }

    @objc private func toggle() {
        if panel.isVisible {
            closePanel()
        } else {
            store.refresh()
            anchorUnderStatusItem()
            // Regardless: an accessory app isn't active, and ordering front the
            // ordinary way does nothing from a status-item click.
            panel.orderFrontRegardless()
            // Key, not just front. AppKit only runs tooltip tracking for the
            // key window, so with the panel merely ordered front every `.help`
            // in here was dead code — you could hover an action forever and
            // never be told what it does. `.nonactivatingPanel` is what makes
            // this safe: the panel takes key without activating the app, so
            // whatever she was typing in keeps its focus.
            panel.makeKey()
            watchForClickAway()
            // Last, and after the window is on screen: the content animates in
            // from a window that's already there, so the first frame of the
            // move isn't spent waiting on the window server.
            store.opens &+= 1
        }
    }
}

// MARK: - Headless mode
//
// `./Tugboat --scan [--describe] [--group]` prints what the menubar would show.
// Exists because a running SwiftUI app can't be screenshotted from a shell —
// this is how the scanner and the model passes get verified without the GUI.

// `./Tugboat --icon <dir>` writes a strip of icon frames to PNG at 8x. The
// menubar can't be screenshotted from a shell, so this is the only way to see
// what the boat actually looks like — including at loads the machine isn't
// under right now.
if let i = CommandLine.arguments.firstIndex(of: "--icon"),
   i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let scale: CGFloat = 8
    for (n, cpu) in [0.0, 15, 60, 200, 600].enumerated() {
        let s = BoatIcon.swell(cpu: cpu)
        for f in 0..<6 {
            let src = BoatIcon.image(phase: Double(f) * 0.55, swell: s)
            let big = NSImage(size: NSSize(width: BoatIcon.size.width * scale,
                                           height: BoatIcon.size.height * scale))
            big.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .none
            NSColor.white.setFill()
            NSRect(origin: .zero, size: big.size).fill()
            src.draw(in: NSRect(origin: .zero, size: big.size))
            big.unlockFocus()
            guard let tiff = big.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/cpu\(n)-\(Int(cpu))-f\(f).png"))
        }
        print(String(format: "cpu %.0f%% → swell %.2f", cpu, s))
    }
    print("frames in \(dir)")
    exit(0)
}

if CommandLine.arguments.contains("--scan") {
    let wantDescribe = CommandLine.arguments.contains("--describe")
    let wantGroup = CommandLine.arguments.contains("--group")
    let listeners = Scanner.scan()
    let describer = Describer()
    let grouper = Grouper()
    // `--simple` / `--technical` override the saved voice for this run only, so
    // both registers can be read side by side without touching her setting.
    if CommandLine.arguments.contains("--simple") { describer.voice = .simple; grouper.voice = .simple }
    if CommandLine.arguments.contains("--technical") { describer.voice = .technical; grouper.voice = .technical }

    print("\(listeners.count) listening · \(describer.voice.title.lowercased()) wording\n")
    for l in listeners {
        let d = describer.desc(for: l)
        let tags = [l.freeToKill(d) ? "FREE" : nil,
                    d?.safeToKill == true && l.inUse ? "in-use" : nil,
                    l.connections == 0 && l.cpuPercent < 1 && l.ageDays >= 2 ? "forgotten?" : nil]
            .compactMap { $0 }.joined(separator: " ")
        print("\(String(l.port).padding(toLength: 6, withPad: " ", startingAt: 0))"
              + "\(d?.label ?? l.command)  \(tags)")
        print("       \(l.command) · pid \(l.pid) · \(l.startedLabel) · "
              + "\(l.memoryLabel) · \(l.activityLabel) · up \(l.ageDays)d")
        if let d { print("       \(d.description) [\(d.confidence)]") }
    }

    if wantDescribe || wantGroup {
        let missing = listeners.filter { describer.desc(for: $0) == nil }
        if wantDescribe && !missing.isEmpty {
            print("\ndescribing \(missing.count) uncached…")
            let group = DispatchGroup()
            for l in missing {
                group.enter()
                describer.describe(l)
                DispatchQueue.global().async {
                    while describer.desc(for: l) == nil { usleep(200_000) }
                    let d = describer.desc(for: l)!
                    print("  \(l.port)  \(d.label) — \(d.description)")
                    group.leave()
                }
            }
            // The describer commits results on main, so main must keep running.
            DispatchQueue.global().async { group.wait(); afterDescribe() }
        } else {
            DispatchQueue.global().async { afterDescribe() }
        }

        func afterDescribe() {
            guard wantGroup else { exit(0) }
            print("\ngrouping…")
            DispatchQueue.main.async {
                grouper.group(listeners, descs: describer.snapshot(listeners), force: true)
            }
            DispatchQueue.global().async {
                // `working` is set on main, which hasn't run yet when we get
                // here — and `groups` is already populated from the on-disk
                // cache, so "wait until non-empty" exits instantly and prints
                // the STALE groups. Give main a beat to start, then wait.
                usleep(600_000)
                while grouper.working { usleep(200_000) }
                for g in grouper.groups {
                    print("\n▸ \(g.name)  \(g.ports.map(String.init).joined(separator: " "))")
                    print("  \(g.note)")
                }
                exit(0)
            }
        }
        RunLoop.main.run()
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
