import AppKit

/// Hermes Agent (Nous Research) running on another Mac: its recent chats,
/// Telegram ones included, shown as threads. Talks to that machine's
/// `hermes serve` backend the way Hermes Desktop does in Remote mode: a
/// password login (`POST /auth/password-login`), then the REST API with the
/// session token as a bearer. The password lives in the login Keychain so an
/// expired token (12 h) can be renewed without asking again.
struct HermesChat: Equatable, Sendable {
    let id: String
    /// Where the chat happens: "telegram", "slack", "cli", "desktop"…
    let source: String
    let title: String?
    let lastActive: Date
    let model: String?
    var prompt: String?
    var reply: String?

    /// "telegram" → "Telegram"; Hermes' own front ends → "Hermes".
    var sourceName: String {
        switch source {
        case "cli", "tui", "desktop", "dashboard", "web", "api", "hermes": "Hermes"
        default: source.prefix(1).uppercased() + source.dropFirst()
        }
    }
}

actor HermesAPI {
    static let shared = HermesAPI()
    static let urlKey = "hermesURL"
    static let userKey = "hermesUser"
    /// Chats shown: the most recent few, active in the last week.
    static let window: TimeInterval = 7 * 86_400
    static let maxChats = 5

    enum Failure: LocalizedError {
        case notConfigured, badLogin, rateLimited, unreachable, insecureAddress, http(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Hermes isn't connected."
            case .badLogin: "Hermes didn't accept that username and password."
            case .rateLimited: "Hermes is limiting sign-in attempts. Wait a minute and try again."
            case .unreachable: "Couldn't reach Hermes at that address. Is Tailscale on, and `hermes serve` running?"
            case .insecureAddress: "macOS only allows plain http:// to local names. Use the machine's name (e.g. http://my-mac-mini:9119, its Tailscale name) instead of a 100.x number."
            case .http(let code): "Hermes answered \(code)."
            }
        }
    }

    private let session = URLSession(configuration: .ephemeral)
    private var token: String?
    /// Last message pair per chat, refetched only when the chat moves on.
    private var exchanges: [String: (lastActive: Date, prompt: String?, reply: String?)] = [:]

    nonisolated static var isConfigured: Bool {
        UserDefaults.standard.string(forKey: urlKey) != nil && UserDefaults.standard.string(forKey: userKey) != nil
    }

    /// The Remote URL Hermes Desktop has saved on this Mac, to prefill.
    nonisolated static var desktopURL: String? {
        let file = NSHomeDirectory() + "/Library/Application Support/Hermes/connection.json"
        guard let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remote = json["remote"] as? [String: Any] else { return nil }
        return remote["url"] as? String
    }

    /// Checks the login, then saves it (password to the Keychain).
    func connect(url: String, user: String, password: String) async throws {
        let base = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        token = try await login(base: base, user: user, password: password)
        UserDefaults.standard.set(base, forKey: Self.urlKey)
        UserDefaults.standard.set(user, forKey: Self.userKey)
        Self.keychain.write(password)
    }

    func disconnect() {
        token = nil
        exchanges = [:]
        UserDefaults.standard.removeObject(forKey: Self.urlKey)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        Self.keychain.delete()
    }

    /// The most recent chats (cron jobs left out), each with its latest
    /// prompt and reply.
    func recentChats() async throws -> [HermesChat] {
        let body = try await get("/api/sessions?limit=20&order=recent&archived=exclude&exclude_sources=cron")
        guard let rows = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["sessions"] as? [[String: Any]] else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-Self.window)
        var chats = rows.compactMap { row -> HermesChat? in
            guard let id = row["id"] as? String, let active = row["last_active"] as? Double else { return nil }
            let lastActive = Date(timeIntervalSince1970: active)
            guard lastActive > cutoff else { return nil }
            return HermesChat(id: id, source: row["source"] as? String ?? "hermes",
                              title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              lastActive: lastActive,
                              model: row["model"] as? String)
        }
        chats = Array(chats.prefix(Self.maxChats))
        for index in chats.indices {
            let chat = chats[index]
            if let cached = exchanges[chat.id], cached.lastActive == chat.lastActive {
                chats[index].prompt = cached.prompt
                chats[index].reply = cached.reply
                continue
            }
            let (prompt, reply) = (try? await latestExchange(chat.id)) ?? (nil, nil)
            exchanges[chat.id] = (chat.lastActive, prompt, reply)
            chats[index].prompt = prompt
            chats[index].reply = reply
        }
        return chats
    }

    /// The newest user message and the newest non-empty assistant reply.
    private func latestExchange(_ id: String) async throws -> (String?, String?) {
        let body = try await get("/api/sessions/\(id)/messages?limit=12&order=latest")
        guard let messages = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]] else {
            return (nil, nil)
        }
        func last(_ role: String) -> String? {
            messages.last { $0["role"] as? String == role && !(($0["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?["content"] as? String
        }
        return (last("user"), last("assistant"))
    }

    // MARK: HTTP

    /// A one-use ticket for the live WebSocket (`/api/ws?ticket=…`), and
    /// that socket's URL.
    func liveSocket() async throws -> URL {
        let body = try await call("POST", "/api/auth/ws-ticket", body: Data("{}".utf8))
        guard let base = UserDefaults.standard.string(forKey: Self.urlKey),
              let ticket = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["ticket"] as? String,
              var url = URLComponents(string: base + "/api/ws") else { throw Failure.notConfigured }
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        url.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let socket = url.url else { throw Failure.notConfigured }
        return socket
    }

    private func get(_ path: String) async throws -> Data {
        try await call("GET", path, body: nil)
    }

    /// A request with the session token; signs in again once if it expired.
    private func call(_ method: String, _ path: String, body: Data?) async throws -> Data {
        guard let base = UserDefaults.standard.string(forKey: Self.urlKey),
              let user = UserDefaults.standard.string(forKey: Self.userKey),
              let password = Self.keychain.read() else { throw Failure.notConfigured }
        for attempt in 0..<2 {
            if token == nil || attempt == 1 { token = try await login(base: base, user: user, password: password) }
            guard let url = URL(string: base + path) else { throw Failure.notConfigured }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = method
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
            let (data, response) = try await send(request)
            switch response.statusCode {
            case 200: return data
            case 401 where attempt == 0: continue
            default: throw Failure.http(response.statusCode)
            }
        }
        throw Failure.badLogin
    }

    /// Returns the access token the backend sets as `hermes_session_at`
    /// (with a `__Host-`/`__Secure-` prefix over https).
    private func login(base: String, user: String, password: String) async throws -> String {
        guard let url = URL(string: base + "/auth/password-login") else { throw Failure.unreachable }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["provider": "basic", "username": user, "password": password])
        let (_, response) = try await send(request)
        switch response.statusCode {
        case 200: break
        case 401: throw Failure.badLogin
        case 429: throw Failure.rateLimited
        default: throw Failure.http(response.statusCode)
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { fields, pair in
            if let key = pair.key as? String, let value = pair.value as? String { fields[key] = value }
        }
        let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).first { $0.name.hasSuffix("hermes_session_at") }
        guard let token = cookie?.value, !token.isEmpty else { throw Failure.badLogin }
        return token
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch {
            // App Transport Security: plain http only to local names, so a
            // Tailscale 100.x address is refused where its machine name works.
            if (error as NSError).code == NSURLErrorAppTransportSecurityRequiresSecureConnection { throw Failure.insecureAddress }
            EventLog.write("hermes request to \(request.url?.host ?? "?") failed: \(error.localizedDescription)")
            throw Failure.unreachable
        }
    }

    private static let keychain = KeychainSecret(service: "Notch Agent Hermes", account: "hermes")
}

// MARK: - Live

/// What a Hermes chat started or replied to from the notch is doing, keyed
/// by its stored session id (the one the REST API and threads use).
enum HermesEvent: Sendable {
    case started(String)
    case tool(String, name: String, context: String?)
    case completed(String, text: String)
    case failed(String, message: String)
    /// A command waiting for permission; `choices` from "once", "session",
    /// "always", "deny".
    case approval(String, command: String, description: String?, choices: [String])
    /// A question Hermes asked (`clarify`), answered by its request id.
    case question(String, requestID: String, PromptQuestion)
}

/// The live half of Hermes: one JSON-RPC 2.0 WebSocket (`/api/ws`), the
/// same one Hermes Desktop uses. A chat's events only go to the socket that
/// owns it, so the notch takes a chat over (`session.resume`) to reply and
/// creates its own for Ask. Each frame is one JSON object: replies carry
/// the request `id`, events come as `{"method":"event","params":{type,
/// session_id, payload}}`. Live session ids are per socket (8 hex chars);
/// they map to stored ids, and are forgotten when the socket drops.
actor HermesLive {
    static let shared = HermesLive()

    enum Failure: LocalizedError {
        case disconnected, rpc(String)

        var errorDescription: String? {
            switch self {
            case .disconnected: "Lost the connection to Hermes. Try again."
            case .rpc(let message): "Hermes: \(message)"
            }
        }
    }

    private var socket: URLSessionWebSocketTask?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var storedByLive: [String: String] = [:]
    private var liveByStored: [String: String] = [:]
    private var handler: (@Sendable (HermesEvent) -> Void)?

    func onEvent(_ handler: @escaping @Sendable (HermesEvent) -> Void) {
        self.handler = handler
    }

    /// Starts a new chat; returns its stored id once Hermes has the prompt.
    func ask(_ text: String) async throws -> String {
        let created = try await call("session.create", ["cols": 80])
        guard let live = created["session_id"] as? String, let stored = created["stored_session_id"] as? String else {
            throw Failure.rpc("no session id")
        }
        remember(live: live, stored: stored)
        _ = try await call("prompt.submit", ["session_id": live, "text": text])
        return stored
    }

    /// Continues an existing chat. Runs in this backend, so a Telegram
    /// chat's reply shows here and in Hermes, not in Telegram.
    func reply(to stored: String, text: String) async throws {
        _ = try await call("prompt.submit", ["session_id": try await liveID(for: stored), "text": text])
    }

    /// Hermes' own context compression for a chat.
    func compress(_ stored: String) async throws {
        _ = try await call("session.compress", ["session_id": try await liveID(for: stored)])
    }

    /// The chat's id on this socket, taking it over first if needed.
    private func liveID(for stored: String) async throws -> String {
        if let known = liveByStored[stored] { return known }
        let resumed = try await call("session.resume", ["session_id": stored, "omit_messages": true])
        guard let id = resumed["session_id"] as? String else { throw Failure.rpc("couldn't open that chat") }
        remember(live: id, stored: stored)
        return id
    }

    /// Answers a command approval: "once", "session", "always" or "deny".
    func approve(_ stored: String, choice: String) async throws {
        guard let live = liveByStored[stored] else { throw Failure.disconnected }
        _ = try await call("approval.respond", ["session_id": live, "choice": choice, "all": false])
    }

    func answer(_ requestID: String, with answer: String) async throws {
        _ = try await call("clarify.respond", ["request_id": requestID, "answer": answer])
    }

    private func remember(live: String, stored: String) {
        storedByLive[live] = stored
        liveByStored[stored] = live
    }

    // MARK: JSON-RPC

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let socket = try await connected()
        nextID += 1
        let id = nextID
        let frame = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            socket.send(.string(String(decoding: frame, as: UTF8.self))) { error in
                guard let error else { return }
                Task { await self.finish(id, with: .failure(error)) }
            }
        }
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.rpc("bad reply") }
        if let error = reply["error"] as? [String: Any] { throw Failure.rpc(error["message"] as? String ?? "error") }
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func finish(_ id: Int, with result: Result<Data, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func connected() async throws -> URLSessionWebSocketTask {
        if let socket { return socket }
        let url = try await HermesAPI.shared.liveSocket()
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 32 << 20
        socket.resume()
        self.socket = socket
        Task { await self.read(socket) }
        return socket
    }

    private func read(_ socket: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                dropped(socket)
                return
            }
            switch message {
            case .string(let text): handle(Data(text.utf8))
            case .data(let data): handle(data)
            @unknown default: break
            }
        }
    }

    /// The socket closed: fail what's waiting, forget the live ids (they
    /// belonged to that socket), reconnect on the next call.
    private func dropped(_ closed: URLSessionWebSocketTask) {
        guard socket === closed else { return }
        socket = nil
        for (_, continuation) in pending { continuation.resume(throwing: Failure.disconnected) }
        pending = [:]
        for stored in storedByLive.values { handler?(.failed(stored, message: Failure.disconnected.localizedDescription)) }
        storedByLive = [:]
        liveByStored = [:]
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = frame["id"] as? Int {
            finish(id, with: .success(data))
            return
        }
        guard frame["method"] as? String == "event", let params = frame["params"] as? [String: Any],
              let type = params["type"] as? String, let live = params["session_id"] as? String,
              let stored = storedByLive[live] else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        switch type {
        case "message.start":
            handler?(.started(stored))
        case "tool.start":
            handler?(.tool(stored, name: payload["name"] as? String ?? "Tool", context: payload["context"] as? String))
        case "message.complete":
            handler?(.completed(stored, text: payload["text"] as? String ?? ""))
        case "error":
            handler?(.failed(stored, message: payload["message"] as? String ?? "Hermes hit an error."))
        case "approval.request":
            let command = payload["command"] as? String ?? "a command"
            let choices = payload["choices"] as? [String] ?? ["once", "deny"]
            handler?(.approval(stored, command: command, description: payload["description"] as? String, choices: choices))
        case "clarify.request":
            guard let requestID = payload["request_id"] as? String else { return }
            // Choices come as plain labels, or as {label, description}.
            let options = (payload["choices"] as? [Any] ?? []).compactMap { choice -> PromptQuestion.Option? in
                if let label = choice as? String { return PromptQuestion.Option(label: label, description: nil) }
                guard let fields = choice as? [String: Any], let label = fields["label"] as? String else { return nil }
                return PromptQuestion.Option(label: label, description: fields["description"] as? String)
            }
            let question = PromptQuestion(id: 0, question: payload["question"] as? String ?? "Hermes has a question",
                                          header: nil, options: options, multiSelect: payload["multi_select"] as? Bool ?? false)
            handler?(.question(stored, requestID: requestID, question))
        default:
            break
        }
    }
}

