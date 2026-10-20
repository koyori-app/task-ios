import SwiftUI

/// 自分宛ての通知（テナント・プロジェクトをまたぐ）。開くと既読にして、タスクやレビューへ進める。
struct NotificationsView: View {
    /// 未読数が変わるたびに呼ぶ（一覧の上のベルに出す）
    let onUnreadCountChange: (Int) -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// `nil` はすべて。API の `kind`（`task` / `review`）
    @State private var kind: String?
    @State private var notifications: [AppNotification]?
    /// `notifications` を読んだときの `kind`。詳細から戻るたびに読み直して続きを失わないよう比べる
    @State private var loadedKind: String??
    @State private var nextCursor: String?
    @State private var unreadCount = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Picker("種類", selection: $kind) {
                    Text("すべて").tag(String?.none)
                    Text("タスク").tag(Optional("task"))
                    Text("レビュー").tag(Optional("review"))
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                ForEach(notifications ?? []) { item in
                    Group {
                        if let destination = destination(item) {
                            NavigationLink {
                                destination.task { await markRead(item) }
                            } label: {
                                NotificationRow(item: item)
                            }
                        } else {
                            NotificationRow(item: item)
                        }
                    }
                    .swipeActions {
                        if item.readAt == nil {
                            Button("既読にする", systemImage: "envelope.open") { Task { await markRead(item) } }.tint(.blue)
                        }
                    }
                }
                if notifications?.isEmpty == true {
                    ContentUnavailableView("通知はありません", systemImage: "bell.slash")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if nextCursor != nil {
                    ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden).task { await loadMore() }
                }
            }
            .listStyle(.plain)
            .loadState(isLoaded: notifications != nil, error: $error)
            .navigationTitle("通知")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("すべて既読") { Task { await markAllRead() } }.disabled(unreadCount == 0)
                }
            }
            .onChange(of: unreadCount) { onUnreadCountChange(unreadCount) }
            .task(id: kind) {
                guard loadedKind != .some(kind) else { return }
                notifications = nil
                nextCursor = nil
                await reload()
            }
            .refreshable { await reload() }
        }
    }

    /// 開ける先。タスクの通知はタスク、レビューの通知はそのラウンド。
    private func destination(_ item: AppNotification) -> AnyView? {
        guard let summary = item.project else { return nil }
        // 開く先の画面はキーと ID しか使わないので、通知の要約から組み立てる
        let project = Project(id: summary.id, tenantId: summary.tenantId, key: summary.key, name: summary.key, iconEmoji: nil)
        if let reviewId = item.payload.reviewId {
            return AnyView(ReviewRoundView(project: project, reviewId: reviewId))
        }
        if let task = item.task {
            return AnyView(TaskLoaderView(project: project, taskId: task.id))
        }
        return nil
    }

    private func reload() async {
        let kind = kind
        do {
            let page = try await session.api.notifications(kind: kind, unreadOnly: false, cursor: nil)
            notifications = page.notifications
            nextCursor = page.nextCursor
            unreadCount = page.unreadCount
            loadedKind = .some(kind)
        } catch {
            self.error = error.displayMessage
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        do {
            let page = try await session.api.notifications(kind: kind, unreadOnly: false, cursor: cursor)
            notifications?.append(contentsOf: page.notifications)
            nextCursor = page.nextCursor
            unreadCount = page.unreadCount
        } catch {
            self.error = error.displayMessage
        }
    }

    private func markRead(_ item: AppNotification) async {
        guard item.readAt == nil else { return }
        do {
            let updated = try await session.api.markNotificationRead(id: item.id)
            if let index = notifications?.firstIndex(where: { $0.id == item.id }) { notifications?[index] = updated }
            unreadCount = max(0, unreadCount - 1)
        } catch {
            self.error = error.displayMessage
        }
    }

    private func markAllRead() async {
        do {
            try await session.api.markAllNotificationsRead()
            await reload()
        } catch {
            self.error = error.displayMessage
        }
    }
}

struct NotificationRow: View {
    let item: AppNotification

