import SwiftUI

struct ExploreView: View {
    @EnvironmentObject var store: AppStore
    @State private var hover = HoverModel()
    @State private var selection = Set<FileNode.ID>()
    @State private var sortOrder = [KeyPathComparator(\FileNode.size, order: .reverse)]

    var body: some View {
        if let current = store.current {
            VStack(spacing: 0) {
                BreadcrumbBar(node: current)
                Divider()
                VSplitView {
                    TreemapView(node: current, revision: store.revision, hover: hover, onClick: handleMapClick, onTrash: trash)
                        .frame(minHeight: 240, idealHeight: 430)
                    FileTable(node: current, revision: store.revision, selection: $selection, sortOrder: $sortOrder,
                              onOpen: open, onTrash: trash)
                        .frame(minHeight: 150)
                }
                Divider()
                StatusBar(hover: hover, current: current, selected: selectedNodes(in: current))
            }
            .onChange(of: store.current) { selection = [] }
            .toolbar {
                ToolbarItemGroup {
                    Button { Finder.reveal(selectedNodes(in: current).map(\.url)) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .disabled(selection.isEmpty)
                    .help("Show selected items in Finder")
                    Button { trash(selectedNodes(in: current)) } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)
                    .help("Move selected items to the Trash")
                }
            }
        }
    }

    private func selectedNodes(in current: FileNode) -> [FileNode] {
        current.children.filter { selection.contains($0.id) }
    }

    private func handleMapClick(_ node: FileNode) {
        if node.isDirectory {
            store.navigate(to: node)
        } else if let parent = node.parent, parent !== store.current {
            store.navigate(to: parent)
            DispatchQueue.main.async { selection = [node.id] }
        } else {
            selection = [node.id]
        }
    }

    private func open(_ node: FileNode) {
        if node.isDirectory { store.navigate(to: node) } else { Finder.open(node.url) }
    }

    private func trash(_ nodes: [FileNode]) {
        store.requestTrash(nodes: nodes)
    }
}

struct BreadcrumbBar: View {
    @EnvironmentObject var store: AppStore
    let node: FileNode

    var body: some View {
        HStack(spacing: 10) {
            Button { store.goUp() } label: { Image(systemName: "chevron.left") }
                .disabled(node.parent == nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Up one level (⌘↑)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    let chain = node.lineage
                    ForEach(Array(chain.enumerated()), id: \.offset) { i, n in
                        if i > 0 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button(i == 0 ? (store.target?.title ?? n.name) : n.name) { store.navigate(to: n) }
                            .buttonStyle(.plain)
                            .font(n === node ? .body.weight(.semibold) : .body)
                            .foregroundStyle(n === node ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            Text(node.size.bytes).font(.headline).monospacedDigit()
            Text("· \(node.fileCount.formatted()) files").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct FileTable: View {
    let node: FileNode
    let revision: Int
    @Binding var selection: Set<FileNode.ID>
    @Binding var sortOrder: [KeyPathComparator<FileNode>]
    var onOpen: (FileNode) -> Void
    var onTrash: ([FileNode]) -> Void

    var body: some View {
        let rows = node.children.sorted(using: sortOrder)
        let parentSize = max(1, node.size)
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { n in
                HStack(spacing: 6) {
                    FileIcon(node: n)
                    Text(n.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Size", value: \.size) { n in
                Text(n.size.bytes).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Share of Folder") { n in
                ShareBar(fraction: Double(n.size) / Double(parentSize))
            }
            .width(min: 100, ideal: 160)
            TableColumn("Files", value: \.fileCount) { n in
                Text(n.isDirectory ? n.fileCount.formatted() : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Modified", value: \.modifiedDate) { n in
                Text(n.modifiedDate, format: .dateTime.year().month(.abbreviated).day()).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: FileNode.ID.self) { ids in
            FileActionsMenu(nodes: rows.filter { ids.contains($0.id) }, onOpen: onOpen, onTrash: onTrash)
        } primaryAction: { ids in
            if let n = rows.first(where: { ids.contains($0.id) }) { onOpen(n) }
        }
        .onDeleteCommand {
            onTrash(rows.filter { selection.contains($0.id) })
        }
    }
}

struct StatusBar: View {
    @ObservedObject var hover: HoverModel
    let current: FileNode
    let selected: [FileNode]

    var body: some View {
        HStack(spacing: 8) {
            if let t = hover.tile {
                if let n = t.node {
                    FileIcon(node: n)
                    Text(n.name).fontWeight(.medium).lineLimit(1)
                    Text(n.size.bytes).monospacedDigit()
                    Text("· \(percent(n.size)) of this folder").foregroundStyle(.secondary)
                    if n.isDirectory { Text("· \(n.fileCount.formatted()) files").foregroundStyle(.secondary) }
                    Spacer()
                    Text(n.isDirectory ? "Click to zoom in · right-click for actions" : "Right-click for actions")
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "square.grid.3x3.fill").foregroundStyle(.secondary)
                    Text(t.label).fontWeight(.medium)
                    Text(t.size.bytes).monospacedDigit()
                    Text("· too small to draw — see the list below").foregroundStyle(.secondary)
                    Spacer()
                }
            } else if !selected.isEmpty {
                let total = selected.reduce(Int64(0)) { $0 + $1.size }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                Text("\(selected.count) selected").fontWeight(.medium)
                Text(total.bytes).monospacedDigit()
                Spacer()
                Text("Press Delete to move to the Trash").foregroundStyle(.tertiary)
            } else {
                Text(current.path.abbreviatingHome).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Hover the map to inspect · click folders to zoom in").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func percent(_ size: Int64) -> String {
        guard current.size > 0 else { return "0%" }
        let f = Double(size) / Double(current.size)
        return f.formatted(.percent.precision(.fractionLength(f < 0.1 ? 1 : 0)))
    }
}
