import SwiftUI

public struct RootView: View {
    @State private var session = AppSession()

    public init() {}

    public var body: some View {
        Group {
            if session.credentials == nil {
                SignInView()
            } else {
                MainView()
            }
        }
        .animation(.default, value: session.credentials == nil)
        .environment(session)
    }
}

struct SignInView: View {
    @Environment(AppSession.self) private var session
    @AppStorage("origin") private var origin = AppSession.defaultOrigin.absoluteString
    @State private var isSigningIn = false
    @State private var error: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            // アプリのアイコン（ライト・ダーク）と同じ絵。ロゴはアプリの Assets にある
            Image("Logo")
                .resizable()
                .scaledToFit()
                .padding(16)
                .offset(x: 2, y: -1)
                .frame(width: 104, height: 104)
                .background(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(hex: "#33302B"), Color(hex: "#171412")] : [Color(hex: "#FFF9ED"), Color(hex: "#FAE6BD")],
                        startPoint: .top, endPoint: .bottom),
                    in: .rect(cornerRadius: 26)
                )
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .accentColor.opacity(0.35), radius: 18, y: 8)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Koyori").font(.largeTitle.bold())
                Text("タスクの確認と更新を、いつでも手元で。").foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("サーバー", text: $origin)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 50)
                .background(.fill.tertiary, in: .capsule)

                Button {
                    Task { await signIn() }
                } label: {
                    HStack(spacing: 8) {
                        if isSigningIn { ProgressView() }
                        Text(isSigningIn ? "ブラウザで承認を待っています" : "ブラウザでログイン").fontWeight(.semibold)
                    }
                    // アクセント色（琥珀）の上は、ライトでは白・ダークでは黒の方が読みやすい
                    .foregroundStyle(.background)
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(isSigningIn)

                Group {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text("ブラウザで Koyori にログインし、この端末を承認します。").foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.14), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }

    private func signIn() async {
        // トークンを平文で流さないよう https に限る
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespaces)), url.scheme == "https", url.host() != nil
        else {
            error = "https:// から始まる URL を入力してください"
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        error = nil
        do {
            try await session.signIn(origin: url)
        } catch {
            self.error = error.displayMessage
        }
    }
}

