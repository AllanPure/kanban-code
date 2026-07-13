import SwiftUI
import KanbanCodeCore

/// Per-file diff of a card's worktree — the "review what the agent changed" view, in a
/// GitHub-PR style: every changed file stacked in one scroll, each with a collapsible
/// header + stats, and a unified / side-by-side toggle.
struct WorktreeDiffView: View {
    let worktreePath: String

    enum ViewMode: String, CaseIterable { case unified = "Unifié", split = "Côte à côte" }

    @State private var changes: WorktreeChanges?
    @State private var loading = false
    @State private var mode: ViewMode = .unified

    var body: some View {
        Group {
            if worktreePath.isEmpty {
                placeholder("Cette carte n'a pas de worktree — pas de diff à afficher.")
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                }
            }
        }
        .task(id: worktreePath) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Modifications").font(.app(.headline))
            if let files = changes?.files, !files.isEmpty {
                Text("\(files.count) fichier\(files.count > 1 ? "s" : "")")
                    .font(.app(.caption)).foregroundStyle(.secondary)
                let adds = files.compactMap(\.additions).reduce(0, +)
                let dels = files.compactMap(\.deletions).reduce(0, +)
                if adds > 0 { Text("+\(adds)").font(.app(size: 10, weight: .semibold)).foregroundStyle(.green) }
                if dels > 0 { Text("−\(dels)").font(.app(size: 10, weight: .semibold)).foregroundStyle(.red) }
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise").font(.app(.caption))
            }
            .buttonStyle(.plain).help("Recharger le diff")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if loading && changes == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if changes?.files.isEmpty ?? true {
            placeholder("Aucune modification par rapport à la branche de base.")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(changes?.files ?? []) { file in
                        FileDiffSection(file: file, worktreePath: worktreePath,
                                        baseRef: changes?.baseRef ?? "HEAD", mode: mode)
                    }
                }
                .padding(12)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.app(.callout)).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func load() async {
        guard !worktreePath.isEmpty else { return }
        loading = true
        changes = await WorktreeDiff.changes(worktreePath: worktreePath)
        loading = false
    }
}

/// One collapsible file section: header (status, path, stats, chevron) + its diff, loaded
/// lazily the first time it's expanded.
private struct FileDiffSection: View {
    let file: DiffFile
    let worktreePath: String
    let baseRef: String
    let mode: WorktreeDiffView.ViewMode

