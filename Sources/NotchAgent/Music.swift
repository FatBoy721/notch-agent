import AppKit
import SwiftUI

/// What's playing in Apple Music or Spotify, read through each app's
/// AppleScript dictionary (the system-wide Now Playing API is closed to
/// third-party apps). Only apps that are already running are asked, so the
/// notch never launches a player.
struct NowPlaying: Equatable {
    enum Player: String {
        case music = "Music", spotify = "Spotify"

        var bundleID: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            }
        }
    }

    let player: Player
    let title: String
    let artist: String
    let album: String
    let duration: Double
    var position: Double
    var playing: Bool
    var volume: Double
    var artworkURL: String?
    /// Spotify's id for the track, e.g. "spotify:track:…" (nil for Music).
    var uri: String?
    /// nil when unknown. Spotify has no ♥ over AppleScript; its value comes
    /// from the Web API once connected.
    var favorite: Bool?
    var shuffle: Bool?
    var sampledAt = Date()

    var trackKey: String { [player.rawValue, title, artist, album].joined(separator: "|") }

    /// Extrapolated between samples so the progress bar and lyrics move smoothly.
    func position(at date: Date) -> Double {
        min(duration, playing ? position + date.timeIntervalSince(sampledAt) : position)
    }

    /// The same playback as `other`, just sampled later: nothing changed but
    /// the clock. Republishing that every second would redraw the whole notch.
    func continues(_ other: NowPlaying?, at date: Date) -> Bool {
        guard let other else { return false }
        var aligned = self
        aligned.position = other.position
        aligned.sampledAt = other.sampledAt
        return aligned == other && abs(position - other.position(at: date)) < 0.75
    }
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

@MainActor
final class MusicStore: ObservableObject {
    enum LyricsStatus { case none, loading, synced, plain, missing }
    /// The column beside the player card.
    enum Panel { case lyrics, upNext, browse }
    /// `checking`: the Client ID, before the browser opens. `connecting`: signing in there.
    enum SpotifyLink: Equatable { case off, checking, connecting, on, failed(String) }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent = Color(white: 0.65)
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var lyricsStatus: LyricsStatus = .none
    /// The synced line being sung. Changes exactly when the next line is due
    /// (not on a polling tick), so the notch can animate to it in step.
    @Published private(set) var lyricLine: LyricLine?
    private var lineTask: Task<Void, Never>?
    @Published var panel: Panel? = .lyrics
    /// Spotify's queue; nil until it has been read for the current track.
    @Published private(set) var upNext: [QueueItem]?
    @Published private(set) var spotify: SpotifyLink = .off
    /// Search and playlists, for the browse column.
    let browser = SpotifyBrowser()
    private var trackKey: String?
    private var task: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var queueDueAt = Date.distantPast
    /// Reads this track whose "now playing" didn't match ours yet.
    private var queueMisses = 0
    /// ♥ on Spotify, from its Liked Songs; nil until read for this track.
    private var spotifyLiked: Bool?
    private var likedKey: String?
    private var likeTask: Task<Void, Never>?
    /// The Spotify login predates ♥, so the heart asks to connect once more.
    @Published private(set) var likeNeedsPermission = false

    var isPlaying: Bool { nowPlaying?.playing == true }

    /// The Music page is on screen: its progress, volume and shuffle are
    /// being looked at, so the player is read every second.
    var watching = false {
        didSet { if watching && !oldValue { Task { await requestPoll() } } }
    }
    private var polling = false
    private var pollAgain = false

    /// Spotify and Music announce every play, pause and track change, so
    /// the player is read when they do, plus a slow check for what they
    /// don't announce (volume, drift). Reading it every second meant an
    /// osascript launch per second, all day.
    private var pollInterval: TimeInterval {
        watching ? 1 : isPlaying ? 5 : 15
    }