/// 全テナントのプロジェクトをテナントごとに並べる。iPad では左の列、iPhone では最初の画面になる。
struct MainView: View {
    @Environment(AppSession.self) private var session
    /// 最後に開いたプロジェクト。次に起動したときもそこから始める
    @AppStorage("projectId") private var projectId: String?
    @State private var tenants: [Tenant]?
    @State private var projects: [Project] = []
    @State private var error: String?
    @State private var isShowingAccount = false
    @State private var isShowingNotifications = false
    @State private var unreadCount = 0
    /// ログインしている本人（右上のアイコン）
    @State private var me: Account?
    @State private var creatingIn: Tenant?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List(selection: $projectId) {
                ForEach(tenants ?? []) { tenant in
                    Section {
                        NavigationLink(value: calendarTag(tenant)) { Label("カレンダー", systemImage: "calendar") }
                        ForEach(projects.filter { $0.tenantId == tenant.id }) { project in
                            NavigationLink(value: project.id.uuidString) { ProjectRow(project: project) }
                        }
                        if isOwner(of: tenant) {
                            Button {
                                creatingIn = tenant
                            } label: {
                                Label("プロジェクトを作成", systemImage: "plus")
                            }
                        }
                    } header: {
                        Text(verbatim: [tenant.iconEmoji, tenant.name].compactMap { $0 }.joined(separator: " "))
                    }
                }
            }
            .loadState(isLoaded: tenants != nil, error: $error)
            .overlay {
                if let tenants, projects.isEmpty, !tenants.contains(where: isOwner) {
                    ContentUnavailableView("プロジェクトはありません", systemImage: "folder")
                }
            }
            .navigationTitle("プロジェクト")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingNotifications = true
                    } label: {
                        Label {
                            Text("通知")
                        } icon: {
                            // 未読があれば赤い印の付いたベルにする
                            if unreadCount > 0 {
                                // ツールバーは単色に揃えるので、印の色を直接指定する
                                Image(systemName: "bell.badge")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.red, Color.primary)
                            } else {
                                Image(systemName: "bell")
                            }
                        }
                    }
                    .accessibilityValue(unreadCount > 0 ? Text("未読 \(unreadCount) 件") : Text(""))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingAccount = true
                    } label: {
                        if let me {
                            Avatar(name: me.username, url: me.avatarUrl, size: 30)
                        } else {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                    .accessibilityLabel("アカウント")
                }
            }
            .sheet(isPresented: $isShowingAccount) {
                AccountView(account: me)
            }
            .refreshable { await load() }
            .sheet(isPresented: $isShowingNotifications, onDismiss: { Task { await loadUnreadCount() } }) {
                NotificationsView { unreadCount = $0 }
            }
            .sheet(item: $creatingIn) { tenant in
                ProjectCreateView(tenant: tenant) { project in
                    projects.append(project)
                    // 作ったプロジェクトをそのまま開く
                    projectId = project.id.uuidString
                }
            }
        } detail: {
            if let project = projects.first(where: { $0.id.uuidString == projectId }) {
                NavigationStack { TaskListView(project: project) }.id(project.id)
            } else if let tenant = tenants?.first(where: { calendarTag($0) == projectId }) {
                NavigationStack { ScheduleView(tenant: tenant) }.id(tenant.id)
            } else if tenants == nil {
                if let error {
                    ContentUnavailableView("読み込めませんでした", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            } else {
                ContentUnavailableView("プロジェクトを選んでください", systemImage: "folder")
            }
        }
        // 前回のプロジェクトを開いて起動した iPhone では左の一覧が出ないので、全体に付ける
        .task {
            await load()
            await loadUnreadCount()
        }
        // プッシュ通知が無いので、アプリに戻るたびに未読を数え直す。Web でプロフィールを変えて戻ったときのため本人も読み直す
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task {
                    await loadUnreadCount()
                    if let me = try? await session.api.me() { self.me = me }
                }
            }
        }
    }

    /// サイドバーの選択の値。プロジェクトは ID、テナントのカレンダーはこの値
    private func calendarTag(_ tenant: Tenant) -> String {
        "calendar:\(tenant.id.uuidString)"
    }

    private func isOwner(of tenant: Tenant) -> Bool {
        tenant.membership == "Owner"
    }

    private func loadUnreadCount() async {
        if let page = try? await session.api.notifications(kind: nil, unreadOnly: true, cursor: nil, limit: 1) {
            unreadCount = page.unreadCount
        }
    }

    private func load() async {
        let api = session.api
        do {
            async let me = api.me()
            let tenants = try await api.tenants()
            projects = try await withThrowingTaskGroup(of: [Project].self) { group in
                for tenant in tenants {
                    group.addTask { try await api.projects(tenantId: tenant.id) }
                }
                var projects: [Project] = []
                for try await chunk in group { projects += chunk }
                return projects
            }
            self.tenants = tenants
            // 取れなくても一覧は出す（右上が人のマークになるだけ）
            self.me = (try? await me) ?? self.me
            // 消えたプロジェクトを開いたままにしない
            if !projects.contains(where: { $0.id.uuidString == projectId }), !tenants.contains(where: { calendarTag($0) == projectId }) {
                projectId = nil
            }
        } catch {
            self.error = error.displayMessage
        }
    }
}

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let emoji = project.iconEmoji {
                    Text(verbatim: emoji)
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                } else {
                    Text(verbatim: String(project.key.prefix(1)))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color(seed: project.key).gradient, in: .rect(cornerRadius: 8))
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            Text(project.name)
            Spacer()
            Text(verbatim: project.key).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

struct TaskListView: View {
    let project: Project
    @Environment(AppSession.self) private var session
    @AppStorage("taskSort") private var sort = TaskSort.createdAtDesc
    @State private var statusFilter: UUID?
    @State private var assigneeFilter: UUID?
    @State private var creatorFilter: UUID?
    @State private var statuses: [TaskStatus] = []
    @State private var members: [UserSummary] = []
    @State private var tasks: [TaskItem]?
    /// `tasks` を読んだときの絞り込みと並び。詳細から戻るたびに読み直して続きを失わないよう比べる
    @State private var loadedQuery: [String?]?
    @State private var nextCursor: String?
    @State private var error: String?
    @State private var isCreating = false
    @State private var isManagingLabels = false
    @State private var completions = 0

    private var query: [String?] { [statusFilter?.uuidString, assigneeFilter?.uuidString, creatorFilter?.uuidString, sort.rawValue] }
    private var isFiltered: Bool { statusFilter != nil || assigneeFilter != nil || creatorFilter != nil }

