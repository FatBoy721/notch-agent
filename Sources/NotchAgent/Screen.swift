import AppKit
import SwiftUI

/// Files and screenshots going along with a prompt or reply. The agent gets
/// their paths in the message and opens them itself (Claude Code and Codex
/// both read images from a path).
struct Attachment: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isScreenshot: Bool

    var name: String { isScreenshot ? "Screenshot" : url.lastPathComponent }
}

enum Attachments {
    /// "look at my screen", "what's on screen", "take a screenshot"…
    private static let screenPhrases = try! NSRegularExpression(pattern: [
        #"\b(my|the|this) (screen|display|monitor)\b"#,
        #"\bscreen ?shot\b"#,
        #"\bon (the )?screen\b"#,
        #"\bwhat (i'?m|i am) (looking at|seeing)\b"#,
        #"\bsee (what|my)\b.*\bscreen\b"#,
    ].joined(separator: "|"), options: [.caseInsensitive])

    static func mentionsScreen(_ text: String) -> Bool {
        screenPhrases.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The text with the attachments' paths added so the agent can open them.
    static func compose(_ text: String, with attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let notes = attachments.map { attachment in
            attachment.isScreenshot
                ? "[screenshot of my screen: \(attachment.url.path)]"
                : "[attached file: \(attachment.url.path)]"
        }
        return ([text] + notes).joined(separator: " ")
    }
}

enum ScreenCapture {
    enum Failure: LocalizedError {
        case notAllowed, failed

        var errorDescription: String? {
            switch self {
            case .notAllowed: "Allow Notch Agent under System Settings › Privacy & Security › Screen Recording, then try again."
            case .failed: "Couldn't take a screenshot."
            }
        }
    }

    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchAgent/Screenshots", isDirectory: true)

    /// Closes the notch so it isn't in the picture, captures the main
    /// display, and leaves the PNG in the app's caches folder.
    @MainActor
    static func capture(hiding ui: NotchUI, reopen: Bool) async throws -> Attachment {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw Failure.notAllowed
        }
        let page = ui.page
        ui.mode = .closed
        try? await Task.sleep(for: .milliseconds(450))
        defer {
            if reopen {
                ui.page = page
                ui.mode = .open
            }
        }
        let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            removeOld()
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("screen-\(stamp).png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-m", "-t", "png", url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else { throw Failure.failed }
            return url
        }.value
        return Attachment(url: url, isScreenshot: true)
    }

    /// Screenshots are only needed until the agent has read them; keep a day's worth.
    private static func removeOld() {
        let cutoff = Date().addingTimeInterval(-86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < cutoff {
            try? FileManager.default.removeItem(at: file)
        }
    }

    @MainActor
    static func chooseFiles() -> [Attachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { Attachment(url: $0, isScreenshot: false) }
    }
}

/// The 📷 and 📎 buttons beside a prompt or reply field.
struct AttachButtons: View {
    let screenshot: () -> Void
    let files: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("camera.viewfinder", help: "Attach a screenshot of your screen", action: screenshot)
            button("paperclip", help: "Attach files (or drop them on the notch)", action: files)
        }
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(Palette.mute)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Attached items as removable chips; screenshots show a thumbnail.
struct AttachmentChips: View {
    let attachments: [Attachment]
    let remove: (Attachment) -> Void

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 6) {
                            if attachment.isScreenshot, let image = NSImage(contentsOf: attachment.url) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 28, height: 18).clipShape(RoundedRectangle(cornerRadius: 3))
                            } else {
                                Image(systemName: "doc").font(.system(size: 11))
                            }
                            Text(attachment.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Button { remove(attachment) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.mute)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.08), in: Capsule())
                        .transition(Motion.row)
                    }
                }
            }
        }
    }
}
