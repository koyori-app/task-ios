import Foundation
import SwiftUI
import Testing
@testable import KoyoriKit

@Test func pkceChallengeMatchesRFC7636AppendixB() {
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    // backend は code_verifier / code_challenge を 43〜128 文字の base64url に限る
    #expect(PKCE.randomString().wholeMatch(of: /[A-Za-z0-9_-]{43}/) != nil)
}

@Test func loopbackCallbackReadsOnlyCallbackWithCodeAndState() throws {
    let callback = try #require(LoopbackCallback(request: Data("GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)))
    #expect(callback.code == "abc" && callback.state == "xyz")
    #expect(LoopbackCallback(request: Data("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8)) == nil)
    #expect(LoopbackCallback(request: Data("GET /callback?code=abc HTTP/1.1\r\n\r\n".utf8)) == nil)
    #expect(LoopbackCallback(request: Data("POST /callback?code=abc&state=xyz HTTP/1.1\r\n\r\n".utf8)) == nil)
}

@Test func loopbackServerReceivesBrowserRedirect() async throws {
    let server = try LoopbackServer()
    defer { server.stop() }
    let (callbacks, continuation) = AsyncStream<LoopbackCallback>.makeStream()
    let port = try await server.start { continuation.yield($0) }
    // Web の承認画面は 1024〜65535 のポートしか受け付けない
    #expect((1024...65535).contains(port))

    let favicon = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
    #expect((favicon.1 as? HTTPURLResponse)?.statusCode == 404)
    let url = URL(string: "http://127.0.0.1:\(port)/callback?code=c1&state=s1")!
    let (_, response) = try await URLSession.shared.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    var iterator = callbacks.makeAsyncIterator()
    let callback = await iterator.next()
    #expect(callback?.code == "c1" && callback?.state == "s1")
}

@Test func decodesTaskPageWithBackendDates() throws {
    let json = """
        {"tasks":[{"id":"7f0e8a52-3c1b-4f5e-9a3d-2b6c1d4e5f60","project_id":"0b8d6c2e-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
        "seq_id":12,"title":"t","description":null,"status_id":"1c2d3e4f-5a6b-4c7d-8e9f-a0b1c2d3e4f5",
        "priority":"High","progress_pct":0,"is_archived":false,
        "assignees":[{"role":"assignee","user":{"id":"2d3e4f5a-6b7c-4d8e-9fa0-b1c2d3e4f5a6","username":"u","avatar_url":null}}],
        "labels":[{"id":"3e4f5a6b-7c8d-4e9f-a0b1-c2d3e4f5a6b7","name":"bug","description":"","color":"#ef4444","icon_url":null}],
        "soft_deadline":"2026-10-14T12:34:56+00:00","hard_deadline":null,
        "created_by":{"id":"2d3e4f5a-6b7c-4d8e-9fa0-b1c2d3e4f5a6","username":"c","avatar_url":null},
        "created_at":"2026-10-14T12:34:56.123456Z","updated_at":"2026-10-14T12:34:56.123456+00:00"}],
        "total":1,"next_cursor":null}
        """
    let task = try #require(try APIClient.decoder().decode(TaskPage.self, from: Data(json.utf8)).tasks.first)
    #expect(task.seqId == 12 && task.priorityLabel == "高" && task.assignees.first?.user.username == "u")
    #expect(task.createdBy?.username == "c" && task.createdAt == task.updatedAt && task.labels.map(\.name) == ["bug"])
    let softDeadline = try #require(task.softDeadline)
    #expect(abs(task.updatedAt.timeIntervalSince(softDeadline) - 0.123456) < 0.001)
}

@Test func updateRequestSendsOnlyChangedFields() throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let statusId = UUID()
    let body = try JSONSerialization.jsonObject(
        with: encoder.encode(UpdateTaskRequest(clearDescription: true, statusId: statusId))) as? [String: Any]
    #expect(body?.keys.sorted() == ["clear_description", "status_id"])
    // ラベルは全置換の label_ids ではなく差分で送る
    let labelId = UUID()
    let labels = try JSONSerialization.jsonObject(
        with: encoder.encode(UpdateTaskRequest(addLabelIds: [labelId]))) as? [String: Any]
    #expect(labels?.keys.sorted() == ["add_label_ids"])
    #expect(labels?["add_label_ids"] as? [String] == [labelId.uuidString])
}

