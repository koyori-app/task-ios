import Foundation

// koyori-app/task の apps/frontend/openapi.json に合わせた DTO。使う項目だけを持つ。

struct Tenant: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let displayId: String
    let name: String
    let iconEmoji: String?
    /// 自分から見た関わり方（`Owner` / `Member` / `Guest`）。プロジェクトを作れるのはオーナーだけ
    let membership: String?
}

struct Project: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let tenantId: UUID
    let key: String
    let name: String
    let iconEmoji: String?
}

struct TaskStatus: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let color: String
    let position: Int
    let isDefault: Bool
    let isDoneState: Bool
}

enum TaskPriority: String, CaseIterable, Codable, Sendable {
    case criticalFire = "CriticalFire"
    case critical = "Critical"
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    case trivial = "Trivial"

    /// Web の `PRIORITY_CONFIG`（apps/frontend/src/lib/task-display.ts）と同じ表記。
    var label: String {
        switch self {
        case .criticalFire: "緊急"
        case .critical: "重大"
        case .high: "高"
        case .medium: "中"
        case .low: "低"
        case .trivial: "些細"
        }
    }
}

/// タスク一覧の `sort`。値と意味は backend の一覧 API と同じ（`priority_asc` は緊急が先）。
enum TaskSort: String, CaseIterable, Sendable {
    case createdAtDesc = "created_at_desc"
    case priorityAsc = "priority_asc"
    case deadlineAsc = "deadline_asc"

    var label: String {
        switch self {
        case .createdAtDesc: "新しい順"
        case .priorityAsc: "優先度が高い順"
        case .deadlineAsc: "期限が近い順"
        }
    }
}

struct UserSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let username: String
    /// https の画像（プロフィールで https 以外は受け付けない）。未設定なら頭文字で描く
    let avatarUrl: String?
}

/// `UserResponse`（`GET /v1/auth/me`）のうち画面で使う項目。
struct Account: Decodable, Equatable, Sendable {
    let id: UUID
    let username: String
    let email: String?
    let bio: String?
    let avatarUrl: String?
}

/// `ProjectMemberResponse`。担当者で絞り込む候補に使う。
struct ProjectMember: Decodable, Sendable {
    let user: UserSummary
}

struct TaskAssignee: Decodable, Hashable, Sendable {
    let role: String
    let user: UserSummary
}

struct TaskLabel: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let color: String
    /// 未入力なら空文字
    let description: String
}

/// ラベルの作成（`POST`）と更新（`PUT`）。更新でも 3 つとも送る。
struct LabelRequest: Encodable, Equatable, Sendable {
    let name: String
    let color: String
    let description: String

    /// Web と同じく、名前と説明は前後の空白を除いて送る
    init(name: String, color: String, description: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.color = color
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// backend と同じく名前は 1〜100 文字。validator crate に合わせてコードポイント単位で数える
    var isValid: Bool { (1...100).contains(name.unicodeScalars.count) }
}

/// `TaskResponse` / `TaskDetailResponse`。Swift の `Task` と衝突するので `TaskItem` と呼ぶ。
struct TaskItem: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let seqId: Int
    let title: String
    let description: String?
    let statusId: UUID
    /// 未知の値が増えても一覧ごと読めなくならないよう文字列のまま持つ。
    let priority: String
    let assignees: [TaskAssignee]
    let labels: [TaskLabel]
    let softDeadline: Date?
    let hardDeadline: Date?
    /// 利用者の行が消えていると nil
    let createdBy: UserSummary?
    let createdAt: Date
    let updatedAt: Date
    let parentTaskId: UUID?
    /// 開始予定日（`YYYY-MM-DD`）。締切との前後はサーバーが検証しない
    let plannedStartOn: String?
    /// 説明の `<@利用者ID>` から引ける表示情報（詳細の応答だけが持つ）。キーは UUID の文字列
    let mentions: [String: MentionedUser]?

    var priorityLabel: String { TaskPriority(rawValue: priority)?.label ?? priority }
}

/// `TaskRelationsResponse` のうち親子だけ（ブロック関係は使っていない）。
struct TaskRelations: Decodable, Sendable {
    let parent: TaskItem?
    var subtasks: [TaskItem]
}

struct TaskPage: Decodable, Sendable {
    let tasks: [TaskItem]
    let total: Int
    let nextCursor: String?
}

