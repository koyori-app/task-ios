import MarkdownUI
import SwiftUI

/// 選ぶとすぐ保存する。表示は保存後の値に従う。
struct StatusPicker: View {
    let statuses: [TaskStatus]
    let selection: UUID
    let onSelect: (UUID) -> Void

    var body: some View {
        Picker(selection: Binding(get: { selection }, set: { onSelect($0) })) {
            ForEach(statuses) { status in
                Label { Text(status.name) } icon: { StatusIcon(status: status) }.tag(status.id)
            }
        } label: {
            Label("ステータス", systemImage: "circle.inset.filled")
        }
    }
}

/// 選ぶとすぐ保存する。表示は保存後の値に従う。
struct PriorityPicker: View {
    let selection: String
    let onSelect: (TaskPriority) -> Void

    var body: some View {
        Picker(selection: Binding(get: { selection }, set: { TaskPriority(rawValue: $0).map(onSelect) })) {
            ForEach(TaskPriority.allCases, id: \.self) { priority in
                Label { Text(priority.label) } icon: { priority.icon }.tag(priority.rawValue)
            }
        } label: {
            Label("優先度", systemImage: "cellularbars")
        }
    }
}

/// 完了の切り替え先。未完了なら最初の完了ステータス、完了済みなら既定（なければ最初の未完了）のステータス。
func completionTarget(from status: TaskStatus?, in statuses: [TaskStatus]) -> TaskStatus? {
    if status?.isDoneState == true {
        return statuses.first { $0.isDefault && !$0.isDoneState } ?? statuses.first { !$0.isDoneState }
    }
    return statuses.first(where: \.isDoneState)
}

/// 左からのスワイプで完了にする。完了済みなら未完了に戻す（一覧とサブタスク）。
struct CompletionSwipeButton: View {
    let status: TaskStatus?
    let statuses: [TaskStatus]
    let onSelect: (UUID) -> Void

    var body: some View {
        if let target = completionTarget(from: status, in: statuses) {
            if status?.isDoneState == true {
                Button("未完了に戻す", systemImage: "arrow.uturn.backward") { onSelect(target.id) }.tint(.gray)
            } else {
                Button("完了", systemImage: "checkmark") { onSelect(target.id) }.tint(.green)
            }
        }
    }
}

/// ステータスの色の丸。完了扱いのステータスはチェック。
struct StatusIcon: View {
    let status: TaskStatus?

    var body: some View {
        Image(systemName: status?.isDoneState == true ? "checkmark.circle.fill" : "circle.inset.filled")
            .foregroundStyle(Color(hex: status?.color ?? ""))
    }
}

struct PriorityLabel: View {
    let priority: String

    var body: some View {
        let known = TaskPriority(rawValue: priority)
        Label {
            Text(known?.label ?? priority)
        } icon: {
            if let known { known.icon }
        }
    }
}

extension TaskPriority {
    /// Web の `PRIORITY_CONFIG` と同じ色。
    var color: Color {
        switch self {
        case .criticalFire: Color(hex: "#dc2626")
        case .critical: Color(hex: "#ef4444")
        case .high: Color(hex: "#f97316")
        case .medium: Color(hex: "#eab308")
        case .low: Color(hex: "#6b7280")
        case .trivial: Color(hex: "#9ca3af")
        }
    }

    /// 強さは電波の本数で表し、緊急だけ炎にする。
    var icon: some View {
        let (symbol, level): (String, Double) =
            switch self {
            case .criticalFire: ("flame.fill", 1)
            case .critical: ("cellularbars", 1)
            case .high: ("cellularbars", 0.75)
            case .medium: ("cellularbars", 0.5)
            case .low, .trivial: ("cellularbars", 0.25)
            }
        return Image(systemName: symbol, variableValue: level).foregroundStyle(color)
    }
}

struct DeadlineLabel: View {
    let date: Date
    let isDone: Bool

    var body: some View {
        let deadline = deadlineText(date)
        Label(deadline.text, systemImage: "calendar")
            .foregroundStyle(deadline.isOverdue && !isDone ? Color.red : Color.secondary)
    }
}

/// Web の `formatDeadline` と同じ表記（今日・N日超過・7日以内は N日後・それより先は月日）。
func deadlineText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> (text: String, isOverdue: Bool) {
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    let isOverdue = date < now
    if days == 0 { return ("今日", isOverdue) }
    if isOverdue { return ("\(-days)日超過", true) }
    if days <= 7 { return ("\(days)日後", false) }
    return (date.formatted(.dateTime.month().day()), false)
}

struct LabelChip: View {
    let label: TaskLabel

    var body: some View {
        let color = Color(hex: label.color)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label.name).lineLimit(1)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // ラベルの色をうっすら敷いて、灰色の札より見分けやすくする
        .background(color.opacity(0.15), in: .capsule)
    }
}

