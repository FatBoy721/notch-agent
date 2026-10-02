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
    /// nil when the player doesn't say (Spotify has no ♥ over AppleScript).
    var favorite: Bool?
    var shuffle: Bool?
    var sampledAt = Date()

    var trackKey: String { [player.rawValue, title, artist, album].joined(separator: "|") }

    /// Extrapolated between samples so the progress bar and lyrics move smoothly.
    func position(at date: Date) -> Double {
        min(duration, playing ? position + date.timeIntervalSince(sampledAt) : position)
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

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent = Color(white: 0.65)
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var lyricsStatus: LyricsStatus = .none
    @Published var showsLyrics = true
    private var trackKey: String?
    private var task: Task<Void, Never>?

    var isPlaying: Bool { nowPlaying?.playing == true }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func currentLine(at date: Date) -> LyricLine? {
        guard lyricsStatus == .synced, let position = nowPlaying?.position(at: date) else { return nil }
        return lyrics.last { $0.time <= position + 0.15 }
    }

    // MARK: Controls

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }
    func seek(to seconds: Double) { send("set player position to \(Int(seconds))") }
    func setVolume(_ volume: Double) { send("set sound volume to \(Int(volume))") }

    func toggleFavorite() {
        guard let track = nowPlaying, track.player == .music, let favorite = track.favorite else { return }
        send("set favorited of current track to \(!favorite)")
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
            await poll()
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
        let reading = await Task.detached { MusicBridge.read(players) }.value
        nowPlaying = reading
        if reading?.trackKey != trackKey {
            trackKey = reading?.trackKey
            artwork = nil
            accent = Color(white: 0.65)
            lyrics = []
            lyricsStatus = .none
            if let reading {
                loadArtwork(for: reading)
                loadLyrics(for: reading)
            }
        }
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
                      player == .spotify ? "(artwork url of t)" : "\"\""]
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
        guard parts.count >= 10 else { return nil }
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        func flag(_ text: String) -> Bool? { text == "true" ? true : text == "false" ? false : nil }
        return NowPlaying(player: player, title: parts[0], artist: parts[1], album: parts[2],
                          duration: number(parts[3]), position: number(parts[4]), playing: parts[5] == "playing",
                          volume: number(parts[6]), artworkURL: parts[7].isEmpty ? nil : parts[7],
                          favorite: flag(parts[8]), shuffle: flag(parts[9]))
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

/// The closed notch while music plays and no agent is busy: cover and
/// waves on the left, the current lyric (or the title) on the right.
@MainActor
struct MusicTab {
    static func wing(_ music: MusicStore, now: Date = Date()) -> CGFloat {
        let text = music.currentLine(at: now)?.text ?? music.nowPlaying?.title ?? ""
        return max(20 + 6 + 18, min(220, textWidth(text, size: 12.5)))
    }
}

struct MusicTabLeft: View {
    @ObservedObject var music: MusicStore

    var body: some View {
        HStack(spacing: 6) {
            Artwork(image: music.artwork, size: 20, radius: 5)
            LevelBars(color: music.accent, playing: music.isPlaying, height: 12)
        }
    }
}

struct MusicTabRight: View {
    @ObservedObject var music: MusicStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(music.currentLine(at: context.date)?.text ?? music.nowPlaying.map { "\($0.title) · \($0.artist)" } ?? "")
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .trailing)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.25), value: music.currentLine(at: context.date)?.id)
        }
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
/// controls, volume) with lyrics in a column beside it when they're on.
struct MusicPage: View {
    @ObservedObject var music: MusicStore
    @ObservedObject var ui: NotchUI

    /// The notch's width for this page: narrow for the card alone, wide with lyrics.
    static func panelWidth(_ music: MusicStore) -> CGFloat {
        music.nowPlaying != nil && music.showsLyrics ? 660 : 380
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
                if music.showsLyrics {
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1).padding(.leading, 18).padding(.vertical, 4)
                    LyricsView(music: music)
                        .padding(.leading, 18)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .offset(x: -8)))
                }
            }
            .animation(Motion.calm, value: music.showsLyrics)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = track.position(at: context.date)
            HStack(spacing: 10) {
                Text(clock(position)).frame(width: 36, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: proxy.size.width * (track.duration > 0 ? position / track.duration : 0))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        music.seek(to: track.duration * Double(location.x / proxy.size.width))
                    }
                }
                .frame(height: 4)
                Text("-" + clock(max(0, track.duration - position))).frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.46))
        }
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct Controls: View {
    @ObservedObject var music: MusicStore
    let track: NowPlaying

    var body: some View {
        ZStack {
            HStack(spacing: 17) {
                control("backward.fill", size: 16) { music.previous() }
                control(track.playing ? "pause.fill" : "play.fill", size: 24) { music.playPause() }
                control("forward.fill", size: 16) { music.next() }
            }
            HStack(spacing: 2) {
                side("list.bullet", on: false, help: "Open \(track.player.rawValue)") { music.openPlayer() }
                side("quote.bubble.fill", on: music.showsLyrics, help: "Lyrics") { music.showsLyrics.toggle() }
                Spacer()
                if let favorite = track.favorite {
                    Button { music.toggleFavorite() } label: {
                        Image(systemName: favorite ? "heart.fill" : "heart")
                            .font(.system(size: 15))
                            .foregroundStyle(favorite ? Color(red: 0.96, green: 0.31, blue: 0.44) : .white.opacity(0.72))
                            .frame(width: 32, height: 32)
                    }
                    .help(favorite ? "Unfavorite" : "Favorite")
                }
                if let shuffle = track.shuffle {
                    side("shuffle", on: shuffle, help: "Shuffle") { music.toggleShuffle() }
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func control(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(.white.opacity(0.97)).frame(width: 46, height: 36)
        }
    }

    private func side(_ icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(on ? .white.opacity(0.97) : .white.opacity(0.46))
                .frame(width: 32, height: 32)
                .background(.white.opacity(on ? 0.16 : 0), in: Circle())
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
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let current = music.currentLine(at: context.date)
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 4) {
                                ForEach(music.lyrics) { line in
                                    let isCurrent = line.id == current?.id
                                    Text(line.text)
                                        .font(.system(size: isCurrent ? 17 : 14, weight: .bold))
                                        .foregroundStyle(.white.opacity(isCurrent || music.lyricsStatus == .plain ? 1 : 0.34))
                                        .shadow(color: .white.opacity(isCurrent ? 0.45 : 0), radius: 7)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 2)
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
                    .animation(.easeOut(duration: 0.3), value: current?.id)
                }
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