    func start() {
        guard task == nil else { return }
        Task {
            if await SpotifyAPI.shared.isConnected, spotify == .off { spotify = .on }
        }
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { await self?.requestPoll() }
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.requestPoll()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 5))
            }
        }
    }

    /// One read at a time; a request during a read runs once more after it,
    /// so a notification never gets an answer from before it.
    private func requestPoll() async {
        if polling {
            pollAgain = true
            return
        }
        polling = true
        repeat {
            pollAgain = false
            await poll()
        } while pollAgain
        polling = false
    }

    /// Where the user is dragging the progress bar; the clock and lyrics
    /// show this until they let go.
    @Published private(set) var scrubPosition: Double?

    private func currentLine(at date: Date) -> LyricLine? {
        guard lyricsStatus == .synced, let position = scrubPosition ?? nowPlaying?.position(at: date) else { return nil }
        return lyrics.last { $0.time <= position + 0.15 }
    }

    /// Dragging along the progress bar: lyrics follow at once; the player
    /// jumps there on release (seeking on every move would stutter it).
    func scrub(to seconds: Double) {
        scrubPosition = seconds
        scheduleLyricLine()
    }

    func endScrub(at seconds: Double) {
        scrubPosition = nil
        // Shown at once; the next read of the player confirms it.
        nowPlaying?.position = seconds
        nowPlaying?.sampledAt = Date()
        seek(to: seconds)
        scheduleLyricLine()
    }

    // MARK: Controls

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }
    func seek(to seconds: Double) { send("set player position to \(String(format: "%.2f", seconds))") }
    func setVolume(_ volume: Double) { send("set sound volume to \(Int(volume))") }

    func toggleFavorite() {
        guard let track = nowPlaying else { return }
        switch track.player {
        case .music:
            guard let favorite = track.favorite else { return }
            send("set favorited of current track to \(!favorite)")
        case .spotify:
            if likeNeedsPermission {
                reconnectSpotify()
                return
            }
            guard let uri = track.uri, let liked = spotifyLiked else { return }
            setSpotifyLiked(!liked)
            Task {
                do {
                    try await SpotifyAPI.shared.setLiked(uri, !liked)
                } catch {
                    EventLog.write("spotify like: \(error.localizedDescription)")
                    guard trackKey == track.trackKey else { return }
                    setSpotifyLiked(liked)
                    if case SpotifyAPI.Failure.refused = error { likeNeedsPermission = true }
                }
            }
        }
    }

    func toggleShuffle() {
        guard let track = nowPlaying, let shuffle = track.shuffle else { return }
        send(track.player == .music ? "set shuffle enabled to \(!shuffle)" : "set shuffling to \(!shuffle)")
    }

    /// Brings the player forward (its queue and library live there).
    func openPlayer() {
        guard let track = nowPlaying,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: track.player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String) {
        guard let player = nowPlaying?.player else { return }
        Task {
            _ = await Task.detached { MusicBridge.run("tell application \"\(player.rawValue)\" to \(command)") }.value
            await requestPoll()
        }
    }

    // MARK: Spotify

    /// Opens Spotify's sign-in page; the redirect comes back through the hook
    /// server to `finishSpotifyLogin`.
    func connectSpotify(clientID: String) {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, spotify != .checking else { return }
        spotify = .checking
        Task {
            do {
                try await SpotifyAPI.checkClientID(clientID)
            } catch {
                spotify = .failed(error.localizedDescription)
                return
            }
            spotify = .connecting
            NSWorkspace.shared.open(await SpotifyAPI.shared.beginLogin(clientID: clientID))
        }
    }

    /// Signs in again with the saved Client ID, to grant scopes added since.
    func reconnectSpotify() {
        guard let clientID = UserDefaults.standard.string(forKey: SpotifyAPI.clientIDKey) else { return }
        connectSpotify(clientID: clientID)
    }

    /// Plays a song, album or playlist in the Spotify app, optionally inside
    /// a context (a liked song in Liked Songs) so playback carries on there.
    func playOnSpotify(_ uri: String, context: String? = nil) {
        // Spotify URIs only, so nothing can break out of the AppleScript string.
        let pattern = "^spotify(:[A-Za-z0-9._-]+)+$"
        guard uri.range(of: pattern, options: .regularExpression) != nil else { return }
        let inContext = context.flatMap { $0.range(of: pattern, options: .regularExpression) != nil ? " in context \"\($0)\"" : nil } ?? ""
        Task {
            _ = await Task.detached { MusicBridge.run("tell application \"Spotify\" to play track \"\(uri)\"\(inContext)") }.value
            await requestPoll()
        }
    }

    func finishSpotifyLogin(_ query: [String: String]) {
        guard spotify == .connecting else { return }
        Task {
            do {
                try await SpotifyAPI.shared.finishLogin(query)
                spotify = .on
                likedKey = nil
                likeNeedsPermission = false
                browser.reset()
                queueDueAt = .distantPast
                refreshQueueIfDue()
            } catch {
                spotify = .failed(error.localizedDescription)
            }
        }
    }

    /// Back to where it was: connecting again (for ♥) keeps the old login.
    func cancelSpotifyLogin() {
        Task {
            await SpotifyAPI.shared.cancelLogin()
            spotify = await SpotifyAPI.shared.isConnected ? .on : .off
        }
    }

    func disconnectSpotify() {
        spotify = .off
        upNext = nil
        spotifyLiked = nil
        likedKey = nil
        likeNeedsPermission = false
        browser.reset()
        Task { await SpotifyAPI.shared.disconnect() }
    }

    /// Every 15 s while Spotify plays, sooner right after a skip: Spotify's
    /// API takes a moment to catch up, and until then its queue is the old one.
    private func refreshQueueIfDue() {
        guard spotify == .on, queueTask == nil, Date() >= queueDueAt,
              let track = nowPlaying, track.player == .spotify else { return }
        queueTask = Task {
            defer { queueTask = nil }
            do {
                let queue = try await SpotifyAPI.shared.queue()
                guard trackKey == track.trackKey else { return }
                // After a few misses take it anyway (titles can differ, e.g. local files).
                let caughtUp = queue.current == nil || queue.current == track.title || queueMisses >= 3
                if caughtUp { upNext = queue.items } else { queueMisses += 1 }
                queueDueAt = Date().addingTimeInterval(caughtUp ? 15 : 2)
            } catch SpotifyAPI.Failure.notConnected {
                spotify = .off
                upNext = nil
            } catch SpotifyAPI.Failure.refused {
                spotify = .failed(SpotifyAPI.Failure.refused.localizedDescription)
            } catch {
                // Rate limits, network: keep what's shown and back off.
                EventLog.write("spotify queue: \(error.localizedDescription)")
                queueDueAt = Date().addingTimeInterval(60)
            }
        }
    }

    private func canLikeOnSpotify(_ track: NowPlaying) -> Bool {
        spotify == .on && track.player == .spotify
            && (track.uri?.hasPrefix("spotify:track:") == true || track.uri?.hasPrefix("spotify:episode:") == true)
    }

    private func setSpotifyLiked(_ liked: Bool) {
        spotifyLiked = liked
        nowPlaying?.favorite = liked
    }

    /// Once per track: is it in Liked Songs?
    private func refreshLikeIfNeeded(_ track: NowPlaying) {
        guard likedKey != track.trackKey, likeTask == nil, let uri = track.uri else { return }
        likeTask = Task {
            defer { likeTask = nil }
            guard await SpotifyAPI.shared.hasScope("user-library-modify") else {
                likeNeedsPermission = true
                likedKey = track.trackKey
                return
            }
            likeNeedsPermission = false
            do {
                let liked = try await SpotifyAPI.shared.isLiked(uri)
                guard trackKey == track.trackKey else { return }
                likedKey = track.trackKey
                setSpotifyLiked(liked)
            } catch {
                // Not retried every second; the next track tries again.
                EventLog.write("spotify liked check: \(error.localizedDescription)")
                likedKey = track.trackKey
                if case SpotifyAPI.Failure.refused = error { likeNeedsPermission = true }
            }
        }
    }

    // MARK: Polling

    private func poll() async {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let players = [NowPlaying.Player.music, .spotify].filter { running.contains($0.bundleID) }
        guard !players.isEmpty else {
            if nowPlaying != nil { nowPlaying = nil }
            return
        }
        var reading = await Task.detached { MusicBridge.read(players) }.value
        if reading?.trackKey != trackKey {
            trackKey = reading?.trackKey
            artwork = nil
            accent = Color(white: 0.65)
            lyrics = []
            lyricsStatus = .none
            upNext = nil
            queueDueAt = .distantPast
            queueMisses = 0
            spotifyLiked = nil
            if let reading {
                loadArtwork(for: reading)
                loadLyrics(for: reading)
            }
        }
        if let track = reading, canLikeOnSpotify(track) {
            reading?.favorite = likeNeedsPermission ? false : spotifyLiked
        }
        if reading?.continues(nowPlaying, at: Date()) != true { nowPlaying = reading }
        scheduleLyricLine()
        if let track = reading, canLikeOnSpotify(track) { refreshLikeIfNeeded(track) }
        refreshQueueIfDue()
    }

    private func loadArtwork(for track: NowPlaying) {
        Task {
            let image = await Task.detached { await MusicBridge.artwork(for: track) }.value
            guard trackKey == track.trackKey, let image else { return }
            artwork = image
            accent = image.accentColor
        }
    }

    private func loadLyrics(for track: NowPlaying) {
        lyricsStatus = .loading
        Task {
            let found = await Lyrics.fetch(for: track)
            guard trackKey == track.trackKey else { return }
            switch found {
            case .synced(let lines): lyrics = lines; lyricsStatus = .synced
            case .plain(let lines): lyrics = lines; lyricsStatus = .plain
            case nil: lyricsStatus = .missing
            }
            scheduleLyricLine()
        }
    }

    /// Sets the current line and sleeps until the next one is due. Every poll
    /// reschedules it, which also corrects for seeks and pauses.
    private func scheduleLyricLine() {
        lineTask?.cancel()
        let now = Date()
        let line = currentLine(at: now)
        if line != lyricLine { lyricLine = line }
        guard lyricsStatus == .synced, scrubPosition == nil, let track = nowPlaying, track.playing else { return }
        let position = track.position(at: now)
        guard let next = lyrics.first(where: { $0.time > position + 0.15 }) else { return }
        let delay = max(0.01, next.time - 0.15 - position)
        lineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.scheduleLyricLine()
        }
    }
}