/// Asks for the Hermes address and login in a small window, tests it, and
/// saves it. `onConnected` runs after a successful sign-in.
@MainActor
enum HermesConnectDialog {
    static func present(onConnected: @escaping () -> Void) {
        let url = field(UserDefaults.standard.string(forKey: HermesAPI.urlKey) ?? HermesAPI.desktopURL ?? "http://", placeholder: "http://100.x.x.x:9119")
        let user = field(UserDefaults.standard.string(forKey: HermesAPI.userKey) ?? "", placeholder: "Username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = "Password"
        let stack = NSStackView(views: [url, user, password])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 88)

        let alert = NSAlert()
        alert.messageText = "Connect Hermes"
        alert.informativeText = "Your Hermes backend (`hermes serve`) and its login, as in Hermes Desktop. Over Tailscale, use the machine's name (http://my-mac-mini:9119). The password is kept in your Keychain."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let values = (url.stringValue, user.stringValue, password.stringValue)
        Task {
            do {
                try await HermesAPI.shared.connect(url: values.0, user: values.1, password: values.2)
                onConnected()
            } catch {
                let failed = NSAlert()
                failed.messageText = "Couldn't connect Hermes"
                failed.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                failed.runModal()
            }
        }
    }

    private static func field(_ value: String, placeholder: String) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        return field
    }
}

/// One secret in the login Keychain, through `/usr/bin/security` so dev
/// builds and the installed app share it without prompts. Written on stdin
/// (`security -i`), never as an argument `ps` could show.
struct KeychainSecret: Sendable {
    let service: String
    let account: String

    func read() -> String? {
        let output = Self.security(["find-generic-password", "-s", service, "-w"])
        return output?.isEmpty == false ? output : nil
    }

    func write(_ secret: String) {
        // Quoted for `security -i`: backslashes and quotes escaped.
        let quoted = secret.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard !secret.contains("\n") else { return }
        Self.security(["-i"], input: "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -w \"\(quoted)\"\n")
    }

    func delete() {
        Self.security(["delete-generic-password", "-s", service])
    }

    @discardableResult
    private static func security(_ arguments: [String], input: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        do { try process.run() } catch { return nil }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
