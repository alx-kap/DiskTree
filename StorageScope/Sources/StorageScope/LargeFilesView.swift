import SwiftUI

struct LargeFilesView: View {
    @EnvironmentObject var store: AppStore
    @State private var minSize: Int64 = 100_000_000
    @State private var kind: FileCategory?
    @State private var search = ""
    @State private var selection = Set<FileNode.ID>()
    @State private var sortOrder = [KeyPathComparator(\FileNode.size, order: .reverse)]

    var body: some View {
        let rows = store.largeFiles
            .filter { $0.size >= minSize }
            .filter { kind == nil || $0.category == kind }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
        let selected = rows.filter { selection.contains($0.id) }

        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("Larger than", selection: $minSize) {
                    Text("50 MB").tag(Int64(50_000_000))
                    Text("100 MB").tag(Int64(100_000_000))
                    Text("500 MB").tag(Int64(500_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000))
                    Text("5 GB").tag(Int64(5_000_000_000))
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
                Picker("Kind", selection: $kind) {
                    Text("All kinds").tag(FileCategory?.none)
                    Divider()
                    ForEach(FileCategory.allCases) { c in
                        Label(c.rawValue, systemImage: c.symbol).tag(FileCategory?.some(c))
                    }
                }
                .frame(width: 210)
                Spacer()
                Text("\(rows.count) files · \(rows.reduce(Int64(0)) { $0 + $1.size }.bytes)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(12)
            Divider()

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { n in
                    HStack(spacing: 6) {
                        FileIcon(node: n)
                        Text(n.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 180, ideal: 300)
                TableColumn("Size", value: \.size) { n in
                    Text(n.size.bytes).monospacedDigit().fontWeight(.medium)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Kind") { n in
                    Text(n.category.rawValue).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 120)
                TableColumn("Location") { n in
                    Text(n.parent?.path.abbreviatingHome ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                .width(min: 120, ideal: 300)
                TableColumn("Modified", value: \.modifiedDate) { n in
                    Text(n.modifiedDate, format: .dateTime.year().month(.abbreviated).day()).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110)
            }
            .contextMenu(forSelectionType: FileNode.ID.self) { ids in
                FileActionsMenu(nodes: rows.filter { ids.contains($0.id) }, onTrash: { store.requestTrash(nodes: $0) })
            } primaryAction: { ids in
                Finder.reveal(rows.filter { ids.contains($0.id) }.map(\.url))
            }
            .onDeleteCommand { store.requestTrash(nodes: selected) }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Matching Files", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Try a smaller size or a different kind."))
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter by name")
        .toolbar {
            ToolbarItemGroup {
                Button { Finder.reveal(selected.map(\.url)) } label: { Label("Show in Finder", systemImage: "folder") }
                    .disabled(selected.isEmpty)
                Button { store.requestTrash(nodes: selected) } label: { Label("Move to Trash", systemImage: "trash") }
                    .disabled(selected.isEmpty)
            }
        }
    }
}