// MARK: - AppleScript

enum MusicBridge {
    private static let separator = "(ASCII character 9)"

    static func read(_ players: [NowPlaying.Player]) -> NowPlaying? {
        let readings = players.compactMap(read)
        return readings.first(where: \.playing) ?? readings.first
    }

    private static func read(_ player: NowPlaying.Player) -> NowPlaying? {
        let fields = ["name of t", "artist of t", "album of t",
                      player == .spotify ? "((duration of t) / 1000)" : "(duration of t)",
                      "player position", "(player state as text)", "sound volume",
                      player == .spotify ? "(artwork url of t)" : "\"\"",
                      player == .spotify ? "(id of t)" : "\"\""]
        // ♥ and shuffle in `try` blocks: their names differ between player
        // versions, and a missing one shouldn't lose the whole reading.
        let favorite = player == .music ? "favorited of t" : "missing value"
        let shuffle = player == .music ? "shuffle enabled" : "shuffling"
        let script = """
        tell application "\(player.rawValue)"
            if player state is stopped then return ""
            set t to current track
            set fav to "?"
            try
                set fav to (\(favorite)) as text
            end try
            set shuf to "?"
            try
                set shuf to (\(shuffle)) as text
            end try
            return \(fields.map { "(\($0) as text)" }.joined(separator: " & \(separator) & ")) & \(separator) & fav & \(separator) & shuf
        end tell
        """
        guard let output = run(script), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "\t")
        guard parts.count >= 11 else { return nil }
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        func flag(_ text: String) -> Bool? { text == "true" ? true : text == "false" ? false : nil }
        return NowPlaying(player: player, title: parts[0], artist: parts[1], album: parts[2],
                          duration: number(parts[3]), position: number(parts[4]), playing: parts[5] == "playing",
                          volume: number(parts[6]), artworkURL: parts[7].isEmpty ? nil : parts[7],
                          uri: parts[8].isEmpty ? nil : parts[8], favorite: flag(parts[9]), shuffle: flag(parts[10]))
    }

    static func artwork(for track: NowPlaying) async -> NSImage? {
        if let url = track.artworkURL.flatMap(URL.init(string:)) {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        // Music hands artwork back as «data tdta89504E47…»: a type code, then hex.
        guard let output = run("tell application \"Music\" to get raw data of artwork 1 of current track"),
              let start = output.range(of: "«data ") else { return nil }
        let hex = output[start.upperBound...].dropFirst(4).prefix { $0 != "»" }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return NSImage(data: data)
    }

    @discardableResult
    static func run(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

// MARK: - Lyrics

/// Time-synced lyrics from LRCLIB, a free, open lyrics database. Only the
/// track's title, artist, album and length are sent.
enum Lyrics {
    enum Result {
        case synced([LyricLine])
        case plain([LyricLine])
    }

    private struct Record: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    static func fetch(for track: NowPlaying) async -> Result? {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [.init(name: "track_name", value: track.title), .init(name: "artist_name", value: track.artist),
                            .init(name: "album_name", value: track.album), .init(name: "duration", value: String(Int(track.duration)))]
        if let record: Record = await get(exact.url), let result = parse(record) { return result }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [.init(name: "track_name", value: track.title), .init(name: "artist_name", value: track.artist)]
        guard let records: [Record] = await get(search.url) else { return nil }
        return records.lazy.compactMap(parse).first
    }

    private static func get<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("NotchAgent/0.1 (personal notch app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func parse(_ record: Record) -> Result? {
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines).enumerated().map { LyricLine(id: $0, time: 0, text: $1) })
        }
        return nil
    }

    /// "[01:23.45] words" lines; blank timed lines become "♪" breaks.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                if stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for time in times { lines.append((time, words.isEmpty ? "♪" : words)) }
        }
        return lines.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0, time: $1.0, text: $1.1) }
    }
}