struct CommentUser: Decodable, Hashable, Sendable {
    let id: UUID
    let name: String
    let avatarUrl: String?
}

struct CommentReply: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let body: String?
    let user: CommentUser
    let createdAt: Date
    let isDeleted: Bool
}

struct CommentThread: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let body: String?
    let user: CommentUser
    let replies: [CommentReply]
    let createdAt: Date
    let isDeleted: Bool
}

struct CommentList: Decodable {
    let comments: [CommentThread]
    /// 全コメントの本文の `<@利用者ID>` から引ける表示情報
    let mentions: [String: MentionedUser]?
}

/// `MentionedUser`。`status` は `member` / `outside` / `gone`。
struct MentionedUser: Decodable, Hashable, Sendable {
    let status: String
    let name: String?
    let avatarUrl: String?
}

/// `UserProfileResponse`（`GET /v1/tenants/{t}/users/{u}`）。他人に見せる項目だけ。
struct UserProfile: Decodable, Sendable {
    let id: UUID
    let username: String
    let bio: String?
    let avatarUrl: String?
}

/// nil の項目は送らない。キーを省くと backend が名前から作る（重複したら末尾に番号を付ける）。
struct CreateProjectRequest: Encodable, Sendable {
    var name: String
    var key: String?
    var description: String?
    var iconEmoji: String?
}

/// nil の項目は送らない。組み立ては `TaskDraft.request(fields:calendar:)`。
struct CreateTaskRequest: Encodable, Sendable {
    var title: String
    var statusId: UUID
    var description: String?
    var priority: TaskPriority?
    var assignees: [AssigneeInput]?
    var labelIds: [UUID]?
    /// `YYYY-MM-DDT00:00:00.000Z`。日付だけを選ぶので、Web と同じく暦日のまま UTC の 0 時で送る
    var softDeadline: String?
    var hardDeadline: String?
    /// `YYYY-MM-DD`
    var plannedStartOn: String?
    var estimatedMinutes: Int32?
    var progressPct: Int?
    var milestoneId: UUID?
    var sprintId: UUID?
    var parentTaskId: UUID?
    var customFieldValues: [CustomFieldValueInput]?
}

struct AssigneeInput: Encodable, Hashable, Sendable {
    let userId: UUID
    /// Web の作成画面・詳細画面と同じ役割（役割を使い分ける画面はまだない）
    var role = "primary"
}

struct CustomFieldValueInput: Encodable, Hashable, Sendable {
    let fieldId: UUID
    let value: String
}

struct Milestone: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let projectId: UUID
    let name: String
    /// `YYYY-MM-DD`
    let dueDate: String
}

struct Sprint: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    /// `planning` / `active` / `completed`。完了したスプリントにはタスクを足せない
    let status: String
    let projectId: UUID
    /// `YYYY-MM-DD`
    let startDate: String
    let endDate: String
}

/// `ProjectCustomFieldResponse`。
struct CustomField: Decodable, Identifiable, Hashable, Sendable {
    struct Option: Decodable, Hashable, Sendable {
        let label: String
        let value: String
    }

    let id: UUID
    let name: String
    /// `text` / `number` / `select` / `date` / `url` / `checkbox`。未知の種類でも一覧ごと読めなくならないよう文字列で持つ
    let fieldType: String
    let isRequired: Bool
    let position: Int
    let options: [Option]

    enum CodingKeys: String, CodingKey {
        case id, name, fieldType, isRequired, position, options
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fieldType = try container.decode(String.self, forKey: .fieldType)
        isRequired = try container.decode(Bool.self, forKey: .isRequired)
        position = try container.decode(Int.self, forKey: .position)
        // options は選択式でだけ `[{label, value}]`。型の決まっていない JSON なので、読めなければ空にする
        options = (try? container.decode([Option].self, forKey: .options)) ?? []
    }
}

struct CustomFieldList: Decodable {
    let fields: [CustomField]
}

/// 親タスクの候補。検索結果（`SearchTaskHit`）と一覧の両方から作る。
struct TaskReference: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let seqId: Int
    let title: String
}

struct SearchTasksResponse: Decodable {
    let tasks: [TaskReference]
}

/// nil の項目は送らない（= 変更しない）。説明を消すときは `clearDescription`。
struct UpdateTaskRequest: Encodable, Sendable {
    var title: String?
    var description: String?
    var clearDescription: Bool?
    var statusId: UUID?
    var priority: TaskPriority?
    /// 付け外しの差分。`label_ids`（全置換）だと、同時に他の人が付けたラベルを消してしまう
    var addLabelIds: [UUID]?
    var removeLabelIds: [UUID]?
}

