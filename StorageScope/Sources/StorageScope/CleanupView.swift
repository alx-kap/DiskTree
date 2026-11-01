import SwiftUI

struct ReviewContext: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let entries: [FileNode]
    let preselected: Set<FileNode.ID>
    var onComplete: (() -> Void)?
}

struct CleanupView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cleanup: CleanupStore
    @State private var reviewing: ReviewContext?
    @State private var confirmEmptyTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                let unreadable = cleanup.items.filter { if case .unreadable = $0.state { return true }; return false }
                if !unreadable.isEmpty {
                    PrivateFoldersNote(message: "macOS keeps these private, so they can't be measured: \(unreadable.map(\.definition.title).joined(separator: ", ")).")
                }

                ForEach(cleanup.visibleItems) { item in
                    CleanupCard(item: item, review: { review(item) }, cleanAll: { cleanAll(item) },
                                emptyTrash: { confirmEmptyTrash = true })
                }

                nodeModulesCard
            }
            .padding(24)
        }
        .onAppear { if !cleanup.hasLoaded { cleanup.refresh() } }
        .onChange(of: store.revision) { cleanup.refresh(only: ["trash"]) }
        .sheet(item: $reviewing) { ctx in ReviewSheet(context: ctx) }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) {
                store.emptyTrash { cleanup.refresh(only: ["trash"]) }
            }
        } message: {
            Text("Everything in the Trash will be permanently erased. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean Up").font(.largeTitle.bold())
                Text("Places that commonly fill up a Mac. Everything you remove goes to the Trash first, so you can change your mind.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(cleanup.safeTotal.bytes).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                Text("safe to clean").foregroundStyle(.secondary)
            }
            Button {
                cleanup.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(cleanup.isRefreshing)
            .padding(.leading, 12)
        }
    }

    @ViewBuilder private var nodeModulesCard: some View {
        if store.root == nil {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass.circle.fill").font(.title).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Find more with a scan").font(.headline)
                        Text("Scan your home folder to also find node_modules folders and your largest files.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Scan Home Folder") { store.startScan(.home); store.section = .overview }
                }
            }
        } else if !store.nodeModules.isEmpty {
            let total = store.nodeModules.reduce(Int64(0)) { $0 + $1.size }
            let def = CleanupDefinition(
                id: "node_modules", title: "node_modules Folders",
                detail: "JavaScript dependencies found in your scan. Reinstall them any time with “npm install”.",
                symbol: "shippingbox.circle.fill", tint: .green, paths: [], safety: .review)
            CleanupCard(item: CleanupItem(definition: def, state: .loaded(entries: store.nodeModules, total: total)),
                        review: {
                            reviewing = ReviewContext(title: def.title, detail: def.detail, entries: store.nodeModules, preselected: [])
                        }, cleanAll: {}, emptyTrash: {})
        }
    }

    private func review(_ item: CleanupItem) {
        let pre = Set(item.entries.filter(item.isPreselected).map(\.id))
        reviewing = ReviewContext(title: item.definition.title, detail: item.definition.detail,
                                  entries: item.entries, preselected: pre,
                                  onComplete: { cleanup.refresh(only: [item.id]) })
    }

    private func cleanAll(_ item: CleanupItem) {
        store.requestTrash(nodes: item.entries, onComplete: { cleanup.refresh(only: [item.id]) })
    }
}

private struct CleanupCard: View {
    @EnvironmentObject var store: AppStore
    let item: CleanupItem
    var review: () -> Void
    var cleanAll: () -> Void
    var emptyTrash: () -> Void