private extension NSImage {
    /// The artwork's average color, lifted so it reads on black.
    var accentColor: Color {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Color(white: 0.65) }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Color(white: 0.65)
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let average = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(1, saturation * 1.3), brightness: max(0.75, brightness))
    }
}

// MARK: - Views

/// The closed notch while music plays: the title on the left and artist on
/// the right until the singing starts, then each lyric line read across the
/// notch, its first half on the left and the rest on the right.
@MainActor
struct MusicTab {
    static let textSize: CGFloat = 12.5
    /// Widest a side gets; past it the text shrinks (to 75 %) before it's
    /// cut, so lines up to ~90 characters fit whole.
    static let maxHalf: CGFloat = 230
    static let minimumScale: CGFloat = 0.75

    /// A sung line is showing (not the title, or a "♪" break).
    static func isSinging(_ music: MusicStore) -> Bool {
        music.lyricLine.map { $0.text != "♪" } ?? false
    }

    /// What the two sides say right now.
    static func halves(_ music: MusicStore) -> (left: String, right: String) {
        if isSinging(music), let line = music.lyricLine?.text { return split(line) }
        guard let track = music.nowPlaying else { return ("", "") }
        return (track.title, track.artist)
    }

    /// Each side's width: cover + text on the left, text + bars on the right.
    static func wing(_ music: MusicStore) -> CGFloat {
        let (left, right) = halves(music)
        let leftWidth = 20 + 6 + min(maxHalf, textWidth(left, size: textSize))
        let rightWidth = min(maxHalf, textWidth(right, size: textSize)) + 6 + 18
        return max(44, leftWidth, rightWidth)
    }

