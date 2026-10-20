import SwiftUI

// 表記は Web の `lib/review-findings.ts` と同じ。

func severityLabel(_ severity: String) -> String {
    ["high": "High", "medium": "Medium", "low": "Low", "nit": "Nit"][severity] ?? severity
}

func findingStateLabel(_ state: String) -> String {
    ["open": "Open", "fixing": "Fixing", "fixed": "Fixed", "verified": "Verified", "deferred": "Deferred", "rejected": "Rejected"][
        state] ?? state
}

/// PR・Issue のホスト上の状態。
func forgeStateLabel(_ state: String) -> String {
    ["open": "オープン", "closed": "クローズ", "merged": "マージ済み", "unknown": "状態不明"][state] ?? state
}

/// マージ判定で「未解決」と数える状態（backend の `counts_as_unresolved` と対）。
func isUnresolved(_ state: String) -> Bool {
    ["open", "fixing", "fixed"].contains(state)
}

/// 指摘の操作の名前。遷移できる先は backend の `available_actions` だけを使う。
func findingActionLabel(to: String, from state: String) -> String {
    switch to {
    case "fixing": "修正に着手する"
    case "fixed": "修正した"
    case "verified": "確認した"
    case "deferred": "繰り延べる"
    case "rejected": "指摘を取り下げる"
    case "open": state == "fixed" ? "レビューに戻す" : state == "fixing" ? "着手を取り消す" : "再オープン"
    default: findingStateLabel(to)
    }
}

struct MergeVerdict: Equatable {
    enum Tone { case good, bad, warning, neutral }
    let title: String
    let detail: String
    let tone: Tone
}

/// マージ可否の見出しと説明。判定は backend の `gate` をそのまま使い、再計算しない（Web の `mergeVerdict`）。
func mergeVerdict(_ summary: ReviewSummary) -> MergeVerdict {
    let reviewed = summary.latestHeadSha.map { "最新ラウンドは \($0.prefix(7)) を見ています" }
    let join = { (parts: [String?]) in parts.compactMap { $0 }.joined(separator: " · ") }
    switch summary.gate {
    case "unlinked":
        return MergeVerdict(
            title: "リポジトリ未確定", detail: "GitHub 連携が無いため、どのリポジトリの PR を見た集計か決まりません。マージの判断には使えません",
            tone: .neutral)
    case "unreviewed":
        return MergeVerdict(title: "未レビュー", detail: "まだレビューされていません。レビューを 1 ラウンド出してください", tone: .neutral)
    case "blocked":
        return MergeVerdict(
            title: "マージ不可（\(summary.blocking) 件）", detail: join(["High / Medium が未解決です。Low / Nit は繰り延べできます", reviewed]),
            tone: .bad)
    case "stale_unknown":
        return MergeVerdict(
            title: "鮮度不明", detail: join(["High / Medium の未解決はありませんが、現在の HEAD を確認できていません", reviewed]), tone: .warning)
    case "outdated":
        return MergeVerdict(
            title: "レビューが古い",
            detail: join(["レビュー後にコミットが積まれています（現在 \((summary.cachedPrHeadSha ?? "").prefix(7))）", reviewed]),
            tone: .warning)
    case "ready":
        // キャッシュは push では更新されないので、いつ時点の確認かを必ず添える
        let checked = summary.prHeadCheckedAt.map { "GitHub 確認: \($0.formatted(date: .abbreviated, time: .shortened)) 時点" }
        return MergeVerdict(title: "マージ可", detail: join(["High / Medium の未解決はありません", reviewed, checked]), tone: .good)
    default:
        return MergeVerdict(title: summary.gate, detail: join([reviewed]), tone: .neutral)
    }
}

/// PR 一覧の状態での絞り込み。
enum PullRequestFilter: String, CaseIterable, Hashable {
    case all, needsFix, awaitingApproval, unresolved, resolved

    var label: String {
        switch self {
        case .all: "すべて"
        case .needsFix: "要対応"
        case .awaitingApproval: "承認待ち"
        case .unresolved: "未解決"
        case .resolved: "解決済み"
        }
    }
}