/// 一覧の行のラベル。札にせず「● 名前」だけを並べて、行を軽く保つ。
struct InlineLabels: View {
    let labels: [TaskLabel]

    var body: some View {
        // 入らない分は数で出す（ViewThatFits は先頭から試すので、全部出す形を先に置く）
        ViewThatFits(in: .horizontal) {
            ForEach(0..<labels.count, id: \.self) { hidden in
                HStack(spacing: 10) {
                    ForEach(labels.dropLast(hidden)) { label in
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: label.color)).frame(width: 7, height: 7)
                            Text(label.name)
                        }
                        .fixedSize()
                    }
                    if hidden > 0 { Text(verbatim: "+\(hidden)").fixedSize() }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 横に並べ、入りきらなければ折り返す（ラベルの札用）。
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(width: bounds.width, subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}

/// 利用者のアイコン。未設定・読み込み中・読めないときは名前の頭文字の丸。
struct Avatar: View {
    let name: String
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                // ツールバーに置いても単色で塗られないよう、元の色で描く
                image.renderingMode(.original).resizable().scaledToFill()
            } else {
                // 濃い単色の丸は並ぶと騒がしいので、名前の色を薄く敷いて頭文字をその色で書く
                let color = Color(seed: name)
                Text(verbatim: String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .frame(width: size, height: size)
                    .background(color.opacity(0.2))
                    .background(.background)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// 重ねたアイコン（一覧の行の担当者）。多いときは先頭の 3 人までにして、残りは数で出す。
struct AvatarStack: View {
    let users: [UserSummary]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size / 4) {
            ForEach(users.prefix(3)) { user in
                Avatar(name: user.username, url: user.avatarUrl, size: size)
                    .padding(1.5)
                    .background(.background, in: .circle)
            }
            if users.count > 3 {
                Text(verbatim: "+\(users.count - 3)")
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.fill.secondary, in: .circle)
                    .padding(1.5)
                    .background(.background, in: .circle)
            }
        }
    }
}

/// アイコンと名前の札（詳細の担当者・作成者）。
struct PersonChip: View {
    let name: String
    let url: String?

    var body: some View {
        HStack(spacing: 6) {
            Avatar(name: name, url: url, size: 22)
            Text(verbatim: name).lineLimit(1)
        }
        .font(.subheadline)
        // ボタンの中の `.primary` はアクセント色になるので、文字色を直接指定する
        .foregroundStyle(Color.primary)
        .padding(.leading, 3)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(.fill.tertiary, in: .capsule)
    }
}

/// アイコンと文字を詰めて並べる（行内の小さな情報用）。
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    static var compact: Self { .init() }
}

extension View {
    /// 詳細画面のステータス・優先度のような、押せる小さな札。`tint` を渡すとその色を薄く敷く。
    func pill(tint: Color? = nil) -> some View {
        labelStyle(.compact)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.map { AnyShapeStyle($0.opacity(0.16)) } ?? AnyShapeStyle(.fill.secondary), in: .capsule)
            .overlay(Capsule().strokeBorder(tint?.opacity(0.3) ?? .clear))
    }

    /// 画面下に固定する入力欄など。iOS 26 以降は下に流れる内容を隠して、浮かせた部品を読みやすくする。
    @ViewBuilder
    func bottomBar(@ViewBuilder content: () -> some View) -> some View {
        if #available(iOS 26, macOS 26, *) {
            safeAreaBar(edge: .bottom, content: content).scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, content: content)
        }
    }

    /// iOS 26 以降は Liquid Glass、それより前は半透明の素材で浮かせる。
    @ViewBuilder
    func glassBackground(in shape: some Shape) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape).shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        }
    }

    /// 初回の読み込み中・失敗は一覧に重ねて出し、表示後の失敗はアラートで出す。
    func loadState(isLoaded: Bool, error: Binding<String?>) -> some View {
        overlay {
            if !isLoaded {
                if let message = error.wrappedValue {
                    ContentUnavailableView("読み込めませんでした", systemImage: "exclamationmark.triangle", description: Text(message))
                } else {
                    ProgressView()
                }
            }
        }
        .alert(
            "エラー",
            isPresented: Binding(get: { isLoaded && error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }),
            actions: {},
            message: { Text(error.wrappedValue ?? "") }
        )
    }
}

extension Error {
    /// 画面を離れたときの取り消しは表示しない。
    var displayMessage: String? {
        if self is CancellationError || (self as? URLError)?.code == .cancelled { return nil }
        return localizedDescription
    }
}