    /// Splits at the word boundary that balances the two sides' widths.
    static func split(_ line: String) -> (String, String) {
        let words = line.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (line, "") }
        var best = (index: 1, difference: CGFloat.infinity)
        for index in 1..<words.count {
            let left = textWidth(words[..<index].joined(separator: " "), size: textSize)
            let right = textWidth(words[index...].joined(separator: " "), size: textSize)
            if abs(left - right) < best.difference { best = (index, abs(left - right)) }
        }
        return (words[..<best.index].joined(separator: " "), words[best.index...].joined(separator: " "))
    }
}

/// Cover at the edge; the text runs up to the notch.
struct MusicTabLeft: View {
    @ObservedObject var music: MusicStore

    var body: some View {
        HStack(spacing: 6) {
            Artwork(image: music.artwork, size: 20, radius: 5)
            Spacer(minLength: 0)
            Text(MusicTab.halves(music).left)
                .foregroundStyle(.white)
                .minimumScaleFactor(MusicTab.minimumScale)
                .truncationMode(.head)
                .frame(maxWidth: MusicTab.maxHalf, alignment: .trailing)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The text continues from the notch; the bars sit at the edge.
struct MusicTabRight: View {
    @ObservedObject var music: MusicStore

    var body: some View {
        // Animated by the notch along with its width (NotchView), so the
        // line and the tab around it change in one motion.
        HStack(spacing: 6) {
            Text(MusicTab.halves(music).right)
                .foregroundStyle(MusicTab.isSinging(music) ? .white : .white.opacity(0.6))
                .minimumScaleFactor(MusicTab.minimumScale)
                .truncationMode(.tail)
                .frame(maxWidth: MusicTab.maxHalf, alignment: .leading)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            LevelBars(color: music.accent, playing: music.isPlaying, height: 12)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Artwork: View {
    let image: NSImage?
    var size: CGFloat = 52
    var radius: CGFloat = 10

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(Palette.mute))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: .black.opacity(0.35), radius: size > 30 ? 8 : 0, y: size > 30 ? 4 : 0)
    }
}

/// The player, laid out like Drop Notch's: a 324pt card (cover, progress,
/// controls, volume) with lyrics or Up Next in a column beside it.
struct MusicPage: View {
    @ObservedObject var music: MusicStore
    @ObservedObject var ui: NotchUI

    /// The notch's width for this page: narrow for the card alone, wide with a column.
    static func panelWidth(_ music: MusicStore) -> CGFloat {
        music.nowPlaying != nil && music.panel != nil ? 660 : 380
    }

    var body: some View {
        if let track = music.nowPlaying {
            HStack(alignment: .center, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Artwork(image: music.artwork)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text(track.artist).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.46)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        LevelBars(color: music.accent, playing: track.playing, height: 16)
                        Button {
                            music.panel = music.panel == .browse ? nil : .browse
                        } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .bold))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(music.panel == .browse ? 0.24 : 0.12), in: Circle())
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .buttonStyle(.plain)
                        .help("Search and playlists")
                        Button {
                            ui.tabSide = .agents
                            ui.page = .threads
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.12), in: Circle())
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .buttonStyle(.plain)
                        .help("Close the player")
                    }
                    Progress(music: music, track: track).padding(.top, 13)
                    Controls(music: music, track: track).padding(.top, 8)
                    VolumeRow(music: music, track: track).padding(.top, 12)
                }
                .frame(width: 324)
                if let panel = music.panel {
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1).padding(.leading, 18).padding(.vertical, 4)
                    Group {
                        switch panel {
                        case .lyrics: LyricsView(music: music)
                        case .upNext: UpNextView(music: music, track: track)
                        case .browse: BrowseView(music: music, browser: music.browser)
                        }
                    }
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .offset(x: -8)))
                }
            }
            .animation(Motion.calm, value: music.panel)
            .onAppear { music.watching = true }
            .onDisappear { music.watching = false }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(Palette.mute)
                Text("Nothing playing").font(.system(size: 13.5, weight: .semibold))
                Text("Play something in Music or Spotify and it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(Palette.mute)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }
}

