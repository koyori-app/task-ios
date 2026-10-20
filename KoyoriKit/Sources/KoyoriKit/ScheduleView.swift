import SwiftUI

/// `lower`〜`upper` の日付が、`first` から `days` 日の表の何日目から何日目にあたるか。範囲外は端で切り、まったく重ならなければ nil。
func dayRange(_ lower: Date, _ upper: Date, first: Date, days: Int, calendar: Calendar = .current) -> ClosedRange<Int>? {
    let index = { (date: Date) in
        calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: date)).day ?? 0
    }
    let (start, end) = (index(lower), index(upper))
    guard start < days, end >= 0, start <= end else { return nil }
    return max(start, 0)...min(end, days - 1)
}

extension Schedule.Item {
    /// 締切の日付（Soft → 無ければ Hard）。backend と同じく端末のタイムゾーンで日付に落とす
    var deadline: Date? { softDeadline ?? hardDeadline }

    /// 帯の範囲（始点 = 開始予定日と締切の早い方、終点 = 遅い方。片方だけならその日）。
    func span(first: Date, days: Int, calendar: Calendar = .current) -> ClosedRange<Int>? {
        let ends = [plannedStartOn.flatMap { date(fromCalendarDate: $0, calendar) }, deadline].compactMap { $0 }
        guard let lower = ends.min(), let upper = ends.max() else { return nil }
        return dayRange(lower, upper, first: first, days: days, calendar: calendar)
    }
}

/// テナントのカレンダー。メンバーごとの段に、タスクを開始予定日〜締切の帯で並べる 2 週間（月曜始まり）の表。
struct ScheduleView: View {
    let tenant: Tenant
    @Environment(AppSession.self) private var session
    @State private var first = ScheduleView.monday(of: .now)
    @State private var schedule: Schedule?
    @State private var memberFilter: UUID?
    @State private var projectFilter: UUID?
    @State private var target: TaskTarget?
    @State private var error: String?

    private static let days = 14
    private static let dayWidth: CGFloat = 44
    private static let labelWidth: CGFloat = 112

