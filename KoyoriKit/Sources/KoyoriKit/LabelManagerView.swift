import SwiftUI

/// プロジェクトのラベルの作成・編集・削除（Web のプロジェクト設定の「ラベル」と同じ）。
struct LabelManagerView: View {
    let project: Project
    @Environment(AppSession.self) private var session
    @State private var labels: [TaskLabel]?
    @State private var sheet: LabelSheet?
    @State private var deleting: TaskLabel?
    @State private var error: String?

    private enum LabelSheet: Identifiable {
        case create
        case edit(TaskLabel)

        var id: UUID? {
            if case .edit(let label) = self { return label.id }
            return nil
        }
    }

    var body: some View {
        List(labels ?? []) { label in
            Button {
                sheet = .edit(label)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    // ボタンの中の `.primary` はアクセント色になるので、文字色を直接指定する
                    LabelChip(label: label).foregroundStyle(Color.primary)
                    if !label.description.isEmpty {
                        Text(label.description).font(.subheadline).foregroundStyle(Color.secondary)
                    }
                }
                .padding(.vertical, 2)
                // 区切り線は札の中の文字ではなく行の端にそろえる（説明の有無で位置が変わらないよう）
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
            .swipeActions {
                Button("削除", systemImage: "trash", role: .destructive) { deleting = label }
            }
            .contextMenu {
                Button("編集", systemImage: "pencil") { sheet = .edit(label) }
                Button("削除", systemImage: "trash", role: .destructive) { deleting = label }
            }
        }
        .loadState(isLoaded: labels != nil, error: $error)
        .overlay {
            if labels?.isEmpty == true {
                ContentUnavailableView("ラベルはありません", systemImage: "tag", description: Text("右上の＋から作成できます。"))
            }
        }
        .navigationTitle("ラベルの管理")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("作成", systemImage: "plus") { sheet = .create }.disabled(labels == nil)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create:
                LabelFormView(project: project, label: nil) { labels?.append($0) }
            case .edit(let label):
                LabelFormView(project: project, label: label) { saved in
                    if let index = labels?.firstIndex(where: { $0.id == saved.id }) { labels?[index] = saved }
                }
            }
        }
        .confirmationDialog(
            Text(verbatim: "「\(deleting?.name ?? "")」を削除しますか？"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { label in
            Button("削除", role: .destructive) { Task { await delete(label) } }
        } message: { _ in
            Text("付いているタスクからも外れます。この操作は取り消せません。")
        }
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

    private func delete(_ label: TaskLabel) async {
        do {
            try await session.api.deleteLabel(project, id: label.id)
            withAnimation { labels?.removeAll { $0.id == label.id } }
        } catch {
            self.error = error.displayMessage
        }
    }
}

/// ラベルの作成（`label` が nil）と編集。色は Web と同じ候補から選ぶか、色の選択で自由に決める。
struct LabelFormView: View {
    let project: Project
    let label: TaskLabel?
    let onSave: (TaskLabel) -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name: String
    @State private var color: String
    @State private var description: String
    @State private var isSaving = false
    @State private var error: String?

    /// Web の `LABEL_COLOR_PRESETS` と同じ色。名前は読み上げ用
    private static let presets: [(hex: String, name: String)] = [
        ("#ef4444", "赤"), ("#f97316", "オレンジ"), ("#f59e0b", "黄"), ("#22c55e", "緑"), ("#06b6d4", "水色"),
        ("#3b82f6", "青"), ("#8b5cf6", "紫"), ("#ec4899", "ピンク"), ("#64748b", "灰"),
    ]

    init(project: Project, label: TaskLabel?, onSave: @escaping (TaskLabel) -> Void) {
        self.project = project
        self.label = label
        self.onSave = onSave
        _name = State(initialValue: label?.name ?? "")
        _color = State(initialValue: label?.color ?? Self.presets[0].hex)
        _description = State(initialValue: label?.description ?? "")
    }

    private var request: LabelRequest { LabelRequest(name: name, color: color, description: description) }

    private var hasChanges: Bool {
        request != LabelRequest(name: label?.name ?? "", color: label?.color ?? Self.presets[0].hex, description: label?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 出来上がりの見た目
                    LabelChip(label: TaskLabel(
                        id: label?.id ?? UUID(), name: request.name.isEmpty ? "ラベル" : request.name, color: color, description: ""))
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextField("名前", text: $name).focused($isNameFocused)
                    TextField("説明（任意）", text: $description, axis: .vertical).lineLimit(2...)
                } footer: {
                    if request.name.unicodeScalars.count > 100 {
                        Text("名前は 100 文字までです。").foregroundStyle(.red)
                    }
                }

                Section("色") {
                    FlowLayout(spacing: 12) {
                        ForEach(Self.presets, id: \.hex) { preset in
                            let isSelected = color.lowercased() == preset.hex
                            Button {
                                color = preset.hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: preset.hex))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if isSelected { Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                        ColorPicker("ほかの色", selection: Binding(get: { Color(hex: color) }, set: { color = $0.hex }), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 30, height: 30)
                    }
                    .padding(.vertical, 4)
                }
            }
            .loadState(isLoaded: true, error: $error)
            .navigationTitle(label == nil ? "ラベルを作成" : "ラベルを編集")
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
                        Button(label == nil ? "作成" : "保存") { Task { await save() } }
                            .disabled(!request.isValid || !hasChanges)
                    }
                }
            }
            // 書きかけを下へのスワイプで失わない
            .interactiveDismissDisabled(hasChanges)
            .onAppear { if label == nil { isNameFocused = true } }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved: TaskLabel
            if let label {
                saved = try await session.api.updateLabel(project, id: label.id, request)
            } else {
                saved = try await session.api.createLabel(project, request)
            }
            onSave(saved)
            dismiss()
        } catch {
            self.error = error.displayMessage
        }
    }
}
