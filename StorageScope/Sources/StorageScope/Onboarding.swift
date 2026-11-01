import SwiftUI
import AppKit
import Carbon

/// Tracks the permissions StorageScope needs, re-checking while the setup screen is open
/// so rows turn green as soon as the user flips a switch in System Settings.
@MainActor
final class Permissions: ObservableObject {
    enum FinderStatus { case unknown, granted, denied, notAsked }

    @Published private(set) var folders = false
    @Published private(set) var foldersDenied = false
    @Published private(set) var askingFolders = false
    /// The System Settings pane to send people to when something was declined.
    private var deniedPane = "Privacy_FilesAndFolders"
    @Published private(set) var finder: FinderStatus = .unknown
    @Published private(set) var askingFinder = false

    var allGranted: Bool { folders && finder == .granted }

    /// Reading these places the first time is what makes macOS ask, so we only check after the user opts in.
    private var foldersAsked: Bool {
        get { UserDefaults.standard.bool(forKey: "foldersAsked") }
        set { UserDefaults.standard.set(newValue, forKey: "foldersAsked") }
    }
    nonisolated static let protectedFolders = ["Desktop", "Documents", "Downloads"].map { NSHomeDirectory() + "/" + $0 }

    private var timer: Timer?

    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        if foldersAsked, !askingFolders {
            apply(Self.blockedPane())
        }
        guard !askingFinder else { return }
        Task {
            let status = await Task.detached { Self.finderPermission(ask: false) }.value
            if !askingFinder { finder = status }
        }
    }

    /// Shows macOS's "Allow StorageScope to control Finder?" prompt, or opens Settings if it was already declined.
    func requestFinder() {
        if finder == .denied {
            Self.openSettings("Privacy_Automation")
            return
        }
        askingFinder = true
        Task {
            finder = await Task.detached { Self.finderPermission(ask: true) }.value
            askingFinder = false
        }
    }

    /// Shows macOS's Desktop, Documents, Downloads, Photos and Music prompts now, instead of in the middle of a scan.
    func requestFolders() {
        if foldersDenied {
            Self.openSettings(deniedPane)
            return
        }
        askingFolders = true
        Task {
            let blocked = await Task.detached { () -> String? in
                Self.touchMediaFolders()
                return Self.blockedPane()
            }.value
            foldersAsked = true
            apply(blocked)
            askingFolders = false
        }
    }

    private func apply(_ blockedPane: String?) {
        folders = blockedPane == nil
        foldersDenied = blockedPane != nil
        if let blockedPane { deniedPane = blockedPane }
    }

    private static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The Photos and Music libraries macOS guards with their own prompts.
    nonisolated static func mediaLibraries() -> (photos: [String], music: [String]) {
        let fm = FileManager.default
        let pictures = NSHomeDirectory() + "/Pictures"
        let photos = ((try? fm.contentsOfDirectory(atPath: pictures)) ?? [])
            .filter { $0.hasSuffix(".photoslibrary") }
            .map { pictures + "/" + $0 }
        let music = ["Music", "iTunes"].map { NSHomeDirectory() + "/Music/" + $0 }.filter { fm.fileExists(atPath: $0) }
        return (photos, music)
    }

    /// Walks a little way into Pictures and Music, like a scan does, so every prompt shows up now.
    nonisolated static func touchMediaFolders() {
        let fm = FileManager.default
        func walk(_ path: String, depth: Int) {
            guard depth < 3, let names = try? fm.contentsOfDirectory(atPath: path) else { return }
            for name in names {
                let child = path + "/" + name
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue { walk(child, depth: depth + 1) }
            }
        }
        for folder in protectedFolders + ["Pictures", "Music"].map({ NSHomeDirectory() + "/" + $0 }) {
            walk(folder, depth: 1)
        }
    }

    /// The Settings pane for the first place that's still unreadable, or nil when everything is readable.
    nonisolated static func blockedPane() -> String? {
        let readable = { (path: String) in (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil }
        if !protectedFolders.allSatisfy(readable) { return "Privacy_FilesAndFolders" }
        let media = mediaLibraries()
        if !media.photos.allSatisfy(readable) { return "Privacy_Photos" }
        if !media.music.allSatisfy(readable) { return "Privacy_Media" }
        return nil
    }

    nonisolated static func finderPermission(ask: Bool) -> FinderStatus {
        var target = AEAddressDesc()
        let bundleID = "com.apple.finder"
        let created = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown
        }
    }
}

struct OnboardingView: View {
    @StateObject private var permissions = Permissions()
    var onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Welcome to StorageScope").font(.largeTitle.bold())
                    Text("Two quick steps let StorageScope measure your files and clean up in one click. Nothing ever leaves your Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                VStack(spacing: 14) {
                    PermissionRow(
                        number: 1,
                        symbol: "folder.fill", tint: .blue,
                        title: "Your files, photos & music",
                        detail: "Lets StorageScope measure Desktop, Documents, Downloads and your Photos and Music libraries. macOS asks once for each.",
                        granted: permissions.folders
                    ) {
                        Button(permissions.foldersDenied ? "Open Settings" : "Allow…") { permissions.requestFolders() }
                            .buttonStyle(.borderedProminent)
                            .disabled(permissions.askingFolders)
                    } help: {
                        if permissions.foldersDenied {
                            Text("Something was turned off. Open Settings and turn StorageScope on, then come back here.")
                        } else {
                            Text("Click Allow (or OK) on each prompt that appears.")
                        }
                    }

                    PermissionRow(
                        number: 2,
                        symbol: "trash.fill", tint: .red,
                        title: "Empty the Trash",
                        detail: "Lets StorageScope ask Finder to empty the Trash, so you never have to switch apps to actually free the space.",
                        granted: permissions.finder == .granted
                    ) {
                        Button(permissions.finder == .denied ? "Open Settings" : "Allow…") { permissions.requestFinder() }
                            .buttonStyle(.borderedProminent)
                            .disabled(permissions.askingFinder)
                    } help: {
                        if permissions.finder == .denied {
                            Text("This was turned off earlier. In Automation, open StorageScope and turn on Finder.")
                        } else {
                            Text("macOS will ask once. Click OK.")
                        }
                    }
                }
                .frame(maxWidth: 640)

                VStack(spacing: 10) {
                    Button(action: finish) {
                        Text(permissions.allGranted ? "Get Started" : "Waiting for permissions…")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!permissions.allGranted)
                    .keyboardShortcut(.defaultAction)

                    Button("Set up later", action: finish)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func finish() {
        permissions.stopWatching()
        onDone()
    }
}

private struct PermissionRow<Action: View, Help: View>: View {
    let number: Int
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder var action: Action
    @ViewBuilder var help: Help

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(number). \(title)").font(.headline)
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !granted {
                        help.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 16)

                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.semibold))
                } else {
                    action
                }
            }
        }
    }
}
