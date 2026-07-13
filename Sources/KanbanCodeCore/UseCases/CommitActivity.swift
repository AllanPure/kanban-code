import Foundation

/// A day's commit activity across projects — for the "what did I work on" panel.
public struct DayCommits: Identifiable, Sendable, Equatable {
    public var id: String { day }
    public let day: String                 // "YYYY-MM-DD"
    public let total: Int
    public let byProject: [String: Int]    // project name → commit count

    public init(day: String, total: Int, byProject: [String: Int]) {
        self.day = day
        self.total = total
        self.byProject = byProject
    }
}

/// A single commit placed in time — for the day calendar / timesheet reconstruction.
public struct CommitEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: String        // commit hash
    public let time: Date        // author time
    public let project: String
    public let subject: String
    public let url: String?      // web URL of the commit (nil if the repo has no GitHub remote)

    public init(id: String, time: Date, project: String, subject: String, url: String? = nil) {
        self.id = id; self.time = time; self.project = project; self.subject = subject; self.url = url
    }
}

/// On-disk cache of parsed commits + per-repo watermark, so history is read once and
/// only new commits load thereafter (~/.kanban-code/commit-index.json).
public struct CommitIndex: Codable, Sendable {
    public var commits: [CommitEvent] = []
    public var newest: [String: Date] = [:]   // repoPath → newest indexed commit time
    public var oldest: [String: Date] = [:]   // repoPath → oldest indexed commit time
    public init() {}
}

public enum CommitIndexStore {
    static func path() -> String {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        return (base as NSString).appendingPathComponent("commit-index.json")
    }
    public static func read() -> CommitIndex {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path())),
              let idx = try? indexDecoder.decode(CommitIndex.self, from: data) else { return CommitIndex() }
        return idx
    }
    public static func write(_ index: CommitIndex) {
        let p = path()
        try? FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? indexEncoder.encode(index) else { return }
        try? data.write(to: URL(fileURLWithPath: p))
    }
    private static let indexDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let indexEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