extension Color {
    /// `#RRGGBB`（ステータス・ラベルの色）。読めなければ灰色。
    init(hex: String) {
        let value = UInt32(hex.trimmingPrefix("#"), radix: 16) ?? 0x9CA3AF
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// `#rrggbb`。色の選択で選んだ色を API の形にする（sRGB の外の色は端に寄せる）。
    var hex: String {
        let color = resolve(in: EnvironmentValues())
        let byte = { (value: Float) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.red), byte(color.green), byte(color.blue))
    }

    /// 名前から決まる色。`hashValue` は起動ごとに変わるので FNV-1a で選ぶ（文字コードの和は似た名前が同じ色に寄る）。
    init(seed: String) {
        // 薄く敷いた地の上で頭文字が読める、色相の離れた色
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .green]
        let hash = seed.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        self = palette[Int(hash % UInt32(palette.count))]
    }
}

/// 説明・コメントの Markdown。Web と同じく GFM で読み、1 つの改行もそのまま改行にする（remark-breaks と同じ）。
/// `KEY-N` はタスクへのリンク、`<@利用者ID>` は `@名前` にする（`renderReferences`）。リンクは `taskReferenceLinks` で開く。
struct MarkdownText: View {
    let text: String
    var mentions: [String: MentionedUser] = [:]

    var body: some View {
        // 選択可能にすると iOS では本文中のリンクのタップが選択の操作に取られ、KEY-N を開けない
        Markdown(renderReferences(text, mentions: mentions))
            .markdownTheme(.koyori)
            .markdownSoftBreakMode(.lineBreak)
    }
}

extension Theme {
    /// GitHub の配色（引用の線・コードの背景・表の罫線がライトとダークの両方で見える）のまま、
    /// 白い背景と固定の文字サイズを外して行になじませ、文字サイズの設定に従わせる。
    static var koyori: Theme {
        Theme.gitHub
            .text { ForegroundColor(.primary) }
            // 既定の完了済みは薄い灰色で押せないように見えるので、アクセント色にする
            .taskListMarker { configuration in
                Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isCompleted ? Color.accentColor : Color.secondary)
                    .imageScale(.small)
                    .frame(minWidth: 24, alignment: .trailing)
            }
    }
}

// MARK: - 本文中の KEY-N とメンション

/// Web の remark-kfm-task-ref と同じ規則。JS の `\w` は ASCII だけなので、ICU の `\w`（日本語も含む）は使わない
private let taskKeyPattern = try! NSRegularExpression(
    pattern: "(?<![A-Za-z0-9_/-])([A-Z][A-Z0-9]{1,9})-([0-9]+)(?![A-Za-z0-9_-])")

/// 本文の `KEY-N` を `[KEY-N](koyori://task/KEY/KEY-N)` に、`<@利用者ID>` を `@名前` に置き換える。
/// コードブロック・インラインコード・既存のリンク（`[..](..)`・`<url>`・生 URL）の内側は変えない。
/// shortcut: インデントのコードブロック（4 字下げ）はコードとして扱わない。使われるようなら行頭の字下げも見る
func renderReferences(_ markdown: String, mentions: [String: MentionedUser] = [:]) -> String {
    var result: [String] = []
    var prose: [Substring] = []
    var fence: (char: Character, count: Int)?
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        let rest = line.drop { $0 == " " }
        let run = rest.prefix { $0 == rest.first && ($0 == "`" || $0 == "~") }
        if let open = fence {
            result.append(String(line))
            if run.first == open.char, run.count >= open.count, rest.dropFirst(run.count).allSatisfy(\.isWhitespace) { fence = nil }
        } else if line.count - rest.count <= 3, run.count >= 3 {
            if !prose.isEmpty { result.append(renderInline(prose.joined(separator: "\n"), mentions)) }
            prose = []
            fence = (run.first!, run.count)
            result.append(String(line))
        } else {
            prose.append(line)
        }
    }
    if !prose.isEmpty { result.append(renderInline(prose.joined(separator: "\n"), mentions)) }
    return result.joined(separator: "\n")
}

