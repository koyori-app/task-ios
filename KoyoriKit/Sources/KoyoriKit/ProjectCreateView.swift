import SwiftUI

/// プロジェクトの作成（テナントのオーナーだけ）。ステータスは backend が既定のセットで作る。
struct ProjectCreateView: View {
    let tenant: Tenant
    let onCreate: (Project) -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var emoji = ""
    @State private var name = ""
    @State private var key = ""
    /// キーを自分で書き換えたら、名前からの候補で上書きしない
    @State private var isKeyEdited = false
    @State private var description = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        TextField("😀", text: $emoji)
                            .font(.title)
                            .multilineTextAlignment(.center)
                            .frame(width: 52, height: 52)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                            // アイコンは 1 文字。打ち直したら新しいほうを残す
                            .onChange(of: emoji) { if emoji.count > 1 { emoji = String(emoji.suffix(1)) } }
                            .accessibilityLabel("アイコンの絵文字")
                        TextField("プロジェクト名", text: $name).font(.headline).focused($isNameFocused)
                    }
                } footer: {
                    Text("アイコンは絵文字 1 文字です（なくても作れます）。")
                }

                Section {
                    TextField("自動", text: Binding(get: { key }, set: { key = $0.uppercased(); isKeyEdited = true }))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                } header: {
                    Text("キー")
                } footer: {
                    if isValidProjectKey(key) {
                        Text(verbatim: "タスク番号の接頭辞（例: \(key.isEmpty ? "ABC" : key)-1）。空欄なら名前から自動で作ります。")
                    } else {
                        Text("2〜10 文字で、先頭は大文字英字、残りは大文字英字か数字にしてください。").foregroundStyle(.red)
                    }
                }

                Section("説明") {
                    TextField("このプロジェクトは何のためのものですか？", text: $description, axis: .vertical).lineLimit(3...)
                }

                Section {
                    LabeledContent("テナント") {
                        Text(verbatim: [tenant.iconEmoji, tenant.name].compactMap { $0 }.joined(separator: " "))
                    }
                } footer: {
                    Text("ステータスは既定のセット（Backlog・Todo・In Progress・Done）で作られます。あとから Web で変えられます。")
                }
            }
            .onChange(of: name) { if !isKeyEdited { key = suggestProjectKey(name) } }
            .loadState(isLoaded: true, error: $error)
            .navigationTitle("プロジェクトを作成")
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
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isValidProjectKey(key))
                    }
                }
            }
            // 書きかけを下へのスワイプで失わない
            .interactiveDismissDisabled(!name.isEmpty || !description.isEmpty)
            .onAppear { isNameFocused = true }
        }
    }

    private func save() async {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        defer { isSaving = false }
        do {
            let project = try await session.api.createProject(
                tenantId: tenant.id,
                CreateProjectRequest(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines), key: key.isEmpty ? nil : key,
                    description: description.isEmpty ? nil : description, iconEmoji: emoji.isEmpty ? nil : emoji))
            onCreate(project)
            dismiss()
        } catch {
            self.error = error.displayMessage
        }
    }
}

/// backend の `validate_project_key` と同じ規則（2〜10 文字、先頭は大文字英字、残りは大文字英字か数字）。空は自動生成に任せる。
func isValidProjectKey(_ key: String) -> Bool {
    key.isEmpty || key.wholeMatch(of: /[A-Z][A-Z0-9]{1,9}/) != nil
}

/// 名前からキーの候補を作る（Web の `suggestKey` と同じ）。2 文字に満たなければ空にして自動生成に任せる。
func suggestProjectKey(_ name: String) -> String {
    let letters = name.decomposedStringWithCompatibilityMapping.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    let key = String(letters.drop(while: \.isNumber).prefix(10))
    return key.count >= 2 ? key : ""
}
