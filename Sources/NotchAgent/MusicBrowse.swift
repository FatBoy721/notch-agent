import SwiftUI

/// Spotify search and the user's playlists, for the player's browse column.
/// Results play in the Spotify app over AppleScript, so playing needs no
/// extra permission; listing playlists does (`playlist-read-private`), and
/// Liked Songs uses the ♥ scope (`user-library-read`).
@MainActor
final class SpotifyBrowser: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    /// nil while the query is too short to search.
    @Published private(set) var results: [SpotifyItem]?
    @Published private(set) var searching = false
    @Published private(set) var playlists: [SpotifyItem]?
    @Published private(set) var likedSongs: [SpotifyItem]?
    /// The Liked Songs list is open in place of the playlists.
    @Published var showingLiked = false
    @Published private(set) var playlistsNeedPermission = false
    @Published private(set) var problem: String?
    private var searchTask: Task<Void, Never>?
    private var playlistsLoadedAt = Date.distantPast

    /// At most every 5 minutes: playlists rarely change mid-listen.
    func loadPlaylists() {
        guard Date().timeIntervalSince(playlistsLoadedAt) > 300 else { return }
        playlistsLoadedAt = Date()
        Task {
            guard await SpotifyAPI.shared.hasScope("playlist-read-private") else {
                playlistsNeedPermission = true
                return
            }
            playlistsNeedPermission = false
            do {
                async let liked = SpotifyAPI.shared.likedSongs()
                playlists = try await SpotifyAPI.shared.playlists()
                likedSongs = try? await liked
            } catch {
                EventLog.write("spotify playlists: \(error.localizedDescription)")
                problem = error.localizedDescription
                playlistsLoadedAt = .distantPast
            }
        }
    }

    /// After signing in again or out: what was loaded may no longer apply.
    func reset() {
        searchTask?.cancel()
        query = ""
        results = nil
        searching = false
        playlists = nil
        likedSongs = nil
        showingLiked = false
        playlistsNeedPermission = false
        problem = nil
        playlistsLoadedAt = .distantPast
    }

    /// Waits for a pause in typing, so each word isn't its own request.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = nil
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let found = try await SpotifyAPI.shared.search(text)
                guard !Task.isCancelled else { return }
                results = found
                problem = nil
            } catch {
                guard !Task.isCancelled else { return }
                problem = error.localizedDescription
            }
            searching = false
        }
    }
}

struct BrowseView: View {
    @ObservedObject var music: MusicStore
    @ObservedObject var browser: SpotifyBrowser
    @FocusState private var searchFocused: Bool

    var body: some View {
        SpotifyGate(music: music) {
            VStack(alignment: .leading, spacing: 8) {
                searchField
                if let results = browser.results {
                    if results.isEmpty, !browser.searching {
                        caption(browser.problem ?? "Nothing found")
                    } else {
                        FadingList { rows(results, kindInSubtitle: true) }
                    }
                } else {
                    playlists
                }
            }
            .onAppear { browser.loadPlaylists() }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.mute)
            TextField("Search Spotify", text: $browser.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
            if browser.searching {
                ArcSpinner(size: 11)
            } else if !browser.query.isEmpty {
                Button { browser.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.mute)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .onAppear { searchFocused = true }
    }

    @ViewBuilder private var playlists: some View {
        if browser.playlistsNeedPermission {
            PanelNote(title: "Show your playlists here", detail: "Spotify needs to allow it once.") {
                Button("Allow in Spotify") { music.reconnectSpotify() }
            }
        } else if browser.showingLiked, let liked = browser.likedSongs {
            HStack {
                Button { browser.showingLiked = false } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 9.5, weight: .bold))
                        Text("Liked Songs")
                    }
                    .foregroundStyle(Palette.mute)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if let first = liked.first {
                    Button("Play all") { music.playOnSpotify(first.uri, context: first.context) }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            FadingList { rows(liked, kindInSubtitle: false) }
        } else if let playlists = browser.playlists {
            Text("Your library").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.mute)
            FadingList {
                if let liked = browser.likedSongs {
                    MediaRow(title: "Liked Songs", subtitle: liked.count == 50 ? "50 most recent" : "\(liked.count) songs",
                             artworkURL: nil, symbol: "heart.fill", actionSymbol: "chevron.right") {
                        browser.showingLiked = true
                    }
                }
                rows(playlists, kindInSubtitle: false)
            }
        } else if let problem = browser.problem {
            caption(problem)
        } else {
            ArcSpinner(size: 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rows(_ items: [SpotifyItem], kindInSubtitle: Bool) -> some View {
        ForEach(items) { item in
            MediaRow(title: item.title,
                     subtitle: kindInSubtitle ? [item.kind.rawValue, item.subtitle].filter { !$0.isEmpty }.joined(separator: " · ") : item.subtitle,
                     artworkURL: item.artworkURL) {
                music.playOnSpotify(item.uri, context: item.context)
            }
            .help("Play \(item.title)")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.mute)
            .lineLimit(2).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
