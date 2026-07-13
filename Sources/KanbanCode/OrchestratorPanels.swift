import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KanbanCodeCore

/// "What did I work on" — recent commits per day, broken down by project. The user's
/// stated pain point: finding what they worked on. Approximate (all branches, no merges).
struct CommitActivityPanel: View {
    let projects: [Project]
    @State private var days: [DayCommits] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal")
                Text("Recent activity").font(.app(.headline))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }

            if !loading && days.isEmpty {
                Text("No commits in the last 14 days.")
                    .font(.app(.caption)).foregroundStyle(.tertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(day.day).font(.app(.caption, weight: .semibold))
                                Spacer()
                                Text("\(day.total)").font(.app(.caption, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(day.byProject.sorted { $0.value > $1.value }
                                    .map { "\($0.key) ·\($0.value)" }.joined(separator: "   "))
                                .font(.app(size: 9)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .task {
            loading = true
            days = await CommitActivity.load(projects: projects)
            loading = false
        }
    }
}

/// Calendar of your commits placed at their real time — to reconstruct the day/week for
/// timesheeting. Period selector (default Week). Google Calendar (iCal) overlay is next.
struct OrchestratorCalendarView: View {
    let projects: [Project]

    enum Period: String, CaseIterable, Identifiable { case day = "Day", week = "Week"; var id: String { rawValue } }

    @State private var period: Period = .week
    @State private var anchor = Calendar.current.startOfDay(for: Date())
    @State private var allCommits: [CommitEvent] = []
    @State private var sources: [CalendarSource] = []
    @State private var calEvents: [CalendarEvent] = []
    @State private var showCalendars = false
    @State private var hiddenProjects: Set<String> = []
    @State private var showProjects = false
    @State private var loading = true

    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c } // Monday
    private var weekStart: Date {
        cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)) ?? anchor
    }
    private var visibleCommits: [CommitEvent] { allCommits.filter { !hiddenProjects.contains($0.project) } }
    private var dayCommits: [CommitEvent] {
        visibleCommits.filter { cal.isDate($0.time, inSameDayAs: anchor) }.sorted { $0.time < $1.time }
    }
    private var projectNames: [String] { Array(Set(allCommits.map(\.project))).sorted() }
    private static let projectPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .brown, .cyan, .mint]
    private func colorForProject(_ name: String) -> Color {
        guard let idx = projectNames.firstIndex(of: name) else { return .accentColor }
        return Self.projectPalette[idx % Self.projectPalette.count]
    }

    private var projectsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projects").font(.app(.headline))
            if projectNames.isEmpty { Text("No commits yet.").font(.app(.caption)).foregroundStyle(.tertiary) }
            ForEach(projectNames, id: \.self) { name in
                Toggle(isOn: Binding(
                    get: { !hiddenProjects.contains(name) },
                    set: { on in if on { hiddenProjects.remove(name) } else { hiddenProjects.insert(name) } }
                )) {
                    HStack(spacing: 6) {
                        Circle().fill(colorForProject(name)).frame(width: 10, height: 10)
                        Text(name).font(.app(.callout))
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(16).frame(width: 260)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch period {
            case .day: dayAgenda
            case .week: WeekCalendarGrid(weekStart: weekStart, commits: visibleCommits, events: calEvents, projectColor: colorForProject, onOpen: open)
            }
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            Text(title).font(.app(.headline))
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
            Button("Today") { anchor = cal.startOfDay(for: Date()) }.controlSize(.small)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { showProjects.toggle() } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .help("Show / hide projects")
            .popover(isPresented: $showProjects, arrowEdge: .bottom) { projectsPopover }
            Button { showCalendars.toggle() } label: {
                Image(systemName: "calendar.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Manage Google/iCal calendars")
            .popover(isPresented: $showCalendars, arrowEdge: .bottom) {
                CalendarSourcesEditor(sources: $sources, onChange: { Task { await reloadEvents() } })
            }
            Picker("", selection: $period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var title: String {
        switch period {
        case .day: return anchor.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .week:
            let end = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            return "\(weekStart.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }

    private var dayAgenda: some View {
        ScrollView {
            if dayCommits.isEmpty && !loading {
                Text("No commits this day.").font(.app(.body)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(dayCommits) { commit in
                    Button { open(commit) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(commit.time.formatted(date: .omitted, time: .shortened))
                                .font(.app(.callout, weight: .semibold)).frame(width: 62, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.subject).font(.app(.callout)).lineLimit(2)
                                Text(commit.project).font(.app(.caption2)).foregroundStyle(Color.accentColor.opacity(0.85))
                            }
                            Spacer(minLength: 0)
                            if commit.url != nil { Image(systemName: "arrow.up.right.square").font(.app(.caption)).foregroundStyle(.tertiary) }
                        }
                        .contentShape(Rectangle()).padding(.vertical, 7).padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain).disabled(commit.url == nil)
                    Divider()
                }
            }
        }
    }

    private func shift(_ n: Int) {
        let unit: Calendar.Component = (period == .week) ? .weekOfYear : .day
        if let next = cal.date(byAdding: unit, value: n, to: anchor) { anchor = next }
    }
    private func open(_ c: CommitEvent) { if let u = c.url, let url = URL(string: u) { NSWorkspace.shared.open(url) } }
    private func load() async {
        loading = true
        sources = CalendarStore.read()
        // Fetch calendar events concurrently; stream commits so recent work shows first.
        Task { calEvents = await CalendarFeed.loadEvents(sources: sources) }
        for await batch in CommitActivity.loadEventsProgressive(projects: projects) {
            allCommits = batch
            loading = false
        }
    }
    private func reloadEvents() async {
        calEvents = await CalendarFeed.loadEvents(sources: sources)
    }
}

extension Color {
    /// Build a Color from a `#RRGGBB` (or `#RGB`) hex string; grey on failure.
    init(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        guard s.count == 6 else { self = .gray; return }
        self = Color(red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }
}

/// Week time-grid (Google Calendar style): 7 day columns, an hour axis, commits as
/// clickable pills and subscribed-calendar events as colored blocks, both at their time.
struct WeekCalendarGrid: View {
    let weekStart: Date
    let commits: [CommitEvent]
    var events: [CalendarEvent] = []
    var projectColor: (String) -> Color = { _ in .accentColor }
    let onOpen: (CommitEvent) -> Void

    private let startHour = 0
    private let endHour = 23
    private let hourHeight: CGFloat = 34
    private let gutter: CGFloat = 46

    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }
    private var days: [Date] { (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) } }

    /// Work-day end hour: Friday is a 7h day (ends 16h), other weekdays 17h.
    private func endHour(for day: Date) -> Int { cal.component(.weekday, from: day) == 6 ? 16 : 17 }
    private func yOffset(hour: Int) -> CGFloat { CGFloat(hour - startHour) * hourHeight }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer().frame(width: gutter)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.app(.caption2)).foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day())).font(.app(.callout, weight: .semibold))
                            .foregroundStyle(cal.isDateInToday(day) ? Color.accentColor : .primary)
                        ForEach(allDay(day)) { ev in
                            Text(ev.summary).font(.app(size: 8, weight: .medium)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color(hex: ev.colorHex).opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(startHour...endHour, id: \.self) { h in
                                Text("\(h)h").font(.app(size: 9)).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4)
                                    .frame(height: hourHeight, alignment: .top)
                                    .id(h)
                            }
                        }
                        .frame(width: gutter)
                        ForEach(days, id: \.self) { day in dayColumn(day) }
                    }
                }
                .onAppear { proxy.scrollTo(7, anchor: .top) }
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let dayCommits = commits.filter { cal.isDate($0.time, inSameDayAs: day) }
        let timed = events.filter { !$0.allDay && cal.isDate($0.start, inSameDayAs: day) }
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(startHour...endHour, id: \.self) { _ in
                    Divider()
                    Spacer(minLength: 0).frame(height: hourHeight - 1)
                }
            }
            // Work-hours guides (dotted): start 8h, end 17h (16h on Friday).
            workLine(.green.opacity(0.7)).offset(y: yOffset(hour: 8))
            workLine(.orange.opacity(0.7)).offset(y: yOffset(hour: endHour(for: day)))
            // Calendar event blocks (background).
            ForEach(timed) { ev in
                let color = Color(hex: ev.colorHex)
                Text(ev.summary).font(.app(size: 9, weight: .medium)).lineLimit(3)
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .frame(height: blockHeight(ev), alignment: .topLeading)
                    .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.4)))
                    .padding(.horizontal, 2)
                    .offset(y: yOffset(ev.start))
            }
            // Commit pills (on top, filled with the project colour so they read over
            // event blocks and are distinguishable per project).
            ForEach(dayCommits) { commit in
                Button { onOpen(commit) } label: {
                    HStack(spacing: 3) {
                        Text(commit.time.formatted(date: .omitted, time: .shortened))
                            .font(.app(size: 8, weight: .bold)).opacity(0.9)
                        Text(commit.subject).font(.app(size: 9)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(projectColor(commit.project), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("\(commit.subject) — \(commit.project)")
                .padding(.horizontal, 2)
                .offset(y: yOffset(commit.time))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.primary.opacity(0.06)), alignment: .leading)
    }

    private func allDay(_ day: Date) -> [CalendarEvent] {
        events.filter { $0.allDay && cal.isDate($0.start, inSameDayAs: day) }
    }
    private func blockHeight(_ ev: CalendarEvent) -> CGFloat {
        let end = ev.end ?? ev.start.addingTimeInterval(1800)
        let hours = max(0.5, end.timeIntervalSince(ev.start) / 3600)
        return CGFloat(hours) * hourHeight - 2
    }
    private func yOffset(_ time: Date) -> CGFloat {
        let h = cal.component(.hour, from: time), m = cal.component(.minute, from: time)
        return max(0, (CGFloat(h - startHour) + CGFloat(m) / 60) * hourHeight)
    }

    private func workLine(_ color: Color) -> some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: g.size.width, y: 0.5))
            }
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(color)
        }
        .frame(height: 1)
    }
}

