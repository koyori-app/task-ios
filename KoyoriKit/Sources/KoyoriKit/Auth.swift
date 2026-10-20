import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Observation
import Security
#if os(iOS)
import UIKit
#endif

// ログインは Koyori Desktop と同じ Device Token の発行手順（Authorization Code + PKCE、loopback）を使う。
// 規則は koyori-app/task の apps/backend/docs/personal-access-tokens-authz.md の「Desktop 認証」。
//
//   127.0.0.1:{port} で待ち受け → {origin}/desktop/authorize?port=&code_challenge=&state=&name= を開く
//   → Web で承認 → http://127.0.0.1:{port}/callback?code=&state= → POST /v1/desktop/auth/token

/// RFC 7636 の PKCE（S256）。
enum PKCE {
    /// 32 バイト乱数の base64url（43 文字）。code_verifier と state に使う。
    static func randomString() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URL
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct LoopbackCallback: Equatable, Sendable {
    let code: String
    let state: String

    /// HTTP 要求の先頭行 `GET /callback?code=…&state=… HTTP/1.1` を読む。それ以外（favicon 等）は nil。
    init?(request: Data) {
        guard let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET",
              let url = URLComponents(string: String(parts[1])), url.path == "/callback",
              let code = url.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = url.queryItems?.first(where: { $0.name == "state" })?.value
        else { return nil }
        self.code = code
        self.state = state
    }
}

/// 127.0.0.1 の空きポートで待ち受け、`/callback` を受けたら `onCallback` を呼ぶ。
final class LoopbackServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.koyori.task.loopback")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// 待ち受けを始め、割り当てられたポートを返す。
    func start(onCallback: @escaping @Sendable (LoopbackCallback) -> Void) async throws -> UInt16 {
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            // shortcut: 最初の受信だけを読む。要求行はブラウザの最初のパケットに収まる前提
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                let callback = data.flatMap(LoopbackCallback.init(request:))
                let body = Data((callback == nil ? "" : Self.doneHTML).utf8)
                let head = "HTTP/1.1 \(callback == nil ? "404 Not Found" : "200 OK")\r\n"
                    + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                if let callback { onCallback(callback) }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private static let doneHTML = """
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>Koyori</title><p style="font-family:system-ui;text-align:center;margin-top:40vh">ログインしました。アプリに戻ります。</p>
        """
}

struct Credentials: Codable, Sendable {
    let origin: URL
    let token: String
    let deviceId: UUID
}

@MainActor
enum DeviceAuth {
    /// Web の承認画面をアプリ内ブラウザで開き、承認されたら Device Token を受け取る。
    /// 利用者がブラウザを閉じたら `CancellationError`。
    static func signIn(origin: URL) async throws -> Credentials {
        let verifier = PKCE.randomString()
        let state = PKCE.randomString()
        let (callbacks, continuation) = AsyncThrowingStream<LoopbackCallback, Error>.makeStream()

        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try await server.start { callback in
            continuation.yield(callback)
            continuation.finish()
        }

        var url = origin.appending(path: "desktop/authorize")
        url.append(queryItems: [
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "name", value: "Koyori iOS"),
        ])
        // 承認後の遷移先は 127.0.0.1 なので、このスキームには戻ってこない。閉じる操作だけをここで受ける
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("koyori")) { _, error in
            let canceled = error == nil || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            continuation.finish(throwing: canceled ? CancellationError() : error)
        }
        let anchor = AnchorProvider()
        session.presentationContextProvider = anchor
        guard session.start() else { throw CancellationError() }
        defer { session.cancel() }  // 受け取ったらブラウザを閉じる

        var iterator = callbacks.makeAsyncIterator()
        guard let callback = try await iterator.next() else { throw CancellationError() }
        guard callback.state == state else { throw URLError(.badServerResponse) }

        let token = try await APIClient(origin: origin).exchangeDesktopCode(code: callback.code, codeVerifier: verifier)
        return Credentials(origin: origin, token: token.token, deviceId: token.deviceId)
    }
}

@MainActor
private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
        return (scene as? UIWindowScene)?.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()  // macOS はビルド検証用
        #endif
    }
}

/// Device Token は Keychain だけに置く（UserDefaults・ログに出さない）。
enum CredentialStore {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.koyori.task",
            kSecAttrAccount as String: "device-token",
        ]
    }

    static func load() -> Credentials? {
        var query = query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) throws {
        delete()
        var query = query
        query[kSecValueData as String] = try JSONEncoder().encode(credentials)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor @Observable
final class AppSession {
    static let defaultOrigin = URL(string: "https://task.koyori.app")!

    private(set) var credentials = CredentialStore.load()

    /// 画面はログイン中にしか作らないので、未ログイン時の値は使われない。
    var api: APIClient {
        let token = credentials?.token
        return APIClient(origin: credentials?.origin ?? Self.defaultOrigin, token: token) {
            // 期限切れ・Web からの失効。再承認を促すためログイン画面へ戻す
            Task { @MainActor in
                if self.credentials?.token == token { self.clear() }
            }
        }
    }

    func signIn(origin: URL) async throws {
        let credentials = try await DeviceAuth.signIn(origin: origin)
        try CredentialStore.save(credentials)
        self.credentials = credentials
    }

    func signOut() async {
        guard let credentials else { return }
        // オフライン等で失効に失敗しても端末からは消す。残ったトークンは Web の設定 > セキュリティから失効できる
        try? await api.revokeDevice(id: credentials.deviceId)
        clear()
    }

    private func clear() {
        CredentialStore.delete()
        credentials = nil
    }
}
