import SwiftUI

/// One file or folder in a scanned tree. Paths are derived from the parent chain to keep memory low.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    let name: String
    let isDirectory: Bool
    var size: Int64
    var fileCount: Int = 0
    let modifiedTime: Double
    var children: [FileNode] = []
    weak var parent: FileNode?
    private let rootPath: String?

    init(name: String, isDirectory: Bool, size: Int64, modified: Double, rootPath: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedTime = modified
        self.rootPath = rootPath
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        return (parent.path as NSString).appendingPathComponent(name)
    }
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
    var modifiedDate: Date { Date(timeIntervalSince1970: modifiedTime) }
    var pathExtension: String { (name as NSString).pathExtension.lowercased() }

    var category: FileCategory {
        var p = parent
        while let a = p {
            if let c = FileCategory.bundleCategory(forDirectoryNamed: a.name) { return c }
            p = a.parent
        }
        if isDirectory { return FileCategory.bundleCategory(forDirectoryNamed: name) ?? .other }
        return FileCategory.forExtension(pathExtension)
    }

    /// Root first, self last.
    var lineage: [FileNode] {
        var chain: [FileNode] = [self]
        var p = parent
        while let a = p { chain.append(a); p = a.parent }
        return chain.reversed()
    }

    func isAttached(to root: FileNode) -> Bool {
        var n: FileNode? = self
        while let a = n { if a === root { return true }; n = a.parent }
        return false
    }
}

enum FileCategory: String, CaseIterable, Identifiable, Sendable {
    case apps = "Apps"
    case video = "Videos"
    case photos = "Photos & Images"
    case audio = "Music & Audio"
    case documents = "Documents"
    case archives = "Archives & Disk Images"
    case developer = "Developer"
    case other = "Other"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .apps: return Color(hue: 0.58, saturation: 0.65, brightness: 0.90)
        case .video: return Color(hue: 0.95, saturation: 0.60, brightness: 0.92)
        case .photos: return Color(hue: 0.08, saturation: 0.70, brightness: 0.95)
        case .audio: return Color(hue: 0.80, saturation: 0.50, brightness: 0.85)
        case .documents: return Color(hue: 0.13, saturation: 0.75, brightness: 0.95)
        case .archives: return Color(hue: 0.47, saturation: 0.60, brightness: 0.75)
        case .developer: return Color(hue: 0.36, saturation: 0.55, brightness: 0.75)
        case .other: return Color(white: 0.6)
        }
    }

    var symbol: String {
        switch self {
        case .apps: return "app.badge"
        case .video: return "film"
        case .photos: return "photo"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .other: return "questionmark.folder"
        }
    }

    private static let extensionMap: [String: FileCategory] = {
        var m: [String: FileCategory] = [:]
        func add(_ c: FileCategory, _ list: String) { for e in list.split(separator: " ") { m[String(e)] = c } }
        add(.video, "mov mp4 m4v mkv avi wmv flv webm mpg mpeg 3gp mts m2ts braw r3d prores")
        add(.photos, "jpg jpeg png gif heic heif tif tiff bmp webp raw cr2 cr3 nef arw dng orf raf psd psb ai svg ico icns xcf sketch fig")
        add(.audio, "mp3 m4a aac wav aif aiff flac alac ogg opus caf mid midi logicx band m4r")
        add(.documents, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf rtfd md csv epub mobi odt ods odp html htm xml eml mbox")
        add(.archives, "zip rar 7z tar gz tgz bz2 xz zst dmg iso img pkg mpkg sparseimage sparsebundle ipa xip vmdk qcow2 vdi utm")
        add(.developer, "swift m mm h hpp c cc cpp js mjs cjs ts tsx jsx py pyc rb go rs java kt class jar o a dylib so json yaml yml lock map wasm sqlite db sql pch pcm swiftmodule swiftdoc")
        return m
    }()

    static func forExtension(_ ext: String) -> FileCategory { extensionMap[ext] ?? .other }

    /// Packages and special folders whose contents should count as one kind of thing.
    static func bundleCategory(forDirectoryNamed name: String) -> FileCategory? {
        if name == "node_modules" || name == ".git" || name == "DerivedData" { return .developer }
        switch (name as NSString).pathExtension.lowercased() {
        case "app", "framework", "appex", "xcarchive", "plugin", "kext": return .apps
        case "photoslibrary", "photolibrary", "aplibrary": return .photos
        case "imovielibrary", "fcpbundle", "tvlibrary", "theater": return .video
        case "musiclibrary", "logicx", "band": return .audio
        case "sparsebundle": return .archives
        default: return nil
        }
    }
}

struct VolumeInfo: Equatable {
    let name: String
    let total: Int64
    let available: Int64
    let freeNow: Int64

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, available - freeNow) }

    static func current() -> VolumeInfo? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]), let total = v.volumeTotalCapacity else { return nil }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            name: v.volumeName ?? "Macintosh HD",
            total: Int64(total),
            available: v.volumeAvailableCapacityForImportantUsage ?? free,
            freeNow: free
        )
    }
}

enum ScanTarget: Hashable, Identifiable {
    case home, applications, disk, folder(URL)

    var id: String { path }

    var path: String {
        switch self {
        case .home: return NSHomeDirectory()
        case .applications: return "/Applications"
        case .disk:
            return FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        case .folder(let url): return url.path
        }
    }

    var title: String {
        switch self {
        case .home: return "Home Folder"
        case .applications: return "Applications"
        case .disk: return "Entire Disk"
        case .folder(let url): return url.lastPathComponent
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .applications: return "square.grid.3x3"
        case .disk: return "internaldrive"
        case .folder: return "folder"
        }
    }
}

struct TrashRecord: Identifiable, Codable {
    var id = UUID()
    let name: String
    let originalPath: String
    let trashedPath: String?
    let size: Int64
    let date: Date
    var restored = false

    var canPutBack: Bool {
        guard !restored, let trashedPath else { return false }
        return FileManager.default.fileExists(atPath: trashedPath)
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension String {
    var abbreviatingHome: String {
        var p = self
        if p.hasPrefix("/System/Volumes/Data/") { p = String(p.dropFirst("/System/Volumes/Data".count)) }
        let home = NSHomeDirectory()
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}
