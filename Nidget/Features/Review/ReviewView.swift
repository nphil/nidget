import SwiftUI

// MARK: - ReviewView
//
// The daily triage screen (ARCHITECTURE §14). The owner's Actual server imports from SimpleFIN,
// so the everyday job is not typing transactions in — it is saying yes or no to the ones that
// already arrived. `AppStore.reviewQueue()` hands back `ReviewGroup`s and this screen renders
// them in three bands:
//
//   1. Suggestions with more than one transaction: a themed card per proposed category with an
//      "Accept all N" button, so a run of the same coffee shop is one tap.
//   2. Suggestions with exactly ONE transaction: pooled into a single "One-offs" card as plain
//      rows with an Accept button each. On a normal day most groups have one item, and a stack of
//      group boxes each wrapping a single row reads as ceremony. This keeps a light day looking
//      like a short list.
//   3. "Needs a category" rows (no guess at all), then "Nidget filed these" — the auto-filed set,
//      collapsed behind a disclosure row, there to be spot-checked rather than worked through.
//
// Tapping any row anywhere opens `CategoryPickerSheet` for that one transaction. Every accept,
// bulk or single, is ONE `applyCategories` call; it returns the previous values, which is what the
// in-screen undo banner replays. Swiping a row skips it for this session only (it stays in the
// queue and comes back next launch).
//
// Per LESSONS §perf: no geometry readers, no scroll-position observers, nothing per row beyond a
// single horizontal drag gesture for the skip.