@Test func deadlineTextMatchesWebLabels() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    func date(_ day: Int, _ hour: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)))
    }
    let now = try date(14, 12)
    func text(_ deadline: Date) -> (String, Bool) {
        let result = deadlineText(deadline, now: now, calendar: calendar)
        return (result.text, result.isOverdue)
    }
    // 同じ日は過ぎていても「今日」で、超過かどうかだけ変わる
    #expect(text(try date(14, 9)) == ("今日", true))
    #expect(text(try date(14, 23)) == ("今日", false))
    #expect(text(try date(12, 23)) == ("2日超過", true))
    // 24 時間たっていなくても日付が変われば翌日
    #expect(text(try date(15, 1)) == ("1日後", false))
    #expect(text(try date(21, 12)) == ("7日後", false))
    let later = text(try date(22, 12))
    #expect(!later.0.hasSuffix("日後") && !later.1)
}

@Test func taskDraftValidatesLikeBackendAndSendsOnlyFilledFields() throws {
    let fields = try APIClient.decoder().decode([CustomField].self, from: Data("""
        [{"id":"00000000-0000-0000-0000-000000000001","name":"顧客","field_type":"text","is_required":true,"position":0,"options":null},
         {"id":"00000000-0000-0000-0000-000000000002","name":"承認","field_type":"checkbox","is_required":true,"position":1,"options":{}},
         {"id":"00000000-0000-0000-0000-000000000003","name":"工数","field_type":"number","is_required":false,"position":2},
         {"id":"00000000-0000-0000-0000-000000000004","name":"資料","field_type":"url","is_required":false,"position":3},
         {"id":"00000000-0000-0000-0000-000000000005","name":"種別","field_type":"select","is_required":false,"position":4,
          "options":[{"label":"バグ","value":"bug"}]}]
        """.utf8))
    // 選択式以外の options（null・{}・なし）でも一覧ごと読めなくならない
    #expect(fields.map(\.options.count) == [0, 0, 0, 0, 1])
    let (customer, approval, effort, document) = (fields[0], fields[1], fields[2], fields[3])

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    // JST の 10/15 0:30 は UTC では前日だが、選んだ日付のまま送る
    let oct15 = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, minute: 30)))
    let oct16 = try #require(calendar.date(byAdding: .day, value: 1, to: oct15))

    var draft = TaskDraft(title: "  t  ", statusId: UUID())
    draft.customValues[customer.id] = "A 社"
    #expect(draft.problem(fields: fields, calendar: calendar) == nil)

    draft.softDeadline = oct15
    draft.hardDeadline = oct15
    #expect(draft.problem(fields: fields, calendar: calendar) == "期限は最終期限より前の日にしてください")
    draft.hardDeadline = oct16

    // 開始予定日は期限と同じ日まで。後なら Web と同じく止める
    draft.plannedStartOn = oct15
    #expect(draft.problem(fields: fields, calendar: calendar) == nil)
    draft.plannedStartOn = oct16
    #expect(draft.problem(fields: fields, calendar: calendar) == "開始予定日は期限以前の日付にしてください")
    draft.plannedStartOn = nil

    for bad in ["0", "abc", "2147483648"] {
        draft.estimate = bad
        #expect(draft.problem(fields: fields, calendar: calendar)?.hasPrefix("見積もり") == true, "\(bad)")
    }
    draft.estimate = "90"

    draft.customValues[customer.id] = " "
    #expect(draft.problem(fields: fields, calendar: calendar) == "「顧客」を入力してください")
    draft.customValues[customer.id] = "A 社"
    draft.customValues[effort.id] = "1e400"
    #expect(draft.problem(fields: fields, calendar: calendar) == "「工数」は数値で入力してください")
    draft.customValues[effort.id] = "1.5"
    for bad in ["ftp://example.com", "https://"] {
        draft.customValues[document.id] = bad
        #expect(draft.problem(fields: fields, calendar: calendar)?.hasPrefix("「資料」") == true, "\(bad)")
    }
    draft.customValues[document.id] = ""

    let request = try #require(draft.request(fields: fields, calendar: calendar))
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let body = try #require(try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
    #expect(body["title"] as? String == "t")
    #expect(body["soft_deadline"] as? String == "2026-10-15T00:00:00.000Z")
    #expect(body["hard_deadline"] as? String == "2026-10-16T00:00:00.000Z")
    #expect(body["estimated_minutes"] as? Int == 90)
    // 空の担当者・ラベル、0% の進捗、未設定の項目は送らない
    #expect(body.keys.sorted() == [
        "custom_field_values", "estimated_minutes", "hard_deadline", "priority", "soft_deadline", "status_id", "title",
    ])
    let values = try #require(body["custom_field_values"] as? [[String: String]])
    // 触っていない必須のチェックボックスは false として送る
    #expect(values == [
        ["field_id": customer.id.uuidString, "value": "A 社"],
        ["field_id": approval.id.uuidString, "value": "false"],
        ["field_id": effort.id.uuidString, "value": "1.5"],
    ])
}