/// PR 一覧の行に出す状態。マージを止めている指摘（High / Medium）は、直す番か確認待ちかで分ける。
enum PullRequestStatus: Equatable {
    /// open か fixing が残っている（作成者が直す番）
    case needsFix(Int)
    /// 残りはすべて fixed（レビュー側の確認待ち）
    case awaitingApproval(Int)
    /// 未解決は Low / Nit だけ
    case unresolved(Int)
    case resolved
}

extension ReviewedPullRequest {
    /// `blocking` は fixed も含むので、`blockingFixed` を引いた残りが直す番の数。
    var status: PullRequestStatus {
        if blocking > blockingFixed { return .needsFix(blocking - blockingFixed) }
        if blocking > 0 { return .awaitingApproval(blocking) }
        return unresolved > 0 ? .unresolved(unresolved) : .resolved
    }

    /// 状態・作者・語（タイトルか番号）の AND。PR 一覧は全件返る（ページ送りが無い）ので、端末で絞っても漏れない。
    func matches(_ filter: PullRequestFilter, author: String?, query: String) -> Bool {
        let state =
            switch (filter, status) {
            case (.all, _), (.needsFix, .needsFix), (.awaitingApproval, .awaitingApproval): true
            case (.unresolved, _): unresolved > 0
            case (.resolved, _): unresolved == 0
            default: false
            }
        let query = String(query.trimmingCharacters(in: .whitespaces).trimmingPrefix("#"))
        let text = query.isEmpty || String(prNumber).hasPrefix(query) || prTitle?.localizedCaseInsensitiveContains(query) == true
        return state && (author == nil || prAuthor == author) && text
    }
}

/// レビューのある PR の一覧。マージの可否は一覧からは決められない（API の注記）ので、件数だけを出す。
struct ReviewListView: View {
    let project: Project
    @Environment(AppSession.self) private var session
    @State private var pullRequests: [ReviewedPullRequest]?
    @State private var filter = PullRequestFilter.all
    @State private var author: String?
    @State private var query = ""
    @State private var error: String?

    private var shown: [ReviewedPullRequest] {
        (pullRequests ?? []).filter { $0.matches(filter, author: author, query: query) }
    }

    private var authors: [String] { Set((pullRequests ?? []).compactMap(\.prAuthor)).sorted() }