private struct Progress: View {
    @ObservedObject var music: MusicStore
    let track: NowPlaying
    @State private var fraction: Double = 0
    /// Bumped by each aim, so a slide queued by an older one doesn't run.
    @State private var aimed = 0

    var body: some View {
        // The bar is one linear animation to the song's end, re-aimed when
        // playback changes (seek, pause, next): it glides at the display's
        // refresh rate without re-laying out the notch each frame. The
        // clocks tick once a second, on the song's own second boundaries.
        let secondStart = track.sampledAt.addingTimeInterval(-track.position.truncatingRemainder(dividingBy: 1))
        TimelineView(.periodic(from: secondStart, by: 1)) { context in
            let position = music.scrubPosition ?? track.position(at: context.date)
            HStack(spacing: 10) {
                Text(clock(position)).frame(width: 36, alignment: .leading)
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.14))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.85))
                                .offset(x: -proxy.size.width * (1 - fraction))
                        }
                        .clipShape(Capsule())
                        .scaleEffect(y: music.scrubPosition == nil ? 1 : 1.75)
                        .animation(.easeOut(duration: 0.15), value: music.scrubPosition == nil)
                        // Taller hit area than the 4 pt bar, so it's easy to grab.
                        .frame(height: 16)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag in scrub(to: drag.location.x / proxy.size.width) }
                            .onEnded { drag in
                                let seconds = track.duration * min(1, max(0, drag.location.x / proxy.size.width))
                                music.endScrub(at: seconds)
                            })
                }
                .frame(height: 16)
                Text("-" + clock(max(0, track.duration - position))).frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.46))
        }
        .onChange(of: track, initial: true) { _, track in aim(track) }
    }

    /// Follows the finger exactly while dragging (a click is a drag that
    /// doesn't move).
    private func scrub(to unit: Double) {
        let unit = min(1, max(0, unit))
        aimed += 1
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) { fraction = unit }
        music.scrub(to: track.duration * unit)
    }

    /// Jumps to where playback is, then (if playing) animates to the end.
    private func aim(_ track: NowPlaying) {
        guard track.duration > 0 else { return }
        let position = track.position(at: Date())
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) { fraction = min(1, position / track.duration) }
        aimed += 1
        guard track.playing else { return }
        let remaining = max(0.1, track.duration - position)
        let generation = aimed
        DispatchQueue.main.async {
            guard generation == aimed else { return }
            withAnimation(.linear(duration: remaining)) { fraction = 1 }
        }
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct Controls: View {
    @ObservedObject var music: MusicStore
    let track: NowPlaying
    /// Up Next needs setting up first, so until it's been opened once a dot
    /// on its button points the way.
    @AppStorage("upNextOpened") private var upNextOpened = false

    private var upNextBadge: Bool {
        !upNextOpened && track.player == .spotify && music.spotify != .on
    }

    var body: some View {
        ZStack {
            HStack(spacing: 17) {
                control("backward.fill", size: 16) { music.previous() }
                control(track.playing ? "pause.fill" : "play.fill", size: 24) { music.playPause() }
                control("forward.fill", size: 16) { music.next() }
            }
            HStack(spacing: 2) {
                side("list.bullet", on: music.panel == .upNext, badge: upNextBadge,
                     help: upNextBadge ? "Up Next: connect Spotify to see what's queued" : "Up Next") { toggle(.upNext) }
                side("quote.bubble.fill", on: music.panel == .lyrics, help: "Lyrics") { toggle(.lyrics) }
                Spacer()
                if let favorite = track.favorite {
                    Button { music.toggleFavorite() } label: {
                        Image(systemName: favorite ? "heart.fill" : "heart")
                            .font(.system(size: 15))
                            .foregroundStyle(favorite ? Color(red: 0.96, green: 0.31, blue: 0.44) : .white.opacity(0.72))
                            .frame(width: 32, height: 32)
                    }
                    .help(music.likeNeedsPermission ? "Like on Spotify (connect once more to allow it)"
                          : favorite ? "Unfavorite" : "Favorite")
                }
                if let shuffle = track.shuffle {
                    side("shuffle", on: shuffle, help: "Shuffle") { music.toggleShuffle() }
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func toggle(_ panel: MusicStore.Panel) {
        music.panel = music.panel == panel ? nil : panel
        if panel == .upNext { upNextOpened = true }
    }

    private func control(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(.white.opacity(0.97)).frame(width: 46, height: 36)
        }
    }

    private func side(_ icon: String, on: Bool, badge: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(on ? .white.opacity(0.97) : .white.opacity(0.46))
                .frame(width: 32, height: 32)
                .background(.white.opacity(on ? 0.16 : 0), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(music.accent).frame(width: 6, height: 6).padding(6) }
                }
        }
        .help(help)
    }
}

private struct VolumeRow: View {
    @ObservedObject var music: MusicStore
    let track: NowPlaying

    var body: some View {
        HStack(spacing: 10) {
            Button { music.openPlayer() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "airplay.audio").font(.system(size: 11))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .frame(width: 38, height: 25)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Output: choose in \(track.player.rawValue)")
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 12))
            Slider(value: Binding(get: { track.volume }, set: { music.setVolume($0) }), in: 0...100)
                .controlSize(.mini)
                .tint(.white)
        }
        .foregroundStyle(.white.opacity(0.72))
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(Motion.calm, value: configuration.isPressed)
    }
}

