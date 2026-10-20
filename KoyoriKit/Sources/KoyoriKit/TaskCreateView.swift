import SwiftUI

/// タスクの作成。作成 API（`CreateTaskRequest`）で指定できる項目をすべて選べる。
struct TaskCreateView: View {
    let project: Project
    let statuses: [TaskStatus]
    let onCreate: (TaskItem) -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTitleFocused: Bool
    @State private var draft: TaskDraft
    private let initialDraft: TaskDraft
    @State private var users: [UserSummary] = []
    @State private var labels: [TaskLabel] = []
    @State private var milestones: [Milestone] = []
    @State private var sprints: [Sprint] = []
    @State private var fields: [CustomField] = []
    /// 読み込めなかった選択肢の名前（担当者・ラベルなど）
    @State private var unavailable: [String] = []
    @State private var isSaving = false
    @State private var error: String?

    /// `parent` を渡すと、そのタスクのサブタスクとして作る（詳細画面の「サブタスクを追加」）。
    init(project: Project, statuses: [TaskStatus], parent: TaskReference? = nil, onCreate: @escaping (TaskItem) -> Void) {
        self.project = project
        self.statuses = statuses
        self.onCreate = onCreate
        var draft = TaskDraft()
        draft.statusId = (statuses.first(where: \.isDefault) ?? statuses.first)?.id
        draft.parent = parent
        initialDraft = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("タイトル", text: $draft.title).font(.headline).focused($isTitleFocused)
                    TextField("説明（Markdown）", text: $draft.description, axis: .vertical).lineLimit(5...)
                }

                Section {
                    Picker(selection: $draft.statusId) {
                        ForEach(statuses) { status in
                            Label { Text(status.name) } icon: { StatusIcon(status: status) }.tag(Optional(status.id))
                        }
                    } label: {
                        Label("ステータス", systemImage: "circle.lefthalf.filled")
                    }
                    Picker(selection: $draft.priority) {
                        ForEach(TaskPriority.allCases, id: \.self) { priority in
                            Label { Text(priority.label) } icon: { priority.icon }.tag(priority)
                        }
                    } label: {
                        // 選んだ優先度の電波アイコンと紛らわしくない形にする
                        Label("優先度", systemImage: "flag")
                    }
                }

                Section {
                    NavigationLink {
                        MultiSelectList(title: "担当者", items: users, selection: $draft.assigneeIds, emptyMessage: "担当者にできる人がいません") {
                            user in
                            HStack(spacing: 10) {
                                Avatar(name: user.username, url: user.avatarUrl, size: 26)
                                Text(user.username)
                            }
                        }
                    } label: {
                        LabeledContent {
                            let names = users.filter { draft.assigneeIds.contains($0.id) }.map(\.username)
                            Text(names.isEmpty ? "なし" : names.joined(separator: ", ")).lineLimit(1)
                        } label: {
                            Label("担当者", systemImage: "person")
                        }
                    }
                    NavigationLink {
                        MultiSelectList(title: "ラベル", items: labels, selection: $draft.labelIds, emptyMessage: "ラベルはありません") {
                            label in
                            HStack(spacing: 10) {
                                Circle().fill(Color(hex: label.color)).frame(width: 10, height: 10)
                                Text(label.name)
                            }
                        }
                    } label: {
                        let selected = labels.filter { draft.labelIds.contains($0.id) }
                        if selected.isEmpty {
                            LabeledContent {
                                Text("なし")
                            } label: {
                                Label("ラベル", systemImage: "tag")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("ラベル", systemImage: "tag")
                                FlowLayout(spacing: 6) { ForEach(selected) { LabelChip(label: $0) } }
                            }
                        }
                    }
                }

