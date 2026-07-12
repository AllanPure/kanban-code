import Foundation

/// Pure graph logic for the card execution-order DAG (`Link.dependsOn`).
///
/// An edge "A depends on B" means B must reach Done before A may run. Sequential
/// chains and parallel fan-out are both expressed with the same edge set, and the
/// graph must stay acyclic so an execution order always exists.
public enum TaskDependencies {
    /// Would adding the edge "`cardId` depends on `dependsOnId`" create a cycle?
    ///
    /// True when it is a self-edge, or when `dependsOnId` already (transitively)
    /// depends on `cardId` — adding the edge would then close a loop. Pure and
    /// side-effect free, so it is safe to call from the reducer.
    public static func wouldCreateCycle(
        links: [String: Link], from cardId: String, to dependsOnId: String
    ) -> Bool {
        if cardId == dependsOnId { return true }
        var stack = [dependsOnId]
        var seen: Set<String> = []
        while let current = stack.popLast() {
            if current == cardId { return true }
            guard seen.insert(current).inserted else { continue }
            for dep in links[current]?.dependsOn ?? [] {
                stack.append(dep)
            }
        }
        return false
    }

    /// Card ids ready to auto-launch: in Backlog, with at least one dependency, not
    /// already launching, and every dependency satisfied.
    ///
    /// A dependency counts as satisfied when its card is Done — or no longer exists
    /// (a deleted prerequisite must not deadlock the chain). Cards **without**
    /// dependencies are deliberately excluded: the scheduler cascades dependents once
    /// their prerequisites finish, while the roots of a graph are launched by the user.
    public static func readyToLaunch(links: [String: Link]) -> [String] {
        links.values.compactMap { card -> String? in
            guard card.column == .backlog,
                  !(card.isLaunching ?? false),
                  let deps = card.dependsOn, !deps.isEmpty else { return nil }
            let satisfied = deps.allSatisfy { depId in
                guard let dep = links[depId] else { return true } // missing → satisfied
                return dep.column == .done
            }
            return satisfied ? card.id : nil
        }
    }
}
