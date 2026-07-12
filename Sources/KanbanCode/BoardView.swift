import SwiftUI
import KanbanCodeCore

struct BoardView: View {
    var store: BoardStore
    @State private var dragState = DragState()
    @State private var sidebarReorderState = SidebarReorderState()
    @State private var renamingPinnedCardId: String?
    var onOpenChannel: (String) -> Void = { _ in }
    var onNewChannel: () -> Void = {}
    var onDeleteChannel: (String) -> Void = { _ in }
    var onRenameChannel: (String) -> Void = { _ in }
    var unreadCountForChannel: (Channel) -> Int = { _ in 0 }
    var onlineCountForChannel: (Channel) -> Int = { _ in 0 }
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String, Bool) -> Void = { _, _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
    var onCopyConversationMarkdown: (String) -> Void = { _ in }
    var onDiscoverCard: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var canCleanupWorktree: (String) -> Bool = { _ in true }
    var onArchiveCard: (String) -> Void = { _ in }
    var onDeleteCard: (String) -> Void = { _ in }
    let onSetCardPinned: (String, Bool) -> Void
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String, String) -> Void = { _, _ in }
    var onMoveToFolder: (String) -> Void = { _ in }
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (String, CodingAssistant) -> Void = { _, _ in }
    var onRefreshBacklog: () -> Void = {}

    var canDropCard: (KanbanCodeCard, KanbanCodeColumn) -> Bool = { _, _ in true }
    var onDropCard: (String, KanbanCodeColumn) -> Void = { _, _ in }
    var onMergeCards: (String, String) -> Void = { _, _ in }   // (sourceId, targetId)
    var onNewTask: () -> Void = {}
    var onCardClicked: (String) -> Void = { _ in }
    var onColumnBackgroundClick: (KanbanCodeColumn) -> Void = { _ in }

    var body: some View {
        boardContent
    }

    @ViewBuilder
    private var channelsPseudoColumn: some View {
        let channels = store.state.channels
        let pinnedCards = store.state.pinnedCards
        if !channels.isEmpty || !pinnedCards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !channels.isEmpty {
                    // Subtle header so the column reads as "Channels" without competing with real columns.
                    HStack(spacing: 6) {
                        Text("Channels")
                            .font(.app(.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        Spacer(minLength: 0)
                        Button(action: onNewChannel) {
                            Image(systemName: "plus")
                                .font(.app(.caption))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New chat channel")
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)

                    ForEach(channels) { ch in
                        let msgs = store.state.channelMessages[ch.name]
                        let last = msgs?.last
                        SidebarReorderableRow(
                            item: .channel(ch.id),
                            reorderState: sidebarReorderState,
                            onMove: reorderChannel
                        ) {
                            ChannelTile(
                                channel: ch,
                                onlineCount: onlineCountForChannel(ch),
                                lastMessageAt: last?.ts,
                                lastMessageBody: last?.body,
                                isSelected: store.state.selectedChannelName == ch.name,
                                unreadCount: unreadCountForChannel(ch),
                                onOpen: { onOpenChannel(ch.name) },
                                onDelete: { onDeleteChannel(ch.name) },
                                onRename: { onRenameChannel(ch.name) }
                            )
                        }
                    }
                    if channels.count > 1 {
                        SidebarReorderEndTarget(
                            kind: .channel(""),
                            reorderState: sidebarReorderState,
                            onMove: reorderChannel
                        )
                    }
                }

                if !pinnedCards.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "pin.fill")
                        Text("Pinned")
                        Spacer(minLength: 0)
                        Text("\(pinnedCards.count)")
                    }
                    .font(.app(.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.top, channels.isEmpty ? 2 : 6)

                    ForEach(pinnedCards) { card in
                        SidebarReorderableRow(
                            item: .pinnedCard(card.id),
                            reorderState: sidebarReorderState,
                            onMove: reorderPinnedCard
                        ) {
                            pinnedCardView(for: card)
                        }
                    }
                    if pinnedCards.count > 1 {
                        SidebarReorderEndTarget(
                            kind: .pinnedCard(""),
                            reorderState: sidebarReorderState,
                            onMove: reorderPinnedCard
                        )
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(width: 240, alignment: .top)
        }
    }

    private func reorderChannel(_ channelId: String, _ targetChannelId: String?, _ above: Bool) {
        store.dispatch(.reorderChannel(channelId: channelId, targetChannelId: targetChannelId, above: above))
    }

    private func reorderPinnedCard(_ cardId: String, _ targetCardId: String?, _ above: Bool) {
        store.dispatch(.reorderPinnedCard(cardId: cardId, targetCardId: targetCardId, above: above))
    }

    private var boardContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    channelsPseudoColumn
                        .id("channels")
                    ForEach(store.state.visibleColumns, id: \.self) { column in
                        DroppableColumnView(
                            column: column,
                            cards: store.state.unpinnedCards(in: column),
                            selectedCardId: Binding(
                                get: { store.state.selectedCardId },
                                set: { store.dispatch(.selectCard(cardId: $0)) }
                            ),
                            dragState: dragState,
                            canDropCard: canDropCard,
                            isRefreshingBacklog: store.state.isRefreshingBacklog,
                            onMoveCard: { cardId, targetColumn in
                                onDropCard(cardId, targetColumn)
                            },
                            onMergeCards: { sourceId, targetId in
                                onMergeCards(sourceId, targetId)
                            },
                            onReorderCard: { cardId, targetCardId, above in
                                store.dispatch(.reorderCard(cardId: cardId, targetCardId: targetCardId, above: above))
                            },
                            onRenameCard: { cardId, name in
                                store.dispatch(.renameCard(cardId: cardId, name: name))
                            },
                            onArchiveCard: { cardId in
                                onArchiveCard(cardId)
                            },
                            onStartCard: onStartCard,
                            onResumeCard: onResumeCard,
                            onForkCard: onForkCard,
                            onCopyResumeCmd: onCopyResumeCmd,
                            onCopyConversationMarkdown: onCopyConversationMarkdown,
                            onSetCardPinned: onSetCardPinned,
                            onDiscoverCard: onDiscoverCard,
                            onCleanupWorktree: onCleanupWorktree,
                            canCleanupWorktree: canCleanupWorktree,
                            onDeleteCard: onDeleteCard,
                            availableProjects: availableProjects,
                            onMoveToProject: onMoveToProject,
                            onMoveToFolder: onMoveToFolder,
                            enabledAssistants: enabledAssistants,
                            onMigrateAssistant: onMigrateAssistant,
                            onRefreshBacklog: column == .backlog ? onRefreshBacklog : nil,
                            onCardClicked: onCardClicked,
                            onCmdClickCard: { store.dispatch(.cmdClickCard(cardId: $0)) },
                            onColumnBackgroundClick: onColumnBackgroundClick
                        )
                        .id(column)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 52)
                .padding(.bottom, 16)
                .overlayPreferenceValue(CardBoundsPreferenceKey.self) { anchors in
                    dependencyArrows(anchors)
                }
            }
            .onChange(of: store.state.selectedCardId) {
                // Scroll to the column containing the selected card
                guard let selectedId = store.state.selectedCardId else { return }
                if store.state.pinnedCards.contains(where: { $0.id == selectedId }) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("channels", anchor: .leading)
                    }
                    return
                }
                for col in store.state.visibleColumns {
                    if store.state.cards(in: col).contains(where: { $0.id == selectedId }) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(col, anchor: .center)
                        }
                        break
                    }
                }
            }
        }
        // Error banner at bottom
        .overlay(alignment: .bottom) {
            if let error = store.state.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.app(.title3))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text(error)
                        .font(.app(.body, weight: .medium))
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        store.dispatch(.setError(nil))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.state.error != nil)
        // Dependency-linking hint (⌘+click flow)
        .overlay(alignment: .top) {
            if let sourceId = store.state.linkingSourceCardId {
                let name = store.state.links[sourceId]?.displayTitle ?? "card"
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Color.accentColor)
                    Text("Linking from “\(name)” — ⌘+click the dependent card")
                        .font(.app(.body, weight: .medium))
                        .lineLimit(1)
                    Button("Cancel") { store.dispatch(.cancelLinking) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.state.linkingSourceCardId)
        // Empty board hint
        .overlay {
            if store.state.filteredCards.isEmpty && !store.state.isLoading {
                VStack(spacing: 12) {
                    if let projectPath = store.state.selectedProjectPath {
                        let name = store.state.configuredProjects.first(where: { $0.path == projectPath })?.name
                            ?? (projectPath as NSString).lastPathComponent
                        Text("No sessions yet for \(name)")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions found")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    }
                    Text("Create a new task or start an assistant session to get going.")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)

                    Button(action: onNewTask) {
                        Label("New Task  \(AppShortcut.newTask.displayString)", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { renamingPinnedCardId != nil },
            set: { if !$0 { renamingPinnedCardId = nil } }
        )) {
            if let cardId = renamingPinnedCardId,
               let card = store.state.pinnedCards.first(where: { $0.id == cardId }) {
                RenameSessionDialog(
                    currentName: card.link.name ?? card.displayTitle,
                    isPresented: Binding(
                        get: { renamingPinnedCardId != nil },
                        set: { if !$0 { renamingPinnedCardId = nil } }
                    ),
                    onRename: { name in store.dispatch(.renameCard(cardId: cardId, name: name)) }
                )
            }
        }
    }

    // MARK: - Dependency graph arrows

    /// Draw an arrow for every `dependsOn` edge — from the prerequisite card to the
    /// dependent card — resolved into the board's coordinate space. Sits behind the
    /// cards so it shows through the gaps; endpoints are clipped to each card's edge.
    @ViewBuilder
    private func dependencyArrows(_ anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            Canvas { ctx, _ in
                for card in store.state.cards {
                    guard let deps = card.link.dependsOn, !deps.isEmpty,
                          let toAnchor = anchors[card.id] else { continue }
                    let toRect = proxy[toAnchor]
                    for depId in deps {
                        guard let fromAnchor = anchors[depId] else { continue }
                        drawArrow(&ctx, from: proxy[fromAnchor], to: toRect)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Draw one dependency edge as an arc bowing into the right-hand gutter, from the
    /// prerequisite's right edge to the dependent's right edge, arrowhead on the
    /// dependent. Bowing outward (scaled by the vertical span) keeps parallel edges
    /// from stacking on top of each other and keeps the card faces clear.
    private func drawArrow(_ ctx: inout GraphicsContext, from: CGRect, to: CGRect) {
        // Anchor just OUTSIDE the right edge so the arcs live in the gutter, clear of
        // the cards' play buttons.
        let gap: CGFloat = 3
        let start = CGPoint(x: from.maxX + gap, y: from.midY)
        let end = CGPoint(x: to.maxX + gap, y: to.midY)
        let color = Color.accentColor.opacity(0.75)

        // Control point out to the right; longer edges bow further so they nest.
        let span = abs(end.y - start.y)
        let bow = min(120, 30 + span * 0.18)
        let control = CGPoint(x: max(start.x, end.x) + bow, y: (start.y + end.y) / 2)

        var line = Path()
        line.move(to: start)
        line.addQuadCurve(to: end, control: control)
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        // Arrowhead along the curve's tangent at the dependent end.
        let angle = atan2(end.y - control.y, end.x - control.x)
        let headLen: CGFloat = 8
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x + cos(angle + .pi * 0.82) * headLen,
                                 y: end.y + sin(angle + .pi * 0.82) * headLen))
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x + cos(angle - .pi * 0.82) * headLen,
                                 y: end.y + sin(angle - .pi * 0.82) * headLen))
        ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func pinnedCardView(for card: KanbanCodeCard) -> CardView {
        CardView(
            card: card,
            isSelected: card.id == store.state.selectedCardId,
            onCopyConversationMarkdown: { onCopyConversationMarkdown(card.id) },
            onSetPinned: { isPinned in onSetCardPinned(card.id, isPinned) },
            onSelect: {
                if NSEvent.modifierFlags.contains(.command) {
                    store.dispatch(.cmdClickCard(cardId: card.id))
                    return
                }
                let newId = store.state.selectedCardId == card.id ? nil : card.id
                store.dispatch(.selectCard(cardId: newId))
                if newId != nil { onCardClicked(card.id) }
            },
            onStart: { onStartCard(card.id) },
            onResume: { onResumeCard(card.id) },
            onFork: { keepWorktree in onForkCard(card.id, keepWorktree) },
            onRenameRequest: { renamingPinnedCardId = card.id },
            onCopyResumeCmd: { onCopyResumeCmd(card.id) },
            onDiscover: { onDiscoverCard(card.id) },
            onCleanupWorktree: { onCleanupWorktree(card.id) },
            canCleanupWorktree: canCleanupWorktree(card.id),
            onArchive: { onArchiveCard(card.id) },
            onDelete: { onDeleteCard(card.id) },
            availableProjects: availableProjects,
            onMoveToProject: { projectPath in onMoveToProject(card.id, projectPath) },
            onMoveToFolder: { onMoveToFolder(card.id) },
            enabledAssistants: enabledAssistants,
            onMigrateAssistant: { target in onMigrateAssistant(card.id, target) }
        )
    }
}