                Section {
                    OptionalDateRow(date: $draft.plannedStartOn) { Label("開始予定日", systemImage: "calendar.badge.clock") }
                    OptionalDateRow(date: $draft.softDeadline) { Label("期限", systemImage: "calendar") }
                    OptionalDateRow(date: $draft.hardDeadline) {
                        Label("最終期限", systemImage: "calendar.badge.exclamationmark")
                    }
                } header: {
                    Text("期限")
                } footer: {
                    // サーバーは前後を検証しないので、Web の作成画面と同じくここで止める
                    if draft.startsAfterSoftDeadline() {
                        Label("開始予定日は期限以前の日付にしてください", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }

                Section("計画") {
                    Picker(selection: $draft.milestoneId) {
                        Text("なし").tag(UUID?.none)
                        ForEach(milestones) { Text("\($0.name)（\($0.dueDate)）").tag(Optional($0.id)) }
                    } label: {
                        Label("マイルストーン", systemImage: "flag.checkered")
                    }
                    Picker(selection: $draft.sprintId) {
                        Text("なし").tag(UUID?.none)
                        ForEach(sprints) { sprint in
                            Text(sprint.status == "active" ? "\(sprint.name)（進行中）" : sprint.name).tag(Optional(sprint.id))
                        }
                    } label: {
                        Label("スプリント", systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink {
                        ParentTaskPicker(project: project, selection: $draft.parent)
                    } label: {
                        LabeledContent {
                            Text(draft.parent.map { "\(project.key)-\($0.seqId) \($0.title)" } ?? "なし").lineLimit(1)
                        } label: {
                            Label("親タスク", systemImage: "arrow.turn.left.up")
                        }
                    }
                    LabeledContent {
                        TextField("分", text: $draft.estimate)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    } label: {
                        Label("見積もり（分）", systemImage: "hourglass")
                    }
                    VStack(spacing: 6) {
                        LabeledContent {
                            Text(verbatim: "\(draft.progress)%").monospacedDigit()
                        } label: {
                            Label("進捗", systemImage: "chart.bar.fill")
                        }
                        Slider(value: Binding(get: { Double(draft.progress) }, set: { draft.progress = Int($0) }), in: 0...100, step: 5)
                    }
                }

                if !fields.isEmpty {
                    Section("カスタムフィールド") {
                        ForEach(fields) { field in
                            CustomFieldRow(field: field, value: $draft.customValues[field.id])
                        }
                    }
                }

                if !unavailable.isEmpty {
                    Section {
                        Label("\(unavailable.joined(separator: "・"))を読み込めませんでした", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .loadState(isLoaded: true, error: $error)
            .navigationTitle("タスクを作成")
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
                        Button("作成") { Task { await save() } }
                            .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            // 書きかけを下へのスワイプで失わない
            .interactiveDismissDisabled(draft != initialDraft)
            .onAppear { isTitleFocused = true }
            .task { await loadOptions() }
        }
    }

    /// 選択肢は 1 つ読めなくても、ほかの項目で作成できるよう別々に扱う。
    private func loadOptions() async {
        let api = session.api
        async let users = api.assignableUsers(project)
        async let labels = api.labels(project)
        async let milestones = api.milestones(project)
        async let sprints = api.sprints(project)
        async let fields = api.customFields(project)
        var unavailable: [String] = []
        do { self.users = try await users } catch { unavailable.append("担当者") }
        do { self.labels = try await labels } catch { unavailable.append("ラベル") }
        do { self.milestones = try await milestones } catch { unavailable.append("マイルストーン") }
        do { self.sprints = try await sprints.filter { $0.status != "completed" } } catch { unavailable.append("スプリント") }
        do { self.fields = try await fields } catch { unavailable.append("カスタムフィールド") }
        self.unavailable = unavailable
    }

    private func save() async {
        guard let body = draft.request(fields: fields) else {
            error = draft.problem(fields: fields)
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            onCreate(try await session.api.createTask(project, body))
            dismiss()
        } catch {
            self.error = error.displayMessage
        }
    }
}

/// 作成フォームの入力。検証と送信内容の組み立てを画面から切り離して試せるようにする。
struct TaskDraft: Equatable {
    var title = ""
    var description = ""
    var statusId: UUID?
    var priority = TaskPriority.medium
    var assigneeIds: Set<UUID> = []
    var labelIds: Set<UUID> = []
    var softDeadline: Date?
    var hardDeadline: Date?
    var plannedStartOn: Date?
    /// 見積もり（分）。空なら送らない
    var estimate = ""
    var progress = 0
    var milestoneId: UUID?
    var sprintId: UUID?
    var parent: TaskReference?
    /// カスタムフィールドの値。API に送る文字列のまま持ち、空は未設定
    var customValues: [UUID: String] = [:]

    var estimatedMinutes: Int32? {
        Int32(estimate.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 1 ? $0 : nil }
    }

    /// チェックボックスは触っていなくても「オフ」として送る（必須でも false は値として通る）。
    func fieldValue(_ field: CustomField) -> String {
        let value = customValues[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty && field.fieldType == "checkbox" ? "false" : value
    }

    /// 開始予定日が期限（Soft）より後の日か。
    func startsAfterSoftDeadline(calendar: Calendar = .current) -> Bool {
        guard let start = plannedStartOn, let soft = softDeadline else { return false }
        return calendarDate(start, calendar) > calendarDate(soft, calendar)
    }

    /// 送れない理由。Web の作成画面と backend の検証に合わせる。
    func problem(fields: [CustomField], calendar: Calendar = .current) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "タイトルを入力してください" }
        if statusId == nil { return "ステータスを選んでください" }
        // backend は同じ日も受け付けない（soft < hard）
        if let soft = softDeadline, let hard = hardDeadline, calendarDate(soft, calendar) >= calendarDate(hard, calendar) {
            return "期限は最終期限より前の日にしてください"
        }
        if startsAfterSoftDeadline(calendar: calendar) { return "開始予定日は期限以前の日付にしてください" }
        if !estimate.trimmingCharacters(in: .whitespaces).isEmpty, estimatedMinutes == nil {
            return "見積もりは 1 以上の整数（分）で入力してください"
        }
        for field in fields {
            let value = fieldValue(field)
            if value.isEmpty {
                if field.isRequired { return "「\(field.name)」を入力してください" }
                continue
            }
            switch field.fieldType {
            case "number" where Double(value)?.isFinite != true:
                return "「\(field.name)」は数値で入力してください"
            case "url" where !isWebURL(value):
                return "「\(field.name)」は http:// か https:// から始まる URL で入力してください"
            default:
                break
            }
        }
        return nil
    }

    /// 送る内容。`problem` があれば nil。空の項目は送らない。
    func request(fields: [CustomField], calendar: Calendar = .current) -> CreateTaskRequest? {
        guard problem(fields: fields, calendar: calendar) == nil, let statusId else { return nil }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = fields.compactMap { field -> CustomFieldValueInput? in
            let value = fieldValue(field)
            return value.isEmpty ? nil : CustomFieldValueInput(fieldId: field.id, value: value)
        }
        let deadline = { (date: Date) in "\(calendarDate(date, calendar))T00:00:00.000Z" }
        return CreateTaskRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            statusId: statusId,
            description: description.isEmpty ? nil : description,
            priority: priority,
            assignees: assigneeIds.isEmpty ? nil : assigneeIds.sorted { $0.uuidString < $1.uuidString }.map { AssigneeInput(userId: $0) },
            labelIds: labelIds.isEmpty ? nil : labelIds.sorted { $0.uuidString < $1.uuidString },
            softDeadline: softDeadline.map(deadline),
            hardDeadline: hardDeadline.map(deadline),
            plannedStartOn: plannedStartOn.map { calendarDate($0, calendar) },
            estimatedMinutes: estimatedMinutes,
            progressPct: progress > 0 ? progress : nil,
            milestoneId: milestoneId,
            sprintId: sprintId,
            parentTaskId: parent?.id,
            customFieldValues: values.isEmpty ? nil : values)
    }

    /// backend（url crate）は http / https でホストのある URL だけを受け付ける。
    private func isWebURL(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.host() != nil else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// 日付だけの値を `YYYY-MM-DD` にする。0 時を UTC に直すと JST では前日になるので、その暦の日付をそのまま使う。
func calendarDate(_ date: Date, _ calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
}

/// `calendarDate` の逆。読めなければ nil。
func date(fromCalendarDate text: String, _ calendar: Calendar = .current) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

/// 未設定にもできる日付（期限・日付のカスタムフィールド）。オンにすると今日から選べる。
struct OptionalDateRow<Title: View>: View {
    @Binding var date: Date?
    @ViewBuilder let title: () -> Title

    var body: some View {
        Toggle(isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? .now) : nil }), label: title)
        if let value = date {
            DatePicker("日付", selection: Binding(get: { value }, set: { date = $0 }), displayedComponents: .date)
        }
    }
}

/// カスタムフィールドの入力。値は API に送る文字列のまま扱う。
struct CustomFieldRow: View {
    let field: CustomField
    @Binding var value: String?

    var body: some View {
        let text = Binding(get: { value ?? "" }, set: { value = $0 })
        switch field.fieldType {
        case "select":
            Picker(selection: text) {
                Text("未設定").tag("")
                ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
            } label: {
                title
            }
        case "checkbox":
            Toggle(isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" })) { title }
        case "date":
            OptionalDateRow(
                date: Binding(get: { value.flatMap { date(fromCalendarDate: $0) } }, set: { value = $0.map { calendarDate($0) } })
            ) {
                title
            }
        default:
            LabeledContent {
                TextField(field.fieldType == "url" ? "https://" : "入力", text: text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled(field.fieldType == "url")
                    #if os(iOS)
                    .keyboardType(field.fieldType == "number" ? .decimalPad : field.fieldType == "url" ? .URL : .default)
                    .textInputAutocapitalization(field.fieldType == "url" ? .never : .sentences)
                    #endif
            } label: {
                title
            }
        }
    }

    private var title: some View {
        HStack(spacing: 6) {
            Text(field.name)
            if field.isRequired {
                Text("必須").font(.caption2.weight(.semibold)).foregroundStyle(.red)
            }
        }
    }
}

/// 複数選ぶ一覧（作成フォームの担当者・ラベル）。
struct MultiSelectList<Item: Identifiable, Row: View>: View where Item.ID == UUID {
    let title: String
    let items: [Item]
    @Binding var selection: Set<UUID>
    let emptyMessage: String
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        List(items) { item in
            let isOn = selection.contains(item.id)
            Button {
                if isOn { selection.remove(item.id) } else { selection.insert(item.id) }
            } label: {
                HStack {
                    // ボタンの中の `.primary` はアクセント色になるので、文字色を直接指定する
                    row(item).foregroundStyle(Color.primary)
                    Spacer()
                    if isOn { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                }
            }
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
        .overlay {
            if items.isEmpty { ContentUnavailableView(emptyMessage, systemImage: "tray") }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 親タスクを選ぶ。検索語が空のあいだは新しいタスクから選べる。
struct ParentTaskPicker: View {
    let project: Project
    @Binding var selection: TaskReference?
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [TaskReference]?
    @State private var error: String?

    var body: some View {
        List {
            Button {
                selection = nil
                dismiss()
            } label: {
                HStack {
                    Text("なし").foregroundStyle(Color.primary)
                    Spacer()
                    if selection == nil { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                }
            }
            ForEach(results ?? []) { task in
                Button {
                    selection = task
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: "\(project.key)-\(task.seqId)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(task.title).foregroundStyle(Color.primary).lineLimit(2)
                        Spacer()
                        if selection?.id == task.id {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .overlay {
            if results?.isEmpty == true, !query.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .loadState(isLoaded: results != nil, error: $error)
        .searchable(text: $query, prompt: "タイトルで検索")
        .navigationTitle("親タスク")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: query) { await search() }
    }

    private func search() async {
        let query = query.trimmingCharacters(in: .whitespaces)
        do {
            if query.isEmpty {
                // サブタスクの下にもサブタスクを作れるので、親子を区別せずに出す
                let page = try await session.api.tasks(
                    project, cursor: nil, statusId: nil, assigneeId: nil, sort: .createdAtDesc, rootOnly: false)
                results = page.tasks.map { TaskReference(id: $0.id, seqId: $0.seqId, title: $0.title) }
            } else {
                // 打っている途中は送らない（次の入力で取り消される）
                try await Task.sleep(for: .milliseconds(300))
                results = try await session.api.searchTasks(project, query: query)
            }
        } catch {
            self.error = error.displayMessage
        }
    }
}