    @State private var expanded = true
    @State private var rows: [DiffRow]?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if expanded {
                Divider()
                if let rows {
                    if rows.isEmpty {
                        Text("(pas de contenu texte — binaire ou fichier vide)")
                            .font(.app(.caption)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } else {
                        DiffBody(rows: rows, mode: mode,
                                 language: SyntaxHighlight.Language.infer(fromPath: file.path))
                    }
                } else {
                    ProgressView().controlSize(.small).padding(12).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        .task(id: expanded) { if expanded, rows == nil { await load() } }
    }

    private var headerRow: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.app(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                Text(file.status.letter)
                    .font(.app(size: 10, weight: .bold)).foregroundStyle(statusColor).frame(width: 12)
                Text(file.path).font(.app(.caption)).lineLimit(1).truncationMode(.head)
                if let old = file.oldPath {
                    Text("← \(old)").font(.app(size: 9)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 6)
                if let a = file.additions, a > 0 { Text("+\(a)").font(.app(size: 9, weight: .medium)).foregroundStyle(.green) }
                if let d = file.deletions, d > 0 { Text("−\(d)").font(.app(size: 9, weight: .medium)).foregroundStyle(.red) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch file.status {
        case .added, .untracked: return .green
        case .modified, .renamed: return .orange
        case .deleted: return .red
        }
    }

    private func load() async {
        loading = true
        let diff = await WorktreeDiff.fileDiff(worktreePath: worktreePath, baseRef: baseRef, file: file)
        rows = WorktreeDiff.parseRows(diff)
        loading = false
    }
}

/// Renders parsed diff rows in unified or split mode with line-number gutters.
private struct DiffBody: View {
    let rows: [DiffRow]
    let mode: WorktreeDiffView.ViewMode
    let language: SyntaxHighlight.Language

    private static let font = Font.system(size: 11, design: .monospaced)
    private static let gutter: CGFloat = 34

    /// Marker (+/−/space, colored by add/remove) followed by the syntax-highlighted line.
    private func attributed(_ row: DiffRow) -> AttributedString {
        var marker = AttributedString(self.marker(row.kind))
        marker.foregroundColor = textColor(row.kind)
        return marker + SyntaxHighlight.highlight(row.text, language: language)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                switch mode {
                case .unified: ForEach(rows.filter { $0.kind != .meta }) { unifiedRow($0) }
                case .split:   ForEach(splitRows) { splitRow($0) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Unified

    @ViewBuilder
    private func unifiedRow(_ row: DiffRow) -> some View {
        if row.kind == .hunk {
            Text(row.text).font(Self.font).foregroundStyle(.cyan)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cyan.opacity(0.08))
        } else {
            HStack(spacing: 0) {
                num(row.oldLine); num(row.newLine)
                Text(attributed(row)).font(Self.font)
                    .padding(.leading, 6).padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(row.kind))
        }
    }

    // MARK: Split

    private struct SplitRow: Identifiable { let id: Int; let left: DiffRow?; let right: DiffRow?; let hunk: String? }

    private var splitRows: [SplitRow] {
        var out: [SplitRow] = []
        var rem: [DiffRow] = [], add: [DiffRow] = []
        var i = 0
        func flush() {
            let n = max(rem.count, add.count)
            for k in 0..<n { out.append(SplitRow(id: i, left: k < rem.count ? rem[k] : nil,
                                                 right: k < add.count ? add[k] : nil, hunk: nil)); i += 1 }
            rem.removeAll(); add.removeAll()
        }
        for row in rows {
            switch row.kind {
            case .removed: rem.append(row)
            case .added: add.append(row)
            case .context: flush(); out.append(SplitRow(id: i, left: row, right: row, hunk: nil)); i += 1
            case .hunk: flush(); out.append(SplitRow(id: i, left: nil, right: nil, hunk: row.text)); i += 1
            case .meta: break
            }
        }
        flush()
        return out
    }

    @ViewBuilder
    private func splitRow(_ row: SplitRow) -> some View {
        if let hunk = row.hunk {
            Text(hunk).font(Self.font).foregroundStyle(.cyan)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.cyan.opacity(0.08))
        } else {
            HStack(spacing: 0) {
                sideCell(row.left, isLeft: true)
                Divider()
                sideCell(row.right, isLeft: false)
            }
        }
    }

    @ViewBuilder
    private func sideCell(_ row: DiffRow?, isLeft: Bool) -> some View {
        HStack(spacing: 0) {
            num(isLeft ? row?.oldLine : row?.newLine)
            Text(row.map { attributed($0) } ?? AttributedString(" "))
                .font(Self.font)
                .padding(.leading, 6).padding(.trailing, 10)
        }
        .frame(width: 360, alignment: .leading)
        .background(row.map { rowBackground($0.kind) } ?? .clear)
    }

    // MARK: Shared bits

    private func num(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(Self.font).foregroundStyle(.tertiary)
            .frame(width: Self.gutter, alignment: .trailing)
            .padding(.trailing, 2)
    }

    private func marker(_ kind: DiffRow.Kind) -> String {
        switch kind { case .added: return "+"; case .removed: return "−"; default: return " " }
    }
    private func textColor(_ kind: DiffRow.Kind) -> Color {
        switch kind { case .added: return .green; case .removed: return .red; default: return .primary }
    }
    private func rowBackground(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.10)
        case .removed: return Color.red.opacity(0.10)
        default: return .clear
        }
    }
}
