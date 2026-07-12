import Foundation

/// A card's status within the dependency DAG, for at-a-glance display on the board.
public enum CardDependencyState: Sendable, Equatable {
    /// No dependencies (or not relevant to show).
    case none
    /// In Backlog with `count` dependencies not yet satisfied — waiting its turn.
    case blocked(Int)
    /// In Backlog with every dependency satisfied — about to auto-launch.
    case ready
    /// This task signalled its own work done (`completedAt`) — handed off to dependents.
    case handedOff
}

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

    /// The card's DAG status for board display (blocked / ready / handed off / none).
    public static func dependencyState(of card: Link, in links: [String: Link]) -> CardDependencyState {
        if card.completedAt != nil { return .handedOff }
        guard let deps = card.dependsOn, !deps.isEmpty, card.column == .backlog else { return .none }
        let unmet = deps.reduce(0) { acc, depId in
            guard let dep = links[depId] else { return acc } // missing → satisfied
            return acc + (isSatisfied(dep) ? 0 : 1)
        }
        return unmet == 0 ? .ready : .blocked(unmet)
    }

    /// Card ids ready to auto-launch: in Backlog, with at least one dependency, not
    /// already launching, and every dependency satisfied.
    ///
    /// A dependency counts as satisfied when its agent has signalled the task done
    /// (`completedAt` set, via `kanban task done`) or its card reached the Done column
    /// — or it no longer exists (a deleted prerequisite must not deadlock the chain).
    /// The `completedAt` signal is what lets a linked chain hand off at task/commit
    /// granularity and share one PR at the end, instead of forcing a merged PR per step.
    /// Cards **without** dependencies are deliberately excluded: the scheduler cascades
    /// dependents once their prerequisites finish, while the roots are launched by the user.
    public static func isSatisfied(_ dep: Link) -> Bool {
        dep.completedAt != nil || dep.column == .done
    }

    public static func readyToLaunch(links: [String: Link]) -> [String] {
        links.values.compactMap { card -> String? in
            guard card.column == .backlog,
                  !(card.isLaunching ?? false),
                  let deps = card.dependsOn, !deps.isEmpty else { return nil }
            let satisfied = deps.allSatisfy { depId in
                guard let dep = links[depId] else { return true } // missing → satisfied
                return isSatisfied(dep)
            }
            return satisfied ? card.id : nil
        }
    }
}
