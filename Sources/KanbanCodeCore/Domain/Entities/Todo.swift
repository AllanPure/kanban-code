import Foundation

/// A lightweight personal todo, shared between the app (the orchestrator's Todos panel)
/// and the `kanban todo` CLI so the orchestrator agent can drive the list. Persisted in
/// ~/.kanban-code/todos.json.
public struct Todo: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var text: String
    public var done: Bool
    public var createdAt: Date
    public var project: String?
    /// Linked Odoo task id (the real `project.task` id), set when synced. nil = not linked.
    public var odooTaskId: Int?
    /// Whether this todo should be synced/published to Odoo by the orchestrator.
    public var publish: Bool

    public init(id: String = KSUID.generate(prefix: "todo"),
                text: String, done: Bool = false,
                createdAt: Date = .now, project: String? = nil,
                odooTaskId: Int? = nil, publish: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
        self.createdAt = createdAt
        self.project = project
        self.odooTaskId = odooTaskId
        self.publish = publish
    }
}

/// Synchronous read/write of ~/.kanban-code/todos.json. Todos are tiny and infrequent,
/// so plain file I/O is fine; the CLI writes the same file.
public enum TodoStore {
    public static func filePath(basePath: String? = nil) -> String {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        return (base as NSString).appendingPathComponent("todos.json")
    }

    public static func read(basePath: String? = nil) -> [Todo] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath(basePath: basePath))),
              let todos = try? JSONDecoder.iso.decode([Todo].self, from: data) else { return [] }
        return todos
    }

    public static func write(_ todos: [Todo], basePath: String? = nil) {
        let path = filePath(basePath: basePath)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(todos) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Open (not done) todos first, newest last within each group.
    public static func sorted(_ todos: [Todo]) -> [Todo] {
        todos.sorted { a, b in
            if a.done != b.done { return !a.done }
            return a.createdAt < b.createdAt
        }
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}
