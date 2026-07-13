import Testing
import Foundation
@testable import KanbanCodeCore

@Suite struct WorktreeDiffTests {

    @Test func parsesNameStatusForAddModifyDelete() {
        let out = "M\tSources/App.swift\nA\tSources/New.swift\nD\tSources/Old.swift"
        let files = WorktreeDiff.parseNameStatus(out)
        #expect(files.count == 3)
        #expect(files[0].path == "Sources/App.swift" && files[0].status == .modified)
        #expect(files[1].path == "Sources/New.swift" && files[1].status == .added)
        #expect(files[2].path == "Sources/Old.swift" && files[2].status == .deleted)
    }

    @Test func parsesRenameWithOldPath() {
        let out = "R100\told/name.swift\tnew/name.swift"
        let files = WorktreeDiff.parseNameStatus(out)
        #expect(files.count == 1)
        #expect(files[0].status == .renamed)
        #expect(files[0].path == "new/name.swift")
        #expect(files[0].oldPath == "old/name.swift")
    }

    @Test func parsesNumstatCountsAndBinary() {
        let out = "12\t3\tSources/App.swift\n-\t-\tassets/logo.png"
        let counts = WorktreeDiff.parseNumstat(out)
        #expect(counts["Sources/App.swift"]?.additions == 12)
        #expect(counts["Sources/App.swift"]?.deletions == 3)
        #expect(counts["assets/logo.png"]?.additions == nil)   // binary
        #expect(counts["assets/logo.png"]?.deletions == nil)
    }

    @Test func numstatRenameKeysOnNewPath() {
        let out = "5\t2\told => new/file.swift"
        let counts = WorktreeDiff.parseNumstat(out)
        #expect(counts["new/file.swift"]?.additions == 5)
    }

    @Test func mergeAttachesCountsToStatus() {
        let nameStatus = "M\tSources/App.swift\nA\tSources/New.swift"
        let numstat = "12\t3\tSources/App.swift\n40\t0\tSources/New.swift"
        let merged = WorktreeDiff.mergeStatusAndNumstat(nameStatus: nameStatus, numstat: numstat)
        #expect(merged.count == 2)
        let app = merged.first { $0.path == "Sources/App.swift" }
        #expect(app?.status == .modified)
        #expect(app?.additions == 12 && app?.deletions == 3)
        let new = merged.first { $0.path == "Sources/New.swift" }
        #expect(new?.status == .added && new?.additions == 40)
    }

    @Test func emptyOutputYieldsNoFiles() {
        #expect(WorktreeDiff.parseNameStatus("").isEmpty)
        #expect(WorktreeDiff.parseNumstat("").isEmpty)
    }

    @Test func parsesHunkHeaderStarts() {
        #expect(WorktreeDiff.parseHunkHeader("@@ -12,7 +12,9 @@ func foo() {")?.old == 12)
        #expect(WorktreeDiff.parseHunkHeader("@@ -12,7 +14,9 @@")?.new == 14)
        #expect(WorktreeDiff.parseHunkHeader("@@ -1 +1 @@")?.old == 1)   // single-line hunk (no count)
    }

    @Test func parseRowsResolvesLineNumbers() {
        let diff = """
        diff --git a/f.swift b/f.swift
        index 111..222 100644
        --- a/f.swift
        +++ b/f.swift
        @@ -10,3 +10,4 @@
         context line
        -removed line
        +added line one
        +added line two
        """
        let rows = WorktreeDiff.parseRows(diff)
        let context = rows.first { $0.kind == .context }
        #expect(context?.oldLine == 10 && context?.newLine == 10)
        let removed = rows.first { $0.kind == .removed }
        #expect(removed?.oldLine == 11 && removed?.newLine == nil)
        #expect(removed?.text == "removed line")
        let added = rows.filter { $0.kind == .added }
        #expect(added.count == 2)
        #expect(added[0].newLine == 11 && added[1].newLine == 12)
        #expect(added[0].text == "added line one")
        // Header/meta lines classified as meta, not content
        #expect(rows.contains { $0.kind == .meta && $0.text.hasPrefix("+++") })
        #expect(rows.contains { $0.kind == .hunk })
    }
}
