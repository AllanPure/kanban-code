import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Task dependencies (execution-order DAG)")
struct TaskDependencyTests {
    private func card(_ id: String, dependsOn: [String]? = nil) -> Link {
        Link(id: id, name: id, column: .backlog, source: .manual, dependsOn: dependsOn)
    }

    private func stateWith(_ links: [Link]) -> AppState {
        var state = AppState()
        for link in links { state.links[link.id] = link }
        state.rebuildCards()
        return state
    }

    @Test("addCardDependency records the edge and persists")
    func addEdge() {
        var state = stateWith([card("a"), card("b")])
        let effects = Reducer.reduce(state: &state, action: .addCardDependency(cardId: "b", dependsOnId: "a"))
        #expect(state.links["b"]?.dependsOn == ["a"])
        #expect(effects.contains { if case .upsertLink = $0 { return true }; return false })
    }

    @Test("self-edge is rejected")
    func selfEdgeRejected() {
        var state = stateWith([card("a")])
        _ = Reducer.reduce(state: &state, action: .addCardDependency(cardId: "a", dependsOnId: "a"))
        #expect(state.links["a"]?.dependsOn == nil)
    }

    @Test("edge to a missing card is rejected")
    func missingTargetRejected() {
        var state = stateWith([card("a")])
        _ = Reducer.reduce(state: &state, action: .addCardDependency(cardId: "a", dependsOnId: "ghost"))
        #expect(state.links["a"]?.dependsOn == nil)
    }

    @Test("duplicate edge is a no-op")
    func duplicateNoOp() {
        var state = stateWith([card("a"), card("b", dependsOn: ["a"])])
        let effects = Reducer.reduce(state: &state, action: .addCardDependency(cardId: "b", dependsOnId: "a"))
        #expect(state.links["b"]?.dependsOn == ["a"])
        #expect(effects.isEmpty)
    }

    @Test("cycle-creating edge is rejected")
    func cycleRejected() {
        // a → b → c (each depends on the next). Adding c depends-on a closes the loop.
        var state = stateWith([
            card("a", dependsOn: ["b"]),
            card("b", dependsOn: ["c"]),
            card("c"),
        ])
        _ = Reducer.reduce(state: &state, action: .addCardDependency(cardId: "c", dependsOnId: "a"))
        #expect(state.links["c"]?.dependsOn == nil)  // rejected, no cycle introduced
    }

    @Test("cmdClickCard: first picks source, second creates the edge")
    func cmdClickLinking() {
        var state = stateWith([card("a"), card("b")])
        // First ⌘-click picks the prerequisite.
        _ = Reducer.reduce(state: &state, action: .cmdClickCard(cardId: "a"))
        #expect(state.linkingSourceCardId == "a")
        #expect(state.links["b"]?.dependsOn == nil)
        // Second ⌘-click on another card creates "b depends on a" and clears state.
        _ = Reducer.reduce(state: &state, action: .cmdClickCard(cardId: "b"))
        #expect(state.linkingSourceCardId == nil)
        #expect(state.links["b"]?.dependsOn == ["a"])
    }

    @Test("cmdClickCard on the same card twice cancels")
    func cmdClickSameCardCancels() {
        var state = stateWith([card("a")])
        _ = Reducer.reduce(state: &state, action: .cmdClickCard(cardId: "a"))
        _ = Reducer.reduce(state: &state, action: .cmdClickCard(cardId: "a"))
        #expect(state.linkingSourceCardId == nil)
        #expect(state.links["a"]?.dependsOn == nil)
    }

    @Test("cmdClick linking respects the cycle guard")
    func cmdClickNoCycle() {
        var state = stateWith([card("a", dependsOn: ["b"]), card("b")])
        _ = Reducer.reduce(state: &state, action: .cmdClickCard(cardId: "a")) // source = a
        _ = Reducer.reduce(state: &state, action: .cmdClickCard(cardId: "b")) // "b depends on a" → cycle (a→b→a)
        #expect(state.links["b"]?.dependsOn == nil) // rejected, no edge
    }

    @Test("removeCardDependency drops the edge, clears to nil when empty")
    func removeEdge() {
        var state = stateWith([card("a"), card("b", dependsOn: ["a"])])
        _ = Reducer.reduce(state: &state, action: .removeCardDependency(cardId: "b", dependsOnId: "a"))
        #expect(state.links["b"]?.dependsOn == nil)
    }

    @Test("wouldCreateCycle detects a transitive loop")
    func transitiveCycleDetection() {
        let links = stateWith([
            card("a", dependsOn: ["b"]),
            card("b", dependsOn: ["c"]),
            card("c"),
        ]).links
        // Adding a→... wait: c depends-on a would loop (a→b→c→a).
        #expect(TaskDependencies.wouldCreateCycle(links: links, from: "c", to: "a") == true)
        // b depends-on a is fine (a already depends on b, so a is reachable from... check):
        // a→b exists; adding b→a would loop. c→b: b reachable from b? b→c→(nothing). Safe.
        #expect(TaskDependencies.wouldCreateCycle(links: links, from: "c", to: "b") == false)
    }

    @Test("externalCardsAppeared adds unknown cards, ignores known and tombstoned")
    func externalMergeAddOnly() {
        var state = stateWith([card("known")])
        state.deletedCardIds.insert("deleted")

        let disk = [
            card("known"),                       // already in memory → ignored
            card("fresh"),                       // brand-new → added
            card("deleted"),                     // tombstoned → not resurrected
        ]
        _ = Reducer.reduce(state: &state, action: .externalCardsAppeared(disk))

        #expect(state.links["fresh"] != nil)
        #expect(state.links["deleted"] == nil)
        #expect(state.links.count == 2) // known + fresh
    }

