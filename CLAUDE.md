# Kanban Code — Claude Code Guidelines

## What this project is

**Kanban Code** is a native app for running **multiple Claude Code agents in parallel**.
Each task is a **card** on a Kanban board; a card ties together everything a Claude
session needs — its git worktree, tmux terminals, GitHub PR, and issue — and flows
from *Backlog → In Progress → Waiting → Review → Done* automatically as Claude works,
opens a PR, and gets it merged. The goal is to kill the context-switching tax of
juggling several agents by centralizing each session's context into its card.

- **macOS**: native SwiftUI (liquid glass, macOS 26 / Tahoe). This repo, this file.
- **Windows**: Tauri app (separate front-end, shares the concept). Not covered here.
- License: **AGPLv3**.

## Core mental model — card-centric with typed links

A **card** is the first-class entity. It has **independently optional typed links**,
each adding capabilities:

| Link         | What it adds                          | Primary label     |
|--------------|---------------------------------------|-------------------|
| SessionLink  | History tab, resume, fork, checkpoint | SESSION (orange)  |
| TmuxLink     | Embedded terminal tab, live view      | —                 |
| WorktreeLink | Branch info, cleanup action           | WORKTREE (green)  |
| PRLink       | PR status, merge detection            | PR (purple)       |
| IssueLink    | Issue body, "Open in Browser"         | ISSUE (blue)      |

- Card IDs are **KSUID** (`card_<27-char-base62>`), sortable by creation time.
- A background **reconciler** scans the machine (Claude sessions under
  `~/.claude/projects/`, tmux sessions, git worktrees, GitHub PRs) and **matches
  discovered resources to existing cards** — this is what prevents duplicate cards.
- Backlog items come from **GitHub issues** (via `gh`) or **manual task creation**.

## Build & Test

```bash
swift build          # build the library + app
swift test           # run all tests (swift-testing)
make run-app         # build + launch the macOS app
```

- swift-tools-version **6.2**, deployment target **macOS 26** — no `#available` checks needed.
- Key deps: local **SwiftTerm** (embedded terminal), swift-markdown-ui, swift-testing.

## Repo layout

Swift package with three products (see `Package.swift`):

- **`Sources/KanbanCodeCore/`** — pure Swift library, **no UI**. The domain lives here.
  - `Domain/` entities (e.g. `Link.swift` — the card), `UseCases/`, `Adapters/`, `Infrastructure/`.
- **`Sources/KanbanCode/`** — the SwiftUI + AppKit **macOS app**. Views, toolbar, tray.
- **`Sources/KanbanCodeActiveSession/`** — small helper executable (`kanban-code-active-session`).
- **`Tests/KanbanCodeCoreTests/`**, **`Tests/KanbanCodeTests/`** — swift-testing suites.
- **`specs/`** — BDD `.feature` specs, one folder per area (board, sessions, terminal,
  review, remote, notifications, …). Start here to understand a feature's intended behavior.
- **`docs/architecture.md`** — the state-management design (read it before touching state).
- **`cli/`** — the bundled TypeScript CLI shipped inside the `.app`.

## Architecture — Elm-like unidirectional state

All app state lives in **one `AppState` struct** (single source of truth). This replaced
an earlier design with two sources of truth and 5 racing writers, which caused cards
bouncing between columns and terminals disappearing. Full rationale: `docs/architecture.md`.

Rules of the road:

- **Never mutate state directly** and **never write to `CoordinationStore` from views** —
  always `store.dispatch(action)`.
- Flow: `dispatch(action)` → **pure `Reducer.reduce(inout AppState, Action) -> [Effect]`**
  (synchronous, `@MainActor`, no side effects, fully testable) → async **`Effect`s**
  executed by the `EffectHandler` actor (disk I/O, tmux, cleanup) → optional completion
  action dispatched back.
- `isLaunching` on a `Link` protects a card mid-launch/resume: background reconciliation
  (`.reconciled`) **skips** any card with `isLaunching == true`, so it doesn't bounce columns.

Key files:

