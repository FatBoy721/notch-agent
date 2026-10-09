import AppKit

/// New versions from the app's GitHub releases. It looks once a day by
/// itself (and whenever asked), and installs with one click: downloads the
/// release's .dmg, checks the app inside is Notch Agent and newer, puts it
/// in place of this one and relaunches. Downloaded this way, rather than
/// through a browser, the new copy carries no quarantine flag, so macOS
/// doesn't ask "Open Anyway" again.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repository = "FatBoy721/notch-agent"

    struct Release: Equatable, Sendable {
        let version: String
        let page: URL
        /// The .dmg attached to the release; without one, updating means
        /// opening the page.
        let download: URL?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading, installing, failed(String)
    }

    @Published private(set) var state = State.idle
    /// Told when a check it made by itself finds a new version.
    var onFound: ((Release) -> Void)?

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static let lastCheckKey = "updateLastCheck"
    private var timer: Timer?

    /// A first look a little after launch, then every few hours; GitHub is
    /// asked at most once a day.
    func startAutomaticChecks() {
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(30))
            checkIfDue()
        }
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task {
            await check()
            if let available { onFound?(available) }
        }
    }

    func check() async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await Self.latest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            let newer = release.version.compare(Self.currentVersion, options: .numeric) == .orderedDescending
            state = newer ? .available(release) : .upToDate
        } catch {
            state = .failed("Couldn't reach GitHub. Try again later.")
        }
    }

    /// Where it can't replace itself (not in a folder it can write to, or a
    /// release without a .dmg), it opens the release page instead.
    func install() {
        guard let release = available else { return }
        let app = Bundle.main.bundleURL
        guard let download = release.download, app.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .downloading
        Task {
            do {
                let (file, response) = try await URLSession.shared.download(from: download)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.download }
                state = .installing
                let staged = try await Task.detached { try Self.stage(dmg: file, next: app, version: release.version) }.value
                try Self.relaunch(replacing: app, with: staged)
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? "The update failed: \(error.localizedDescription)")
            }
        }
    }

    enum Failure: LocalizedError {
        case download, mount, notOurs, notNewer, damaged

        var errorDescription: String? {
            switch self {
            case .download: "The download didn't finish. Try again."
            case .mount: "Couldn't open the downloaded disk image."
            case .notOurs: "The download doesn't contain Notch Agent."
            case .notNewer: "The download isn't the version GitHub announced."
            case .damaged: "The downloaded app's signature is broken, so it wasn't installed."
            }
        }
    }

    /// The newest release. NOTCH_AGENT_UPDATE_FEED (set by whoever launches
    /// the app) points it at another release JSON, for testing.
    nonisolated static func latest() async throws -> Release {
        let feed = ProcessInfo.processInfo.environment["NOTCH_AGENT_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: feed, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.download }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { throw Failure.download }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, download: dmg.flatMap(URL.init(string:)))
    }

    /// Mounts the image, checks the app in it (our bundle id, the announced
    /// version, an intact signature) and copies it beside the running app,
    /// on the same disk so the swap is a rename.
    nonisolated private static func stage(dmg: URL, next current: URL, version: String) throws -> URL {
        guard let plist = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path]),
              let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let mount = (info["system-entities"] as? [[String: Any]])?.compactMap({ $0["mount-point"] as? String }).first else {
            throw Failure.mount
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mount)) ?? []
        guard let name = contents.first(where: { $0.hasSuffix(".app") }) else { throw Failure.notOurs }
        let found = URL(fileURLWithPath: mount).appendingPathComponent(name)
        let bundle = Bundle(url: found)
        guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw Failure.notOurs }
        guard bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else { throw Failure.notNewer }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", found.path]) != nil else { throw Failure.damaged }

        let staged = current.deletingLastPathComponent().appendingPathComponent(".NotchAgent-update.app")
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [found.path, staged.path]) != nil else { throw Failure.download }
        return staged
    }

    /// A small shell waits for this process to quit, swaps the new app in
    /// and opens it; then the app quits.
    private static func relaunch(replacing current: URL, with staged: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2" && mv "$3" "$2" && open "$2"
            """, "sh", String(ProcessInfo.processInfo.processIdentifier), current.path, staged.path]
        try process.run()
        NSApp.terminate(nil)
    }

    /// Its output, or nil when it failed.
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
