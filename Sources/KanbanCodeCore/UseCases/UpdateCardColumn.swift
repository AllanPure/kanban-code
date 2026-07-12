import Foundation

/// Updates a link's column based on current activity state, PR status, and worktree existence.
/// Wraps AssignColumn with persistence via CoordinationStore.
public enum UpdateCardColumn {

    /// Grace period before a freshly-idle In Progress card drops to Waiting.
    /// Bridges the brief gaps between turns (tool runs, back-to-back messages) so
    /// the card doesn't bounce columns on every micro-pause. After the session has
    /// been quiet this long, it falls to Waiting as usual.
    public static let waitingDebounce: TimeInterval = 60

    /// Update a single link's column assignment.
    /// PR state is read directly from `link.prLinks`.
    /// `now` is injectable for tests; production uses the wall clock.
    public static func update(
        link: inout Link,
        activityState: ActivityState?,
        hasWorktree: Bool,
        now: Date = .now
    ) {
        let hasPR = !link.prLinks.isEmpty
        let allPRsDone = link.allPRsDone

        let newColumn = AssignColumn.assign(
            link: link,
            activityState: activityState,
            hasPR: hasPR,
            allPRsDone: allPRsDone,
            hasWorktree: hasWorktree
        )

        // If an archived card becomes live again, clear the archive flag so it
        // stays in waiting (not allSessions) once work stops. Require a live
        // tmux/worktree signal so stale activity does not unarchive old cards.
        if link.manuallyArchived && newColumn == .inProgress && hasWorktree {
            link.manuallyArchived = false
        }

        // Debounce the In Progress → Waiting drop: a session that just went idle
        // (idleWaiting) keeps the card in In Progress until it has been quiet for
        // `waitingDebounce`. Genuine blocks (needsAttention) and terminal states
        // are not idleWaiting, so they fall through immediately. Only applies once
        // there is a real activity timestamp to measure against.
        if link.column == .inProgress,
           newColumn == .waiting,
           activityState == .idleWaiting,
           let last = link.lastActivity,
           now.timeIntervalSince(last) < waitingDebounce {
            return
        }

        if newColumn != link.column {
            link.column = newColumn
            link.updatedAt = now
        }
    }
}
