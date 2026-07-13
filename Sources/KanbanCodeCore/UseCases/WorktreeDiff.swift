import Foundation

/// The change kind of a file in a worktree, relative to its base (fork point).
public enum DiffStatus: String, Sendable, Equatable {
    case added, modified, deleted, renamed, untracked

    public var letter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        }
    }
}

/// One changed file in a worktree.
public struct DiffFile: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String            // the (new) path
    public let oldPath: String?        // for renames
    public let status: DiffStatus
    public let additions: Int?         // nil = binary / unknown
    public let deletions: Int?

    public init(path: String, oldPath: String? = nil, status: DiffStatus,
                additions: Int? = nil, deletions: Int? = nil) {
        self.path = path; self.oldPath = oldPath; self.status = status
        self.additions = additions; self.deletions = deletions
    }
}

/// One rendered row of a unified diff, with resolved old/new line numbers so the UI can
/// show gutters (unified) or pair removed/added lines (split view).
public struct DiffRow: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, added, removed, hunk, meta }
    public let id: Int              // stable index within the file
    public let kind: Kind
    public let oldLine: Int?
    public let newLine: Int?
    public let text: String         // content without the +/-/space marker; hunk/meta keep full line

    public init(id: Int, kind: Kind, oldLine: Int?, newLine: Int?, text: String) {
        self.id = id; self.kind = kind; self.oldLine = oldLine; self.newLine = newLine; self.text = text
    }
}

/// The full change set of a worktree relative to its base commit.
public struct WorktreeChanges: Sendable, Equatable {
    public let baseRef: String
    public let files: [DiffFile]
    public init(baseRef: String, files: [DiffFile]) { self.baseRef = baseRef; self.files = files }
}

/// Computes "what changed in this worktree" the way the card review flow needs it:
/// every file that differs from the branch's fork point (committed work by the agent
/// PLUS uncommitted edits), and the per-file unified diff. All git-running; the parsers
/// are pure and unit-tested.
public enum WorktreeDiff {

    // MARK: - Public API

    public static func changes(worktreePath: String) async -> WorktreeChanges {
        let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        let base = await resolveBase(worktreePath: worktreePath, git: git)

        async let nameStatusOut = run(git, ["-C", worktreePath, "diff", "--name-status", "-M", base])
        async let numstatOut = run(git, ["-C", worktreePath, "diff", "--numstat", "-M", base])
        async let untrackedOut = run(git, ["-C", worktreePath, "ls-files", "--others", "--exclude-standard"])

        let tracked = mergeStatusAndNumstat(
            nameStatus: await nameStatusOut, numstat: await numstatOut)
        let untracked = (await untrackedOut)
            .split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }
            .map { DiffFile(path: $0, status: .untracked) }

