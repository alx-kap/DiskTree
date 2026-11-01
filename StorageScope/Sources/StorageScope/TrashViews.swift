import SwiftUI

struct TrashConfirmSheet: View {
    let request: TrashRequest
    @EnvironmentObject var store: AppStore
    @State private var acknowledged = false

    var body: some View {
        let allowed = request.allowed
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text(allowed.isEmpty ? "Nothing can be removed" :
                            "Move \(allowed.count) item\(allowed.count == 1 ? "" : "s") to the Trash?")
                        .font(.title3.bold())
                    Text(allowed.isEmpty ? "Everything you picked is protected." :
                            "\(request.allowedSize.bytes) · You can put things back from the Trash until you empty it.")
                        .foregroundStyle(.secondary)
                }
            }

            List(request.candidates.prefix(500)) { c in
                HStack(alignment: .top, spacing: 8) {
                    icon(for: c.verdict)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).lineLimit(1).truncationMode(.middle)
                            .strikethrough(c.verdict.isBlocked)
                        Text(c.url.deletingLastPathComponent().path.abbreviatingHome)
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        if let msg = c.verdict.message {
                            Text(msg).font(.caption)
                                .foregroundStyle(c.verdict.isBlocked ? Color.red : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Text(c.size.bytes).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 160, maxHeight: 320)

            if !request.blocked.isEmpty {
                Label("\(request.blocked.count) protected item\(request.blocked.count == 1 ? "" : "s") will be skipped.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            if request.hasCautions && !allowed.isEmpty {
                Toggle("I've read the warnings above and want to continue", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.pendingTrash = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { store.performTrash(request) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(allowed.isEmpty || (request.hasCautions && !acknowledged))
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    @ViewBuilder private func icon(for v: SafetyVerdict) -> some View {
        switch v {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .caution: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .blocked: Image(systemName: "lock.fill").foregroundStyle(.red)
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cleanup: CleanupStore
    @State private var confirmEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trash & History").font(.largeTitle.bold())
                    Text("Everything StorageScope has moved to the Trash. Put things back as long as the Trash hasn't been emptied.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Card {
                HStack(spacing: 14) {
                    Image(systemName: "trash.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trash").font(.headline)
                        Text(trashSummary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Trash") { Finder.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
                    Button("Empty Trash…", role: .destructive) { confirmEmpty = true }
                }
            }

            if store.history.isEmpty {
                ContentUnavailableView("Nothing Moved Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Items you move to the Trash from StorageScope will show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.history) { r in
                        HStack(spacing: 10) {
                            Image(systemName: r.restored ? "arrow.uturn.backward.circle.fill" : "trash.circle")
                                .foregroundStyle(r.restored ? Color.green : Color.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).lineLimit(1)
                                Text((r.originalPath as NSString).deletingLastPathComponent.abbreviatingHome)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(r.size.bytes).monospacedDigit()
                            Text(r.date, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .trailing)
                            if r.restored {
                                Text("Put back").foregroundStyle(.green).frame(width: 90)
                            } else if r.canPutBack {
                                Button("Put Back") { store.putBack(r) }.frame(width: 90)
                            } else {
                                Text("Erased").foregroundStyle(.tertiary).frame(width: 90)
                                    .help("The Trash was emptied, so this can't be restored.")
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    let total = store.history.filter { !$0.restored }.reduce(Int64(0)) { $0 + $1.size }
                    Text("\(total.bytes) moved to the Trash in total").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History") { store.clearHistory() }
                }
            }
        }
        .padding(24)
        .onAppear { if !cleanup.hasLoaded { cleanup.refresh() } }
        .onChange(of: store.revision) { cleanup.refresh(only: ["trash"]) }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) {
                store.emptyTrash { cleanup.refresh(only: ["trash"]) }
            }
        } message: {
            Text("Everything in the Trash will be permanently erased. This can't be undone.")
        }
    }

    private var trashSummary: String {
        if store.trashIsHidden {
            let own = store.ownItemsInTrash
            if own.isEmpty { return "macOS hides what's inside from StorageScope, but Empty Trash still works." }
            let size = own.reduce(Int64(0)) { $0 + $1.size }
            return "\(own.count) item\(own.count == 1 ? "" : "s") from StorageScope · \(size.bytes), plus anything you trashed yourself"
        }
        guard let item = cleanup.item("trash") else { return "" }
        switch item.state {
        case .loading: return "Measuring…"
        case .unreadable: return "macOS keeps the Trash private, but Empty Trash still works."
        case .missing: return "Empty"
        case .loaded(let entries, let total):
            return entries.isEmpty ? "Empty" : "\(entries.count) item\(entries.count == 1 ? "" : "s") · \(total.bytes) — freed when you empty it"
        }
    }
}