private func renderInline(_ text: String, _ mentions: [String: MentionedUser]) -> String {
    let chars = Array(text)
    var out = "", plain = "", i = 0
    func flushPlain() {
        let range = NSRange(plain.startIndex..., in: plain)
        out += taskKeyPattern.stringByReplacingMatches(in: plain, range: range, withTemplate: "[$0](koyori://task/$1/$0)")
        plain = ""
    }
    /// `i` から `end` の手前までを変えずに出す
    func keep(until end: Int) {
        flushPlain()
        out += String(chars[i..<end])
        i = end
    }
    /// `from` から始まる `open` に対応する `close` の位置（入れ子とエスケープを数える）
    func closing(_ open: Character, _ close: Character, from: Int) -> Int? {
        var depth = 0, j = from
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == open { depth += 1 } else if chars[j] == close { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }
    func backticks(at j: Int) -> Int { chars[j...].prefix { $0 == "`" }.count }
    func startsURL(at j: Int) -> Bool {
        guard j == 0 || !(chars[j - 1].isLetter || chars[j - 1].isNumber) else { return false }
        let head = String(chars[j..<min(j + 8, chars.count)]).lowercased()
        return head.hasPrefix("http://") || head.hasPrefix("https://") || head.hasPrefix("www.")
    }

    while i < chars.count {
        let c = chars[i]
        if c == "\\", i + 1 < chars.count {
            keep(until: i + 2)
        } else if c == "`" {
            // 同じ長さの ` の並びで閉じる。閉じなければただの文字
            let count = backticks(at: i)
            var j = i + count, end: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    let n = backticks(at: j)
                    if n == count { end = j + n; break }
                    j += n
                } else {
                    j += 1
                }
            }
            if let end { keep(until: end) } else { plain += String(repeating: "`", count: count); i += count }
        } else if c == "<", let (end, label) = mention(chars, at: i, mentions) {
            flushPlain()
            out += label
            i = end
        } else if c == "<", let end = chars[(i + 1)...].firstIndex(where: { $0 == ">" || $0 == "<" || $0.isWhitespace }),
            chars[end] == ">", end > i + 1
        {
            keep(until: end + 1)
        } else if c == "[", let close = closing("[", "]", from: i), close + 1 < chars.count,
            let end = chars[close + 1] == "(" ? closing("(", ")", from: close + 1)
                : chars[close + 1] == "[" ? closing("[", "]", from: close + 1)
                : chars[close + 1] == ":" && (i == 0 || chars[i - 1] == "\n") ? (chars[close...].firstIndex(of: "\n") ?? chars.count) - 1
                : nil
        {
            keep(until: end + 1)
        } else if startsURL(at: i) {
            keep(until: chars[i...].firstIndex { $0.isWhitespace || $0 == "<" } ?? chars.count)
        } else {
            plain.append(c)
            i += 1
        }
    }
    flushPlain()
    return out
}

/// `<@xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx>` なら（次の位置, 表示）。backend の `payload::mentions` と同じく、ハイフン付きの UUID だけを印とする。
private func mention(_ chars: [Character], at i: Int, _ mentions: [String: MentionedUser]) -> (Int, String)? {
    guard i + 38 < chars.count, chars[i + 1] == "@", chars[i + 38] == ">" else { return nil }
    let id = String(chars[(i + 2)..<(i + 38)])
    guard id.enumerated().allSatisfy({ [8, 13, 18, 23].contains($0.offset) == ($0.element == "-") }), UUID(uuidString: id) != nil
    else { return nil }
    // 名前に Markdown の記号があっても崩れないようにする
    let escape = { (name: String) in name.map { "\\`*_[]<>~|#".contains($0) ? "\\\($0)" : String($0) }.joined() }
    let label: String
    switch (mentions[id.lowercased()]?.status, mentions[id.lowercased()]?.name) {
    case ("member", let name?): label = "**@\(escape(name))**"
    case ("outside", let name?): label = "@\(escape(name))"
    case ("member", nil), ("outside", nil): label = "@（このプロジェクトの外の利用者）"
    case ("gone", _): label = "@（退会した利用者）"
    // 対応表に無い id も出さない（backend の `to_plain` と同じ）
    default: label = "@（不明な利用者）"
    }
    return (i + 39, label)
}

/// `koyori://task/KEY/REF` の（プロジェクトのキー, タスクの ID かキー）。
func taskReference(from url: URL) -> (key: String, ref: String)? {
    guard url.scheme == "koyori", url.host() == "task" else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    return parts.count == 2 ? (parts[0], parts[1]) : nil
}

/// 開くタスク。`ref` は UUID の文字列か `KEY-N`。
struct TaskTarget: Hashable {
    let project: Project
    let ref: String
}

extension View {
    /// 本文の `KEY-N` のリンクを受け、同じテナントのそのキーのプロジェクトのタスクを開く。プロジェクトが見つからなければ何もしない。
    func taskReferenceLinks(tenantId: UUID) -> some View {
        modifier(TaskReferenceLinks(tenantId: tenantId))
    }
}

private struct TaskReferenceLinks: ViewModifier {
    let tenantId: UUID
    @Environment(AppSession.self) private var session
    @State private var target: TaskTarget?

    func body(content: Content) -> some View {
        content
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard let (key, ref) = taskReference(from: url) else { return .systemAction }
                    Task {
                        if let project = try? await session.api.projects(tenantId: tenantId).first(where: { $0.key == key }) {
                            target = TaskTarget(project: project, ref: ref)
                        }
                    }
                    return .handled
                }
            )
            .navigationDestination(item: $target) { TaskLoaderView(project: $0.project, taskRef: $0.ref) }
    }
}
