import AppKit
import CryptoKit

/// One song (or episode) in Spotify's queue.
struct QueueItem: Identifiable, Equatable, Sendable {
    /// Position in the queue: the same track can be queued twice.
    let id: Int
    let title: String
    let subtitle: String
    let duration: Double
    let artworkURL: URL?
}

/// A search result or one of the user's playlists: anything Spotify's app
/// can play from its URI.
struct SpotifyItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case track = "Song", album = "Album", playlist = "Playlist" }

    let uri: String
    let kind: Kind
    let title: String
    let subtitle: String
    let artworkURL: URL?
    /// What keeps playing after it: a liked song plays on through Liked Songs.
    var context: String?

    var id: String { uri }
}

/// Spotify's queue, which its AppleScript dictionary doesn't expose, read
/// from the Web API (`GET /me/player/queue`). Sign-in goes through the user's
/// own Spotify developer app with PKCE (no client secret) and lands on the
/// hook server's loopback port. It asks to read playback, to read and change
/// Liked Songs (for ♥) and to list playlists; the refresh token lives in the
/// login Keychain. Search needs no scope.
actor SpotifyAPI {
    static let shared = SpotifyAPI()
    static let redirectURI = "http://127.0.0.1:\(HookBridge.port)/spotify/callback"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    static let clientIDKey = "spotifyClientID"
    private static let scopes = ["user-read-playback-state", "user-read-currently-playing", "user-library-read",
                                 "user-library-modify", "playlist-read-private"].joined(separator: " ")

    enum Failure: LocalizedError {
        case notConnected, cancelled, staleLogin, refused, malformedClientID, unknownClientID, http(Int)

        var errorDescription: String? {
            switch self {
            case .notConnected: "Spotify isn't connected."
            case .cancelled: "Spotify sign-in was cancelled."
            case .staleLogin: "That sign-in link expired. Connect again."
            case .refused: "Spotify refused (403). Developer apps only work while their owner has Premium, for users on the app's allowlist."
            case .malformedClientID: "That isn't a Client ID. Copy the 32-character one from your app's page."
            case .unknownClientID: "Spotify doesn't know that Client ID. Check it on your app's page."
            case .http(let code): "Spotify answered \(code)."
            }
        }
    }

    struct Queue: Sendable {
        /// Title of the song Spotify thinks is playing. It lags a skip by a
        /// second or two, and until it catches up the queue is the old one.
        let current: String?
        let items: [QueueItem]
    }

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    /// What the current token allows. Logins from before a feature existed
    /// lack its scope until the user connects again.
    private var grantedScopes: Set<String> = []
    private var pending: (state: String, verifier: String, clientID: String)?
    private var userID: String?

    var isConnected: Bool { Keychain.read() != nil }

    /// The browser URL that starts sign-in; `finishLogin` completes it.
    func beginLogin(clientID: String) -> URL {
        let verifier = Self.randomString(64)
        let state = Self.randomString(24)
        pending = (state, verifier, clientID)
        UserDefaults.standard.set(clientID, forKey: Self.clientIDKey)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [.init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
                          .init(name: "redirect_uri", value: Self.redirectURI), .init(name: "scope", value: Self.scopes),
                          .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
                          .init(name: "state", value: state)]
        return url.url!
    }

    /// The redirect's query: `code` + `state` on success, `error` otherwise.
    func finishLogin(_ query: [String: String]) async throws {
        guard let pending, query["state"] == pending.state else { throw Failure.staleLogin }
        self.pending = nil
        guard let code = query["code"] else { throw Failure.cancelled }
        try await requestToken(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                                "client_id": pending.clientID, "code_verifier": pending.verifier])
    }

    /// Spotify's sign-in page only checks the Client ID after the user logs
    /// in, but its token endpoint checks it up front: a made-up code fails as
    /// `invalid_grant` for a real app and `invalid_client` for an unknown one.
    /// (A missing redirect URI can't be caught this way; Spotify only says so
    /// on its own page, after login.) Offline counts as fine: sign-in will tell.
    static func checkClientID(_ clientID: String) async throws {
        guard clientID.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { throw Failure.malformedClientID }
        let request = tokenRequest(["grant_type": "authorization_code", "code": "check", "redirect_uri": redirectURI,
                                    "client_id": clientID, "code_verifier": randomString(64)])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if body["error"] as? String == "invalid_client" { throw Failure.unknownClientID }
    }

    func cancelLogin() {
        pending = nil
    }

    func disconnect() {
        accessToken = nil
        expiresAt = .distantPast
        grantedScopes = []
        userID = nil
        Keychain.delete()
    }

    func queue() async throws -> Queue {
        let response = try await call("GET", "https://api.spotify.com/v1/me/player/queue")
        switch response.status {
        case 200: break
        case 204: return Queue(current: nil, items: [])
        case 403: throw Failure.refused
        default: throw Failure.http(response.status)
        }
        let body = try Self.decode(QueueBody.self, from: response.data)
        let items = body.queue.prefix(20).enumerated().map { index, item in
            QueueItem(id: index, title: item.name,
                      subtitle: item.artists?.map(\.name).joined(separator: ", ") ?? item.show?.name ?? "",
                      duration: (item.durationMs ?? 0) / 1000, artworkURL: item.thumbnail)
        }
        return Queue(current: body.currentlyPlaying?.name, items: items)
    }

    /// False when the login predates the feature that needs `scope`, and
    /// needs connecting again.
    func hasScope(_ scope: String) async -> Bool {
        guard (try? await validAccessToken()) != nil else { return false }
        return grantedScopes.contains(scope)
    }

    // MARK: Search and playlists

    /// Songs, then albums, then playlists. Developer apps get at most 10 per
    /// type; 5 keeps the column short.
    func search(_ query: String) async throws -> [SpotifyItem] {
        var url = URLComponents(string: "https://api.spotify.com/v1/search")!
        url.queryItems = [.init(name: "q", value: query), .init(name: "type", value: "track,album,playlist"), .init(name: "limit", value: "5")]
        let response = try await call("GET", url.string!)
        guard response.status == 200 else { throw response.status == 403 ? Failure.refused : Failure.http(response.status) }
        let body = try Self.decode(SearchBody.self, from: response.data)
        let tracks = (body.tracks?.items ?? []).compactMap { $0 }.compactMap { item -> SpotifyItem? in
            guard let uri = item.uri else { return nil }
            return SpotifyItem(uri: uri, kind: .track, title: item.name,
                               subtitle: item.artists?.map(\.name).joined(separator: ", ") ?? "", artworkURL: item.thumbnail)
        }
        let albums = (body.albums?.items ?? []).compactMap { $0 }.map { album in
            SpotifyItem(uri: album.uri, kind: .album, title: album.name,
                        subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "", artworkURL: Self.smallest(album.images))
        }
        let playlists = (body.playlists?.items ?? []).compactMap { $0 }.map(\.item)
        return tracks + albums + playlists
    }

    /// The 50 most recently liked songs, each set to play on through Liked
    /// Songs (`spotify:user:<id>:collection`) when the user id is known.
    func likedSongs() async throws -> [SpotifyItem] {
        let response = try await call("GET", "https://api.spotify.com/v1/me/tracks?limit=50")
        guard response.status == 200 else { throw response.status == 403 ? Failure.refused : Failure.http(response.status) }
        let context = await currentUserID().map { "spotify:user:\($0):collection" }
        return try Self.decode(Page<SavedTrack>.self, from: response.data).items.compactMap { saved -> SpotifyItem? in
            guard let track = saved?.track, let uri = track.uri else { return nil }
            return SpotifyItem(uri: uri, kind: .track, title: track.name,
                               subtitle: track.artists?.map(\.name).joined(separator: ", ") ?? "",
                               artworkURL: track.thumbnail, context: context)
        }
    }

    private func currentUserID() async -> String? {
        if let userID { return userID }
        struct Me: Decodable { let id: String }
        guard let response = try? await call("GET", "https://api.spotify.com/v1/me"), response.status == 200,
              let me = try? Self.decode(Me.self, from: response.data) else { return nil }
        userID = me.id
        return me.id
    }

    func playlists() async throws -> [SpotifyItem] {
        let response = try await call("GET", "https://api.spotify.com/v1/me/playlists?limit=50")
        guard response.status == 200 else { throw response.status == 403 ? Failure.refused : Failure.http(response.status) }
        return try Self.decode(Page<PlaylistBody>.self, from: response.data).items.compactMap { $0?.item }
    }

    // MARK: Liked Songs

    func isLiked(_ uri: String) async throws -> Bool {
        let response = try await call("GET", Self.libraryURL("contains", uri: uri))
        guard response.status == 200 else { throw response.status == 403 ? Failure.refused : Failure.http(response.status) }
        return (try JSONDecoder().decode([Bool].self, from: response.data)).first ?? false
    }

    func setLiked(_ uri: String, _ liked: Bool) async throws {
        let response = try await call(liked ? "PUT" : "DELETE", Self.libraryURL(nil, uri: uri))
        guard (200..<300).contains(response.status) else { throw response.status == 403 ? Failure.refused : Failure.http(response.status) }
    }

    private static func libraryURL(_ path: String?, uri: String) -> String {
        let encoded = uri.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uri
        return "https://api.spotify.com/v1/me/library" + (path.map { "/" + $0 } ?? "") + "?uris=" + encoded
    }

    // MARK: Tokens

    /// One API call, retried once with a fresh token if the old one was refused.
    private func call(_ method: String, _ url: String) async throws -> (status: Int, data: Data) {
        var response = try await send(method, url)
        if response.status == 401 {
            expiresAt = .distantPast
            response = try await send(method, url)
        }
        return response
    }

    private func send(_ method: String, _ url: String) async throws -> (status: Int, data: Data) {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, expiresAt > Date().addingTimeInterval(30) { return accessToken }
        guard let refresh = Keychain.read(), let clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) else {
            throw Failure.notConnected
        }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        guard let accessToken else { throw Failure.notConnected }
        return accessToken
    }

    private static func tokenRequest(_ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        return request
    }

    private func requestToken(_ form: [String: String]) async throws {
        let (data, response) = try await URLSession.shared.data(for: Self.tokenRequest(form))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 400 on a refresh means the grant was revoked (or the app deleted).
        if status == 400, form["grant_type"] == "refresh_token" {
            disconnect()
            throw Failure.notConnected
        }
        guard status == 200 else { throw Failure.http(status) }
        let token = try Self.decode(TokenBody.self, from: data)
        accessToken = token.accessToken
        expiresAt = Date().addingTimeInterval(token.expiresIn)
        if let scope = token.scope { grantedScopes = Set(scope.split(separator: " ").map(String.init)) }
        // Spotify may rotate the refresh token; the old one then stops working.
        if let refresh = token.refreshToken { Keychain.write(refresh) }
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    /// What the browser tab shows after Spotify sends it back.
    nonisolated static func callbackPage(for query: [String: String]) -> String {
        let message = query["code"] != nil
            ? "Finishing sign-in. You can close this tab; the notch shows when Spotify is connected."
            : "Spotify sign-in was cancelled. You can close this tab."
        return """
        <!doctype html><meta charset="utf-8"><title>Notch Agent</title>
        <body style="font: 15px -apple-system, sans-serif; background: #111; color: #eee; display: grid; place-items: center; height: 90vh">
        <p>\(message)</p>
        """
    }

    // MARK: Wire format

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    /// The smallest cover (Spotify sends 640, 300 and 64 px).
    private static func smallest(_ images: [Image]?) -> URL? {
        (images ?? []).min { ($0.width ?? .max) < ($1.width ?? .max) }.flatMap { URL(string: $0.url) }
    }

    private struct Image: Decodable { let url: String; let width: Int? }
    private struct Named: Decodable { let name: String }

    /// Spotify pages can hold `null` entries (e.g. a deleted playlist).
    private struct Page<T: Decodable>: Decodable { let items: [T?] }

    private struct SearchBody: Decodable {
        let tracks: Page<Item>?
        let albums: Page<AlbumBody>?
        let playlists: Page<PlaylistBody>?
    }

    private struct SavedTrack: Decodable { let track: Item? }

    private struct AlbumBody: Decodable {
        let name: String
        let uri: String
        let images: [Image]?
        let artists: [Named]?
    }

    private struct PlaylistBody: Decodable {
        struct Owner: Decodable { let displayName: String? }
        let name: String
        let uri: String
        let images: [Image]?
        let owner: Owner?

        var item: SpotifyItem {
            SpotifyItem(uri: uri, kind: .playlist, title: name, subtitle: owner?.displayName ?? "", artworkURL: SpotifyAPI.smallest(images))
        }
    }

    private struct TokenBody: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?
        let scope: String?
    }

    private struct QueueBody: Decodable {
        let currentlyPlaying: Item?
        let queue: [Item]
    }

    /// A track, or a podcast episode (which has a show and its own images).
    private struct Item: Decodable {
        struct Album: Decodable { let images: [Image]? }

        let name: String
        let uri: String?
        let durationMs: Double?
        let artists: [Named]?
        let album: Album?
        let show: Named?
        let images: [Image]?

        var thumbnail: URL? { SpotifyAPI.smallest(album?.images ?? images) }
    }
}

/// The refresh token, through `/usr/bin/security` like Claude Code's own
/// credentials in Limits.swift: the item then trusts that tool rather than
/// this binary, so dev builds and the installed app share it without prompts.
private enum Keychain {
    private static let service = "Notch Agent Spotify"

    static func read() -> String? {
        let output = security(["find-generic-password", "-s", service, "-w"])
        return output?.isEmpty == false ? output : nil
    }

    /// The token goes in on stdin (`security -i`), not as an argument,
    /// where any process could read it from `ps` while it ran.
    static func write(_ token: String) {
        // Spotify tokens are URL-safe; anything else can't be quoted safely
        // for `-i`, so it falls back to the argument (still saved, not lost).
        guard token.range(of: "^[A-Za-z0-9._~+/=-]+$", options: .regularExpression) != nil else {
            security(["add-generic-password", "-U", "-s", service, "-a", "spotify", "-w", token])
            return
        }
        security(["-i"], input: "add-generic-password -U -s \"\(service)\" -a spotify -w \"\(token)\"\n")
    }

    static func delete() {
        security(["delete-generic-password", "-s", service])
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