        // Sort: path alphabetical, stable.
        let files = (tracked + untracked).sorted { $0.path < $1.path }
        return WorktreeChanges(baseRef: base, files: files)
    }

    /// The unified diff of one file. For untracked files, diffs against /dev/null so the
    /// whole file shows as added.
    public static func fileDiff(worktreePath: String, baseRef: String, file: DiffFile) async -> String {
        let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        if file.status == .untracked {
            // --no-index exits non-zero by design; we still want its stdout.
            return await run(git, ["-C", worktreePath, "diff", "--no-index", "--", "/dev/null", file.path])
        }
        return await run(git, ["-C", worktreePath, "diff", baseRef, "--", file.oldPath ?? file.path, file.path])
    }

    // MARK: - Base resolution

    /// The commit this worktree branched from — its upstream's merge-base, else the repo's
    /// default branch merge-base, else HEAD (uncommitted-only view).
    static func resolveBase(worktreePath: String, git: String) async -> String {
        let upstream = (await run(git, ["-C", worktreePath, "rev-parse", "--abbrev-ref",
                                        "--symbolic-full-name", "@{upstream}"]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if !upstream.isEmpty, !upstream.contains("fatal") { candidates.append(upstream) }
        candidates += ["origin/HEAD", "origin/main", "origin/master", "main", "master"]

        for candidate in candidates {
            let base = (await run(git, ["-C", worktreePath, "merge-base", "HEAD", candidate]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty, !base.contains("fatal") { return base }
        }
        return "HEAD"
    }

    // MARK: - Pure parsers (unit-tested)

    /// Merge `git diff --name-status -M` (status + rename tracking) with `git diff
    /// --numstat -M` (line counts) into DiffFiles, keyed by the new path.
    static func mergeStatusAndNumstat(nameStatus: String, numstat: String) -> [DiffFile] {
        let counts = parseNumstat(numstat)              // newPath → (add, del)
        return parseNameStatus(nameStatus).map { file in
            let c = counts[file.path]
            return DiffFile(path: file.path, oldPath: file.oldPath, status: file.status,
                            additions: c?.additions ?? file.additions,
                            deletions: c?.deletions ?? file.deletions)
        }
    }

    /// Parse `git diff --name-status -M`. Lines: `M\tpath`, `A\tpath`, `D\tpath`,
    /// `R100\told\tnew`, `C100\told\tnew`.
    static func parseNameStatus(_ output: String) -> [DiffFile] {
        output.split(separator: "\n").compactMap { line -> DiffFile? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let code = parts.first?.first else { return nil }
            switch code {
            case "A": return parts.count >= 2 ? DiffFile(path: parts[1], status: .added) : nil
            case "M": return parts.count >= 2 ? DiffFile(path: parts[1], status: .modified) : nil
            case "D": return parts.count >= 2 ? DiffFile(path: parts[1], status: .deleted) : nil
            case "R", "C":
                // R100  old  new
                return parts.count >= 3 ? DiffFile(path: parts[2], oldPath: parts[1], status: .renamed) : nil
            default:
                return parts.count >= 2 ? DiffFile(path: parts[1], status: .modified) : nil
            }
        }
    }

    /// Parse `git diff --numstat -M`. Lines: `<add>\t<del>\t<path>`; `-` for binary; renames
    /// appear as `add\tdel\tnew` (with -M) or `old => new` — we key on the last path field.
    static func parseNumstat(_ output: String) -> [String: (additions: Int?, deletions: Int?)] {
        var result: [String: (Int?, Int?)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let add = parts[0] == "-" ? nil : Int(parts[0])
            let del = parts[1] == "-" ? nil : Int(parts[1])
            // Rename numstat path can be "old => new" or brace form; take text after "=> " if present.
            var path = parts[2]
            if let range = path.range(of: " => ") { path = String(path[range.upperBound...]) }
            path = path.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            result[path] = (add, del)
        }
        return result
    }

    /// Turn a unified diff (git diff output) into rows with resolved line numbers. Hunk
    /// headers (`@@ -a,b +c,d @@`) reset the counters; +/- advance the new/old counter.
    public static func parseRows(_ diff: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldLine = 0, newLine = 0
        var id = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            defer { id += 1 }
            if raw.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(raw) { oldLine = o; newLine = n }
                rows.append(DiffRow(id: id, kind: .hunk, oldLine: nil, newLine: nil, text: raw))
            } else if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("diff ")
                        || raw.hasPrefix("index ") || raw.hasPrefix("new file") || raw.hasPrefix("deleted file")
                        || raw.hasPrefix("similarity ") || raw.hasPrefix("rename ") || raw.hasPrefix("\\ ")
                        || raw.hasPrefix("Binary ") || raw.hasPrefix("old mode") || raw.hasPrefix("new mode") {
                rows.append(DiffRow(id: id, kind: .meta, oldLine: nil, newLine: nil, text: raw))
            } else if raw.hasPrefix("+") {
                rows.append(DiffRow(id: id, kind: .added, oldLine: nil, newLine: newLine, text: String(raw.dropFirst())))
                newLine += 1
            } else if raw.hasPrefix("-") {
                rows.append(DiffRow(id: id, kind: .removed, oldLine: oldLine, newLine: nil, text: String(raw.dropFirst())))
                oldLine += 1
            } else if raw.hasPrefix(" ") {
                rows.append(DiffRow(id: id, kind: .context, oldLine: oldLine, newLine: newLine, text: String(raw.dropFirst())))
                oldLine += 1; newLine += 1
            } else if raw.isEmpty {
                continue
            } else {
                rows.append(DiffRow(id: id, kind: .meta, oldLine: nil, newLine: nil, text: raw))
            }
        }
        return rows
    }

    /// Parse `@@ -oldStart,oldCount +newStart,newCount @@` → (oldStart, newStart).
    static func parseHunkHeader(_ line: String) -> (old: Int, new: Int)? {
        // Between the two "@@" markers: "-a,b +c,d"
        guard let firstAt = line.range(of: "@@"),
              let secondAt = line.range(of: "@@", range: firstAt.upperBound..<line.endIndex) else { return nil }
        let spec = line[firstAt.upperBound..<secondAt.lowerBound].trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        func start(_ token: Substring) -> Int? {
            // token like "-a,b" or "+c" — strip sign, take the number before the comma
            let s = token.dropFirst()
            return Int(s.split(separator: ",").first ?? s)
        }
        guard let o = start(parts[0]), let n = start(parts[1]) else { return nil }
        return (o, n)
    }

    // MARK: - Private

    private static func run(_ git: String, _ args: [String]) async -> String {
        (try? await ShellCommand.run(git, arguments: args))?.stdout ?? ""
    }
}
