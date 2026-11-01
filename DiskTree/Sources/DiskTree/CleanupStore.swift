import SwiftUI

enum CleanupSafety {
    case safe, review, info

    var label: String {
        switch self {
        case .safe: return "Safe to clean"
        case .review: return "Review first"
        case .info: return "Good to know"
        }
    }

    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .info: return .blue
        }
    }
}

struct CleanupDefinition: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let paths: [String]
    let safety: CleanupSafety
    var olderThanDays: Int? = nil
    var command: String? = nil
}

struct CleanupItem: Identifiable {
    enum State {
        case loading
        case missing
        case unreadable
        case loaded(entries: [FileNode], total: Int64)
    }

    let definition: CleanupDefinition
    var state: State = .loading
    /// Keeps the scanned folders alive: entries only hold a weak link to their parent,
    /// which they need to know their own path.
    var roots: [FileNode] = []
    var id: String { definition.id }

    var entries: [FileNode] {
        if case .loaded(let e, _) = state { return e }
        return []
    }

    var total: Int64 {
        if case .loaded(_, let t) = state { return t }
        return 0
    }

    func isPreselected(_ node: FileNode) -> Bool {
        if let days = definition.olderThanDays {
            return node.modifiedDate < Date().addingTimeInterval(-Double(days) * 86_400)
        }
        return definition.safety == .safe
    }

    /// The size the card advertises: everything for safe items, only old files for "older than" items.
    var headline: Int64 {
        if definition.olderThanDays != nil { return entries.filter(isPreselected).reduce(0) { $0 + $1.size } }
        return total
    }
}

@MainActor
final class CleanupStore: ObservableObject {
    @Published private(set) var items: [CleanupItem]
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false

    init() {
        items = Self.definitions.map { CleanupItem(definition: $0) }
    }

    var visibleItems: [CleanupItem] {
        items.filter {
            if case .missing = $0.state { return false }
            if case .loaded(let e, let t) = $0.state, e.isEmpty || t < 1_000_000, $0.id != "trash" { return false }
            return true
        }
    }

    var safeTotal: Int64 {
        items.filter { $0.definition.safety == .safe }.reduce(0) { $0 + $1.headline }
    }

    func item(_ id: String) -> CleanupItem? { items.first { $0.id == id } }

    func refresh(only ids: Set<String>? = nil) {
        hasLoaded = true
        isRefreshing = true
        let defs = items.map(\.definition).filter { ids?.contains($0.id) ?? true }
        for d in defs {
            if let i = items.firstIndex(where: { $0.id == d.id }) { items[i].state = .loading }
        }
        Task {
            await withTaskGroup(of: (String, CleanupItem.State, [FileNode]).self) { group in
                for def in defs {
                    group.addTask {
                        let (state, roots) = Self.measure(def)
                        return (def.id, state, roots)
                    }
                }
                for await (id, state, roots) in group {
                    if let i = items.firstIndex(where: { $0.id == id }) {
                        items[i].state = state
                        items[i].roots = roots
                    }
                }
            }
            isRefreshing = false
        }
    }

    nonisolated private static func measure(_ def: CleanupDefinition) -> (CleanupItem.State, [FileNode]) {
        let fm = FileManager.default
        var entries: [FileNode] = []
        var roots: [FileNode] = []
        var total: Int64 = 0
        var exists = false
        var readable = false
        for path in def.paths where fm.fileExists(atPath: path) {
            exists = true
            guard let result = Scanner.scan(path: path) else { continue }
            readable = true
            roots.append(result.root)
            entries += result.root.children
            total += result.root.size
        }
        if !exists { return (.missing, []) }
        if !readable { return (.unreadable, []) }
        entries.sort { $0.size > $1.size }
        return (.loaded(entries: entries, total: total), roots)
    }

    private static var definitions: [CleanupDefinition] {
        let h = NSHomeDirectory()
        let xcode = h + "/Library/Developer/Xcode"
        return [
            CleanupDefinition(
                id: "caches", title: "App Caches",
                detail: "Temporary files apps keep so they load faster. Apps recreate them automatically. Quit apps first for the best result.",
                symbol: "shippingbox.fill", tint: .blue, paths: [h + "/Library/Caches"], safety: .safe),
            CleanupDefinition(
                id: "logs", title: "Log Files",
                detail: "Diagnostic logs written by apps. They're only useful for troubleshooting.",
                symbol: "doc.plaintext.fill", tint: .gray, paths: [h + "/Library/Logs"], safety: .safe),
            CleanupDefinition(
                id: "derived", title: "Xcode Build Data",
                detail: "DerivedData holds intermediate build products. Xcode rebuilds it on the next build.",
                symbol: "hammer.fill", tint: .indigo, paths: [xcode + "/DerivedData"], safety: .safe),
            CleanupDefinition(
                id: "devicesupport", title: "Xcode Device Support",
                detail: "Debug symbols copied from devices you've connected. Xcode copies them again the next time you plug that device in.",
                symbol: "iphone.gen3", tint: .indigo,
                paths: ["iOS", "watchOS", "tvOS", "visionOS"].map { xcode + "/\($0) DeviceSupport" }, safety: .safe),
            CleanupDefinition(
                id: "simcaches", title: "Simulator Caches",
                detail: "Caches used by the iOS Simulator. Recreated automatically.",
                symbol: "ipad.and.iphone", tint: .indigo, paths: [h + "/Library/Developer/CoreSimulator/Caches"], safety: .safe),
            CleanupDefinition(
                id: "pkgcaches", title: "Developer Package Caches",
                detail: "Download caches for npm, pnpm, Gradle and Cargo. Packages are re-downloaded when needed.",
                symbol: "cube.box.fill", tint: .teal,
                paths: [h + "/.npm/_cacache", h + "/Library/pnpm/store", h + "/.gradle/caches", h + "/.cargo/registry/cache"], safety: .safe),
            CleanupDefinition(
                id: "downloads", title: "Old Downloads",
                detail: "Items in Downloads that haven't changed in 90+ days. Installers, disk images and zips are usually safe to remove once used.",
                symbol: "arrow.down.circle.fill", tint: .orange, paths: [h + "/Downloads"], safety: .review, olderThanDays: 90),
            CleanupDefinition(
                id: "backups", title: "iPhone & iPad Backups",
                detail: "Local device backups made by Finder. Remove old ones only if you have a newer backup or use iCloud Backup.",
                symbol: "externaldrive.fill.badge.timemachine", tint: .pink,
                paths: [h + "/Library/Application Support/MobileSync/Backup"], safety: .review),
            CleanupDefinition(
                id: "archives", title: "Xcode Archives",
                detail: "Builds you archived for distribution. Keep any you might need to symbolicate crash reports.",
                symbol: "archivebox.fill", tint: .indigo, paths: [xcode + "/Archives"], safety: .review),
            CleanupDefinition(
                id: "simulators", title: "Simulator Devices",
                detail: "Each simulator stores its own apps and data. Remove old ones with Xcode › Devices and Simulators, or with the command below.",
                symbol: "apps.iphone", tint: .indigo, paths: [h + "/Library/Developer/CoreSimulator/Devices"], safety: .info,
                command: "xcrun simctl delete unavailable"),
            CleanupDefinition(
                id: "trash", title: "Trash",
                detail: "Things in the Trash still take up space until you empty it.",
                symbol: "trash.fill", tint: .red, paths: [h + "/.Trash"], safety: .info),
        ]
    }
}