public enum CommitActivity {
    /// Parse `git log --pretty=%H<US>%aI<US>%s` output (unit-separator `\u{1f}` fields)
    /// into timed commit events for one project. Pure/testable.
    public static func parseCommitEvents(gitOutput: String, project: String, urlBase: String? = nil) -> [CommitEvent] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return gitOutput.split(separator: "\n").compactMap { line -> CommitEvent? in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let time = iso.date(from: parts[1]) else { return nil }
            let url = urlBase.map { "\($0)/commit/\(parts[0])" }
            return CommitEvent(id: parts[0], time: time, project: project, subject: parts[2], url: url)
        }
    }

    /// Convert a git remote URL to its GitHub https base, e.g.
    /// `git@github.com:owner/repo.git` / `https://github.com/owner/repo.git` →
    /// `https://github.com/owner/repo`. nil for non-GitHub remotes.
    public static func gitHubBase(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let range = s.range(of: "git@github.com:") {
            return "https://github.com/" + s[range.upperBound...]
        }
        if s.hasPrefix("https://github.com/") || s.hasPrefix("http://github.com/") {
            return s.replacingOccurrences(of: "http://", with: "https://")
        }
        return nil
    }

    /// Aggregate per-project commit dates (one entry per commit, "YYYY-MM-DD") into
    /// per-day totals with a project breakdown, newest day first. Pure and testable.
    public static func aggregate(projectDates: [(project: String, dates: [String])]) -> [DayCommits] {
        var byDay: [String: [String: Int]] = [:]     // day → project → count
        for (project, dates) in projectDates {
            for d in dates where !d.isEmpty {
                byDay[d, default: [:]][project, default: 0] += 1
            }
        }
        return byDay
            .map { day, byProject in
                DayCommits(day: day, total: byProject.values.reduce(0, +), byProject: byProject)
            }
            .sorted { $0.day > $1.day }
    }

    /// Load recent commit activity by running `git log` in each candidate repo. An
    /// approximation: counts commits across all branches in the last `days` days.
    ///
    /// Candidates = the configured projects PLUS git repos auto-discovered by scanning
    /// the parent/grandparent directories of those projects — so work done in repos not
    /// added to Kanban Code (e.g. sibling projects under `~/docker`) is still counted.
    public static func load(projects: [Project], days: Int = 14) async -> [DayCommits] {
        let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        var perProject: [(project: String, dates: [String])] = []
        for (repo, name) in candidateRepos(projects: projects) {
            guard let out = try? await ShellCommand.run(
                git,
                arguments: ["-C", repo, "log", "--all", "--no-merges",
                            "--since=\(days) days ago", "--date=short", "--pretty=%ad"]
            ), out.succeeded else { continue }
            let dates = out.stdout.split(separator: "\n").map(String.init)
            if !dates.isEmpty { perProject.append((name, dates)) }
        }
        return aggregate(projectDates: perProject)
    }

    /// Timed commit events across all candidate repos, for the calendar. `days == nil`
    /// loads the full history (the user wants everything, not just recent weeks).
    /// Progressive, indexed commit loading. Yields the growing commit list: cached first
    /// (instant), then fresh commits, then history backfilled in widening stages (≈1 month
    /// → year → more) so recent work shows immediately and older history fills in. Only
    /// uncovered ranges are fetched, so it's incremental across runs.
    public static func loadEventsProgressive(projects: [Project]) -> AsyncStream<[CommitEvent]> {
        AsyncStream { continuation in
            Task {
                let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
                var index = CommitIndexStore.read()
                let repos = candidateRepos(projects: projects)
                let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
                var known = Set(index.commits.map(\.id))

                func yieldNow() {
                    CommitIndexStore.write(index)
                    continuation.yield(index.commits.sorted { $0.time > $1.time })
                }
                if !index.commits.isEmpty { continuation.yield(index.commits.sorted { $0.time > $1.time }) }

                // Fetch a per-repo window (parallel), merge new commits, advance watermarks.
                func pass(_ range: (String) -> (since: String, until: String?)?) async -> Bool {
                    let ranges: [(repo: String, name: String, since: String, until: String?)] = repos.compactMap { repo, name in
                        range(repo).map { (repo, name, $0.since, $0.until) }
                    }
                    let out = await withTaskGroup(of: (String, [CommitEvent]).self) { group in
                        for r in ranges {
                            group.addTask {
                                var args = ["-C", r.repo, "log", "--all", "--no-merges",
                                            "--pretty=%H\u{1f}%aI\u{1f}%s", "--since=\(r.since)"]
                                if let until = r.until { args.append("--until=\(until)") }
                                guard let o = try? await ShellCommand.run(git, arguments: args), o.succeeded else { return (r.repo, []) }
                                let remote = try? await ShellCommand.run(git, arguments: ["-C", r.repo, "remote", "get-url", "origin"])
                                let urlBase = remote.flatMap { $0.succeeded ? gitHubBase(fromRemote: $0.stdout) : nil }
                                return (r.repo, parseCommitEvents(gitOutput: o.stdout, project: r.name, urlBase: urlBase))
                            }
                        }
                        var acc: [(String, [CommitEvent])] = []
                        for await x in group { acc.append(x) }
                        return acc
                    }
                    var changed = false
                    for (repo, events) in out {
                        for e in events where !known.contains(e.id) { index.commits.append(e); known.insert(e.id); changed = true }
                        if let mx = events.map(\.time).max(), mx > (index.newest[repo] ?? .distantPast) { index.newest[repo] = mx }
                        if let mn = events.map(\.time).min(), mn < (index.oldest[repo] ?? .distantFuture) { index.oldest[repo] = mn }
                    }
                    return changed
                }

                // 1) Fresh commits for already-indexed repos (since their newest watermark).
                if await pass({ repo in index.newest[repo].map { (since: iso.string(from: $0.addingTimeInterval(-3600)), until: nil) } }) {
                    yieldNow()
                }
                // 2) Widening backfill — first ~1 month (fast), then out to years.
                for stageDays in [31, 92, 366, 1096, 3650] {
                    let target = Date().addingTimeInterval(-Double(stageDays) * 86_400)
                    let targetStr = iso.string(from: target)
                    let changed = await pass { repo in
                        if let oldest = index.oldest[repo], oldest <= target { return nil }   // already covered
                        let until = index.oldest[repo].map { iso.string(from: $0) }            // fetch [target, oldest)
                        return (since: targetStr, until: until)
                    }
                    if changed { yieldNow() }
                }
                continuation.finish()
            }
        }
    }

    /// Repo path → display name: the configured projects plus git repos auto-discovered
    /// under their parent/grandparent directories (so work in repos not added to Kanban
    /// Code, e.g. sibling projects under `~/docker`, still counts).
    static func candidateRepos(projects: [Project]) -> [String: String] {
        var repoNames: [String: String] = [:]
        for project in projects { repoNames[project.effectiveRepoRoot] = project.name }
        // Scan the parent & grandparent of each project for sibling repos — but NEVER
        // the home dir or `/` (a project directly under ~ would otherwise scan the whole
        // home directory, finding hundreds of repos and hanging the load).
        let home = NSHomeDirectory()
        var roots = Set<String>()
        for project in projects {
            let parent = (project.path as NSString).deletingLastPathComponent
            let grand = (parent as NSString).deletingLastPathComponent
            for root in [parent, grand] where root != home && root != "/" && !root.isEmpty {
                roots.insert(root)
            }
        }
        for root in roots {
            for repo in discoverGitRepos(under: root, maxDepth: 3) where repoNames[repo] == nil {
                repoNames[repo] = (repo as NSString).lastPathComponent
            }
        }
        return repoNames
    }

    /// Find git repositories under `root` (dirs containing `.git`), bounded in depth and
    /// count, skipping heavy/irrelevant subtrees. Doesn't descend into a repo once found.
    static func discoverGitRepos(under root: String, maxDepth: Int) -> [String] {
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", ".build", "dist", "vendor", "Pods",
                                 ".venv", "venv", ".git", "target", "build"]
        var found: [String] = []
        var stack: [(dir: String, depth: Int)] = [(root, 0)]
        while let (dir, depth) = stack.popLast() {
            if found.count >= 200 { break }
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                found.append(dir)
                continue // a repo — don't descend further
            }
            guard depth < maxDepth,
                  let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where !entry.hasPrefix(".") && !skip.contains(entry) {
                let path = (dir as NSString).appendingPathComponent(entry)
                // Never follow symlinks — projects often symlink to the Odoo source tree,
                // whose (huge, irrelevant) git repo we don't want to index.
                if (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    stack.append((path, depth + 1))
                }
            }
        }
        return found
    }
}