    var body: some View {
        List {
            if pullRequests?.isEmpty == false {
                Picker("状態", selection: $filter) {
                    ForEach(PullRequestFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(shown) { pr in
                NavigationLink {
                    ReviewPullRequestView(project: project, prNumber: pr.prNumber, title: pr.prTitle)
                } label: {
                    PullRequestRow(pr: pr)
                }
            }
            if pullRequests?.isEmpty == false, shown.isEmpty {
                ContentUnavailableView("該当する PR はありません", systemImage: "line.3.horizontal.decrease.circle", description: Text("絞り込みを変えてください。"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if pullRequests?.isEmpty == true {
                ContentUnavailableView("レビューはありません", systemImage: "checklist", description: Text("task CLI でレビューを起票するとここに出ます。"))
            }
        }
        .loadState(isLoaded: pullRequests != nil, error: $error)
        .searchable(text: $query, prompt: "タイトルか番号で検索")
        .toolbar {
            if authors.count > 1 {
                ToolbarItem {
                    Menu {
                        Picker("作者", selection: $author) {
                            Text("すべての作者").tag(String?.none)
                            ForEach(authors, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    } label: {
                        Label("作者で絞り込む", systemImage: author == nil ? "person.crop.circle" : "person.crop.circle.fill")
                    }
                }
            }
        }
        .navigationTitle("レビュー")
        // 行のリンク先タスクを開く
        .taskReferenceLinks(tenantId: project.tenantId)
        .task { if pullRequests == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let list = try await session.api.reviewedPullRequests(project)
            pullRequests = list.sorted { $0.lastReviewedAt > $1.lastReviewedAt }
        } catch {
            self.error = error.displayMessage
        }
    }
}

struct PullRequestRow: View {
    let pr: ReviewedPullRequest
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "#\(pr.prNumber)").font(.subheadline.monospaced().weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(pr.prTitle ?? "PR #\(pr.prNumber)").lineLimit(2)
                HStack(spacing: 10) {
                    Text(verbatim: "R\(pr.rounds)")
                    if let author = pr.prAuthor { Label(author, systemImage: "person") }
                    Text(pr.lastReviewedAt, format: .relative(presentation: .named))
                    if let state = pr.state, state != "unknown" { Text(forgeStateLabel(state)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.compact)
                if let tasks = pr.linkedTasks, !tasks.isEmpty {
                    // 行の遷移（PR のレビュー）と別に押せるよう、枠なしのボタンにする
                    HStack(spacing: 6) {
                        ForEach(tasks) { task in
                            Button {
                                if let url = URL(string: "koyori://task/\(task.key)/\(task.id.uuidString)") { openURL(url) }
                            } label: {
                                Text(verbatim: "\(task.key)-\(task.seqId)").font(.caption.monospaced())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(task.key)-\(task.seqId) \(task.title)")
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            Group {
                switch pr.status {
                case .needsFix(let count):
                    Text("要対応 \(count)")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(Color.red, in: .capsule)
                case .awaitingApproval(let count):
                    Label("承認待ち \(count)", systemImage: "hourglass").foregroundStyle(.orange)
                case .unresolved(let count):
                    Text("未解決 \(count)")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.fill.secondary, in: .capsule)
                case .resolved:
                    Label("解決済み", systemImage: "checkmark").foregroundStyle(.green)
                }
            }
            .font(.caption.weight(.semibold))
            .labelStyle(.compact)
        }
        .padding(.vertical, 2)
    }
}

/// 1 つの PR のレビュー。マージ判定・指摘・ラウンド。
struct ReviewPullRequestView: View {
    let project: Project
    let prNumber: Int
    let title: String?
    @Environment(AppSession.self) private var session
    @State private var summary: ReviewSummary?
    @State private var rounds: [ReviewRound] = []
    @State private var findings: [ReviewFinding] = []
    @State private var showsResolved = false
    /// `nil` はすべての重大度
    @State private var severity: String?
    @State private var error: String?

    private var shownFindings: [ReviewFinding] {
        let order = ["high", "medium", "low", "nit"]
        return findings
            .filter { (showsResolved || isUnresolved($0.state)) && (severity == nil || $0.severity == severity) }
            .sorted {
                (isUnresolved($0.state) ? 0 : 1, order.firstIndex(of: $0.severity) ?? 4, -$0.round)
                    < (isUnresolved($1.state) ? 0 : 1, order.firstIndex(of: $1.severity) ?? 4, -$1.round)
            }
    }

    var body: some View {
        List {
            if let summary {
                Section {
                    VerdictCard(verdict: mergeVerdict(summary), repository: summary.repository)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(shownFindings) { finding in
                    NavigationLink {
                        FindingDetailView(project: project, finding: finding) { replace($0) }
                    } label: {
                        FindingRow(finding: finding)
                    }
                }
                if summary != nil, shownFindings.isEmpty {
                    Text(severity != nil ? "該当する指摘はありません" : showsResolved ? "指摘はありません" : "未解決の指摘はありません")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("指摘")
                    Spacer()
                    Picker("表示", selection: $showsResolved) {
                        Text("未解決").tag(false)
                        Text("すべて").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Menu {
                        Picker("重大度", selection: $severity) {
                            Text("すべての重大度").tag(String?.none)
                            ForEach(["high", "medium", "low", "nit"], id: \.self) { Text(severityLabel($0)).tag(Optional($0)) }
                        }
                    } label: {
                        Image(systemName: severity == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .imageScale(.large)
                    }
                    .accessibilityLabel("重大度で絞り込む")
                }
            }
            if !rounds.isEmpty {
                Section("ラウンド") {
                    ForEach(rounds.sorted { $0.round > $1.round }) { round in
                        NavigationLink {
                            ReviewRoundView(project: project, reviewId: round.id)
                        } label: {
                            RoundRow(round: round)
                        }
                    }
                }
            }
        }
        .loadState(isLoaded: summary != nil, error: $error)
        .navigationTitle(Text(verbatim: "#\(prNumber)"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let title {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(verbatim: "#\(prNumber)").font(.headline)
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .task { if summary == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        let api = session.api
        do {
            async let summary = api.reviewSummary(project, pr: prNumber)
            async let rounds = api.reviewRounds(project, pr: prNumber)
            async let findings = api.reviewFindings(project, pr: prNumber)
            (self.rounds, self.findings) = (try await rounds, try await findings)
            self.summary = try await summary
        } catch {
            self.error = error.displayMessage
        }
    }

    private func replace(_ finding: ReviewFinding) {
        if let index = findings.firstIndex(where: { $0.id == finding.id }) { findings[index] = finding }
        // 件数とマージ判定は backend だけが決めるので読み直す
        Task { summary = (try? await session.api.reviewSummary(project, pr: prNumber)) ?? summary }
    }
}

struct VerdictCard: View {
    let verdict: MergeVerdict
    let repository: String?

    var body: some View {
        let (symbol, color): (String, Color) =
            switch verdict.tone {
            case .good: ("checkmark.seal.fill", .green)
            case .bad: ("xmark.octagon.fill", .red)
            case .warning: ("exclamationmark.triangle.fill", .orange)
            case .neutral: ("questionmark.circle.fill", .gray)
            }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verdict.title).font(.headline)
                Text(verdict.detail).font(.subheadline).foregroundStyle(.secondary)
                if let repository {
                    Label(repository, systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary).labelStyle(.compact)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct SeverityBadge: View {
    let severity: String

    var body: some View {
        let color: Color =
            switch severity {
            case "high": .red
            case "medium": .orange
            case "low": .blue
            default: .gray
            }
        Text(severityLabel(severity))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color, in: .capsule)
    }
}

struct FindingRow: View {
    let finding: ReviewFinding

    var body: some View {
        let resolved = !isUnresolved(finding.state)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SeverityBadge(severity: finding.severity)
                Text(finding.title)
                    .strikethrough(resolved)
                    .foregroundStyle(resolved ? .secondary : .primary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Text(findingStateLabel(finding.state)).fontWeight(.semibold)
                Text(verbatim: "R\(finding.round)")
                if let file = finding.file {
                    Text(verbatim: finding.line.map { "\(file):\($0)" } ?? file).monospaced().lineLimit(1).truncationMode(.head)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct RoundRow: View {
    let round: ReviewRound

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "R\(round.round)").font(.subheadline.monospaced().weight(.semibold))
            Avatar(name: round.reviewer.username, url: round.reviewer.avatarUrl, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(round.reviewer.username).font(.subheadline)
                Text(verbatim: "\(round.headSha.prefix(7)) · 指摘 \(round.findingCount) 件").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(round.createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 1 回のレビュー（R1, R2, …）。要約と、その回の指摘。
struct ReviewRoundView: View {
    let project: Project
    let reviewId: UUID
    @Environment(AppSession.self) private var session
    @State private var round: ReviewRound?
    @State private var findings: [ReviewFinding] = []
    @State private var error: String?

    var body: some View {
        List {
            if let round {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(round.prTitle ?? "PR #\(round.prNumber)").font(.title3.bold())
                        HStack(spacing: 8) {
                            Avatar(name: round.reviewer.username, url: round.reviewer.avatarUrl, size: 22)
                            Text(round.reviewer.username)
                            Text(verbatim: round.headSha.prefix(7).description).monospaced().foregroundStyle(.secondary)
                            Text(round.createdAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .listRowBackground(Color.clear)
                }
                if !round.summary.isEmpty {
                    Section("要約") { MarkdownText(text: round.summary) }
                }
                Section("指摘 \(findings.count) 件") {
                    ForEach(findings) { finding in
                        NavigationLink {
                            FindingDetailView(project: project, finding: finding) { updated in
                                if let index = findings.firstIndex(where: { $0.id == updated.id }) { findings[index] = updated }
                            }
                        } label: {
                            FindingRow(finding: finding)
                        }
                    }
                }
                Section {
                    NavigationLink("この PR のレビューをすべて見る") {
                        ReviewPullRequestView(project: project, prNumber: round.prNumber, title: round.prTitle)
                    }
                }
            }
        }
        .loadState(isLoaded: round != nil, error: $error)
        .taskReferenceLinks(tenantId: project.tenantId)
        .navigationTitle(round.map { Text(verbatim: "#\($0.prNumber) R\($0.round)") } ?? Text("レビュー"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { if round == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let detail = try await session.api.reviewRound(project, id: reviewId)
            round = detail.round
            findings = detail.findings
        } catch {
            self.error = error.displayMessage
        }
    }
}

/// 指摘の本文・状態の変更・履歴。
struct FindingDetailView: View {
    let project: Project
    let onChange: (ReviewFinding) -> Void
    @Environment(AppSession.self) private var session
    @State private var finding: ReviewFinding
    @State private var savingState: String?
    /// 理由を書いてから遷移する操作（取り下げ・繰り延べ）
    @State private var pendingState: String?
    @State private var note = ""
    @State private var error: String?

    init(project: Project, finding: ReviewFinding, onChange: @escaping (ReviewFinding) -> Void) {
        self.project = project
        self.onChange = onChange
        _finding = State(initialValue: finding)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SeverityBadge(severity: finding.severity)
                        Text(findingStateLabel(finding.state)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: "R\(finding.round)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(finding.title).font(.title3.bold()).textSelection(.enabled)
                    if let file = finding.file {
                        Label(finding.line.map { "\(file):\($0)" } ?? file, systemImage: "doc.text")
                            .labelStyle(.compact)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                .listRowBackground(Color.clear)
            }

            if !finding.body.isEmpty {
                Section("内容") { MarkdownText(text: finding.body) }
            }

            if !finding.availableActions.isEmpty {
                Section("操作") {
                    ForEach(finding.availableActions, id: \.self) { state in
                        Button {
                            if ["rejected", "deferred"].contains(state) {
                                note = ""
                                pendingState = state
                            } else {
                                Task { await transition(to: state, note: nil) }
                            }
                        } label: {
                            HStack {
                                Text(findingActionLabel(to: state, from: finding.state))
                                    .foregroundStyle(state == "rejected" ? Color.red : Color.accentColor)
                                Spacer()
                                if savingState == state { ProgressView() }
                            }
                        }
                        .disabled(savingState != nil)
                    }
                }
            }

            if let taskId = finding.deferredTaskId {
                Section {
                    NavigationLink {
                        TaskLoaderView(project: project, taskId: taskId)
                    } label: {
                        Label("繰り延べ先のタスク", systemImage: "arrow.uturn.forward")
                    }
                }
            }

            Section("履歴") {
                ForEach(finding.transitions.sorted { $0.createdAt > $1.createdAt }) { transition in
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(name: transition.actor.username, url: transition.actor.avatarUrl, size: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(transition.actor.username).font(.subheadline.weight(.semibold))
                                Text(transition.createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(
                                transition.fromState.map { "\(findingStateLabel($0)) → \(findingStateLabel(transition.toState))" }
                                    ?? "起票（\(findingStateLabel(transition.toState))）"
                            )
                            .font(.subheadline)
                            if let note = transition.note, !note.isEmpty {
                                Text(note).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .loadState(isLoaded: true, error: $error)
        .taskReferenceLinks(tenantId: project.tenantId)
        .navigationTitle("指摘")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            pendingState.map { findingActionLabel(to: $0, from: finding.state) } ?? "",
            isPresented: Binding(get: { pendingState != nil }, set: { if !$0 { pendingState = nil } })
        ) {
            TextField("理由（任意）", text: $note)
            Button("キャンセル", role: .cancel) {}
            Button("実行") {
                if let state = pendingState {
                    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await transition(to: state, note: note.isEmpty ? nil : note) }
                }
            }
        } message: {
            Text("理由は履歴に残ります。")
        }
        .sensoryFeedback(.success, trigger: finding.state)
    }

    private func transition(to state: String, note: String?) async {
        savingState = state
        defer { savingState = nil }
        do {
            finding = try await session.api.updateFinding(project, id: finding.id, state: state, note: note)
            onChange(finding)
        } catch {
            self.error = error.displayMessage
        }
    }
}
