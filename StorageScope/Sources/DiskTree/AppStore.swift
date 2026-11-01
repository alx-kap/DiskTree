import SwiftUI
import AppKit

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var action: (label: String, perform: () -> Void)? = nil
}

struct TrashCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let verdict: SafetyVerdict
}

struct TrashRequest: Identifiable {
    let id = UUID()
    let candidates: [TrashCandidate]
    var onComplete: (() -> Void)?

    var allowed: [TrashCandidate] { candidates.filter { !$0.verdict.isBlocked } }
    var blocked: [TrashCandidate] { candidates.filter { $0.verdict.isBlocked } }
    var hasCautions: Bool { candidates.contains { $0.verdict.isCaution } }
    var allowedSize: Int64 { allowed.reduce(0) { $0 + $1.size } }
}

private struct TrashOutcome: Sendable {
    struct Moved: Sendable { let url: URL; let trashedURL: URL?; let size: Int64 }
    var moved: [Moved] = []
    var failed: [(name: String, reason: String)] = []
}

@MainActor
final class AppStore: ObservableObject {
    enum Section: Hashable { case overview, explore, largeFiles, cleanup, history }

    @Published var section: Section? = .overview
    @Published private(set) var target: ScanTarget?
    @Published private(set) var root: FileNode?
    @Published var current: FileNode?
    @Published private(set) var categoryTotals: [FileCategory: Int64] = [:]
    @Published private(set) var largeFiles: [FileNode] = []
    @Published private(set) var nodeModules: [FileNode] = []
    @Published private(set) var unreadableCount = 0
    @Published private(set) var scanDuration: TimeInterval = 0
    @Published private(set) var isScanning = false
    @Published private(set) var progressFiles = 0
    @Published private(set) var progressBytes: Int64 = 0
    @Published private(set) var progressPath = ""
    @Published private(set) var volume: VolumeInfo? = VolumeInfo.current()
    @Published private(set) var revision = 0
    @Published private(set) var history: [TrashRecord] = []
    @Published private(set) var trashIsHidden = false
    @Published var pendingTrash: TrashRequest?
    @Published var alert: AlertInfo?
    @Published var toast: String?

    private var scanProgress: ScanProgress?
    private var toastTask: Task<Void, Never>?
    private let historyKey = "trashHistory"

    init() {
        loadHistory()
        checkTrashAccess()
    }

    // MARK: Scanning