/// Karaoke: the current line large and lit, the rest dim, scrolling with
/// the song.
private struct LyricsView: View {
    @ObservedObject var music: MusicStore

    var body: some View {
        Group {
            switch music.lyricsStatus {
            case .synced, .plain:
                let current = music.lyricLine
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(music.lyrics) { line in
                                let isCurrent = line.id == current?.id
                                // One font size, scaled: a scale animates on the GPU,
                                // where a font change re-lays out every line and jumps.
                                Text(line.text)
                                    .font(.system(size: 17, weight: .bold))
                                    .scaleEffect(isCurrent || music.lyricsStatus == .plain ? 1 : 0.84)
                                    .foregroundStyle(.white.opacity(isCurrent || music.lyricsStatus == .plain ? 1 : 0.34))
                                    .shadow(color: .white.opacity(isCurrent ? 0.45 : 0), radius: 7)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 1)
                                    .id(line.id)
                                    .onTapGesture { if music.lyricsStatus == .synced { music.seek(to: line.time) } }
                            }
                        }
                        .padding(.vertical, 50)
                    }
                    .onChange(of: current?.id, initial: true) { _, id in
                        guard let id else { return }
                        withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.55)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .animation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.45), value: current?.id)
            case .loading:
                Text("Finding lyrics…").font(.system(size: 12.5)).foregroundStyle(Palette.mute)
            case .missing, .none:
                Text("No lyrics found for this song").font(.system(size: 12.5)).foregroundStyle(Palette.mute)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

/// Spotify's queue, or the one-time setup that unlocks it.
private struct UpNextView: View {
    @ObservedObject var music: MusicStore
    let track: NowPlaying