/// Manage subscribed calendars: add a Google iCal "secret address", toggle, remove.
struct CalendarSourcesEditor: View {
    @Binding var sources: [CalendarSource]
    var onChange: () -> Void
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calendars").font(.app(.headline))
            if sources.isEmpty {
                Text("No calendars yet.").font(.app(.caption)).foregroundStyle(.tertiary)
            }
            ForEach($sources) { $src in
                HStack(spacing: 8) {
                    Toggle("", isOn: $src.enabled).labelsHidden()
                        .onChange(of: src.enabled) { save() }
                    Circle().fill(Color(hex: src.colorHex)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(src.name).font(.app(.callout)).lineLimit(1)
                        if isFile(src) {
                            Text("file").font(.app(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if isFile(src) {
                        Button("Replace…") { importFile(replacing: src) }.controlSize(.small)
                    }
                    Button { remove(src) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                }
            }
            Divider()

            Button { importFile() } label: {
                Label("Import an .ics file…", systemImage: "square.and.arrow.down")
            }
            Text("Export your (private) Google Calendar to .ics and import it — re-export to the same file to refresh.")
                .font(.app(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("…or subscribe to its “Secret address in iCal format” (live):")
                .font(.app(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name (e.g. Work)", text: $newName).textFieldStyle(.roundedBorder)
            TextField("https://calendar.google.com/…/private-…/basic.ics", text: $newURL).textFieldStyle(.roundedBorder)
            Button("Add calendar") { add() }
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16).frame(width: 400)
    }

    private func isFile(_ s: CalendarSource) -> Bool { s.url.hasPrefix("/") || s.url.hasPrefix("file://") }

    private func add() {
        let color = CalendarStore.palette[sources.count % CalendarStore.palette.count]
        sources.append(CalendarSource(
            name: newName.isEmpty ? "Calendar" : newName,
            url: newURL.trimmingCharacters(in: .whitespaces), colorHex: color))
        newName = ""; newURL = ""; save()
    }

    private func importFile(replacing: CalendarSource? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let existing = replacing, let i = sources.firstIndex(where: { $0.id == existing.id }) {
            sources[i].url = url.path
        } else {
            let color = CalendarStore.palette[sources.count % CalendarStore.palette.count]
            sources.append(CalendarSource(
                name: url.deletingPathExtension().lastPathComponent, url: url.path, colorHex: color))
        }
        save()
    }

    private func remove(_ s: CalendarSource) { sources.removeAll { $0.id == s.id }; save() }
    private func save() { CalendarStore.write(sources); onChange() }
}

/// GitHub-style activity: a contribution heatmap over the last year + a recent feed of
/// commits grouped by day (clickable). Uses the full commit history.
struct OrchestratorActivityPanel: View {
    let projects: [Project]
    @State private var commits: [CommitEvent] = []
    @State private var loading = true

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func dayKey(_ d: Date) -> String { dayFmt.string(from: d) }

    private var countsByDay: [String: Int] {
        Dictionary(grouping: commits, by: { Self.dayKey($0.time) }).mapValues(\.count)
    }
    private var projectTotals: [(name: String, count: Int)] {
        Dictionary(grouping: commits, by: \.project).mapValues(\.count)
            .map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }
    private var recentByDay: [(day: String, items: [CommitEvent])] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        return Dictionary(grouping: commits.filter { $0.time >= cutoff }, by: { Self.dayKey($0.time) })
            .map { (day: $0.key, items: $0.value.sorted { $0.time > $1.time }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                    Text("Activity").font(.app(.title3, weight: .semibold))
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Text("\(commits.count) commits").font(.app(.caption)).foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    ContributionHeatmap(countsByDay: countsByDay)
                }

                if !projectTotals.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Projects").font(.app(.headline))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(projectTotals.prefix(18), id: \.name) { p in
                                HStack(spacing: 4) {
                                    Text(p.name).font(.app(.caption)).lineLimit(1)
                                    Text("\(p.count)").font(.app(.caption2, weight: .bold)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent activity").font(.app(.headline))
                    if recentByDay.isEmpty && !loading {
                        Text("No recent commits.").font(.app(.caption)).foregroundStyle(.tertiary)
                    }
                    ForEach(recentByDay, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.day).font(.app(.caption, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(group.items) { commit in row(commit) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .task {
            loading = true
            for await batch in CommitActivity.loadEventsProgressive(projects: projects) {
                commits = batch
                loading = false
            }
        }
    }

    private func row(_ c: CommitEvent) -> some View {
        Button { if let u = c.url, let url = URL(string: u) { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: 8) {
                Text(c.time.formatted(date: .omitted, time: .shortened))
                    .font(.app(.caption2)).foregroundStyle(.tertiary).frame(width: 48, alignment: .trailing)
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Text(c.subject).font(.app(.callout)).lineLimit(1)
                Text(c.project).font(.app(.caption2)).foregroundStyle(Color.accentColor.opacity(0.8))
                Spacer(minLength: 0)
                if c.url != nil { Image(systemName: "arrow.up.right.square").font(.app(.caption2)).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle()).padding(.vertical, 3)
        }
        .buttonStyle(.plain).disabled(c.url == nil)
    }
}

/// GitHub-style contribution heatmap: 53 week-columns × 7 day-rows, coloured by commit count.
struct ContributionHeatmap: View {
    let countsByDay: [String: Int]
    private let weeks = 53
    private let cell: CGFloat = 11
    private let gap: CGFloat = 2
    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }

    private var startDate: Date {
        let today = cal.startOfDay(for: Date())
        let thisWeekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) ?? today
        return cal.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeekStart) ?? today
    }

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        let date = cal.date(byAdding: .day, value: w * 7 + d, to: startDate) ?? startDate
                        let count = countsByDay[OrchestratorActivityPanel.dayKey(date)] ?? 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(date > Date() ? Color.clear : color(count))
                            .frame(width: cell, height: cell)
                            .help("\(OrchestratorActivityPanel.dayKey(date)) · \(count) commit\(count == 1 ? "" : "s")")
                    }
                }
            }
        }
    }
    private func color(_ n: Int) -> Color {
        switch n {
        case 0: return Color.primary.opacity(0.08)
        case 1...2: return Color.green.opacity(0.35)
        case 3...5: return Color.green.opacity(0.55)
        case 6...9: return Color.green.opacity(0.78)
        default: return Color.green
        }
    }
}

/// Dedicated Mail tab — reads macOS Mail's local `.emlx` store directly (indexed +
/// incremental), so the whole inbox is available instantly and searchable, no fetch.
/// Needs Full Disk Access (TCC-protected directory); prompts for it when blocked.
struct OrchestratorMailPanel: View {
    @State private var items: [MailItem] = []
    @State private var status: Status = .loading
    @State private var query = ""
    /// Which account to show ("" = all). Persisted so the choice sticks across launches.
    @AppStorage("mailAccountFilter") private var accountFilter = ""

    enum Status: Equatable { case loading, ready, needsAccess, empty }

    private static let dayTime: DateFormatter = {
        let f = DateFormatter(); f.locale = .autoupdatingCurrent; f.dateFormat = "d MMM HH:mm"; return f
    }()

    /// Distinct account addresses present in the index (for the account picker).
    private var accounts: [String] {
        Array(Set(items.map(\.account))).filter { !$0.isEmpty }.sorted()
    }

    private var filtered: [MailItem] {
        var result = items
        if !accountFilter.isEmpty { result = result.filter { $0.account == accountFilter } }
        if !query.isEmpty {
            let q = query.lowercased()
            result = result.filter {
                $0.from.lowercased().contains(q) || $0.subject.lowercased().contains(q)
                    || $0.snippet.lowercased().contains(q) || $0.mailbox.lowercased().contains(q)
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope").font(.app(.title2))
                Text("Mail").font(.app(.title3, weight: .semibold))
                if status == .loading {
                    ProgressView().controlSize(.small)
                    Text(items.isEmpty ? "Indexation…" : "Mise à jour…")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                } else if !items.isEmpty {
                    let shown = filtered
                    let unread = shown.lazy.filter(\.unread).count
                    Text("· \(shown.count) messages\(unread > 0 ? " · \(unread) non lus" : "")")
                        .font(.app(.caption)).foregroundStyle(.tertiary)
                }
                Spacer()
                if accounts.count > 1 || (!accountFilter.isEmpty) {
                    Menu {
                        Button("Tous les comptes") { accountFilter = "" }
                        Divider()
                        ForEach(accounts, id: \.self) { acc in
                            Button(acc) { accountFilter = acc }
                        }
                    } label: {
                        Label(accountFilter.isEmpty ? "Tous les comptes" : accountFilter,
                              systemImage: "person.crop.circle")
                            .font(.app(.caption))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Button { reload() } label: { Image(systemName: "arrow.clockwise").font(.app(.caption)) }
                    .buttonStyle(.plain).disabled(status == .loading)
                    .help("Réindexer (ne parse que les nouveaux messages)")
            }

            switch status {
            case .needsAccess: accessPrompt
            case .empty: emptyState
            case .loading, .ready:
                TextField("Rechercher (expéditeur, objet, contenu, dossier)…", text: $query)
                    .textFieldStyle(.roundedBorder).font(.app(.callout))
                if items.isEmpty {
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) { ForEach(filtered) { row($0) } }
                    }
                }
            }
        }
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(24)
        .task { await load() }
    }

    private var accessPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accès complet au disque requis")
                .font(.app(.headline))
            Text("Kanban Code lit directement le stockage local de Mail.app (~/Library/Mail), protégé par macOS. Accorde l'« Accès complet au disque » à Kanban Code, puis reviens ici et réindexe.")
                .font(.app(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Ouvrir les Réglages Système") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(u)
                    }
                }
                Button("Réessayer") { reload() }
            }
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aucun message trouvé.").font(.app(.body)).foregroundStyle(.secondary)
            Text("Vérifie que ton compte est bien configuré dans l'app Mail de macOS et que les messages sont téléchargés localement, puis réindexe.")
                .font(.app(.callout)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func row(_ m: MailItem) -> some View {
        Button {
            if let s = m.mailAppURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(m.unread ? Color.accentColor : .clear)
                    .frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(m.from).font(.app(.callout, weight: m.unread ? .semibold : .regular)).lineLimit(1)
                        Spacer()
                        Text(Self.dayTime.string(from: m.date))
                            .font(.app(.caption)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Text(m.subject).font(.app(.callout)).lineLimit(1)
                        .foregroundStyle(m.unread ? .primary : .secondary)
                    if !m.snippet.isEmpty {
                        Text(m.snippet).font(.app(.caption)).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                if m.mailAppURL != nil {
                    Image(systemName: "arrow.up.right.square").font(.app(.caption)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle()).padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(m.mailAppURL == nil)
    }

    private func reload() { Task { await load() } }

    private func load() async {
        status = .loading
        for await event in MailIndexer.loadProgressive() {
            switch event {
            case .items(let list):
                items = list
                status = .ready
            case .failure(let error):
                if items.isEmpty { status = error == .needsFullDiskAccess ? .needsAccess : .empty }
            }
        }
        if items.isEmpty, status == .loading { status = .empty }
    }
}

/// Open pull requests across all cards — a quick "what's in flight" list, clickable.
struct OrchestratorPRsPanel: View {
    let cards: [KanbanCodeCard]

    private var openPRs: [(card: KanbanCodeCard, pr: PRLink)] {
        cards.flatMap { card in
            card.link.prLinks
                .filter { $0.status != .merged && $0.status != .closed }
                .map { (card: card, pr: $0) }
        }
        .sorted { $0.pr.number > $1.pr.number }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text("Pull requests").font(.app(.headline))
                Spacer()
                Text("\(openPRs.count) open").font(.app(.caption)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            ScrollView {
                if openPRs.isEmpty {
                    Text("No open pull requests.")
                        .font(.app(.body)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                VStack(spacing: 0) {
                    ForEach(openPRs, id: \.pr.number) { item in
                        Button {
                            if let u = item.pr.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(color(item.pr.status))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.pr.title ?? "PR #\(item.pr.number)").font(.app(.callout)).lineLimit(1)
                                    HStack(spacing: 8) {
                                        Text("#\(item.pr.number)").foregroundStyle(.secondary)
                                        Text(item.card.link.name ?? item.card.displayTitle)
                                            .foregroundStyle(Color.accentColor.opacity(0.85)).lineLimit(1)
                                        if let s = item.pr.status { Text(label(s)).foregroundStyle(color(s)) }
                                        if let t = item.pr.unresolvedThreads, t > 0 {
                                            Text("\(t) unresolved").foregroundStyle(.orange)
                                        }
                                    }.font(.app(.caption2))
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square").font(.app(.caption)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 8).padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.pr.url == nil)
                        Divider()
                    }
                }
            }
        }
    }

    private func label(_ s: PRStatus) -> String {
        switch s {
        case .failing: return "CI failing"
        case .unresolved: return "unresolved"
        case .changesRequested: return "changes requested"
        case .reviewNeeded: return "review needed"
        case .pendingCI: return "CI pending"
        case .approved: return "approved"
        case .merged: return "merged"
        case .closed: return "closed"
        }
    }
    private func color(_ s: PRStatus?) -> Color {
        switch s {
        case .approved: return .green
        case .failing, .changesRequested: return .red
        case .reviewNeeded, .pendingCI, .unresolved: return .orange
        default: return .gray
        }
    }
}

/// Dedicated orchestrator chat: the live Claude session full-bleed (no card-detail
/// chrome), plus a bar of one-tap Jarvis actions that inject ready-made prompts into
/// the tmux session. Replaces the generic CardDetailView for the Chat tab.
struct OrchestratorChatView: View {
    let card: KanbanCodeCard
    var githubBaseURL: String? = nil

    private var session: String? { card.link.tmuxLink?.sessionName }

    private struct QuickAction: Identifiable {
        let id = UUID(); let label: String; let icon: String; let prompt: String
    }
    private let actions: [QuickAction] = [
        .init(label: "Recap du jour", icon: "sun.max",
              prompt: "Fais-moi le recap de ma journée : lance `kanban activity --days 1 --json`, puis résume par projet ce sur quoi j'ai travaillé."),
        .init(label: "Timesheet", icon: "clock",
              prompt: "Aide-moi à faire mon timesheet du jour : croise `kanban activity --days 1 --json` avec mon calendrier (~/.kanban-code/calendars.json) pour reconstituer ma journée heure par heure (code / réunions / trous)."),
        .init(label: "Découper une tâche", icon: "square.stack.3d.up",
              prompt: "J'ai une tâche à découper. Utilise le skill task-orchestrator pour la casser en cartes Backlog avec leurs dépendances, et propose-moi le plan AVANT de créer quoi que ce soit."),
        .init(label: "Trier mes mails", icon: "envelope",
              prompt: "Lis et trie ma boîte via le MCP Gmail : liste les mails importants / non lus (expéditeur, sujet, date), ce qui attend une réponse, et ce que je peux ignorer. (L'onglet Mail affiche déjà ma boîte locale — ici je veux ton analyse.)"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(actions) { a in
                        Button { send(a.prompt) } label: {
                            Label(a.label, systemImage: a.icon).font(.app(.caption))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(session == nil)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            Divider()
            if let session {
                TerminalContainerView(
                    sessions: [session], activeSession: session,
                    grabFocus: true, githubBaseURL: githubBaseURL)
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Démarrage de l'orchestrateur…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Paste a prompt into the Claude session and submit it. Uses bracketed paste
    /// (load-buffer + paste-buffer -p, then Enter) — a raw `send-keys -l` doesn't work
    /// because Claude Code expects a paste event, not literally typed characters.
    private func send(_ prompt: String) {
        guard let session else { return }
        Task { try? await TmuxAdapter().pastePrompt(to: session, text: prompt) }
    }
}

/// Personal todo list, drivable by the orchestrator agent via `kanban todo` (shared
/// todos.json) and editable inline here. The user's "todo list I can pilot" brick.
struct OrchestratorTodosPanel: View {
    /// Project new in-panel todos are tagged with (the orchestrator's current project).
    var defaultProject: String? = nil
    @State private var todos: [Todo] = []
    @State private var newText = ""
    @State private var editingOdoo: String? = nil   // todo id whose Odoo-link popover is open
    @State private var odooDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist"); Text("Todos").font(.app(.headline))
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise").font(.app(.caption)) }
                    .buttonStyle(.plain).help("Refresh (pick up the orchestrator's changes)")
            }

            TextField("Add a todo…", text: $newText)
                .textFieldStyle(.roundedBorder).font(.app(.caption))
                .onSubmit(add)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(TodoStore.sorted(todos)) { todo in
                        HStack(alignment: .top, spacing: 6) {
                            Button { toggle(todo) } label: {
                                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(todo.done ? Color.green : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(todo.text)
                                    .font(.app(.caption))
                                    .strikethrough(todo.done)
                                    .foregroundStyle(todo.done ? .secondary : .primary)
                                if let project = todo.project, !project.isEmpty {
                                    Text(project)
                                        .font(.app(size: 8, weight: .medium))
                                        .foregroundStyle(Color.accentColor.opacity(0.8))
                                }
                            }
                            Spacer(minLength: 0)
                            Button {
                                odooDraft = todo.odooTaskId.map(String.init) ?? ""
                                editingOdoo = todo.id
                            } label: {
                                if let odoo = todo.odooTaskId {
                                    Text("Odoo #\(odoo)").font(.app(size: 8, weight: .medium))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.purple.opacity(0.12), in: Capsule())
                                        .foregroundStyle(.purple)
                                } else {
                                    Image(systemName: "link").font(.app(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(todo.odooTaskId == nil ? "Link an Odoo task id" : "Edit / unlink the Odoo task")
                            .popover(isPresented: Binding(
                                get: { editingOdoo == todo.id },
                                set: { if !$0 { editingOdoo = nil } })) {
                                odooEditor(todo)
                            }
                            Button { togglePublish(todo) } label: {
                                Image(systemName: todo.publish ? "cloud.fill" : "cloud")
                                    .foregroundStyle(todo.publish ? Color.blue : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(todo.publish ? "Marked to sync to Odoo" : "Mark to sync to Odoo (the orchestrator pushes it)")
                        }
                    }
                    if todos.isEmpty {
                        Text("No todos. Add one, or ask the orchestrator to.")
                            .font(.app(.caption)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .task { reload() }
    }

    @ViewBuilder
    private func odooEditor(_ todo: Todo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link to Odoo").font(.app(.caption).bold())
            HStack(spacing: 4) {
                Text("Task id").font(.app(size: 9)).foregroundStyle(.secondary)
                TextField("e.g. 690", text: $odooDraft)
                    .textFieldStyle(.roundedBorder).font(.app(.caption)).frame(width: 90)
                    .onSubmit { setOdoo(todo) }
            }
            Text("The orchestrator syncs published todos to this task via Odoo.")
                .font(.app(size: 9)).foregroundStyle(.tertiary).frame(width: 190, alignment: .leading)
            HStack {
                if todo.odooTaskId != nil {
                    Button("Unlink", role: .destructive) { odooDraft = ""; setOdoo(todo) }
                        .font(.app(.caption))
                }
                Spacer()
                Button("Save") { setOdoo(todo) }.font(.app(.caption)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12).frame(width: 214)
    }

    private func setOdoo(_ todo: Todo) {
        var list = TodoStore.read()
        if let i = list.firstIndex(where: { $0.id == todo.id }) {
            let trimmed = odooDraft.trimmingCharacters(in: .whitespaces)
            list[i].odooTaskId = trimmed.isEmpty ? nil : Int(trimmed)
            // Linking to a task implies you want it published; unlinking clears that intent.
            if list[i].odooTaskId != nil { list[i].publish = true }
            TodoStore.write(list)
        }
        editingOdoo = nil
        reload()
    }

    private func reload() { todos = TodoStore.read() }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = TodoStore.read()
        list.append(Todo(text: t, project: defaultProject))
        TodoStore.write(list)
        newText = ""
        reload()
    }

    private func toggle(_ todo: Todo) {
        var list = TodoStore.read()
        if let i = list.firstIndex(where: { $0.id == todo.id }) {
            list[i].done.toggle()
            TodoStore.write(list)
        }
        reload()
    }

    private func togglePublish(_ todo: Todo) {
        var list = TodoStore.read()
        if let i = list.firstIndex(where: { $0.id == todo.id }) {
            list[i].publish.toggle()
            TodoStore.write(list)
        }
        reload()
    }
}
