import Foundation

enum SafetyVerdict: Equatable {
    case ok
    case caution(String)
    case blocked(String)

    var isBlocked: Bool { if case .blocked = self { return true }; return false }
    var isCaution: Bool { if case .caution = self { return true }; return false }
    var message: String? {
        switch self {
        case .ok: return nil
        case .caution(let m), .blocked(let m): return m
        }
    }
}

/// Decides what the app is willing to move to the Trash. Anything not clearly the user's own
/// stuff is refused; app data and iCloud files get an explicit warning.
enum SafetyGuard {
    private static let home = NSHomeDirectory()

    private static let protectedHomeFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
        "Public", "Applications", "Sites", ".Trash",
    ]

    private static let cleanLibraryPrefixes = [
        "Library/Caches/", "Library/Logs/",
        "Library/Developer/Xcode/DerivedData/", "Library/Developer/Xcode/Archives/",
        "Library/Developer/Xcode/iOS DeviceSupport/", "Library/Developer/Xcode/watchOS DeviceSupport/",
        "Library/Developer/Xcode/tvOS DeviceSupport/", "Library/Developer/Xcode/visionOS DeviceSupport/",
        "Library/Developer/CoreSimulator/Caches/", "Library/pnpm/store/",
    ]

    private static let sealedPackages: Set<String> = ["app", "photoslibrary", "musiclibrary", "framework", "fcpbundle", "imovielibrary"]

    static func check(_ rawPath: String) -> SafetyVerdict {
        var path = (rawPath as NSString).standardizingPath
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        if path.isEmpty || path == "/" { return .blocked("This is the top of your disk.") }

        let comps = path.split(separator: "/").map(String.init)

        // Never reach inside packages like apps or the Photos library.
        for (i, c) in comps.enumerated() where i < comps.count - 1 {
            let ext = (c as NSString).pathExtension.lowercased()
            if sealedPackages.contains(ext) {
                return .blocked("This is inside “\(c)”. Removing pieces of it can corrupt it — remove the whole item or manage it in its app.")
            }
        }

        if path == home { return .blocked("This is your home folder.") }

        if path.hasPrefix(home + "/") {
            let rel = String(path.dropFirst(home.count + 1))
            let parts = rel.split(separator: "/").map(String.init)
            if parts.count == 1 && protectedHomeFolders.contains(parts[0]) {
                return .blocked("“\(parts[0])” is a standard macOS folder. You can remove things inside it, but not the folder itself.")
            }
            if parts.first == ".Trash" { return .blocked("This is already in the Trash.") }
            if parts.first == "Library" {
                if parts.count == 2 { return .blocked("“\(parts[1])” is a core Library folder that macOS and apps rely on.") }
                if parts[1] == "Keychains" { return .blocked("Keychains store your passwords and certificates.") }
                if cleanLibraryPrefixes.contains(where: { (rel + "/").hasPrefix($0) && rel + "/" != $0 }) { return .ok }
                if parts[1] == "Mobile Documents" || parts[1] == "CloudStorage" {
                    return .caution("Stored in iCloud or cloud storage — removing it also removes it from your other devices.")
                }
                if rel.hasPrefix("Library/Application Support/MobileSync/Backup/") {
                    return .caution("A device backup. Make sure you have a newer backup before removing it.")
                }
                return .caution("App data in your Library. Removing it can reset an app or delete data it stores.")
            }
            if comps.last.map({ ($0 as NSString).pathExtension.lowercased() == "photoslibrary" }) == true {
                return .caution("This is a Photos library. Everything stored in it will go to the Trash.")
            }
            return .ok
        }

        if path.hasPrefix("/Applications/") {
            if comps.count == 2 { return .caution("This removes the app. Its settings and data in your Library stay behind.") }
            return .blocked("This is inside the Applications folder. Remove whole apps instead.")
        }
        if path.hasPrefix("/Users/Shared/") { return .ok }
        if path.hasPrefix("/Volumes/") && comps.count >= 3 { return .ok }
        if path.hasPrefix("/Users/") { return .blocked("This belongs to another user account on this Mac.") }
        return .blocked("This is a system location. Removing it could break macOS or other apps.")
    }
}