@Test func notificationMessagesByType() throws {
    func decode(_ type: String, _ payload: String) throws -> AppNotification {
        try APIClient.decoder().decode(AppNotification.self, from: Data("""
            {"id":"00000000-0000-0000-0000-000000000001","notification_type":"\(type)","payload":\(payload),
             "cursor":"c","created_at":"2026-10-14T12:34:56.123456Z","read_at":null,
             "project":{"id":"00000000-0000-0000-0000-000000000002","tenant_id":"00000000-0000-0000-0000-000000000003","key":"IOS"},
             "task":{"id":"00000000-0000-0000-0000-000000000004","seq_id":42,"title":"t"}}
            """.utf8))
    }
    let status = try decode("status_changed", #"{"from":"未着手","to":"完了","changed_by":"yupix"}"#)
    #expect(status.message == "yupix さんがステータスを「未着手」から「完了」に変えました")
    #expect(status.subject == "IOS-42 t" && !status.isReview && status.readAt == nil)

    let round = try decode(
        "review_round_created",
        #"{"review_id":"00000000-0000-0000-0000-000000000005","repo":"koyori-app/task","pr_number":7,"round":2,"reviewer":"sakura","counts":{"high":1,"medium":0,"low":2,"nit":0}}"#)
    #expect(round.message == "sakura さんが R2 のレビューを出しました（High 1 / Low 2）")
    #expect(round.isReview && round.payload.reviewId != nil)

    let finding = try decode("review_finding_changed", #"{"title":"null を返す","from":"open","to":"fixed","actor":"kenta"}"#)
    #expect(finding.message == "kenta さんが指摘「null を返す」を Open → Fixed にしました")

    // 知らない種別・形の違う payload でも通知ごと落とさない
    let unknown = try decode("something_new", #"{"round":"二"}"#)
    #expect(unknown.message == "something_new" && unknown.payload.round == nil)
}

@Test func notificationSectionsByDay() throws {
    func item(_ id: Int, _ createdAt: String) throws -> AppNotification {
        try APIClient.decoder().decode(AppNotification.self, from: Data("""
            {"id":"00000000-0000-0000-0000-\(String(format: "%012d", id))","notification_type":"assigned","payload":{},
             "cursor":"c","created_at":"\(createdAt)","read_at":null,"project":null,"task":null}
            """.utf8))
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-20T09:00:00+09:00"))
    // 日付の境目は端末のタイムゾーンで数える（UTC では前日の 2026-10-19T15:00Z が JST の今日の 0 時）
    let items = try [
        item(1, "2026-10-19T15:00:00Z"), item(2, "2026-10-19T14:59:59Z"), item(3, "2026-10-14T00:00:00+09:00"),
        item(4, "2026-10-13T23:59:59+09:00"),
    ]
    let sections = notificationSections(items, now: now, calendar: calendar)
    #expect(sections.map(\.title) == ["今日", "昨日", "この 7 日間", "それ以前"])
    #expect(sections.map(\.items.count) == [1, 1, 1, 1])
    // 空の区切りは出さない
    #expect(notificationSections([items[0], items[3]], now: now, calendar: calendar).map(\.title) == ["今日", "それ以前"])
}

@Test func reviewVerdictAndActionsMatchWeb() throws {
    func summary(_ gate: String, blocking: Int = 0, latest: String? = "abcdef1234", cached: String? = nil) throws -> ReviewSummary {
        let fields = [
            #""pr_number":7"#, #""rounds":2"#, "\"blocking\":\(blocking)", "\"gate\":\"\(gate)\"",
            latest.map { "\"latest_head_sha\":\"\($0)\"" }, cached.map { "\"cached_pr_head_sha\":\"\($0)\"" },
        ].compactMap { $0 }.joined(separator: ",")
        return try APIClient.decoder().decode(ReviewSummary.self, from: Data("{\(fields)}".utf8))
    }
    let blocked = mergeVerdict(try summary("blocked", blocking: 3))
    #expect(blocked.title == "マージ不可（3 件）" && blocked.tone == .bad)
    #expect(blocked.detail == "High / Medium が未解決です。Low / Nit は繰り延べできます · 最新ラウンドは abcdef1 を見ています")
    #expect(mergeVerdict(try summary("outdated", cached: "9876543210")).detail.hasPrefix("レビュー後にコミットが積まれています（現在 9876543）"))
    #expect(mergeVerdict(try summary("unreviewed", latest: nil)).tone == .neutral)
    #expect(mergeVerdict(try summary("ready")).tone == .good)

    #expect(findingActionLabel(to: "open", from: "fixed") == "レビューに戻す")
    #expect(findingActionLabel(to: "open", from: "fixing") == "着手を取り消す")
    #expect(findingActionLabel(to: "open", from: "rejected") == "再オープン")
    #expect(isUnresolved("fixed") && !isUnresolved("deferred"))

    // ReviewDetailResponse はラウンドの項目と同じ階層に findings が並ぶ
    let detail = try APIClient.decoder().decode(ReviewRoundDetail.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000001","pr_number":7,"pr_title":null,"round":2,"head_sha":"abc",
         "reviewer":{"id":"00000000-0000-0000-0000-000000000002","username":"sakura","avatar_url":null},"summary":"s",
         "created_at":"2026-10-14T12:34:56Z","finding_count":1,"findings":[{"id":"00000000-0000-0000-0000-000000000003",
         "review_id":"00000000-0000-0000-0000-000000000001","pr_number":7,"round":2,"severity":"high","title":"t","body":"b",
         "state":"open","file":null,"line":null,"created_at":"2026-10-14T12:34:56Z","updated_at":"2026-10-14T12:34:56Z",
         "transitions":[],"available_actions":["fixing","fixed"]}]}
        """.utf8))
    #expect(detail.round.round == 2 && detail.findings.first?.availableActions == ["fixing", "fixed"])
}

@Test func projectKeyMatchesBackendRules() {
    // 空は自動生成に任せるので通す
    for valid in ["", "AB", "ENG", "BACK2", "ABCDEFGHIJ"] { #expect(isValidProjectKey(valid), "\(valid)") }
    for invalid in ["A", "1AB", "AbC", "ABCDEFGHIJK", "AB-C", "ＡＢ"] { #expect(!isValidProjectKey(invalid), "\(invalid)") }

    // Web の suggestKey と同じ候補（英数字だけを大文字で、先頭の数字は落とし、2 文字未満は空）
    #expect(suggestProjectKey("Web フロントエンド") == "WEB")
    #expect(suggestProjectKey("iOS アプリ") == "IOS")
    #expect(suggestProjectKey("ｂｅｔａ 版") == "BETA")
    #expect(suggestProjectKey("2026 roadmap") == "ROADMAP")
    #expect(suggestProjectKey("Koyori Task Manager") == "KOYORITASK")
    #expect(suggestProjectKey("暮らし") == "")
    #expect(suggestProjectKey("x") == "")
}

@Test func completionTargetTogglesBetweenOpenAndDone() throws {
    func status(_ n: Int, default isDefault: Bool = false, done: Bool = false) throws -> TaskStatus {
        try APIClient.decoder().decode(TaskStatus.self, from: Data("""
            {"id":"00000000-0000-0000-0000-00000000000\(n)","name":"s\(n)","color":"#000000","position":\(n),"is_default":\(isDefault),"is_done_state":\(done)}
            """.utf8))
    }
    let (backlog, todo, done) = (try status(1), try status(2, default: true), try status(3, done: true))
    let statuses = [backlog, todo, done]
    #expect(completionTarget(from: backlog, in: statuses) == done)
    // 完了済みは既定のステータスへ戻す。既定が無ければ最初の未完了
    #expect(completionTarget(from: done, in: statuses) == todo)
    #expect(completionTarget(from: done, in: [backlog, done]) == backlog)
    // 完了ステータスが無いプロジェクトでは操作を出さない
    #expect(completionTarget(from: backlog, in: [backlog, todo]) == nil)
}

@Test func pullRequestFilterCombinesStateAuthorAndQuery() throws {
    // #9 は High / Medium の 2 件とも fixed（承認待ち）。新しい項目（state など）が無い応答でも読める
    let prs = try APIClient.decoder().decode([ReviewedPullRequest].self, from: Data("""
        [{"pr_number":7,"pr_title":"タスク一覧に絞り込みを付ける","pr_author":"yupix","rounds":2,"unresolved":3,"blocking":1,"blocking_fixed":0,"last_reviewed_at":"2026-10-14T12:00:00Z",
          "state":"open","merged_at":null,"merge_effects_processed_at":null,"pull_request_id":"00000000-0000-0000-0000-000000000001",
          "linked_tasks":[{"id":"00000000-0000-0000-0000-000000000002","seq_id":42,"key":"IOS","title":"t"}]},
         {"pr_number":16,"pr_title":"Markdown を GFM で表示","pr_author":"kenta","rounds":1,"unresolved":2,"blocking":0,"blocking_fixed":0,"last_reviewed_at":"2026-10-14T12:00:00Z"},
         {"pr_number":5,"pr_title":null,"pr_author":null,"rounds":3,"unresolved":0,"blocking":0,"blocking_fixed":0,"last_reviewed_at":"2026-10-14T12:00:00Z"},
         {"pr_number":9,"pr_title":"t","pr_author":"kenta","rounds":2,"unresolved":3,"blocking":2,"blocking_fixed":2,"last_reviewed_at":"2026-10-14T12:00:00Z"},
         {"pr_number":11,"pr_title":"t","pr_author":"kenta","rounds":2,"unresolved":2,"blocking":2,"blocking_fixed":1,"last_reviewed_at":"2026-10-14T12:00:00Z"}]
        """.utf8))
    func numbers(_ filter: PullRequestFilter, author: String? = nil, _ query: String = "") -> [Int] {
        prs.filter { $0.matches(filter, author: author, query: query) }.map(\.prNumber)
    }
    #expect(prs[0].state == "open" && prs[0].linkedTasks?.first?.seqId == 42 && prs[1].linkedTasks == nil)
    #expect(numbers(.all) == [7, 16, 5, 9, 11])
    #expect(numbers(.needsFix) == [7, 11])
    #expect(numbers(.awaitingApproval) == [9])
    #expect(numbers(.unresolved) == [7, 16, 9, 11])
    #expect(numbers(.resolved) == [5])
    // 1 件でも直す番の指摘が残れば要対応で、数はその残り
    #expect(prs[4].status == .needsFix(1))
    #expect(prs[3].status == .awaitingApproval(2))
    #expect(prs[1].status == .unresolved(2) && prs[2].status == .resolved)
    #expect(numbers(.all, author: "kenta") == [16, 9, 11])
    // 番号は前方一致（# 付きでも）、タイトルは大文字小文字を区別しない部分一致
    #expect(numbers(.all, "#1") == [16, 11])
    #expect(numbers(.all, "gfm") == [16])
    #expect(numbers(.unresolved, author: "yupix", "絞り込み") == [7])
}

@Test func taskKeysBecomeLinksOutsideCodeAndLinks() {
    func link(_ ref: String) -> String {
        "[\(ref)](koyori://task/\(ref.split(separator: "-")[0])/\(ref))"
    }
    #expect(renderReferences("TASK-58 を見て") == "\(link("TASK-58")) を見て")
    // 日本語や全角括弧に挟まれていても拾う（Web の \w は ASCII だけ）
    #expect(renderReferences("これはENG-1（とAB2-30）") == "これは\(link("ENG-1"))（と\(link("AB2-30"))）")
    // 前後が英数字・/・- なら拾わない。キーは大文字 2〜10 字
    for text in ["foo/TASK-58", "TASK-58-foo", "xTASK-58", "Task-58", "T-1", "ABCDEFGHIJK-1", "TASK-58a"] {
        #expect(renderReferences(text) == text, "\(text)")
    }
    // コード・既存のリンク・URL の内側は変えない
    for text in [
        "`TASK-58`", "``a ` TASK-58``", "[TASK-58](https://example.com)", "[see TASK-58][ref]", "<https://x.test/TASK-58>",
        "https://x.test/a?TASK-58", "[ref]: https://x.test TASK-58",
    ] {
        #expect(renderReferences(text) == text, "\(text)")
    }
    // エスケープした括弧はリンクではないので、中は拾う（Web も text ノードになる）
    #expect(renderReferences("\\[TASK-1\\]") == "\\[\(link("TASK-1"))\\]")
    let fenced = "```\nTASK-1\n```\nTASK-2\n~~~~\nTASK-3\n~~~\nTASK-4"
    #expect(renderReferences(fenced) == "```\nTASK-1\n```\n\(link("TASK-2"))\n~~~~\nTASK-3\n~~~\nTASK-4")
    // 閉じていない ` はただの文字
    #expect(renderReferences("`TASK-1") == "`\(link("TASK-1"))")
}

@Test func mentionsRenderAsNamesExceptInCode() throws {
    let (a, b, c, d) = (
        "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"
    )
    let list = try APIClient.decoder().decode(CommentList.self, from: Data("""
        {"comments":[],"mentions":{"\(a)":{"status":"member","name":"al_ice","avatar_url":null},
         "\(b)":{"status":"outside","name":null,"avatar_url":null},"\(c)":{"status":"gone","name":null,"avatar_url":null}}}
        """.utf8))
    let mentions = try #require(list.mentions)
    // 名前の Markdown の記号はエスケープし、名前に入った KEY-N はリンクにしない
    #expect(renderReferences("<@\(a)> 確認", mentions: mentions) == "**@al\\_ice** 確認")
    #expect(renderReferences("<@\(b)><@\(c)><@\(d)>", mentions: mentions)
        == "@（このプロジェクトの外の利用者）@（退会した利用者）@（不明な利用者）")
    #expect(renderReferences("`<@\(a)>`", mentions: mentions) == "`<@\(a)>`")
    // 印の形でないものは変えない
    #expect(renderReferences("<@alice> <@\(a.replacingOccurrences(of: "-", with: ""))>") == "<@alice> <@\(a.replacingOccurrences(of: "-", with: ""))>")
    #expect(taskReference(from: URL(string: "koyori://task/ENG/ENG-42")!)! == ("ENG", "ENG-42"))
    #expect(taskReference(from: URL(string: "https://task.koyori.app/x/ENG/ENG-42")!) == nil)
}

@Test func plannedStartIsSentAsDateAndBlockedAfterSoftDeadline() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let oct15 = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, minute: 30)))
    let oct16 = try #require(calendar.date(byAdding: .day, value: 1, to: oct15))
    var draft = TaskDraft(title: "t", statusId: UUID())
    draft.plannedStartOn = oct15
    draft.softDeadline = oct15
    #expect(!draft.startsAfterSoftDeadline(calendar: calendar))
    let request = try #require(draft.request(fields: [], calendar: calendar))
    #expect(request.plannedStartOn == "2026-10-15")
    // 期限より後は Web の作成画面と同じく送らない（サーバーは前後を検証しない）
    draft.plannedStartOn = oct16
    #expect(draft.startsAfterSoftDeadline(calendar: calendar))
    #expect(draft.request(fields: [], calendar: calendar) == nil)
}

@Test func scheduleSpanClipsToRangeAndUsesEarlierEnd() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)))
    func item(start: String?, soft: String?, hard: String? = nil) throws -> Schedule.Item {
        let value = { (text: String?) in text.map { "\"\($0)\"" } ?? "null" }
        return try APIClient.decoder().decode(Schedule.Item.self, from: Data("""
            {"id":"00000000-0000-0000-0000-000000000001","seq_id":1,"seq_key":"IOS-1","title":"t",
             "project":{"id":"00000000-0000-0000-0000-000000000002","name":"p","key":"IOS","is_personal":false},
             "status":{"id":"00000000-0000-0000-0000-000000000003","name":"s","color":"#000000","is_done_state":false},
             "planned_start_on":\(value(start)),"soft_deadline":\(value(soft)),"hard_deadline":\(value(hard)),"assignees":[]}
            """.utf8))
    }
    // JST 10/14 23:59 の締切は 10/14（UTC では 14:59）
    #expect(try item(start: "2026-10-13", soft: "2026-10-14T14:59:59Z").span(first: first, days: 14, calendar: calendar) == 1...2)
    // 開始予定日が締切より後でも、早い方〜遅い方
    #expect(try item(start: "2026-10-14", soft: "2026-10-12T03:00:00Z").span(first: first, days: 14, calendar: calendar) == 0...2)
    // 範囲外は端で切る。片方だけならその日。Soft が無ければ Hard
    #expect(try item(start: "2026-10-01", soft: "2026-11-30T00:00:00Z").span(first: first, days: 14, calendar: calendar) == 0...13)
    #expect(try item(start: nil, soft: nil, hard: "2026-10-20T00:00:00Z").span(first: first, days: 14, calendar: calendar) == 8...8)
    #expect(try item(start: "2026-10-26", soft: nil).span(first: first, days: 14, calendar: calendar) == nil)
    #expect(try item(start: nil, soft: nil).span(first: first, days: 14, calendar: calendar) == nil)
}

@Test func decodesTaskRelationsParentAndSubtasks() throws {
    let task = { (id: Int, parent: String) in
        """
        {"id":"00000000-0000-0000-0000-00000000000\(id)","seq_id":\(id),"title":"t\(id)","description":null,
         "status_id":"00000000-0000-0000-0000-000000000009","priority":"Medium","assignees":[],"labels":[],
         "soft_deadline":null,"hard_deadline":null,"created_by":null,"created_at":"2026-10-14T12:00:00Z",
         "updated_at":"2026-10-14T12:00:00Z","parent_task_id":\(parent)}
        """
    }
    let relations = try APIClient.decoder().decode(TaskRelations.self, from: Data("""
        {"parent":\(task(1, "null")),"subtasks":[\(task(3, "\"00000000-0000-0000-0000-000000000002\""))],"blocks":[],"blocked_by":[]}
        """.utf8))
    #expect(relations.parent?.seqId == 1 && relations.parent?.parentTaskId == nil)
    #expect(relations.subtasks.map(\.parentTaskId) == [UUID(uuidString: "00000000-0000-0000-0000-000000000002")])
}

@Test func labelNameAllowsUpTo100CodePointsAfterTrimming() {
    let label = { (name: String) in LabelRequest(name: name, color: "#ef4444", description: " d ") }
    #expect(label(" \(String(repeating: "a", count: 100)) ").isValid)
    #expect(!label(String(repeating: "a", count: 101)).isValid)
    #expect(!label(" \n").isValid)
    // backend はコードポイントで数えるので、肌の色つきの絵文字は 1 字でも 2 と数える
    #expect(!label(String(repeating: "👍🏽", count: 50) + "a").isValid)
    #expect(label("x").description == "d")
}

@Test func colorHexRoundTripsPresetAndClampsWideGamut() {
    #expect(Color(hex: "#3b82f6").hex == "#3b82f6")
    #expect(Color(.displayP3, red: 1, green: 0, blue: 0).hex == "#ff0000")
}

@Test func seedColorIsStableAndSpreads() {
    // 起動をまたいで同じ名前は同じ色（FNV-1a の既知値: "a" → 0xE40C292C）
    #expect(Color(seed: "yupix") == Color(seed: "yupix"))
    #expect(Color(seed: "a") == [Color.blue, .indigo, .purple, .pink, .red, .orange, .green][Int(0xE40C_292C % 7)])
    #expect(Set(["yupix", "tanaka_ken", "suzuki_mio", "sato_haruka", "ito_yui"].map { Color(seed: $0).description }).count >= 4)
}
