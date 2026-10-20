import Foundation

struct APIError: LocalizedError, Sendable {
    let status: Int
    /// API 共通のエラー応答ボディの `message`（例: `internal-error`）。
    let message: String?

    var errorDescription: String? { "\(message ?? "エラー")（HTTP \(status)）" }
}

private struct ErrorBody: Decodable {
    let message: String
}

/// `{origin}/api/v1/...` を Device Token（Bearer）で呼ぶ。
struct APIClient: Sendable {
    let origin: URL
    var token: String?
    /// トークンを付けた要求が 401 になったとき呼ぶ（失効・取り消し）。
    var onUnauthorized: @Sendable () -> Void = {}

    func request<T: Decodable>(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: (any Encodable)? = nil
    ) async throws -> T {
        try Self.decoder().decode(T.self, from: await send(path, method: method, query: query, body: body))
    }

    @discardableResult
    func send(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: (any Encodable)? = nil
    ) async throws -> Data {
        var url = origin.appending(path: "api").appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            req.httpBody = try encoder.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401, token != nil { onUnauthorized() }
            throw APIError(status: status, message: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message)
        }
        return data
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // backend（chrono）は小数秒つきの RFC 3339 を返すので、標準の .iso8601 では読めない
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "日時の形式が不正です: \(text)")
        }
        return decoder
    }
}

// 使っている API の一覧。パスは koyori-app/task の openapi.json と同じ。
extension APIClient {
    func tenants() async throws -> [Tenant] {
        try await request("v1/tenants")
    }

    func projects(tenantId: UUID) async throws -> [Project] {
        try await request("v1/tenants/\(tenantId)/projects")
    }

    /// テナントのオーナーだけが作れる。テナント自体の作成はセッション専用で、Device Token では作れない。
    func createProject(tenantId: UUID, _ body: CreateProjectRequest) async throws -> Project {
        try await request("v1/tenants/\(tenantId)/projects", method: "POST", body: body)
    }

    /// ログインしている本人。更新（`PATCH`）はセッション専用で、Device Token では 401 になる（= ログアウトされる）ので呼ばない。
    func me() async throws -> Account {
        try await request("v1/auth/me")
    }

    func statuses(_ project: Project) async throws -> [TaskStatus] {
        try await request("\(project.path)/statuses")
    }

    func labels(_ project: Project) async throws -> [TaskLabel] {
        try await request("\(project.path)/labels")
    }

    func createLabel(_ project: Project, _ body: LabelRequest) async throws -> TaskLabel {
        try await request("\(project.path)/labels", method: "POST", body: body)
    }

    func updateLabel(_ project: Project, id: UUID, _ body: LabelRequest) async throws -> TaskLabel {
        try await request("\(project.path)/labels/\(id)", method: "PUT", body: body)
    }

    /// 付いているタスクからも外れる。
    func deleteLabel(_ project: Project, id: UUID) async throws {
        try await send("\(project.path)/labels/\(id)", method: "DELETE")
    }

    /// 担当者にできる人。Web の作成画面と同じ候補。
    func assignableUsers(_ project: Project) async throws -> [UserSummary] {
        try await request("\(project.path)/assignable-users")
    }

    func milestones(_ project: Project) async throws -> [Milestone] {
        try await request("\(project.path)/milestones")
    }

    func sprints(_ project: Project) async throws -> [Sprint] {
        try await request("\(project.path)/sprints")
    }

    func customFields(_ project: Project) async throws -> [CustomField] {
        let list: CustomFieldList = try await request("\(project.path)/custom-fields")
        return list.fields.sorted { $0.position < $1.position }
    }

