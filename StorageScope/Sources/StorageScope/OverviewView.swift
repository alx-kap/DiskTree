import SwiftUI
import Charts

private struct CategorySlice: Identifiable {
    let category: FileCategory
    let size: Int64
    var id: String { category.id }
}

struct OverviewView: View {
    @EnvironmentObject var store: AppStore

    private var slices: [CategorySlice] {
        store.categoryTotals
            .filter { $0.value > 0 }
            .map { CategorySlice(category: $0.key, size: $0.value) }
            .sorted { $0.size > $1.size }
    }

    var body: some View {
        if let root = store.root {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(root)

                    if store.unreadableCount > 0 {
                        PrivateFoldersNote(message: "\(store.unreadableCount.formatted()) folders are kept private by macOS (things like Mail and Messages data), so they aren't counted here.")
                    }

                    // Side by side when there's room, stacked when the window is narrow.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            diskCard(root).frame(idealWidth: 340, maxWidth: 380)
                            typesCard
                        }
                        VStack(spacing: 18) {
                            diskCard(root)
                            typesCard
                        }
                    }

                    topFolders(root)
                    largestFiles
                }
                .padding(24)
            }
        }
    }

    private func header(_ root: FileNode) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.target?.title ?? root.name).font(.largeTitle.bold())
                Text("\(root.path.abbreviatingHome) · \(root.fileCount.formatted()) files · scanned in \(store.scanDuration.formatted(.number.precision(.fractionLength(1))))s")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(root.size.bytes).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
        }
    }

    private func diskCard(_ root: FileNode) -> some View {
        Card(title: "Disk") {
            if let v = store.volume {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(v.available.bytes).font(.title.bold()).monospacedDigit()
                        Text("available of \(v.total.bytes)").foregroundStyle(.secondary)
                    }
                    DiskUsageBar(volume: v, highlight: root.size, height: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        LegendDot(color: .accentColor, label: store.target?.title ?? "Scanned", value: root.size.bytes)
                        LegendDot(color: .secondary.opacity(0.55), label: "Everything else", value: max(0, v.used - root.size).bytes)
                        LegendDot(color: .secondary.opacity(0.2), label: "Available", value: v.available.bytes)
                    }
                    if v.purgeable > 100_000_000 {
                        Text("Available space includes \(v.purgeable.bytes) that macOS can free on its own (like local snapshots and iCloud copies).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var typesCard: some View {
        Card(title: "By Kind") {
            // Legend sits beside the chart, or below it when the card is too narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    kindChart
                    kindLegend
                }
                VStack(spacing: 16) {
                    kindChart
                    kindLegend
                }
            }
        }
    }

    private var kindChart: some View {
        Chart(slices) { s in
            SectorMark(angle: .value("Size", Double(s.size)), innerRadius: .ratio(0.62), angularInset: 1.2)
                .foregroundStyle(s.category.color)
                .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .frame(width: 170, height: 170)
    }

    private var kindLegend: some View {
            VStack(alignment: .leading, spacing: 7) {
                let total = max(1, slices.reduce(Int64(0)) { $0 + $1.size })
                ForEach(slices) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.category.symbol)
                            .foregroundStyle(s.category.color)
                            .frame(width: 18)
                        Text(s.category.rawValue).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(s.size.bytes).monospacedDigit().fontWeight(.medium).fixedSize()
                        Text((Double(s.size) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
            .frame(minWidth: 260, maxWidth: .infinity)
    }

    private func topFolders(_ root: FileNode) -> some View {
        Card(title: "Biggest Folders") {
            VStack(spacing: 2) {
                ForEach(root.children.prefix(10)) { n in
                    Button {
                        if n.isDirectory { store.navigate(to: n) } else { Finder.reveal([n.url]) }
                    } label: {
                        HStack(spacing: 10) {
                            FileIcon(node: n, size: 20)
                            Text(n.name).lineLimit(1).frame(width: 220, alignment: .leading)
                            ShareBar(fraction: root.size > 0 ? Double(n.size) / Double(root.size) : 0)
                            Text(n.size.bytes).monospacedDigit().fontWeight(.medium).frame(width: 80, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Explore everything") { store.section = .explore }
                .buttonStyle(.link)
        }
    }

    private var largestFiles: some View {
        Card(title: "Largest Files") {
            if store.largeFiles.isEmpty {
                Text("No files larger than 50 MB here.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(store.largeFiles.prefix(6)) { n in
                        HStack(spacing: 10) {
                            FileIcon(node: n, size: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.name).lineLimit(1)
                                Text(n.parent?.path.abbreviatingHome ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(n.size.bytes).monospacedDigit().fontWeight(.medium)
                            Button { Finder.reveal([n.url]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                }
                Button("See all large files") { store.section = .largeFiles }
                    .buttonStyle(.link)
            }
        }
    }
}