    var body: some View {
        let isUnread = item.readAt == nil
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.isReview ? Color.purple : Color.accentColor)
                .frame(width: 32, height: 32)
                .background(.fill.tertiary, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.message)
                    .font(.subheadline)
                    .fontWeight(isUnread ? .semibold : .regular)
                    .foregroundStyle(isUnread ? .primary : .secondary)
                if let subject = item.subject {
                    Text(subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(item.createdAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if isUnread {
                Circle().fill(.tint).frame(width: 9, height: 9).padding(.top, 6).accessibilityLabel("未読")
            }
        }
        .padding(.vertical, 2)
    }
}

extension AppNotification {
    var isReview: Bool { notificationType.hasPrefix("review_") }

    /// 何が起きたか。知らない種別でも種別名を出す。
    var message: String {
        let payload = payload
        func name(_ value: String?) -> String { value ?? "不明な利用者" }
        switch notificationType {
        case "assigned":
            return "\(name(payload.assignedBy)) さんがあなたを担当者にしました"
        case "mentioned":
            return "\(name(payload.author)) さんがコメントであなたをメンションしました"
        case "comment_added":
            return "\(name(payload.author)) さんがコメントしました"
        case "status_changed":
            return "\(name(payload.changedBy)) さんがステータスを「\(payload.from ?? "?")」から「\(payload.to ?? "?")」に変えました"
        case "deadline_soon":
            return "期限が近づいています"
        case "pr_merged":
            return "PR がマージされました"
        case "review_round_created":
            let counts = ["high", "medium", "low", "nit"].compactMap { severity -> String? in
                guard let count = payload.counts?[severity], count > 0 else { return nil }
                return "\(severityLabel(severity)) \(count)"
            }
            let round = payload.round.map { " R\($0) の" } ?? ""
            return "\(name(payload.reviewer)) さんが\(round)レビューを出しました（\(counts.isEmpty ? "指摘なし" : counts.joined(separator: " / "))）"
        case "review_finding_changed":
            let change = "\(payload.from.map(findingStateLabel) ?? "?") → \(payload.to.map(findingStateLabel) ?? "?")"
            return "\(name(payload.actor)) さんが指摘「\(payload.title ?? "")」を \(change) にしました"
        default:
            return notificationType
        }
    }

    /// 何についての通知か（タスクか PR）。
    var subject: String? {
        if let task, let project { return "\(project.key)-\(task.seqId) \(task.title)" }
        if let pr = payload.prNumber { return "\(payload.repo ?? "")#\(pr)" }
        return nil
    }

    var symbol: String {
        switch notificationType {
        case "assigned": "person.badge.plus"
        case "mentioned": "at"
        case "comment_added": "bubble.left"
        case "status_changed": "circle.lefthalf.filled"
        case "deadline_soon": "clock.badge.exclamationmark"
        case "pr_merged": "arrow.triangle.merge"
        case "review_round_created": "checklist"
        case "review_finding_changed": "exclamationmark.bubble"
        default: "bell"
        }
    }
}

/// ID かキー（`ENG-42`）だけでタスクを開く（通知・繰り延べた指摘・本文の KEY-N から）。
struct TaskLoaderView: View {
    let project: Project
    let taskRef: String
    @Environment(AppSession.self) private var session
    @State private var loaded: (task: TaskItem, statuses: [TaskStatus])?
    @State private var error: String?

    init(project: Project, taskRef: String) {
        self.project = project
        self.taskRef = taskRef
    }

    init(project: Project, taskId: UUID) {
        self.init(project: project, taskRef: taskId.uuidString)
    }

    var body: some View {
        if let loaded {
            TaskDetailView(project: project, task: loaded.task, statuses: loaded.statuses) { _ in }
        } else {
            Color.clear
                .loadState(isLoaded: false, error: $error)
                .task { await load() }
        }
    }

    private func load() async {
        let api = session.api
        do {
            async let task = api.task(project, ref: taskRef)
            async let statuses = api.statuses(project)
            loaded = (try await task, try await statuses.sorted { $0.position < $1.position })
        } catch {
            self.error = error.displayMessage
        }
    }
}