    func searchTasks(_ project: Project, query: String) async throws -> [TaskReference] {
        let response: SearchTasksResponse = try await request(
            "\(project.path)/tasks/search", query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "30")])
        return response.tasks
    }

    /// 他の利用者のプロフィール（同じテナントの人だけ）。
    func userProfile(tenantId: UUID, userId: UUID) async throws -> UserProfile {
        try await request("v1/tenants/\(tenantId)/users/\(userId)")
    }

    /// `from`〜`to`（`YYYY-MM-DD`、両端含む）に重なるタスク・スプリント・マイルストーン。`next_cursor` を辿って全件読む。
    func schedule(tenantId: UUID, from: String, to: String, timezone: String) async throws -> Schedule {
        func page(_ cursor: String?) async throws -> Schedule {
            var query = [
                URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to),
                URLQueryItem(name: "timezone", value: timezone), URLQueryItem(name: "include_done", value: "true"),
                URLQueryItem(name: "limit", value: "500"),
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            return try await request("v1/tenants/\(tenantId)/schedule", query: query)
        }
        var schedule = try await page(nil)
        var cursor = schedule.nextCursor
        while let next = cursor {
            let more = try await page(next)
            let known = Set(schedule.members.map(\.id))
            schedule.tasks += more.tasks
            schedule.members += more.members.filter { !known.contains($0.id) }
            cursor = more.nextCursor
        }
        return schedule
    }

    func members(_ project: Project) async throws -> [ProjectMember] {
        try await request("\(project.path)/members")
    }

    /// 続きの `cursor` は同じ絞り込み・`sort` と一緒に送る。`rootOnly` は「親がこの一覧に無いタスクだけ」（Web の一覧と同じ）。
    func tasks(
        _ project: Project, cursor: String?, statusId: UUID?, assigneeId: UUID?, createdBy: UUID? = nil, sort: TaskSort,
        rootOnly: Bool
    ) async throws -> TaskPage {
        var query = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "sort", value: sort.rawValue)]
        if rootOnly { query.append(URLQueryItem(name: "root_only", value: "true")) }
        if let statusId { query.append(URLQueryItem(name: "status_id", value: statusId.uuidString)) }
        if let assigneeId { query.append(URLQueryItem(name: "assignee_id", value: assigneeId.uuidString)) }
        if let createdBy { query.append(URLQueryItem(name: "created_by", value: createdBy.uuidString)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request("\(project.path)/tasks", query: query)
    }

    func task(_ project: Project, id: UUID) async throws -> TaskItem {
        try await task(project, ref: id.uuidString)
    }

    /// `ref` は UUID のほか `ENG-42` 形式のキーも受ける（backend の `resolve_task`）。
    func task(_ project: Project, ref: String) async throws -> TaskItem {
        try await request("\(project.path)/tasks/\(ref)")
    }

    func relations(_ project: Project, taskId: UUID) async throws -> TaskRelations {
        try await request("\(project.path)/tasks/\(taskId)/relations")
    }

    func createTask(_ project: Project, _ body: CreateTaskRequest) async throws -> TaskItem {
        try await request("\(project.path)/tasks", method: "POST", body: body)
    }

    func updateTask(_ project: Project, id: UUID, _ body: UpdateTaskRequest) async throws -> TaskItem {
        try await request("\(project.path)/tasks/\(id)", method: "PUT", body: body)
    }

    func comments(_ project: Project, taskId: UUID) async throws -> CommentList {
        try await request("\(project.path)/tasks/\(taskId)/comments")
    }

    func forge(_ project: Project, taskId: UUID) async throws -> TaskForge {
        try await request("\(project.path)/tasks/\(taskId)/forge")
    }

    /// リポジトリはプロジェクトの連携先で決まる。
    func linkPullRequest(_ project: Project, taskId: UUID, number: Int, closes: Bool) async throws -> TaskForge.PullRequest {
        try await request(
            "\(project.path)/tasks/\(taskId)/forge/pull-requests", method: "POST",
            body: LinkPullRequestRequest(number: number, closes: closes))
    }

    func unlinkPullRequest(_ project: Project, taskId: UUID, pullRequestId: UUID) async throws {
        try await send("\(project.path)/tasks/\(taskId)/forge/pull-requests/\(pullRequestId)", method: "DELETE")
    }

    func postComment(_ project: Project, taskId: UUID, body: String) async throws {
        try await send("\(project.path)/tasks/\(taskId)/comments", method: "POST", body: CreateCommentRequest(body: body))
    }

    func notifications(kind: String?, unreadOnly: Bool, cursor: String?, limit: Int = 50) async throws -> NotificationPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
        if unreadOnly { query.append(URLQueryItem(name: "unread", value: "true")) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request("v1/users/me/notifications", query: query)
    }

    func markNotificationRead(id: UUID) async throws -> AppNotification {
        try await request("v1/users/me/notifications/\(id)/read", method: "PATCH")
    }

    func markAllNotificationsRead() async throws {
        try await send("v1/users/me/notifications/read-all", method: "PATCH")
    }

    func reviewedPullRequests(_ project: Project) async throws -> [ReviewedPullRequest] {
        try await request("\(project.path)/reviews/pull-requests")
    }

    func reviewSummary(_ project: Project, pr: Int) async throws -> ReviewSummary {
        try await request("\(project.path)/reviews/summary", query: [URLQueryItem(name: "pr", value: String(pr))])
    }

    func reviewRounds(_ project: Project, pr: Int) async throws -> [ReviewRound] {
        try await request("\(project.path)/reviews", query: [URLQueryItem(name: "pr", value: String(pr))])
    }

    func reviewRound(_ project: Project, id: UUID) async throws -> ReviewRoundDetail {
        try await request("\(project.path)/reviews/\(id)")
    }

    func reviewFindings(_ project: Project, pr: Int) async throws -> [ReviewFinding] {
        try await request("\(project.path)/review-findings", query: [URLQueryItem(name: "pr", value: String(pr))])
    }

    func updateFinding(_ project: Project, id: UUID, state: String, note: String?) async throws -> ReviewFinding {
        try await request(
            "\(project.path)/review-findings/\(id)", method: "PATCH", body: UpdateFindingStateRequest(state: state, note: note))
    }

    func exchangeDesktopCode(code: String, codeVerifier: String) async throws -> DesktopAuthTokenResponse {
        try await request(
            "v1/desktop/auth/token", method: "POST",
            body: DesktopAuthTokenRequest(code: code, codeVerifier: codeVerifier))
    }

    func revokeDevice(id: UUID) async throws {
        try await send("v1/users/me/devices/\(id)", method: "DELETE")
    }
}

private extension Project {
    var path: String { "v1/tenants/\(tenantId)/projects/\(id)" }
}
