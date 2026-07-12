import Foundation

/// Persistent store for Link records in ~/.kanban-code/links.json.
/// Atomic writes, file locking, corruption recovery.
public actor CoordinationStore {
    private let filePath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("links.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Public API

    /// Read a best-effort snapshot without entering the actor.
    ///
    /// App termination cannot depend on scheduling an async actor hop: AppKit
    /// is already waiting for a synchronous termination decision. The regular
    /// actor-isolated API remains the source of truth for normal reads/writes.
    public static func readLinksSnapshot(basePath: String? = nil) -> [Link] {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        let filePath = (base as NSString).appendingPathComponent("links.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LinksContainer.self, from: data).links) ?? []
    }

    /// Clear killed tmux associations synchronously during app termination.
    ///
    /// Normal mutations must use the actor-isolated APIs. This narrow fallback
    /// exists because AppKit termination cannot wait for an async actor task.
    public static func clearTmuxSessionsSnapshot(
        _ sessionNames: Set<String>,
        basePath: String? = nil
    ) {
        guard !sessionNames.isEmpty else { return }
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        let filePath = (base as NSString).appendingPathComponent("links.json")
        var links = readLinksSnapshot(basePath: base)
        var changed = false

        for index in links.indices {
            guard var tmux = links[index].tmuxLink else { continue }
            let remaining = tmux.allSessionNames.filter { !sessionNames.contains($0) }
            guard remaining.count != tmux.allSessionNames.count else { continue }

            changed = true
            guard let primary = remaining.first else {
                links[index].tmuxLink = nil
                continue
            }

            tmux.sessionName = primary
            let extras = Array(remaining.dropFirst())
            tmux.extraSessions = extras.isEmpty ? nil : extras
            tmux.tabNames = tmux.tabNames?.filter { remaining.contains($0.key) }
            tmux.isPrimaryDead = nil
            links[index].tmuxLink = tmux
        }
        guard changed else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(LinksContainer(links: links)) else { return }

        let tmpPath = filePath + ".tmp"
        guard (try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: URL(fileURLWithPath: tmpPath))) != nil
        else { return }
        _ = try? FileManager.default.removeItem(atPath: filePath)
        try? FileManager.default.moveItem(atPath: tmpPath, toPath: filePath)
    }

    /// Read all links from the coordination file.
    public func readLinks() throws -> [Link] {
        let container = try readContainer()
        return container.links
    }

    private func readContainer() throws -> LinksContainer {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else {
            return LinksContainer(links: [])
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        do {
            return try decoder.decode(LinksContainer.self, from: data)
        } catch {
            // Corruption recovery: backup and return empty
            let backupPath = filePath + ".bkp"
            try? fileManager.copyItem(atPath: filePath, toPath: backupPath)
            return LinksContainer(links: [])
        }
    }

    /// Write all links to the coordination file (atomic).
    /// Also maintains a rolling set of daily snapshots under
    /// `<filePath>.daily-<YYYY-MM-DD>.bak` so we never again lose card
    /// names/columns if a bug nukes state between runs. Keeps the most
    /// recent `dailyBackupRetention` snapshots.
    public func writeLinks(_ links: [Link]) throws {
        let fileManager = FileManager.default
        let dir = (filePath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Rotate-on-write: snapshot yesterday's file (if any) before overwriting.
        rotateDailyBackupIfNeeded(fileManager: fileManager)

        let container = LinksContainer(links: links)
        let data = try encoder.encode(container)

        // Atomic write: write to .tmp, then rename
        let tmpPath = filePath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        _ = try? fileManager.removeItem(atPath: filePath)
        try fileManager.moveItem(atPath: tmpPath, toPath: filePath)
    }

    // MARK: - Daily backup rotation

    /// How many daily snapshots to keep. Old ones get pruned.
    private static let dailyBackupRetention = 7

    /// Copy the CURRENT on-disk file to `<filePath>.daily-<today>.bak` if
    /// today's snapshot doesn't exist yet. Prunes older snapshots beyond
    /// the retention window. All failures are swallowed — a backup
    /// shouldn't ever block a real write.
    private func rotateDailyBackupIfNeeded(fileManager: FileManager) {
        guard fileManager.fileExists(atPath: filePath) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let today = formatter.string(from: Date())
        let todayPath = "\(filePath).daily-\(today).bak"

        if !fileManager.fileExists(atPath: todayPath) {
            try? fileManager.copyItem(atPath: filePath, toPath: todayPath)
        }

        // Prune beyond retention.
        let parent = (filePath as NSString).deletingLastPathComponent
        let basename = ((filePath as NSString).lastPathComponent) + ".daily-"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: parent) else { return }
        let snapshots = entries
            .filter { $0.hasPrefix(basename) && $0.hasSuffix(".bak") }
            .sorted()                       // alphabetical == chronological for YYYY-MM-DD
            .map { (parent as NSString).appendingPathComponent($0) }
        if snapshots.count > Self.dailyBackupRetention {
            for path in snapshots.dropLast(Self.dailyBackupRetention) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    /// Get a single link by its id.
    public func linkById(_ id: String) throws -> Link? {
        try readLinks().first { $0.id == id }
    }

    /// Get a single link by session ID.
    public func linkForSession(_ sessionId: String) throws -> Link? {
        try readLinks().first { $0.sessionLink?.sessionId == sessionId }
    }

    /// Write a full in-memory snapshot without clobbering cards that only exist on
    /// disk. Any on-disk card whose id is NOT in `links` is preserved and appended —
    /// these are cards created out-of-process (e.g. by the `kanban` CLI) that the app
    /// hasn't merged into memory yet. Deletions never reach here (they go through the
    /// surgical `removeLink`), so a deleted card is already absent from disk and is not
    /// resurrected. Used by the `.persistLinks` effect.
    public func mergeAndWriteLinks(_ links: [Link]) throws {
        let incomingIds = Set(links.map(\.id))
        let onDisk = (try? readLinks()) ?? []
        let safe = links.map { preservingExternalFields($0, from: onDisk) }
        let preserved = onDisk.filter { !incomingIds.contains($0.id) }
        try writeLinks(safe + preserved)
    }

    /// Upsert a link: update if exists (by link.id), insert if new.
    public func upsertLink(_ link: Link) throws {
        var links = try readLinks()
        let safe = preservingExternalFields(link, from: links)
        if let index = links.firstIndex(where: { $0.id == safe.id }) {
            links[index] = safe
        } else {
            links.append(safe)
        }
        try writeLinks(links)
    }

    /// Fields owned by out-of-process writers (the `kanban` CLI / agents), never by
    /// the app: keep the on-disk value when the app rewrites a card it knows, so a
    /// concurrent app edit can't clobber a `completedAt` handoff or a `labels` chip
    /// the agent just set (independent of when the app's watcher adopts them).
    private func preservingExternalFields(_ link: Link, from onDisk: [Link]) -> Link {
        guard let disk = onDisk.first(where: { $0.id == link.id }) else { return link }
        var merged = link
        merged.completedAt = disk.completedAt
        merged.labels = disk.labels
        return merged
    }

    /// Update specific fields of a link by link.id.
    public func updateLink(id: String, update: (inout Link) -> Void) throws {
        var links = try readLinks()
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        update(&links[index])
        links[index].updatedAt = .now
        try writeLinks(links)
    }

    /// Update specific fields of a link by session ID.
    public func updateLink(sessionId: String, update: (inout Link) -> Void) throws {
        var links = try readLinks()
        guard let index = links.firstIndex(where: { $0.sessionLink?.sessionId == sessionId }) else { return }
        update(&links[index])
        links[index].updatedAt = .now
        try writeLinks(links)
    }

    /// Remove a link by its id.
    public func removeLink(id: String) throws {
        var links = try readLinks()
        links.removeAll { $0.id == id }
        try writeLinks(links)
    }

    /// Remove a link by session ID.
    public func removeLink(sessionId: String) throws {
        var links = try readLinks()
        links.removeAll { $0.sessionLink?.sessionId == sessionId }
        try writeLinks(links)
    }

    /// Remove orphaned links whose .jsonl files no longer exist.
    public func removeOrphans() throws {
        let fileManager = FileManager.default
        var links = try readLinks()
        let before = links.count
        links.removeAll { link in
            guard let path = link.sessionLink?.sessionPath else { return false }
            return !fileManager.fileExists(atPath: path)
        }
        if links.count != before {
            try writeLinks(links)
        }
    }

    /// Atomic read-modify-write: reads current links, applies transform, writes back.
    /// Runs entirely within the actor — no interleaving with concurrent reads/writes.
    public func modifyLinks(_ transform: (inout [Link]) -> Void) throws {
        var links = try readLinks()
        transform(&links)
        try writeLinks(links)
    }

    /// The file path for external access / debugging.
    public var path: String { filePath }
}

// MARK: - Codable Container

private struct LinksContainer: Codable {
    let links: [Link]
}
