import SwiftUI

/// ログイン中のアカウント。プロフィールの更新はセッション専用の API なので、Web の設定画面で行う。
struct AccountView: View {
    let account: Account?
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Avatar(name: account?.username ?? "?", url: account?.avatarUrl, size: 88)
                            .padding(.bottom, 4)
                        Text(account?.username ?? "").font(.title2.bold())
                        if let email = account?.email {
                            Text(email).foregroundStyle(.secondary)
                        }
                        if let bio = account?.bio, !bio.isEmpty {
                            Text(bio).font(.subheadline).multilineTextAlignment(.center).padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                if let origin = session.credentials?.origin {
                    Section {
                        Button {
                            openURL(origin.appending(path: "settings/profile"))
                        } label: {
                            HStack {
                                Label("プロフィールを編集", systemImage: "person.text.rectangle")
                                Spacer()
                                Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("名前・アイコン・自己紹介は Web で変えます（アプリのログインでは変えられない仕組みです）。アプリに戻ると反映されます。")
                    }

                    Section {
                        LabeledContent("サーバー") { Text(verbatim: origin.host() ?? origin.absoluteString) }
                    }
                }

                Section {
                    Button("ログアウト", role: .destructive) { isConfirmingSignOut = true }
                } footer: {
                    Text("この端末の承認を取り消します。")
                }
            }
            .navigationTitle("アカウント")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog("ログアウトしますか？", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("ログアウト", role: .destructive) { Task { await session.signOut() } }
            } message: {
                Text("この端末の承認を取り消します。")
            }
        }
    }
}

/// 他の利用者のプロフィール（同じテナントの人だけ見える）。自分なら `AccountView` を出す。
struct UserProfileView: View {
    let tenantId: UUID
    let userId: UUID
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var me: Account?
    @State private var profile: UserProfile?
    @State private var error: String?

    var body: some View {
        if let me, me.id == userId {
            AccountView(account: me)
        } else {
            NavigationStack {
                List {
                    if let profile {
                        Section {
                            VStack(spacing: 8) {
                                Avatar(name: profile.username, url: profile.avatarUrl, size: 88).padding(.bottom, 4)
                                Text(profile.username).font(.title2.bold())
                                if let bio = profile.bio, !bio.isEmpty {
                                    Text(bio).font(.subheadline).multilineTextAlignment(.center).padding(.top, 6)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .loadState(isLoaded: profile != nil, error: $error)
                .navigationTitle("プロフィール")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        let api = session.api
        // 自分ならメールも出せる AccountView にする。取れなければ他人と同じ表示にする
        if let me = try? await api.me(), me.id == userId {
            self.me = me
            return
        }
        do {
            profile = try await api.userProfile(tenantId: tenantId, userId: userId)
        } catch {
            self.error = error.displayMessage
        }
    }
}