struct CreateCommentRequest: Encodable, Sendable {
    let body: String
}

struct DesktopAuthTokenRequest: Encodable, Sendable {
    let code: String
    let codeVerifier: String
}

struct DesktopAuthTokenResponse: Decodable, Sendable {
    let token: String
    let deviceId: UUID
}

// MARK: - 通知

/// `NotificationItem`。テナント・プロジェクトをまたいだ自分宛ての通知。
struct AppNotification: Decodable, Identifiable, Hashable, Sendable {
    struct ProjectSummary: Decodable, Hashable, Sendable {
        let id: UUID
        let tenantId: UUID
        let key: String
    }

    struct TaskSummary: Decodable, Hashable, Sendable {
        let id: UUID
        let seqId: Int
        let title: String
    }

    let id: UUID
    /// `assigned` / `mentioned` / `comment_added` / `status_changed` / `deadline_soon` / `pr_merged` /
    /// `review_round_created` / `review_finding_changed`（backend の `common::notifications`）
    let notificationType: String
    let payload: NotificationPayload
    let createdAt: Date
    let readAt: Date?
    let project: ProjectSummary?
    let task: TaskSummary?

    enum CodingKeys: String, CodingKey {
        case id, notificationType, payload, createdAt, readAt, project, task
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        notificationType = try container.decode(String.self, forKey: .notificationType)
        // payload は種別ごとに形の違う JSON。読めない項目があっても通知ごと落とさない
        payload = (try? container.decode(NotificationPayload.self, forKey: .payload)) ?? NotificationPayload()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        readAt = try container.decodeIfPresent(Date.self, forKey: .readAt)
        project = try container.decodeIfPresent(ProjectSummary.self, forKey: .project)
        task = try container.decodeIfPresent(TaskSummary.self, forKey: .task)
    }
}

/// 通知の種別ごとの中身。画面で使う項目だけを持ち、無いものは nil。
struct NotificationPayload: Decodable, Hashable, Sendable {
    var assignedBy: String?
    var author: String?
    var from: String?
    var to: String?
    var changedBy: String?
    var reviewId: UUID?
    var repo: String?
    var prNumber: Int?
    var round: Int?
    var reviewer: String?
    var title: String?
    var actor: String?
    var note: String?
    var counts: [String: Int]?
}

struct NotificationPage: Decodable, Sendable {
    let notifications: [AppNotification]
    /// 絞り込みに関係なく、見える通知全体の未読数
    let unreadCount: Int
    let nextCursor: String?
}

// MARK: - レビュー

/// `ReviewedPullRequest`。マージの可否はここからは決められない（鮮度と連携の有無が要る）ので持たない。
struct ReviewedPullRequest: Decodable, Identifiable, Hashable, Sendable {
    let prNumber: Int
    let prTitle: String?
    let prAuthor: String?
    let rounds: Int
    /// 未解決（open / fixing / fixed）の指摘数
    let unresolved: Int
    /// マージを塞いでいる指摘数（High / Medium かつ未解決）
    let blocking: Int
    /// `blocking` のうち fixed（レビュー側の確認待ち）の数
    let blockingFixed: Int
    let lastReviewedAt: Date
    /// `open` / `closed` / `merged` / `unknown`
    let state: String?
    let pullRequestId: UUID?
    /// 仕様（9.github-tasks.md §8）にはあるが、まだ返さないサーバーもあるので無ければ空として扱う
    let linkedTasks: [LinkedTask]?

    var id: Int { prNumber }
}

struct LinkedTask: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let seqId: Int
    /// プロジェクトのキー
    let key: String
    let title: String
}

// MARK: - リポジトリ（forge）

/// `TaskForgeResponse`。URL はサーバーが返す `html_url` をそのまま使い、組み立てない。
struct TaskForge: Decodable, Sendable {
    struct PullRequest: Decodable, Identifiable, Hashable, Sendable {
        let id: UUID
        let number: Int
        let title: String
        /// `open` / `closed` / `merged` / `unknown`
        let state: String
        let htmlUrl: String
        let mergeEffectsProcessedAt: Date?
        /// マージを塞いでいる指摘数。レビューが無ければ nil
        let unresolved: Int?
    }