struct ReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var groups: [ReviewGroup] = []
    @State private var hasLoaded = false
    /// Skipped this session only. Never written anywhere.
    @State private var skipped: Set<String> = []
    @State private var autoFiledExpanded = false
    @State private var picker: ReviewPickerTarget?
    @State private var undo: ReviewUndo?

    init() {}

    var body: some View {
        scrollBody
            .themedScreen()
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.large)
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $picker) { target in
                CategoryPickerSheet(categoryID: pickerBinding(target))
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .overlay(alignment: .bottom) { undoBanner }
            .task(id: undo?.id) { await expireUndo() }
    }

    // MARK: Screen

    private var scrollBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.layout.cardSpacing) {
                if !hasLoaded {
                    loadingLine
                } else if visibleGroups.isEmpty {
                    emptyState
                } else {
                    countHeader
                    ForEach(multiItemSuggestions) { group in
                        suggestionCard(group)
                    }
                    if !singleItemSuggestions.isEmpty {
                        singlesCard
                    }
                    if let needs = needsCategoryGroup {
                        needsCategoryCard(needs)
                    }
                    if let filed = autoFiledGroup {
                        autoFiledCard(filed)
                    }
                }
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, 110)
            .animation(reduceMotion ? nil : theme.motion.spring, value: visibleGroups)
            .animation(reduceMotion ? nil : theme.motion.spring, value: autoFiledExpanded)
        }
        .scrollIndicators(.hidden)
    }

    private var loadingLine: some View {
        Text("Looking for what came in…")
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textTertiary)
            .padding(.top, theme.layout.spacing * 2)
            .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        EmptyStateView(systemImage: "checkmark.circle",
                       title: "All caught up.",
                       message: "Nothing is waiting for a category. New transactions land here after your bank syncs.")
            .padding(.top, theme.layout.spacing * 4)
    }

    private var countHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(decisionCount == 1 ? "1 needs a decision" : "\(decisionCount) need a decision")
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
            Text("Accept the ones that look right. Tap any row to change it.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(.bottom, theme.layout.spacing * 0.25)
    }

    // MARK: Suggestion groups (more than one transaction)

    private func suggestionCard(_ group: ReviewGroup) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            groupHeader(group)
            rowStack(group.items) { item in
                ReviewRowView(item: item,
                              subtitle: nil,
                              subtitleIcon: nil,
                              trailing: .plain,
                              onTap: { openPicker(for: item) },
                              onAction: { },
                              onSkip: { skip(item) })
            }
            NidgetButton("Accept all \(group.items.count)") {
                accept(group.items, categoryID: group.categoryID)
            }
        }
        .themedCard()
    }

    private func groupHeader(_ group: ReviewGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.layout.spacing * 0.5) {
            Image(systemName: sourceIcon(groupSource(group)))
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(sourceBlurb(groupSource(group), plural: group.items.count > 1))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: theme.layout.spacing * 0.5)
            countPill(group.items.count)
        }
        .accessibilityElement(children: .combine)
    }

    private func countPill(_ count: Int) -> some View {
        Text("\(count)")
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textSecondary)
            .monospacedDigit()
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.palette.fill))
    }

    // MARK: One-off suggestions

    private var singlesCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            SectionHeader(singleItemSuggestions.count == 1 ? "One to accept" : "Ones and twos")
            rowStack(singleItemSuggestions) { item in
                ReviewRowView(item: item,
                              subtitle: store.categoryName(item.proposedCategoryID),
                              subtitleIcon: sourceIcon(item.source),
                              trailing: .accept,
                              onTap: { openPicker(for: item) },
                              onAction: { accept([item], categoryID: item.proposedCategoryID) },
                              onSkip: { skip(item) })
            }
        }
        .themedCard()
    }

    // MARK: Needs a category

    private func needsCategoryCard(_ group: ReviewGroup) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader("Needs a category")
                Text("No guess for these yet. Pick one and Nidget will remember.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            rowStack(group.items) { item in
                ReviewRowView(item: item,
                              subtitle: nil,
                              subtitleIcon: nil,
                              trailing: .pick,
                              onTap: { openPicker(for: item) },
                              onAction: { openPicker(for: item) },
                              onSkip: { skip(item) })
            }
        }
        .themedCard()
    }

    // MARK: Nidget filed these

    private func autoFiledCard(_ group: ReviewGroup) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            Button {
                Haptics.tap()
                autoFiledExpanded.toggle()
            } label: {
                HStack(spacing: theme.layout.spacing * 0.5) {
                    Image(systemName: "sparkles")
                        .font(theme.font(.subheadline))
                        .fontWeight(theme.icons.weight)
                        .symbolVariant(theme.icons.fill ? .fill : .none)
                        .foregroundStyle(theme.palette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nidget filed these")
                            .font(theme.font(.headline))
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                        Text(group.items.count == 1
                             ? "1 was sure enough to file on its own"
                             : "\(group.items.count) were sure enough to file on their own")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: theme.layout.spacing * 0.5)
                    Image(systemName: "chevron.right")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                        .rotationEffect(.degrees(autoFiledExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(autoFiledExpanded ? "Hides the list" : "Shows the list")

            if autoFiledExpanded {
                rowStack(group.items) { item in
                    ReviewRowView(item: item,
                                  subtitle: store.categoryName(item.transaction.categoryID),
                                  subtitleIcon: nil,
                                  trailing: .confirm,
                                  onTap: { openPicker(for: item) },
                                  onAction: { confirm(item) },
                                  onSkip: { skip(item) })
                }
            }
        }
        .themedCard()
    }

    // MARK: Row scaffolding

    @ViewBuilder
    private func rowStack<Row: View>(_ items: [ReviewItem],
                                     @ViewBuilder row: @escaping (ReviewItem) -> Row) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                if item.id != items.last?.id {
                    Rectangle()
                        .fill(theme.palette.separator)
                        .frame(height: 0.5)
                }
            }
        }
    }

    // MARK: Undo banner
    //
    // In-screen on purpose: RootView owns the app's global chrome and this screen is the only
    // place that knows what to put back. `undo` holds the previous (transactionID, categoryID)
    // pairs the first `applyCategories` handed back, so undo is just the same call in reverse.
    // Its `id` drives the `.task(id:)` timer, so a new accept restarts the countdown instead of
    // inheriting the old one's.

    @ViewBuilder
    private var undoBanner: some View {
        if let undo {
            HStack(spacing: theme.layout.spacing) {
                Text(undo.message)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Undo") {
                    perform(undo: undo)
                }
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.accent)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .frame(minHeight: 56)
            .background {
                theme.cardShape
                    .fill(theme.palette.surface)
                    .overlay(theme.cardShape.strokeBorder(theme.palette.surfaceBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.bottom, theme.layout.cardPadding)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func expireUndo() async {
        guard undo != nil else { return }
        try? await Task.sleep(for: .seconds(6))
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : theme.motion.spring) { undo = nil }
    }

    private func perform(undo state: ReviewUndo) {
        Haptics.tap()
        withAnimation(reduceMotion ? nil : theme.motion.spring) { undo = nil }
        Task {
            let assignments = state.previous.map {
                (transactionID: $0.transactionID, categoryID: $0.categoryID)
            }
            await store.applyCategories(assignments)
            // The rows have to come back, and only the store knows what shape they return in.
            await load()
        }
    }

    // MARK: Data

    private var visibleGroups: [ReviewGroup] {
        groups.compactMap { group in
            let items = group.items.filter { !skipped.contains($0.id) }
            guard !items.isEmpty else { return nil }
            var trimmed = group
            trimmed.items = items
            return trimmed
        }
    }

    private var multiItemSuggestions: [ReviewGroup] {
        visibleGroups.filter { $0.kind == .suggestion && $0.items.count > 1 }
    }

    private var singleItemSuggestions: [ReviewItem] {
        visibleGroups.filter { $0.kind == .suggestion && $0.items.count == 1 }.flatMap(\.items)
    }

    private var needsCategoryGroup: ReviewGroup? {
        visibleGroups.first { $0.kind == .needsCategory }
    }

    private var autoFiledGroup: ReviewGroup? {
        visibleGroups.first { $0.kind == .autoFiled }
    }

    /// Auto-filed rows are already filed, so they are spot checks rather than decisions.
    private var decisionCount: Int {
        visibleGroups.filter { $0.kind != .autoFiled }.reduce(0) { $0 + $1.items.count }
    }

    private func load() async {
        let queue = await store.reviewQueue()
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            groups = queue
            hasLoaded = true
        }
    }

    // MARK: Actions

    private func accept(_ items: [ReviewItem], categoryID: String?) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        Haptics.success()
        remove(ids)
        Task {
            let assignments = ids.map { (transactionID: $0, categoryID: categoryID) }
            let previous = await store.applyCategories(assignments)
            guard let previous, !previous.isEmpty else {
                // The rows left the list the moment they were tapped, so the screen is now
                // claiming work that didn't happen. Reload rather than leave that lie sitting
                // there: applyCategories already surfaced the reason through the error toast,
                // and the store is the only thing that knows what actually landed.
                await load()
                return
            }
            show(undo: ReviewUndo(message: acceptedMessage(count: ids.count, categoryID: categoryID),
                                  previous: previous.map {
                                      ReviewUndo.Prior(transactionID: $0.transactionID,
                                                       categoryID: $0.categoryID)
                                  }))
        }
    }

    /// Auto-filed row the owner agrees with: nothing to write, it just leaves the queue.
    private func confirm(_ item: ReviewItem) {
        Haptics.tick()
        remove([item.id])
        store.markReviewed([item.id])
    }

    private func skip(_ item: ReviewItem) {
        Haptics.tick()
        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            _ = skipped.insert(item.id)
        }
    }

    private func remove(_ ids: [String]) {
        let set = Set(ids)
        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            for index in groups.indices {
                groups[index].items.removeAll { set.contains($0.id) }
            }
            groups.removeAll { $0.items.isEmpty }
        }
    }

    private func show(undo state: ReviewUndo) {
        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            undo = state
        }
    }

    private func acceptedMessage(count: Int, categoryID: String?) -> String {
        let name = store.categoryName(categoryID)
        guard categoryID != nil, !name.isEmpty else {
            return count == 1 ? "Cleared the category on 1" : "Cleared the category on \(count)"
        }
        return "Filed \(count) as \(name)"
    }

    // MARK: Category picker

    private func openPicker(for item: ReviewItem) {
        Haptics.tap()
        picker = ReviewPickerTarget(id: item.id,
                                    currentCategoryID: item.transaction.categoryID
                                        ?? item.proposedCategoryID)
    }

    /// The sheet writes through this binding and dismisses itself; the write is the accept.
    private func pickerBinding(_ target: ReviewPickerTarget) -> Binding<String?> {
        Binding(get: { target.currentCategoryID },
                set: { newValue in
                    guard let item = item(withID: target.id) else { return }
                    accept([item], categoryID: newValue)
                })
    }

    private func item(withID id: String) -> ReviewItem? {
        for group in groups {
            if let match = group.items.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    // MARK: Source wording

    private func groupSource(_ group: ReviewGroup) -> ReviewSource {
        group.items.first?.source ?? ReviewSource.none
    }

    private func sourceIcon(_ source: ReviewSource) -> String {
        switch source {
        case .payeeHistory: return "clock.arrow.circlepath"
        case .ai, .autoFiled: return "sparkles"
        case .none: return "questionmark.circle"
        }
    }

    private func sourceBlurb(_ source: ReviewSource, plural: Bool) -> String {
        switch source {
        case .payeeHistory:
            return plural ? "You usually file these here" : "You usually file it here"
        case .ai:
            return "Nidget's best guess"
        case .autoFiled:
            return "Already filed"
        case .none:
            return "Waiting on you"
        }
    }
}

// MARK: - ReviewPickerTarget

/// One transaction handed to `CategoryPickerSheet`. Identifiable so `.sheet(item:)` swaps cleanly
/// when a second row is tapped before the first sheet finishes dismissing.
private struct ReviewPickerTarget: Identifiable {
    let id: String
    let currentCategoryID: String?
}

// MARK: - ReviewUndo

/// What the banner needs to put an accept back: the sentence to show, and the exact assignments
/// `applyCategories` reported as the previous state.
private struct ReviewUndo: Equatable {
    struct Prior: Equatable {
        let transactionID: String
        let categoryID: String?
    }

    let id = UUID()
    let message: String
    let previous: [Prior]
}

// MARK: - ReviewRowView
//
// One transaction: payee, date, an optional category chip, the amount, and an optional trailing
// action. Tapping the body opens the picker; a horizontal drag past 90pt skips the row for this
// session. The drag lives here (one small `@State` per row) rather than in a `List`, because the
// screen is cards rather than list rows and `.swipeActions` needs a `List`.

private struct ReviewRowView: View {
    enum Trailing {
        case plain, accept, confirm, pick
    }

    let item: ReviewItem
    let subtitle: String?
    let subtitleIcon: String?
    let trailing: Trailing
    let onTap: () -> Void
    let onAction: () -> Void
    let onSkip: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragX: CGFloat = 0

    var body: some View {
        HStack(spacing: theme.layout.spacing * 0.5) {
            Button(action: onTap) {
                rowLabel
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the category picker")

            if trailing != .plain {
                actionButton
            }
        }
        .offset(x: dragX)
        .gesture(skipGesture)
        .accessibilityAction(named: Text("Skip for now")) { onSkip() }
    }

    private var rowLabel: some View {
        HStack(spacing: theme.layout.spacing * 0.5) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.payeeName.isEmpty ? "No payee" : item.payeeName)
                    .font(theme.font(.headline))
                    .foregroundStyle(item.payeeName.isEmpty
                                     ? theme.palette.textTertiary
                                     : theme.palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.transaction.date.shortDisplay)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                    if let subtitle, !subtitle.isEmpty {
                        chip(subtitle)
                    }
                }
            }
            Spacer(minLength: theme.layout.spacing * 0.5)
            AmountText(item.transaction.amount, style: .body)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 3) {
            if let subtitleIcon {
                Image(systemName: subtitleIcon)
                    .font(theme.font(.label))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.accent)
            }
            Text(text)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.palette.fill))
    }

    @ViewBuilder
    private var actionButton: some View {
        Button(action: onAction) {
            Text(actionTitle)
                .font(theme.font(.subheadline))
                .fontWeight(.semibold)
                .foregroundStyle(trailing == .pick ? theme.palette.textSecondary : theme.palette.accent)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(Capsule().fill(theme.palette.fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
    }

    private var actionTitle: String {
        switch trailing {
        case .accept: return "Accept"
        case .confirm: return "Looks right"
        case .pick: return "Pick"
        case .plain: return ""
        }
    }

    // MARK: Skip gesture
    //
    // Horizontal-dominant only, so a vertical flick still scrolls the page. No animation on the
    // follow (it tracks the finger); the release either snaps back or hands the row to the
    // parent, whose own transition takes it away.

    private var skipGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                if horizontal, abs(value.translation.width) > 90 {
                    dragX = 0
                    onSkip()
                } else {
                    withAnimation(reduceMotion ? nil : theme.motion.snappy) { dragX = 0 }
                }
            }
    }
}