| File | Role |
|------|------|
| `KanbanCodeCore/UseCases/BoardStore.swift` | `AppState`, `Action`, `Reducer`, `BoardStore` |
| `KanbanCodeCore/UseCases/EffectHandler.swift` | async effect execution |
| `KanbanCodeCore/Domain/Entities/Link.swift` | the card entity |
| `KanbanCodeCore/UseCases/BackgroundOrchestrator.swift` | notifications + activity polling only |
| `KanbanCode/ContentView.swift` | main view: dispatches actions, runs launch/resume flows |
| `KanbanCode/BoardView.swift` | board columns: reads `store.state`, dispatches move/rename/archive |
| `Tests/KanbanCodeCoreTests/ReducerTests.swift` | pure reducer tests (no disk/async/mocks) |

Reducer tests are pure and fast — give state + action, assert new state + effects:

```swift
@Test func resumeCardNoBounce() {
    var state = stateWith([waitingCard])
    Reducer.reduce(state: &state, action: .resumeCard(cardId: "card1"))
    #expect(state.links["card1"]?.column == .inProgress)
    #expect(state.links["card1"]?.isLaunching == true)
    Reducer.reduce(state: &state, action: .reconciled(result)) // must NOT override
    #expect(state.links["card1"]?.column == .inProgress)
}
```

> `BoardState.swift` is **legacy dead code** kept only for regression tests. No UI references it.

## Critical: DispatchSource + @MainActor Crashes

SwiftUI Views are `@MainActor`. In Swift 6, closures formed inside `@MainActor` methods inherit that isolation. If a `DispatchSource` event handler runs on a background GCD queue, the runtime asserts and **crashes** (`EXC_BREAKPOINT` in `_dispatch_assert_queue_fail`).

**Never do this** (crashes at runtime, no compile-time warning):
```swift
// Inside a SwiftUI View (which is @MainActor)
func startWatcher() {
    let source = DispatchSource.makeFileSystemObjectSource(fd: fd, eventMask: .write, queue: .global())
    source.setEventHandler {
        // CRASH: this closure inherits @MainActor but runs on a background queue
        NotificationCenter.default.post(name: .myEvent, object: nil)
    }
}
```

**Always do this** — extract to a `nonisolated` context:
```swift
// Option A: nonisolated static factory
private nonisolated static func makeSource(fd: Int32) -> DispatchSourceFileSystemObject {
    let source = DispatchSource.makeFileSystemObjectSource(fd: fd, eventMask: .write, queue: .global())
    source.setEventHandler {
        NotificationCenter.default.post(name: .myEvent, object: nil)
    }
    source.resume()
    return source
}

// Option B: nonisolated async function with AsyncStream
private nonisolated func watchFile(path: String) async {
    let source = DispatchSource.makeFileSystemObjectSource(...)
    let events = AsyncStream<Void> { continuation in
        source.setEventHandler { continuation.yield() }
        source.setCancelHandler { continuation.finish() }
        source.resume()
    }
    for await _ in events {
        NotificationCenter.default.post(name: .myEvent, object: nil)
    }
}
```

This applies to **any** GCD callback (`setEventHandler`, `setCancelHandler`, `DispatchQueue.global().async`) called from a `@MainActor` context.

## Toolbar Layout (macOS 26 Liquid Glass)

Toolbar uses SwiftUI `.toolbar` with `ToolbarSpacer` (macOS 26+) for separate glass pills:

- **`.navigation`** placement = left side. All items merge into ONE pill (spacers don't help).
- **`.principal`** placement = center. Separate pill from navigation.
- **`.primaryAction`** placement = right side. `ToolbarSpacer(.fixed)` DOES create separate pills here.
- Use `Menu` (not `Text`) for items that need their own pill within `.navigation` — menus map to `NSPopUpButton` which gets separate glass automatically.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages. Release-please uses these to generate changelogs automatically.

- `feat: add dark mode` — new feature (minor version bump)
- `fix: correct session dedup` — bug fix (patch version bump)
- `perf: speed up branch discovery` — performance (patch)
- `refactor: extract hook manager` — refactoring (hidden from changelog)
- `docs: update README` — documentation (hidden)
- `chore: bump deps` — maintenance (hidden)
- `feat!: redesign board layout` — breaking change (major version bump)

## Crash Logs

macOS crash reports: `~/Library/Logs/DiagnosticReports/KanbanCode-*.ips`
App logs: `~/.kanban-code/logs/kanban-code.log`
