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

    private func card(_ id: String, column: KanbanCodeColumn, dependsOn: [String]? = nil, isLaunching: Bool? = nil) -> Link {
        Link(id: id, name: id, column: column, source: .manual, isLaunching: isLaunching, dependsOn: dependsOn)
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

    @Test("dependsOn round-trips through Codable")
    func codableRoundTrip() throws {
        let original = card("b", dependsOn: ["a", "x"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded.dependsOn == ["a", "x"])
    }
}