    var body: some View {
        List {
            if !statuses.isEmpty {
                TaskFilterBar(
                    statuses: statuses, assignee: members.first { $0.id == assigneeFilter },
                    creator: members.first { $0.id == creatorFilter },
                    status: $statusFilter, assigneeId: $assigneeFilter, creatorId: $creatorFilter)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(tasks ?? []) { task in
                let status = statuses.first { $0.id == task.statusId }
                NavigationLink {
                    TaskDetailView(project: project, task: task, statuses: statuses) { replace($0) }
                } label: {
                    TaskRow(project: project, task: task, status: status)
                }
                .swipeActions(edge: .leading) {
                    CompletionSwipeButton(status: status, statuses: statuses) { id in
                        Task { await update(task, UpdateTaskRequest(statusId: id)) }
                    }
                }
                .contextMenu {
                    StatusPicker(statuses: statuses, selection: task.statusId) { id in
                        Task { await update(task, UpdateTaskRequest(statusId: id)) }
                    }
                    .pickerStyle(.menu)
                    PriorityPicker(selection: task.priority) { priority in
                        Task { await update(task, UpdateTaskRequest(priority: priority)) }
                    }
                    .pickerStyle(.menu)
                }
            }
            if tasks?.isEmpty == true {
                ContentUnavailableView(
                    isFiltered ? "該当するタスクはありません" : "タスクはありません", systemImage: "checklist",
                    description: Text(isFiltered ? "絞り込みを変えてください。" : "右上の＋から作成できます。"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if nextCursor != nil {
                // 末尾まで来たら続きを読む
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden).task { await loadMore() }
            }
        }
        .listStyle(.plain)
        .loadState(isLoaded: tasks != nil, error: $error)
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("作成", systemImage: "plus") { isCreating = true }.disabled(statuses.isEmpty)
            }
            ToolbarItem {
                NavigationLink {
                    ReviewListView(project: project)
                } label: {
                    Label("レビュー", systemImage: "checklist.checked")
                }
            }
            ToolbarItem {
                Menu {
                    Picker(selection: $assigneeFilter) {
                        Text("すべての担当者").tag(UUID?.none)
                        ForEach(members, id: \.id) { Text($0.username).tag(Optional($0.id)) }
                    } label: {
                        Label("担当者", systemImage: "person")
                    }
                    .pickerStyle(.menu)
                    Picker(selection: $creatorFilter) {
                        Text("すべての作成者").tag(UUID?.none)
                        ForEach(members, id: \.id) { Text($0.username).tag(Optional($0.id)) }
                    } label: {
                        Label("作成者", systemImage: "person.crop.circle")
                    }
                    .pickerStyle(.menu)
                    Picker(selection: $sort) {
                        ForEach(TaskSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        Label("並び順", systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    Section {
                        Button("ラベルの管理", systemImage: "tag") { isManagingLabels = true }
                    }
                } label: {
                    Label(
                        "絞り込みと並び順",
                        systemImage: assigneeFilter == nil && creatorFilter == nil
                            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            // 並び順に関わらず、作ったものが見えるよう先頭に足す。サブタスクは親の詳細に出るので足さない
            TaskCreateView(project: project, statuses: statuses) { created in
                if created.parentTaskId == nil { tasks?.insert(created, at: 0) }
            }
        }
        .navigationDestination(isPresented: $isManagingLabels) { LabelManagerView(project: project) }
        .sensoryFeedback(.success, trigger: completions)
        .task(id: query) {
            guard loadedQuery != query else { return }
            tasks = nil
            nextCursor = nil
            await reload()
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        let api = session.api
        let (query, statusId, assigneeId, createdBy, sort) = (query, statusFilter, assigneeFilter, creatorFilter, sort)
        do {
            async let statuses = api.statuses(project)
            async let members = api.members(project)
            async let page = api.tasks(
                project, cursor: nil, statusId: statusId, assigneeId: assigneeId, createdBy: createdBy, sort: sort, rootOnly: true)
            self.statuses = try await statuses.sorted { $0.position < $1.position }
            // 絞り込みの候補が取れなくても一覧は出す
            if let members = try? await members {
                self.members = members.map(\.user).sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
            }
            let first = try await page
            tasks = first.tasks
            nextCursor = first.nextCursor
            loadedQuery = query
        } catch {
            self.error = error.displayMessage
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        do {
            let page = try await session.api.tasks(
                project, cursor: cursor, statusId: statusFilter, assigneeId: assigneeFilter, createdBy: creatorFilter, sort: sort,
                rootOnly: true)
            tasks?.append(contentsOf: page.tasks)
            nextCursor = page.nextCursor
        } catch {
            self.error = error.displayMessage
        }
    }

    private func update(_ task: TaskItem, _ body: UpdateTaskRequest) async {
        do {
            let updated = try await session.api.updateTask(project, id: task.id, body)
            if updated.statusId != task.statusId, statuses.first(where: { $0.id == updated.statusId })?.isDoneState == true {
                completions += 1
            }
            withAnimation {
                // 絞り込んでいるステータスから外れたら一覧から消す
                if let statusFilter, updated.statusId != statusFilter {
                    tasks?.removeAll { $0.id == updated.id }
                } else {
                    replace(updated)
                }
            }
        } catch {
            self.error = error.displayMessage
        }
    }

    private func replace(_ task: TaskItem) {
        if let index = tasks?.firstIndex(where: { $0.id == task.id }) { tasks?[index] = task }
    }
}

/// 一覧の絞り込み。ステータスはここで選び、担当者・作成者は右上のメニューで選んだものを先頭に出して外せるようにする。
struct TaskFilterBar: View {
    let statuses: [TaskStatus]
    let assignee: UserSummary?
    let creator: UserSummary?
    @Binding var status: UUID?
    @Binding var assigneeId: UUID?
    @Binding var creatorId: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let assignee { personChip("担当", assignee) { assigneeId = nil } }
                if let creator { personChip("作成", creator) { creatorId = nil } }
                if assignee != nil || creator != nil { Divider().frame(height: 20) }
                chip(isSelected: status == nil, action: { status = nil }) { Text("すべて") }
                ForEach(statuses) { item in
                    chip(isSelected: status == item.id, action: { status = item.id }) {
                        Label { Text(item.name) } icon: { StatusIcon(status: item) }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// ステータスの「選択中」と見分けがつくよう、色を変えて区切る
    private func personChip(_ title: String, _ user: UserSummary, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 6) {
                Avatar(name: user.username, url: user.avatarUrl, size: 20)
                Text(verbatim: "\(title): \(user.username)")
                Image(systemName: "xmark").font(.caption2.bold())
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.18), in: .capsule)
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(user.username)、絞り込みを外す")
    }

    private func chip(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .labelStyle(.compact)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                .background(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.fill.tertiary), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct TaskRow: View {
    let project: Project
    let task: TaskItem
    let status: TaskStatus?

    var body: some View {
        let isDone = status?.isDoneState == true
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StatusIcon(status: status).font(.title3).accessibilityHidden(true)  // 名前は下の行で読む
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .fontWeight(.medium)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        // 親が一覧に無いときだけ一覧に出るサブタスク
                        if task.parentTaskId != nil {
                            Image(systemName: "arrow.turn.down.right").accessibilityLabel("サブタスク")
                        }
                        Text(verbatim: "\(project.key)-\(task.seqId)").monospaced()
                    }
                    if let status { Text(status.name) }
                    PriorityLabel(priority: task.priority)
                    if let deadline = task.softDeadline ?? task.hardDeadline {
                        DeadlineLabel(date: deadline, isDone: isDone)
                    }
                    Spacer(minLength: 0)
                    // 担当者は情報の行の右端に揃える（名前は詳細で見る）
                    if !task.assignees.isEmpty {
                        AvatarStack(users: task.assignees.map(\.user), size: 20)
                            .accessibilityElement()
                            .accessibilityLabel("担当: \(task.assignees.map(\.user.username).joined(separator: "、"))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.compact)
                .lineLimit(1)
                if !task.labels.isEmpty { InlineLabels(labels: task.labels) }
            }
        }
        .padding(.vertical, 4)
    }
}

struct TaskDetailView: View {
    let project: Project
    let statuses: [TaskStatus]
    /// 一覧の行を最新に保つため、内容が変わるたびに呼ぶ。
    let onChange: (TaskItem) -> Void
    @Environment(AppSession.self) private var session
    @State private var task: TaskItem
    @State private var comments: [CommentThread]?
    @State private var commentMentions: [String: MentionedUser] = [:]
    /// 説明のメンション。更新の応答は持たないので、詳細を読んだときの表を残しておく
    @State private var descriptionMentions: [String: MentionedUser] = [:]
    /// 結ばれた PR・コミット・ブランチ。読めなければ（権限など）出さない
    @State private var forge: TaskForge?
    @State private var isLinkingPullRequest = false
    @State private var pullRequestNumber = ""
    @Environment(\.openURL) private var openURL
    @State private var draft = ""
    @State private var isPosting = false
    @State private var relations: TaskRelations?
    /// 開いている入力画面（編集・サブタスクの追加）
    @State private var sheet: DetailSheet?
    @State private var error: String?

    private enum DetailSheet: Identifiable, Hashable {
        case edit, addSubtask
        /// 担当者・作成者・コメントの投稿者のプロフィール
        case profile(UUID)
        var id: Self { self }
    }

    init(project: Project, task: TaskItem, statuses: [TaskStatus], onChange: @escaping (TaskItem) -> Void) {
        self.project = project
        self.statuses = statuses
        self.onChange = onChange
        _task = State(initialValue: task)
    }

    var body: some View {
        let status = statuses.first { $0.id == task.statusId }
        ScrollViewReader { proxy in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(task.title).font(.title2.bold()).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Menu {
                                StatusPicker(statuses: statuses, selection: task.statusId) { id in
                                    Task { await update(UpdateTaskRequest(statusId: id)) }
                                }
                            } label: {
                                Label { Text(status?.name ?? "ステータス") } icon: { StatusIcon(status: status) }
                                    .pill(tint: status.map { Color(hex: $0.color) })
                            }
                            Menu {
                                PriorityPicker(selection: task.priority) { priority in
                                    Task { await update(UpdateTaskRequest(priority: priority)) }
                                }
                            } label: {
                                PriorityLabel(priority: task.priority).pill(tint: TaskPriority(rawValue: task.priority)?.color)
                            }
                        }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .listRowBackground(Color.clear)
                }

                Section {
                    if let start = task.plannedStartOn, let day = date(fromCalendarDate: start) {
                        LabeledContent {
                            Text(day.formatted(date: .abbreviated, time: .omitted))
                        } label: {
                            Label("開始予定日", systemImage: "calendar.badge.clock")
                        }
                    }
                    if let date = task.softDeadline {
                        DeadlineRow(title: "期限", systemImage: "calendar", date: date, isDone: status?.isDoneState == true)
                    }
                    if let date = task.hardDeadline {
                        DeadlineRow(
                            title: "最終期限", systemImage: "calendar.badge.exclamationmark", date: date,
                            isDone: status?.isDoneState == true)
                    }
                    // 行を押すと付け外しの画面へ進む。札を押すとその人のプロフィール
                    NavigationLink {
                        AssigneePickerView(project: project, task: $task)
                    } label: {
                        if task.assignees.isEmpty {
                            LabeledContent {
                                Text("なし")
                            } label: {
                                Label("担当", systemImage: "person")
                            }
                        } else {
                            // ラベルと同じく、見出しの下に札を並べる
                            VStack(alignment: .leading, spacing: 10) {
                                Label("担当", systemImage: "person")
                                FlowLayout(spacing: 6) {
                                    ForEach(task.assignees, id: \.user.id) { assignee in
                                        Button {
                                            sheet = .profile(assignee.user.id)
                                        } label: {
                                            PersonChip(name: assignee.user.username, url: assignee.user.avatarUrl)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    }
                    NavigationLink {
                        LabelPickerView(project: project, task: $task)
                    } label: {
                        if task.labels.isEmpty {
                            LabeledContent {
                                Text("なし")
                            } label: {
                                Label("ラベル", systemImage: "tag")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("ラベル", systemImage: "tag")
                                FlowLayout(spacing: 6) { ForEach(task.labels) { LabelChip(label: $0) } }
                            }
                        }
                    }
                    LabeledContent {
                        if let user = task.createdBy {
                            Button {
                                sheet = .profile(user.id)
                            } label: {
                                PersonChip(name: user.username, url: user.avatarUrl)
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Text("不明")
                        }
                    } label: {
                        Label("作成者", systemImage: "person.crop.circle")
                    }
                    LabeledContent {
                        Text(task.createdAt.formatted(date: .abbreviated, time: .shortened))
                    } label: {
                        Label("作成日時", systemImage: "clock")
                    }
                }

                if let parent = relations?.parent {
                    Section("親タスク") {
                        NavigationLink {
                            TaskDetailView(project: project, task: parent, statuses: statuses) { _ in }
                        } label: {
                            TaskRow(project: project, task: parent, status: statuses.first { $0.id == parent.statusId })
                        }
                    }
                }

                if let subtasks = relations?.subtasks {
                    Section {
                        ForEach(subtasks) { child in
                            let childStatus = statuses.first { $0.id == child.statusId }
                            NavigationLink {
                                TaskDetailView(project: project, task: child, statuses: statuses) { replaceSubtask($0) }
                            } label: {
                                TaskRow(project: project, task: child, status: childStatus)
                            }
                            .swipeActions(edge: .leading) {
                                CompletionSwipeButton(status: childStatus, statuses: statuses) { id in
                                    Task { await updateSubtask(child, UpdateTaskRequest(statusId: id)) }
                                }
                            }
                        }
                        Button {
                            sheet = .addSubtask
                        } label: {
                            Label("サブタスクを追加", systemImage: "plus")
                        }
                        .disabled(statuses.isEmpty)
                    } header: {
                        let done = subtasks.filter { child in statuses.first { $0.id == child.statusId }?.isDoneState == true }.count
                        Text(verbatim: subtasks.isEmpty ? "サブタスク" : "サブタスク \(done)/\(subtasks.count)")
                    }
                }

                if let description = task.description, !description.isEmpty {
                    Section("説明") { MarkdownText(text: description, mentions: task.mentions ?? descriptionMentions) }
                }

                if let forge, forge.repository != nil || forge.issue != nil || !forge.pullRequests.isEmpty || !forge.commits.isEmpty
                    || !forge.branches.isEmpty
                {
                    forgeSection(forge)
                }

                Section {
                    if let comments {
                        if comments.isEmpty {
                            Text("まだコメントはありません").foregroundStyle(.secondary)
                        }
                        ForEach(comments) { thread in
                            CommentView(
                                user: thread.user, text: thread.body, createdAt: thread.createdAt, isDeleted: thread.isDeleted,
                                mentions: commentMentions
                            ) { sheet = .profile(thread.user.id) }
                            .id(thread.id)
                            ForEach(thread.replies) { reply in
                                CommentView(
                                    user: reply.user, text: reply.body, createdAt: reply.createdAt, isDeleted: reply.isDeleted,
                                    mentions: commentMentions
                                ) { sheet = .profile(reply.user.id) }
                                .padding(.leading, 38)
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } header: {
                    if let comments {
                        Text("コメント \(comments.reduce(0) { $0 + 1 + $1.replies.count })")
                    } else {
                        Text("コメント")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .bottomBar {
                CommentComposer(text: $draft, isPosting: isPosting) {
                    Task {
                        await postComment()
                        if let id = comments?.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
            }
        }
        .loadState(isLoaded: true, error: $error)
        .taskReferenceLinks(tenantId: project.tenantId)
        .navigationTitle(Text(verbatim: "\(project.key)-\(task.seqId)"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("編集") { sheet = .edit }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit:
                TaskFormView(project: project, task: task) { task = $0 }
            case .addSubtask:
                TaskCreateView(project: project, statuses: statuses, parent: TaskReference(id: task.id, seqId: task.seqId, title: task.title)) {
                    relations?.subtasks.append($0)
                }
            case .profile(let userId):
                UserProfileView(tenantId: project.tenantId, userId: userId)
            }
        }
        .alert("PR をリンク", isPresented: $isLinkingPullRequest) {
            TextField("PR の番号", text: $pullRequestNumber)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("キャンセル", role: .cancel) {}
            Button("リンク") { Task { await linkPullRequest(closes: false) } }
            Button("リンク（マージで完了にする）") { Task { await linkPullRequest(closes: true) } }
        } message: {
            if let repository = forge?.repository {
                Text(verbatim: "\(repository.repoOwner)/\(repository.repoName) の PR をこのタスクに結びます。")
            }
        }
        .sensoryFeedback(.selection, trigger: task.statusId)
        .onChange(of: task) { onChange(task) }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let api = session.api
        do {
            async let task = api.task(project, id: self.task.id)
            async let comments = api.comments(project, taskId: self.task.id)
            async let relations = api.relations(project, taskId: self.task.id)
            async let forge = api.forge(project, taskId: self.task.id)
            self.task = try await task
            descriptionMentions = self.task.mentions ?? descriptionMentions
            let list = try await comments
            self.comments = list.comments
            commentMentions = list.mentions ?? [:]
            // 親子・リポジトリが取れなくても本体とコメントは出す
            self.relations = (try? await relations) ?? self.relations
            self.forge = (try? await forge) ?? self.forge
        } catch {
            self.error = error.displayMessage
        }
    }

    private func updateSubtask(_ child: TaskItem, _ body: UpdateTaskRequest) async {
        do {
            replaceSubtask(try await session.api.updateTask(project, id: child.id, body))
        } catch {
            self.error = error.displayMessage
        }
    }

    private func replaceSubtask(_ child: TaskItem) {
        if let index = relations?.subtasks.firstIndex(where: { $0.id == child.id }) { relations?.subtasks[index] = child }
    }

    /// 連携先リポジトリ・取り込み元 Issue・PR・コミット・ブランチ。各行はホストの URL をそのまま開く。
    private func forgeSection(_ forge: TaskForge) -> some View {
        Section("リポジトリ") {
            if let repository = forge.repository {
                externalLink(repository.htmlUrl) {
                    Label { Text(verbatim: "\(repository.repoOwner)/\(repository.repoName)") } icon: { Image(systemName: "shippingbox") }
                }
            }
            if let issue = forge.issue {
                externalLink(issue.htmlUrl) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label { Text(verbatim: "Issue #\(issue.number)") } icon: { Image(systemName: "smallcircle.filled.circle") }
                        HStack(spacing: 8) {
                            Text(forgeStateLabel(issue.state))
                            if let synced = issue.lastSyncedAt {
                                Text("最終同期 \(synced.formatted(.relative(presentation: .named)))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(forge.pullRequests) { pr in
                externalLink(pr.htmlUrl) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "#\(pr.number) \(pr.title)").lineLimit(2)
                        HStack(spacing: 8) {
                            Text(forgeStateLabel(pr.state))
                            if let unresolved = pr.unresolved, unresolved > 0 { Text("未解決 \(unresolved)").foregroundStyle(.red) }
                            if pr.state == "merged", pr.mergeEffectsProcessedAt == nil {
                                Label("マージ後の処理が未適用", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.compact)
                    }
                }
                .swipeActions {
                    Button("リンクを外す", role: .destructive) { Task { await unlinkPullRequest(pr) } }
                }
            }
            ForEach(forge.commits) { commit in
                externalLink(commit.htmlUrl) {
                    HStack(spacing: 8) {
                        Text(verbatim: String(commit.sha.prefix(7))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(commit.message).lineLimit(1)
                    }
                }
            }
            ForEach(forge.branches) { branch in
                externalLink(branch.htmlUrl) { Label(branch.branch, systemImage: "arrow.triangle.branch") }
            }
            // リポジトリはプロジェクトの連携先で決まるので、連携が無ければ結べない
            if forge.repository != nil {
                Button {
                    pullRequestNumber = ""
                    isLinkingPullRequest = true
                } label: {
                    Label("PR をリンク", systemImage: "plus")
                }
            }
        }
    }

    private func externalLink(_ url: String, @ViewBuilder label: () -> some View) -> some View {
        Button {
            if let url = URL(string: url) { openURL(url) }
        } label: {
            HStack {
                label().foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
            }
        }
    }

    private func linkPullRequest(closes: Bool) async {
        guard let number = Int(pullRequestNumber.trimmingCharacters(in: .whitespaces)), number >= 1 else {
            error = "PR の番号は 1 以上の整数で入力してください"
            return
        }
        do {
            _ = try await session.api.linkPullRequest(project, taskId: task.id, number: number, closes: closes)
            forge = try await session.api.forge(project, taskId: task.id)
        } catch {
            self.error = error.displayMessage
        }
    }

    private func unlinkPullRequest(_ pr: TaskForge.PullRequest) async {
        do {
            try await session.api.unlinkPullRequest(project, taskId: task.id, pullRequestId: pr.id)
            withAnimation { forge?.pullRequests.removeAll { $0.id == pr.id } }
        } catch {
            self.error = error.displayMessage
        }
    }

    private func update(_ body: UpdateTaskRequest) async {
        do {
            task = try await session.api.updateTask(project, id: task.id, body)
        } catch {
            self.error = error.displayMessage
        }
    }

    private func postComment() async {
        isPosting = true
        defer { isPosting = false }
        do {
            try await session.api.postComment(project, taskId: task.id, body: draft.trimmingCharacters(in: .whitespacesAndNewlines))
            draft = ""
            let list = try await session.api.comments(project, taskId: task.id)
            comments = list.comments
            commentMentions = list.mentions ?? [:]
        } catch {
            self.error = error.displayMessage
        }
    }
}

/// プロジェクトのラベルを付け外しする。押すたびに保存する。
struct LabelPickerView: View {
    let project: Project
    @Binding var task: TaskItem
    @Environment(AppSession.self) private var session
    @State private var labels: [TaskLabel]?
    /// 保存中のラベル。応答の順が入れ替わって古い内容に戻らないよう、1 つずつ送る
    @State private var savingId: UUID?
    @State private var error: String?

    var body: some View {
        List(labels ?? []) { label in
            let isOn = task.labels.contains { $0.id == label.id }
            Button {
                Task { await toggle(label, isOn: isOn) }
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: label.color)).frame(width: 10, height: 10)
                    // ボタンの中の `.primary` はアクセント色になるので、文字色を直接指定する
                    Text(label.name).foregroundStyle(Color.primary)
                    Spacer()
                    if savingId == label.id {
                        ProgressView()
                    } else if isOn {
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                    }
                }
            }
            .disabled(savingId != nil)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
        .loadState(isLoaded: labels != nil, error: $error)
        .overlay {
            if labels?.isEmpty == true {
                ContentUnavailableView(
                    "ラベルはありません", systemImage: "tag", description: Text("右上の「管理」から作成できます。"))
            }
        }
        .navigationTitle("ラベル")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // 戻ると `.task` で読み直すので、作った・変えたラベルがすぐ選べる
                NavigationLink("管理") { LabelManagerView(project: project) }
            }
        }
        .sensoryFeedback(.selection, trigger: task.labels)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            labels = try await session.api.labels(project)
        } catch {
            self.error = error.displayMessage
        }
    }

    private func toggle(_ label: TaskLabel, isOn: Bool) async {
        savingId = label.id
        defer { savingId = nil }
        do {
            task = try await session.api.updateTask(
                project, id: task.id,
                isOn ? UpdateTaskRequest(removeLabelIds: [label.id]) : UpdateTaskRequest(addLabelIds: [label.id]))
        } catch {
            self.error = error.displayMessage
        }
    }
}

/// 担当者を付け外しする。押すたびに保存する。
struct AssigneePickerView: View {
    let project: Project
    @Binding var task: TaskItem
    @Environment(AppSession.self) private var session
    @State private var candidates: [UserSummary]?
    /// 保存中の人。追加と解除が入れ違って古い内容に戻らないよう、1 人ずつ送る
    @State private var savingId: UUID?
    @State private var error: String?

    /// 候補に、候補から外れた今の担当者（プロジェクトを抜けた人など）も足して、外せるようにする
    private var users: [UserSummary] {
        let candidates = candidates ?? []
        return task.assignees.map(\.user).filter { user in !candidates.contains { $0.id == user.id } } + candidates
    }

    var body: some View {
        List(users) { user in
            let isOn = task.assignees.contains { $0.user.id == user.id }
            Button {
                Task { await toggle(user, isOn: isOn) }
            } label: {
                HStack(spacing: 10) {
                    Avatar(name: user.username, url: user.avatarUrl, size: 30)
                    // ボタンの中の `.primary` はアクセント色になるので、文字色を直接指定する
                    Text(user.username).foregroundStyle(Color.primary)
                    Spacer()
                    if savingId == user.id {
                        ProgressView()
                    } else if isOn {
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                    }
                }
            }
            .disabled(savingId != nil)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
        .loadState(isLoaded: candidates != nil, error: $error)
        .overlay {
            if candidates != nil, users.isEmpty {
                ContentUnavailableView("担当者にできる人がいません", systemImage: "person.2.slash")
            }
        }
        .navigationTitle("担当")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sensoryFeedback(.selection, trigger: task.assignees)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            candidates = try await session.api.assignableUsers(project)
                .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
        } catch {
            self.error = error.displayMessage
        }
    }

    private func toggle(_ user: UserSummary, isOn: Bool) async {
        savingId = user.id
        defer { savingId = nil }
        let api = session.api
        do {
            if isOn {
                try await api.removeAssignee(project, taskId: task.id, userId: user.id)
            } else {
                try await api.addAssignee(project, taskId: task.id, userId: user.id)
            }
        } catch {
            // 他の人が先に変えていた（409・404）ときも、読み直した今の担当を出す
            self.error = error.displayMessage
        }
        if let latest = try? await api.task(project, id: task.id) { task = latest }
    }
}

struct DeadlineRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let date: Date
    let isDone: Bool

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                DeadlineLabel(date: date, isDone: isDone).font(.caption).labelStyle(.titleOnly)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

struct CommentView: View {
    let user: CommentUser
    let text: String?
    let createdAt: Date
    let isDeleted: Bool
    let mentions: [String: MentionedUser]
    /// 投稿者のアイコンか名前を押したとき
    let onTapUser: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onTapUser) { Avatar(name: user.name, url: user.avatarUrl, size: 28) }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(user.name)のプロフィール")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button(action: onTapUser) { Text(user.name).font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                    Text(createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
                if isDeleted {
                    Text("削除されたコメント").italic().foregroundStyle(.secondary)
                } else {
                    MarkdownText(text: text ?? "", mentions: mentions)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 詳細画面の下に浮かべるコメント入力欄。
struct CommentComposer: View {
    @Binding var text: String
    let isPosting: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("コメントを書く", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.vertical, 10)
            Group {
                if isPosting {
                    ProgressView()
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("送信")
                }
            }
            .frame(width: 34, height: 40)
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .glassBackground(in: .rect(cornerRadius: 22))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// タイトルと説明の編集。ほかの項目は詳細画面で変える。作成は `TaskCreateView`。
struct TaskFormView: View {
    let project: Project
    let task: TaskItem
    let onSave: (TaskItem) -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var isSaving = false
    @State private var error: String?

    init(project: Project, task: TaskItem, onSave: @escaping (TaskItem) -> Void) {
        self.project = project
        self.task = task
        self.onSave = onSave
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description ?? "")
    }

    private var hasChanges: Bool {
        title != task.title || description != (task.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("タイトル", text: $title).font(.headline)
                    TextField("説明（Markdown）", text: $description, axis: .vertical).lineLimit(5...)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("タスクを編集")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            // 書きかけを下へのスワイプで失わない
            .interactiveDismissDisabled(hasChanges)
        }
    }

    private func save() async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        defer { isSaving = false }
        do {
            var body = UpdateTaskRequest()
            if title != task.title { body.title = title }
            if description != (task.description ?? "") {
                if description.isEmpty { body.clearDescription = true } else { body.description = description }
            }
            onSave(try await session.api.updateTask(project, id: task.id, body))
            dismiss()
        } catch {
            self.error = error.displayMessage
        }
    }
}