    struct Commit: Decodable, Identifiable, Hashable, Sendable {
        let id: UUID
        let sha: String
        /// メッセージの先頭行
        let message: String
        let htmlUrl: String
    }

    struct Branch: Decodable, Identifiable, Hashable, Sendable {
        let id: UUID
        let branch: String
        let htmlUrl: String
    }

    struct Repository: Decodable, Hashable, Sendable {
        let repoOwner: String
        let repoName: String
        let htmlUrl: String
    }

    struct Issue: Decodable, Hashable, Sendable {
        let number: Int
        /// `open` / `closed` / `unknown`
        let state: String
        let htmlUrl: String
        let lastSyncedAt: Date?
    }

    var pullRequests: [PullRequest]
    let commits: [Commit]
    let branches: [Branch]
    /// 連携していなければ nil（手動リンクを出さない）
    let repository: Repository?
    let issue: Issue?
}

struct LinkPullRequestRequest: Encodable, Sendable {
    let number: Int
    /// マージしたらこのタスクを完了にする
    let closes: Bool
}

// MARK: - スケジュール

/// `ScheduleResponse`。ページをまたいで `tasks` と `members` を足し合わせる。
struct Schedule: Decodable, Sendable {
    struct Assignee: Decodable, Hashable, Sendable {
        let userId: UUID
        /// `primary` が主担当
        let role: String
    }

    struct ProjectInfo: Decodable, Hashable, Sendable {
        let id: UUID
        let name: String
        let key: String
    }

    struct StatusInfo: Decodable, Hashable, Sendable {
        let isDoneState: Bool
    }

    struct Item: Decodable, Identifiable, Hashable, Sendable {
        let id: UUID
        let seqKey: String
        let title: String
        let project: ProjectInfo
        let status: StatusInfo
        let plannedStartOn: String?
        let softDeadline: Date?
        let hardDeadline: Date?
        let assignees: [Assignee]
    }

    var tasks: [Item]
    let sprints: [Sprint]
    let milestones: [Milestone]
    var members: [UserSummary]
    let nextCursor: String?
}

/// `ReviewResponse`。PR 内の 1 回のレビュー（R1, R2, …）。
struct ReviewRound: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let prNumber: Int
    let prTitle: String?
    let round: Int
    let headSha: String
    let reviewer: UserSummary
    let summary: String
    let createdAt: Date
    let findingCount: Int
}

/// `ReviewDetailResponse`（ラウンドの項目と同じ階層に `findings` が並ぶ）。
struct ReviewRoundDetail: Decodable, Sendable {
    let round: ReviewRound
    let findings: [ReviewFinding]

    enum CodingKeys: String, CodingKey { case findings }

    init(from decoder: any Decoder) throws {
        round = try ReviewRound(from: decoder)
        findings = try decoder.container(keyedBy: CodingKeys.self).decode([ReviewFinding].self, forKey: .findings)
    }
}

/// `FindingResponse`。重大度・状態は未知の値でも読めるよう文字列のまま持つ。
struct ReviewFinding: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let reviewId: UUID
    let prNumber: Int
    let round: Int
    /// `high` / `medium` / `low` / `nit`
    let severity: String
    let title: String
    let body: String
    /// `open` / `fixing` / `fixed` / `verified` / `deferred` / `rejected`
    let state: String
    let file: String?
    let line: Int?
    let createdAt: Date
    let transitions: [FindingTransition]
    /// いま遷移できる状態。遷移・役割の規則は backend だけが持つので、画面はこれだけを見て操作を出す
    let availableActions: [String]
    /// 繰り延べたときに自動で起票された通常タスク
    let deferredTaskId: UUID?
}

struct FindingTransition: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let actor: UserSummary
    /// 起票は nil
    let fromState: String?
    let toState: String
    let note: String?
    let createdAt: Date
}

/// `ReviewSummaryResponse`。マージ判定は `gate` をそのまま使い、画面で再計算しない。
struct ReviewSummary: Decodable, Sendable {
    let prNumber: Int
    let rounds: Int
    let blocking: Int
    /// `unlinked` / `unreviewed` / `blocked` / `stale_unknown` / `outdated` / `ready`
    let gate: String
    let latestHeadSha: String?
    let cachedPrHeadSha: String?
    let prHeadCheckedAt: Date?
    let repository: String?
}

struct UpdateFindingStateRequest: Encodable, Sendable {
    let state: String
    let note: String?
}
