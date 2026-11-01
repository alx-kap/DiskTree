import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    private static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "bundle", "framework", "xcarchive", "imovielibrary",
        "fcpbundle", "sparsebundle", "pkg", "logicx", "xcodeproj", "xcworkspace", "rtfd",
    ]

    static func icon(for node: FileNode) -> NSImage {
        let ext = node.pathExtension
        let key: String
        if node.isDirectory {
            key = packageExtensions.contains(ext) ? "pkg:" + node.path : "folder"
        } else {
            key = "ext:" + ext
        }
        if let img = cache[key] { return img }
        let img: NSImage
        if node.isDirectory {
            img = packageExtensions.contains(ext) ? NSWorkspace.shared.icon(forFile: node.path) : NSWorkspace.shared.icon(for: .folder)
        } else {
            img = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        cache[key] = img
        return img
    }
}

struct FileIcon: View {
    let node: FileNode
    var size: CGFloat = 16
    var body: some View {
        Image(nsImage: IconCache.icon(for: node))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct ShareBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint.gradient).frame(width: max(2, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 6)
            Text(fraction < 0.001 ? "<0.1%" : fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

struct DiskUsageBar: View {
    let volume: VolumeInfo
    var highlight: Int64? = nil
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(Double(volume.total), 1)
            let usedW = w * Double(volume.used) / total
            let hiW = min(usedW, w * Double(highlight ?? 0) / total)
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor.gradient).frame(width: hiW)
                Rectangle().fill(Color.secondary.opacity(0.55)).frame(width: max(0, usedW - hiW))
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.callout)
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct PrivateFoldersNote: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SafetyBadge: View {
    let safety: CleanupSafety
    var body: some View {
        Text(safety.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(safety.color)
            .background(safety.color.opacity(0.14), in: Capsule())
    }
}

/// Shared right-click menu for files and folders.
struct FileActionsMenu: View {
    let nodes: [FileNode]
    var onOpen: ((FileNode) -> Void)? = nil
    var onTrash: ([FileNode]) -> Void

    var body: some View {
        if nodes.count == 1, let n = nodes.first {
            if n.isDirectory, let onOpen {
                Button("Zoom In") { onOpen(n) }
            }
            Button(n.isDirectory ? "Open in Finder" : "Open") { Finder.open(n.url) }
        }
        if !nodes.isEmpty {
            Button("Show in Finder") { Finder.reveal(nodes.map(\.url)) }
            Button("Copy Path") { Finder.copyPaths(nodes.map(\.url)) }
            Divider()
            Button(role: .destructive) { onTrash(nodes) } label: {
                Text(nodes.count == 1 ? "Move to Trash…" : "Move \(nodes.count) Items to Trash…")
            }
        }
    }
}