    func startScan(_ target: ScanTarget) {
        cancelScan()
        self.target = target
        root = nil
        current = nil
        largeFiles = []
        nodeModules = []
        categoryTotals = [:]
        isScanning = true
        progressFiles = 0
        progressBytes = 0
        progressPath = target.path
        if section == nil { section = .overview }

        let progress = ScanProgress()
        scanProgress = progress
        let path = target.path
        Task { [weak self] in
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard let self else { return }
                    let s = progress.snapshot()
                    self.progressFiles = s.files
                    self.progressBytes = s.bytes
                    self.progressPath = s.path
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                Scanner.scan(path: path, progress: progress)
            }.value
            poller.cancel()
            guard let self, !progress.isCancelled else { return }
            self.isScanning = false
            guard let result else {
                self.alert = AlertInfo(
                    title: "Couldn't scan “\(target.title)”",
                    message: "macOS keeps this location private. If it's your Desktop, Documents or Downloads, turn DiskTree on in System Settings › Privacy & Security › Files & Folders."
                )
                return
            }
            self.apply(result)
        }
    }

    func cancelScan() {
        scanProgress?.cancel()
        scanProgress = nil
        isScanning = false
    }

    func rescan() {
        if let target { startScan(target) }
    }

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or drive to analyze"
        if panel.runModal() == .OK, let url = panel.url {
            startScan(.folder(url))
        }
    }

    private func apply(_ result: ScanResult) {
        root = result.root
        current = result.root
        categoryTotals = result.categoryTotals
        largeFiles = result.largeFiles
        nodeModules = result.nodeModules
        unreadableCount = result.unreadableCount
        scanDuration = result.duration
        revision += 1
        refreshVolume()
    }

    func refreshVolume() { volume = VolumeInfo.current() }

    // MARK: Navigation

    func navigate(to node: FileNode) {
        guard node.isDirectory else { return }
        current = node
        section = .explore
    }

    func goUp() {
        if let parent = current?.parent { current = parent }
    }

    // MARK: Trash

    func requestTrash(nodes: [FileNode], onComplete: (() -> Void)? = nil) {
        // If a folder and something inside it are both selected, only the folder is needed.
        let set = Set(nodes)
        let top = nodes.filter { n in
            var p = n.parent
            while let a = p { if set.contains(a) { return false }; p = a.parent }
            return true
        }
        let candidates = top
            .sorted { $0.size > $1.size }
            .map { TrashCandidate(url: $0.url, name: $0.name, size: $0.size, verdict: SafetyGuard.check($0.path)) }
        guard !candidates.isEmpty else { return }
        pendingTrash = TrashRequest(candidates: candidates, onComplete: onComplete)
    }

    func performTrash(_ request: TrashRequest) {
        pendingTrash = nil
        let jobs = request.allowed.map { ($0.url, $0.size) }
        guard !jobs.isEmpty else { return }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> TrashOutcome in
                var out = TrashOutcome()
                for (url, size) in jobs {
                    // Re-check right before acting, in case anything changed.
                    if SafetyGuard.check(url.path).isBlocked { continue }
                    do {
                        var resulting: NSURL?
                        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                        out.moved.append(.init(url: url, trashedURL: resulting as URL?, size: size))
                    } catch {
                        out.failed.append((url.lastPathComponent, (error as NSError).localizedFailureReason ?? error.localizedDescription))
                    }
                }
                return out
            }.value
            self.finishTrash(outcome, onComplete: request.onComplete)
        }
    }

    private func finishTrash(_ outcome: TrashOutcome, onComplete: (() -> Void)?) {
        var freed: Int64 = 0
        for m in outcome.moved {
            freed += m.size
            detachNode(atPath: m.url.path)
            history.insert(TrashRecord(
                name: m.url.lastPathComponent, originalPath: m.url.path,
                trashedPath: m.trashedURL?.path, size: m.size, date: Date()
            ), at: 0)
        }
        if let root {
            largeFiles = largeFiles.filter { $0.isAttached(to: root) }
            nodeModules = nodeModules.filter { $0.isAttached(to: root) }
        }
        saveHistory()
        revision += 1
        refreshVolume()
        checkTrashAccess()
        if !outcome.moved.isEmpty {
            let n = outcome.moved.count
            showToast("Moved \(n) item\(n == 1 ? "" : "s") to the Trash · \(freed.bytes) is freed when you empty the Trash")
        }
        if !outcome.failed.isEmpty {
            let names = outcome.failed.prefix(8).map { "• \($0.name) — \($0.reason)" }.joined(separator: "\n")
            let more = outcome.failed.count > 8 ? "\n…and \(outcome.failed.count - 8) more" : ""
            alert = AlertInfo(
                title: "\(outcome.failed.count) item\(outcome.failed.count == 1 ? "" : "s") couldn't be moved",
                message: "These are usually in use by a running app or protected by macOS. Nothing was harmed.\n\n" + names + more
            )
        }
        onComplete?()
    }

    private func detachNode(atPath path: String) {
        guard let root, let node = findNode(path: path, in: root), node !== root, let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        var p: FileNode? = parent
        while let a = p {
            a.size -= node.size
            a.fileCount -= node.fileCount
            a.children.sort { $0.size > $1.size }
            p = a.parent
        }
        subtractCategories(of: node, override: nil)
        node.parent = nil
        if let current, !current.isAttached(to: root) { self.current = parent }
    }

    private func subtractCategories(of node: FileNode, override: FileCategory?) {
        if node.isDirectory {
            let o = FileCategory.bundleCategory(forDirectoryNamed: node.name) ?? override
            for c in node.children { subtractCategories(of: c, override: o ?? override) }
        } else {
            let cat = override ?? node.category
            categoryTotals[cat, default: 0] = max(0, (categoryTotals[cat] ?? 0) - node.size)
        }
    }

    private func findNode(path: String, in root: FileNode) -> FileNode? {
        let rootPath = root.path
        for candidate in [path, "/System/Volumes/Data" + path] {
            guard candidate == rootPath || candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { continue }
            if candidate == rootPath { return root }
            let rel = candidate.dropFirst(rootPath.count)
            var n = root
            var found = true
            for comp in rel.split(separator: "/") {
                guard let c = n.children.first(where: { $0.name == comp }) else { found = false; break }
                n = c
            }
            if found { return n }
        }
        return nil
    }

    func putBack(_ record: TrashRecord) {
        guard let trashed = record.trashedPath else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: record.originalPath) {
            alert = AlertInfo(title: "Can't put back “\(record.name)”", message: "Something already exists at its original location:\n\(record.originalPath.abbreviatingHome)")
            return
        }
        do {
            let parent = (record.originalPath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: trashed, toPath: record.originalPath)
            if let i = history.firstIndex(where: { $0.id == record.id }) { history[i].restored = true }
            saveHistory()
            revision += 1
            refreshVolume()
            checkTrashAccess()
            showToast("Put back “\(record.name)”. Rescan to see it in the map.")
        } catch {
            alert = AlertInfo(title: "Can't put back “\(record.name)”", message: error.localizedDescription)
        }
    }

    /// Items DiskTree moved to the Trash that are still sitting there.
    var ownItemsInTrash: [TrashRecord] { history.filter(\.canPutBack) }

    /// Re-checks whether macOS lets us see inside the Trash (it doesn't without Full Disk Access).
    func checkTrashAccess() {
        let known = ownItemsInTrash.compactMap(\.trashedPath)
        Task {
            trashIsHidden = await Task.detached { !TrashBin.isVisible(known: known) }.value
        }
    }

    func emptyTrash(completion: (() -> Void)? = nil) {
        let own = ownItemsInTrash.compactMap { $0.trashedPath.map(URL.init(fileURLWithPath:)) }
        let hidden = trashIsHidden
        Task {
            let (leftover, finderError) = await Task.detached { () -> ([String], Int?) in
                // What we put in the Trash we can erase by path, with no extra permission.
                var leftover = TrashBin.erase(own)
                if !hidden, let rest = try? FileManager.default.contentsOfDirectory(at: TrashBin.url, includingPropertiesForKeys: nil) {
                    leftover += TrashBin.erase(rest)
                    return (leftover, nil)
                }
                // Everything else is hidden from us, so Finder empties it.
                return (leftover, TrashBin.emptyWithFinder())
            }.value
            self.refreshVolume()
            self.checkTrashAccess()
            if !leftover.isEmpty {
                let names = leftover.prefix(3).joined(separator: ", ") + (leftover.count > 3 ? " and \(leftover.count - 3) more" : "")
                self.alert = AlertInfo(
                    title: leftover.count == 1 ? "1 item couldn't be erased" : "\(leftover.count) items couldn't be erased",
                    message: "\(names) may be in use by another app. Quit that app and try again, or open the Trash to remove it.",
                    action: ("Open Trash", { Finder.open(TrashBin.url) })
                )
            } else if finderError != nil {
                self.alert = AlertInfo(
                    title: own.isEmpty ? "Couldn't empty the Trash" : "Erased what DiskTree put in the Trash",
                    message: "To empty everything else from here, allow DiskTree to control Finder in System Settings › Privacy & Security › Automation. Or open the Trash and empty it there.",
                    action: ("Open Trash", { Finder.open(TrashBin.url) })
                )
            } else {
                self.showToast("Trash emptied")
            }
            completion?()
        }
    }

    func showToast(_ message: String) {
        withAnimation { toast = message }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { withAnimation { self.toast = nil } }
        }
    }

    // MARK: History persistence

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let list = try? JSONDecoder().decode([TrashRecord].self, from: data) else { return }
        history = list
    }

    private func saveHistory() {
        if history.count > 500 { history.removeSubrange(500...) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    func clearHistory() {
        history = []
        saveHistory()
    }
}

/// The user's Trash. Without Full Disk Access macOS hides its contents from us,
/// but items at paths we already know can still be removed.
enum TrashBin {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")

    static func isVisible(known: [String]) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
        let listed = Set(names)
        if !known.allSatisfy({ listed.contains(($0 as NSString).lastPathComponent) }) { return false }
        // An empty listing is ambiguous; probe another protected folder to tell "empty" from "hidden".
        if listed.isEmpty, (try? fm.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) == nil { return false }
        return true
    }

    /// Permanently removes the given items. Returns the names of any that couldn't be removed.
    static func erase(_ urls: [URL]) -> [String] {
        let fm = FileManager.default
        var leftover: [String] = []
        for url in urls {
            if (try? fm.removeItem(at: url)) != nil { continue }
            // Locked items (Get Info › Locked) refuse removal; unlock and retry once.
            unlock(url, fm: fm)
            if (try? fm.removeItem(at: url)) == nil, fm.fileExists(atPath: url.path), url.lastPathComponent != ".DS_Store" {
                leftover.append(url.lastPathComponent)
            }
        }
        return leftover
    }

    private static func unlock(_ url: URL, fm: FileManager) {
        var urls = [url]
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in e { urls.append(child) }
        }
        for u in urls {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: u.path)
        }
    }

    /// Asks Finder to empty the Trash, skipping Finder's own "Are you sure?" since the user already confirmed.
    /// Returns nil on success, or the AppleScript error number (-1743 means not allowed to control Finder).
    static func emptyWithFinder() -> Int? {
        let script = """
        tell application "Finder"
            set w to warns before emptying of trash
            set warns before emptying of trash to false
            try
                empty trash
            on error m number n
                set warns before emptying of trash to w
                error m number n
            end try
            set warns before emptying of trash to w
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let r = text.range(of: #"\((-?\d+)\)"#, options: .regularExpression) {
            return Int(text[r].dropFirst().dropLast()) ?? -1
        }
        return -1
    }
}

enum Finder {
    static func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}