    private var def: CleanupDefinition { item.definition }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: def.symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(def.tint.gradient, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(def.title).font(.headline)
                        SafetyBadge(safety: def.safety)
                    }
                    Text(def.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let cmd = def.command {
                        HStack(spacing: 6) {
                            Text(cmd).font(.callout.monospaced()).textSelection(.enabled)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy command")
                        }
                    }
                    if let p = def.paths.first, def.paths.count == 1 {
                        Text(p.abbreviatingHome).font(.caption).foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 8) {
                    sizeView
                    actions
                }
            }
        }
    }

    @ViewBuilder private var sizeView: some View {
        if def.id == "trash", store.trashIsHidden {
            // macOS hides the Trash's contents; show what we know we put there.
            let own = store.ownItemsInTrash
            VStack(alignment: .trailing, spacing: 0) {
                Text(own.reduce(Int64(0)) { $0 + $1.size }.bytes).font(.title2.bold()).monospacedDigit()
                Text("from StorageScope, at least").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            measuredSize
        }
    }

    @ViewBuilder private var measuredSize: some View {
        switch item.state {
        case .loading:
            ProgressView().controlSize(.small)
        case .unreadable:
            Label("No access", systemImage: "lock.fill").foregroundStyle(.secondary)
        case .missing:
            Text("—").foregroundStyle(.secondary)
        case .loaded:
            VStack(alignment: .trailing, spacing: 0) {
                Text(item.headline.bytes).font(.title2.bold()).monospacedDigit()
                if def.olderThanDays != nil {
                    Text("of \(item.total.bytes) total").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(item.entries.count) item\(item.entries.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        let loaded: Bool = { if case .loaded = item.state { return true }; return false }()
        HStack(spacing: 8) {
            if def.id == "trash" {
                Button("Open Trash") { Finder.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
                Button("Empty Trash…", role: .destructive, action: emptyTrash)
                    .disabled(loaded && item.entries.isEmpty && !store.trashIsHidden)
            } else if def.safety == .info {
                if let p = def.paths.first {
                    Button("Show in Finder") { Finder.reveal([URL(fileURLWithPath: p)]) }
                }
            } else {
                Button("Review…", action: review).disabled(!loaded || item.entries.isEmpty)
                if def.safety == .safe {
                    Button("Clean Up", action: cleanAll)
                        .buttonStyle(.borderedProminent)
                        .disabled(!loaded || item.entries.isEmpty)
                }
            }
        }
    }
}

struct ReviewSheet: View {
    let context: ReviewContext
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<FileNode.ID>
    @State private var sortOrder = [KeyPathComparator(\FileNode.size, order: .reverse)]

    init(context: ReviewContext) {
        self.context = context
        _checked = State(initialValue: context.preselected)
    }

    var body: some View {
        let rows = context.entries.sorted(using: sortOrder)
        let chosen = context.entries.filter { checked.contains($0.id) }
        let chosenSize = chosen.reduce(Int64(0)) { $0 + $1.size }

        VStack(alignment: .leading, spacing: 12) {
            Text(context.title).font(.title2.bold())
            Text(context.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Table(rows, sortOrder: $sortOrder) {
                TableColumn("") { n in
                    Toggle("", isOn: Binding(
                        get: { checked.contains(n.id) },
                        set: { on in if on { checked.insert(n.id) } else { checked.remove(n.id) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
                .width(22)
                TableColumn("Name", value: \.name) { n in
                    HStack(spacing: 6) {
                        FileIcon(node: n)
                        Text(n.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 200, ideal: 320)
                TableColumn("Size", value: \.size) { n in Text(n.size.bytes).monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("Modified", value: \.modifiedDate) { n in
                    Text(n.modifiedDate, format: .dateTime.year().month(.abbreviated).day()).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110)
                TableColumn("") { n in
                    Button { Finder.reveal([n.url]) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                }
                .width(24)
            }

            HStack {
                Button("Select All") { checked = Set(context.entries.map(\.id)) }
                Button("Select None") { checked = [] }
                Spacer()
                Text("\(chosen.count) selected · \(chosenSize.bytes)").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash…") {
                    let nodes = chosen
                    let done = context.onComplete
                    dismiss()
                    // Let this sheet close before the confirmation sheet opens.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        store.requestTrash(nodes: nodes, onComplete: done)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760, height: 540)
    }
}