    @Test("externalCardsAppeared does not overwrite an existing card")
    func externalMergeNoOverwrite() {
        var known = card("x")
        known.name = "in-memory name"
        var state = stateWith([known])

        var diskVersion = card("x")
        diskVersion.name = "stale disk name"
        _ = Reducer.reduce(state: &state, action: .externalCardsAppeared([diskVersion]))

        #expect(state.links["x"]?.name == "in-memory name") // memory wins
    }

    // MARK: - Auto-scheduler readiness

    private func card(_ id: String, column: KanbanCodeColumn, dependsOn: [String]? = nil, isLaunching: Bool? = nil, completedAt: Date? = nil) -> Link {
        Link(id: id, name: id, column: column, source: .manual, isLaunching: isLaunching, dependsOn: dependsOn, completedAt: completedAt)
    }

    @Test("readyToLaunch fires only when all deps are Done")
    func readyWhenDepsDone() {
        // b depends on a. a not done → not ready. Then a done → ready.
        var links = [
            "a": card("a", column: .inProgress),
            "b": card("b", column: .backlog, dependsOn: ["a"]),
        ]
        #expect(TaskDependencies.readyToLaunch(links: links).isEmpty)
        links["a"] = card("a", column: .done)
        #expect(TaskDependencies.readyToLaunch(links: links) == ["b"])
    }

    @Test("readyToLaunch needs every dep Done (parallel fan-in)")
    func readyNeedsAllDeps() {
        var links = [
            "a": card("a", column: .done),
            "b": card("b", column: .waiting),
            "c": card("c", column: .backlog, dependsOn: ["a", "b"]),
        ]
        #expect(TaskDependencies.readyToLaunch(links: links).isEmpty) // b not done
        links["b"] = card("b", column: .done)
        #expect(TaskDependencies.readyToLaunch(links: links) == ["c"])
    }

    @Test("cards without dependencies are never auto-launched")
    func rootsNotAutoLaunched() {
        let links = ["a": card("a", column: .backlog)] // no deps
        #expect(TaskDependencies.readyToLaunch(links: links).isEmpty)
    }

    @Test("a launching or already-moved card is excluded")
    func excludesInFlight() {
        let links = [
            "a": card("a", column: .done),
            "b": card("b", column: .backlog, dependsOn: ["a"], isLaunching: true),
            "c": card("c", column: .inProgress, dependsOn: ["a"]),
        ]
        #expect(TaskDependencies.readyToLaunch(links: links).isEmpty)
    }

    @Test("a missing (deleted) dependency does not deadlock the chain")
    func missingDepSatisfied() {
        let links = ["b": card("b", column: .backlog, dependsOn: ["ghost"])]
        #expect(TaskDependencies.readyToLaunch(links: links) == ["b"])
    }

    @Test("readyToLaunch fires on the agent's completion signal, before Done")
    func readyOnCompletionSignal() {
        // A is still In Progress (no merged PR, not Done) but its agent signalled done.
        let links = [
            "a": card("a", column: .inProgress, completedAt: Date(timeIntervalSince1970: 1)),
            "b": card("b", column: .backlog, dependsOn: ["a"]),
        ]
        #expect(TaskDependencies.readyToLaunch(links: links) == ["b"])
    }

    @Test("externalCardsAppeared adopts completedAt for an already-known card")
    func externalMergeAdoptsCompletion() {
        var state = stateWith([card("a", column: .inProgress, dependsOn: nil)])
        #expect(state.links["a"]?.completedAt == nil)

        // The agent's `kanban task done` set completedAt on disk; the watcher re-reads.
        let disk = [card("a", column: .inProgress, completedAt: Date(timeIntervalSince1970: 5))]
        _ = Reducer.reduce(state: &state, action: .externalCardsAppeared(disk))

        #expect(state.links["a"]?.completedAt == Date(timeIntervalSince1970: 5))
    }

    @Test("dependencyState classifies blocked / ready / handed off / none")
    func dependencyStates() {
        let links = [
            "a": card("a", column: .done),
            "b": card("b", column: .backlog, dependsOn: ["a"]),        // dep Done → ready
            "d": card("d", column: .backlog, dependsOn: ["e", "a"]),   // e not done → blocked 1
            "e": card("e", column: .inProgress),
            "f": card("f", column: .backlog),                          // no deps → none
            "g": card("g", column: .inProgress, completedAt: Date(timeIntervalSince1970: 1)),
        ]
        #expect(TaskDependencies.dependencyState(of: links["b"]!, in: links) == .ready)
        #expect(TaskDependencies.dependencyState(of: links["d"]!, in: links) == .blocked(1))
        #expect(TaskDependencies.dependencyState(of: links["f"]!, in: links) == CardDependencyState.none)
        #expect(TaskDependencies.dependencyState(of: links["g"]!, in: links) == .handedOff)
    }

    @Test("dependsOn round-trips through Codable")
    func codableRoundTrip() throws {
        let original = card("b", dependsOn: ["a", "x"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded.dependsOn == ["a", "x"])
    }

    @Test("labels round-trip through Codable")
    func labelsRoundTrip() throws {
        var original = card("b")
        original.labels = ["account", "in test"]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded.labels == ["account", "in test"])
    }

    @Test("externalCardsAppeared adopts labels for a known card")
    func externalMergeAdoptsLabels() {
        var state = stateWith([card("a", column: .inProgress)])
        var disk = card("a", column: .inProgress)
        disk.labels = ["sale_management", "waiting for Codex"]
        _ = Reducer.reduce(state: &state, action: .externalCardsAppeared([disk]))
        #expect(state.links["a"]?.labels == ["sale_management", "waiting for Codex"])
    }
}
