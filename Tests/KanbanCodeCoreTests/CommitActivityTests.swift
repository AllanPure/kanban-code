import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Commit activity + todos")
struct CommitActivityTests {
    @Test("aggregate: per-day totals with project breakdown, newest first")
    func aggregate() {
        let result = CommitActivity.aggregate(projectDates: [
            ("app", ["2026-07-12", "2026-07-12", "2026-07-11"]),
            ("web", ["2026-07-12", ""]),   // empty entries ignored
        ])
        #expect(result.count == 2)
        #expect(result[0].day == "2026-07-12")
        #expect(result[0].total == 3)
        #expect(result[0].byProject["app"] == 2)
        #expect(result[0].byProject["web"] == 1)
        #expect(result[1].day == "2026-07-11")
        #expect(result[1].total == 1)
    }

    @Test("parseCommitEvents parses timed commits (US-separated)")
    func parseEvents() {
        let out = "abc\u{1f}2026-07-12T14:30:00+02:00\u{1f}Fix the bug\ndef\u{1f}2026-07-12T09:05:00+02:00\u{1f}Add feature"
        let events = CommitActivity.parseCommitEvents(gitOutput: out, project: "app")
        #expect(events.count == 2)
        #expect(events[0].id == "abc")
        #expect(events[0].subject == "Fix the bug")
        #expect(events[0].project == "app")
        #expect(events[0].time.timeIntervalSince1970 > 1_700_000_000)
    }

    @Test("TodoStore round-trips through disk")
    func todoRoundTrip() throws {
        let dir = NSTemporaryDirectory() + "kc-todos-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        TodoStore.write([Todo(text: "a", done: true), Todo(text: "b")], basePath: dir)
        let read = TodoStore.read(basePath: dir)
        #expect(read.count == 2)
        // Open todos sort before done ones.
        let sorted = TodoStore.sorted(read)
        #expect(sorted.first?.done == false)
        #expect(sorted.last?.done == true)
    }
}