    var body: some View {
        Group {
            if track.player != .spotify {
                PanelNote(title: "Up Next works with Spotify", detail: "Music doesn't share its queue with other apps.") {
                    Button("Open Music") { music.openPlayer() }
                }
            } else {
                SpotifyGate(music: music) { queue }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    @ViewBuilder private var queue: some View {
        if let items = music.upNext {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Up Next").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.mute)
                    Spacer()
                    Menu {
                        Button("Disconnect Spotify") { music.disconnectSpotify() }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.mute)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if items.isEmpty {
                    Text("Nothing queued").font(.system(size: 12.5)).foregroundStyle(Palette.mute)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FadingList {
                        ForEach(items) { item in
                            MediaRow(title: item.title, subtitle: item.subtitle, artworkURL: item.artworkURL,
                                     trailing: String(format: "%d:%02d", Int(item.duration) / 60, Int(item.duration) % 60))
                        }
                    }
                }
            }
        } else {
            ArcSpinner(size: 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Shows `content` once Spotify is connected; until then the setup steps,
/// or the wait for the browser sign-in.
struct SpotifyGate<Content: View>: View {
    @ObservedObject var music: MusicStore
    @ViewBuilder let content: Content

    var body: some View {
        switch music.spotify {
        case .on:
            content
        case .connecting:
            PanelNote(title: "Finish signing in to Spotify in your browser",
                      detail: "If it says \"Invalid redirect URI\", add the URI to your app's settings, then connect again.") {
                HStack(spacing: 14) {
                    CopyRedirectURI()
                    Button("Cancel") { music.cancelSpotifyLogin() }
                }
            }
        case .off, .checking, .failed:
            SpotifySetup(music: music)
        }
    }
}

/// A short centered message with link buttons, filling a music column.
struct PanelNote<Actions: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Palette.mute) }
            actions.buttonStyle(.link).font(.system(size: 12))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A scrolling column of rows whose bottom edge fades out.
struct FadingList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) { content }
                .padding(.bottom, 16)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

/// Cover, title and subtitle, with text (a length) or a play button on the
/// right. Rows with an action highlight on hover and play on click.
struct MediaRow: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    /// Drawn instead of a cover, e.g. Liked Songs' heart.
    var symbol: String?
    var trailing: String?
    /// Shown on hover for rows with an action.
    var actionSymbol = "play.fill"
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Group {
                if let symbol {
                    LinearGradient(colors: [Color(red: 0.27, green: 0.2, blue: 0.85), Color(red: 0.55, green: 0.75, blue: 0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                } else {
                    AsyncImage(url: artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.46)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: actionSymbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(hovering ? 0.9 : 0))
            } else if let trailing {
                Text(trailing).font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.46))
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

/// Spotify only shares its queue with a signed-in developer app, and those
/// are per person: the user makes their own (free, but the owner needs
/// Premium) and pastes its Client ID here. One step per row, one button each.
private struct SpotifySetup: View {
    @ObservedObject var music: MusicStore
    @State private var clientID = UserDefaults.standard.string(forKey: SpotifyAPI.clientIDKey) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text("See what's next from Spotify").font(.system(size: 13, weight: .semibold))
                Text("One-time setup, about 3 minutes. Needs Spotify Premium.")
                    .font(.system(size: 11)).foregroundStyle(Palette.mute)
            }
            .padding(.bottom, 2)
            step(1, "Create an app, tick Web API") {
                Button("Open ↗") { NSWorkspace.shared.open(SpotifyAPI.dashboardURL) }
            }
            step(2, "Add this redirect URI") { CopyRedirectURI() }
            HStack(spacing: 8) {
                number(3)
                TextField("Paste its Client ID", text: $clientID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .onSubmit { music.connectSpotify(clientID: clientID) }
                if music.spotify == .checking {
                    ArcSpinner(size: 13).frame(width: 52)
                } else {
                    Button("Connect") { music.connectSpotify(clientID: clientID) }
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if case .failed(let message) = music.spotify {
                Text(message).font(.system(size: 11)).foregroundStyle(Palette.warn).lineLimit(2)
            }
        }
        .font(.system(size: 12))
        .buttonStyle(.link)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func step(_ index: Int, _ text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 8) {
            number(index)
            Text(text).lineLimit(1)
            Spacer(minLength: 4)
            action()
        }
    }

    private func number(_ index: Int) -> some View {
        Text("\(index)")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 16, height: 16)
            .background(.white.opacity(0.12), in: Circle())
            .foregroundStyle(.white.opacity(0.72))
    }
}

private struct CopyRedirectURI: View {
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied ✓" : "Copy URI") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SpotifyAPI.redirectURI, forType: .string)
            copied = true
        }
        .help(SpotifyAPI.redirectURI)
    }
}