    static func monday(of date: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private func day(_ index: Int) -> Date { Calendar.current.date(byAdding: .day, value: index, to: first) ?? first }

    private var tasks: [Schedule.Item] {
        (schedule?.tasks ?? []).filter { projectFilter == nil || $0.project.id == projectFilter }
    }

    private var projects: [Schedule.ProjectInfo] {
        var seen = Set<UUID>()
        return (schedule?.tasks ?? []).map(\.project).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }

    private var members: [UserSummary] {
        (schedule?.members ?? []).sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }

    var body: some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    planRows
                    ForEach(members.filter { memberFilter == nil || $0.id == memberFilter }) { member in
                        let items = tasks.filter { $0.assignees.contains { $0.userId == member.id } }
                        if !items.isEmpty {
                            memberSection(items, role: { task in task.assignees.first { $0.userId == member.id }?.role }) {
                                Avatar(name: member.username, url: member.avatarUrl, size: 22)
                                Text(member.username).lineLimit(1)
                            }
                        }
                    }
                    let unassigned = tasks.filter(\.assignees.isEmpty)
                    if memberFilter == nil, !unassigned.isEmpty {
                        memberSection(unassigned, role: { _ in nil }) {
                            Image(systemName: "person.crop.circle.badge.questionmark").font(.title3).foregroundStyle(.secondary)
                            Text("担当者なし").lineLimit(1)
                        }
                    }
                }
                .padding(.bottom)
                .background(alignment: .topLeading) { dayColumns }
            }
        }
        .overlay {
            if schedule != nil, tasks.isEmpty {
                ContentUnavailableView("この期間のタスクはありません", systemImage: "calendar")
            }
        }
        .loadState(isLoaded: schedule != nil, error: $error)
        .navigationTitle("カレンダー")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("前の 2 週間", systemImage: "chevron.left") { move(-Self.days) }
                Button("今日") { first = Self.monday(of: .now) }
                Button("次の 2 週間", systemImage: "chevron.right") { move(Self.days) }
            }
            ToolbarItem {
                Menu {
                    Picker(selection: $memberFilter) {
                        Text("すべてのメンバー").tag(UUID?.none)
                        ForEach(members) { Text($0.username).tag(Optional($0.id)) }
                    } label: {
                        Label("メンバー", systemImage: "person")
                    }
                    .pickerStyle(.menu)
                    Picker(selection: $projectFilter) {
                        Text("すべてのプロジェクト").tag(UUID?.none)
                        ForEach(projects, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    } label: {
                        Label("プロジェクト", systemImage: "folder")
                    }
                    .pickerStyle(.menu)
                } label: {
                    Label(
                        "絞り込み",
                        systemImage: memberFilter == nil && projectFilter == nil
                            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .navigationDestination(item: $target) { TaskLoaderView(project: $0.project, taskRef: $0.ref) }
        .task(id: first) { await load() }
        .refreshable { await load() }
    }

    /// 日付の見出し。週末は薄く、今日は色を付ける
    private var header: some View {
        HStack(spacing: 0) {
            Text(verbatim: "\(first.formatted(.dateTime.month().day())) – \(day(Self.days - 1).formatted(.dateTime.month().day()))")
                .font(.caption.weight(.semibold))
                .frame(width: Self.labelWidth, alignment: .leading)
                .padding(.leading, 8)
            ForEach(0..<Self.days, id: \.self) { index in
                let date = day(index)
                let isToday = Calendar.current.isDateInToday(date)
                VStack(spacing: 2) {
                    Text(date, format: .dateTime.weekday(.narrow))
                    // 今日はカレンダー App と同じく日付を囲む（日本語では「20日」と長いので横長の丸）
                    Text(date, format: .dateTime.day())
                        .fontWeight(isToday ? .bold : .regular)
                        .foregroundStyle(isToday ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 5)
                        .frame(minHeight: 20)
                        .background(isToday ? Color.accentColor : .clear, in: .capsule)
                }
                .font(.caption)
                .foregroundStyle(Calendar.current.isDateInWeekend(date) ? .secondary : .primary)
                .frame(width: Self.dayWidth, height: 46)
            }
        }
    }

    /// 日ごとの列の地。表全体に 1 枚で敷き、段の間で途切れないようにする。週末は薄い灰色、今日はアクセント色
    private var dayColumns: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.labelWidth + 8)
            ForEach(0..<Self.days, id: \.self) { index in
                let date = day(index)
                Rectangle()
                    .fill(
                        Calendar.current.isDateInToday(date)
                            ? Color.accentColor.opacity(0.1)
                            : Calendar.current.isDateInWeekend(date) ? Color.secondary.opacity(0.08) : .clear
                    )
                    .frame(width: Self.dayWidth)
            }
        }
    }

    /// 最上段のスプリント（期間の帯）とマイルストーン（期日の旗）。
    @ViewBuilder
    private var planRows: some View {
        let sprints = (schedule?.sprints ?? []).filter { projectFilter == nil || $0.projectId == projectFilter }
        let milestones = (schedule?.milestones ?? []).filter { projectFilter == nil || $0.projectId == projectFilter }
        if !sprints.isEmpty || !milestones.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Label("計画", systemImage: "flag.checkered")
                    .font(.subheadline)
                    .frame(width: Self.labelWidth, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sprints) { sprint in
                        if let start = date(fromCalendarDate: sprint.startDate), let end = date(fromCalendarDate: sprint.endDate),
                            let range = dayRange(start, end, first: first, days: Self.days)
                        {
                            lane { bar(sprint.name, range: range, color: .purple, filled: false) }
                        }
                    }
                    ForEach(milestones) { milestone in
                        if let due = date(fromCalendarDate: milestone.dueDate),
                            let range = dayRange(due, due, first: first, days: Self.days)
                        {
                            lane {
                                Label(milestone.name, systemImage: "flag.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                                    .labelStyle(.compact)
                                    .fixedSize()
                                    .offset(x: CGFloat(range.lowerBound) * Self.dayWidth + 4)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
        }
    }

    /// メンバー 1 人（または担当者なし）の段。タスク 1 件を 1 行にする。
    private func memberSection(
        _ items: [Schedule.Item], role: @escaping (Schedule.Item) -> String?, @ViewBuilder title: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                HStack(spacing: 6, content: title)
                    .font(.subheadline)
                    .frame(width: Self.labelWidth, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { task in
                        if let range = task.span(first: first, days: Self.days) {
                            lane { taskBar(task, range: range, isPrimary: role(task) == "primary") }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
        }
    }

    private func taskBar(_ task: Schedule.Item, range: ClosedRange<Int>, isPrimary: Bool) -> some View {
        let isOverdue = !task.status.isDoneState && (task.softDeadline.map { $0 < .now } ?? false)
        // 期限切れは一覧の締切と同じ赤。アクセント色（琥珀）と見分けられるようにする
        let color: Color = task.status.isDoneState ? .gray : isOverdue ? .red : .accentColor
        return Button {
            let project = Project(
                id: task.project.id, tenantId: tenant.id, key: task.project.key, name: task.project.name, iconEmoji: nil)
            target = TaskTarget(project: project, ref: task.id.uuidString)
        } label: {
            if task.plannedStartOn == nil {
                // 開始予定日が無いタスクは締切の日の点
                HStack(spacing: 4) {
                    Image(systemName: isPrimary ? "diamond.fill" : "diamond").foregroundStyle(color)
                    Text(verbatim: "\(task.seqKey) \(task.title)")
                }
                .font(.caption2)
                .fixedSize()
                .offset(x: CGFloat(range.lowerBound) * Self.dayWidth + 14)
            } else {
                bar("\(task.seqKey) \(task.title)", range: range, color: color, filled: isPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    /// 主担当は塗り、それ以外は薄い枠。
    private func bar(_ title: String, range: ClosedRange<Int>, color: Color, filled: Bool) -> some View {
        let width = CGFloat(range.count) * Self.dayWidth - 4
        let x = CGFloat(range.lowerBound) * Self.dayWidth + 2
        let fill: Color = filled ? color : color.opacity(0.12)
        let stroke: Color = color.opacity(filled ? 0 : 0.6)
        // アクセント色の上は、ライトでは白・ダークでは黒の方が読みやすい
        let text: AnyShapeStyle = !filled ? AnyShapeStyle(.primary) : color == .accentColor ? AnyShapeStyle(.background) : AnyShapeStyle(.white)
        let shape = RoundedRectangle(cornerRadius: 5)
        // 2 日以下の帯は名前が入らないので、帯の右に出す
        let isShort = range.count <= 2
        return HStack(spacing: 4) {
            Text(verbatim: isShort ? "" : title)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: width, height: 20, alignment: .leading)
                .foregroundStyle(text)
                .background(fill, in: shape)
                .overlay(shape.stroke(stroke))
            if isShort {
                Text(verbatim: title).font(.caption2).lineLimit(1).fixedSize()
            }
        }
        .offset(x: x)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
    }

    /// 1 日 = 固定幅の行（列の地は `dayColumns`）
    private func lane(@ViewBuilder content: () -> some View) -> some View {
        content().frame(width: CGFloat(Self.days) * Self.dayWidth, height: 24, alignment: .leading)
    }

    private func move(_ days: Int) {
        first = Calendar.current.date(byAdding: .day, value: days, to: first) ?? first
    }

    private func load() async {
        let from = calendarDate(first)
        let to = calendarDate(day(Self.days - 1))
        do {
            schedule = try await session.api.schedule(
                tenantId: tenant.id, from: from, to: to, timezone: TimeZone.current.identifier)
        } catch {
            self.error = error.displayMessage
        }
    }
}
