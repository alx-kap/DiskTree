import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct StorageScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    @StateObject private var cleanup = CleanupStore()
    @AppStorage("setupDone") private var setupDone = false

    var body: some Scene {
        Window("StorageScope", id: "main") {
            Group {
                if setupDone {
                    ContentView()
                } else {
                    OnboardingView {
                        setupDone = true
                        store.checkTrashAccess()
                    }
                }
            }
            .environmentObject(store)
            .environmentObject(cleanup)
            .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Permissions…") { setupDone = false }
            }
            CommandGroup(replacing: .newItem) {
                Button("Scan Home Folder") { store.startScan(.home) }.keyboardShortcut("1")
                Button("Scan Entire Disk") { store.startScan(.disk) }.keyboardShortcut("2")
                Button("Scan Applications") { store.startScan(.applications) }.keyboardShortcut("3")
                Button("Scan Folder…") { store.chooseFolderAndScan() }.keyboardShortcut("o")
                Divider()
                Button("Rescan") { store.rescan() }.keyboardShortcut("r").disabled(store.target == nil)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    Button { store.startScan(.home) } label: { Label("Home Folder", systemImage: "house") }
                    Button { store.startScan(.disk) } label: { Label("Entire Disk", systemImage: "internaldrive") }
                    Button { store.startScan(.applications) } label: { Label("Applications", systemImage: "square.grid.3x3") }
                    Divider()
                    Button { store.chooseFolderAndScan() } label: { Label("Choose Folder…", systemImage: "folder") }
                } label: {
                    Label("Scan", systemImage: "scope")
                }
                .help("Choose what to scan")
                if store.isScanning {
                    Button { store.cancelScan() } label: { Label("Stop", systemImage: "stop.circle") }
                        .help("Stop scanning")
                } else {
                    Button { store.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .disabled(store.target == nil)
                        .help("Scan again")
                }
            }
        }
        .sheet(item: $store.pendingTrash) { request in
            TrashConfirmSheet(request: request)
        }
        .alert(item: $store.alert) { info in
            if let action = info.action {
                Alert(title: Text(info.title), message: Text(info.message),
                      primaryButton: .default(Text(action.label), action: action.perform),
                      secondaryButton: .cancel(Text("Close")))
            } else {
                Alert(title: Text(info.title), message: Text(info.message))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private var detail: some View {
        let section = store.section ?? .overview
        switch section {
        case .cleanup:
            CleanupView()
        case .history:
            HistoryView()
        default:
            if store.isScanning {
                ScanningView()
            } else if store.root == nil {
                WelcomeView()
            } else {
                switch section {
                case .explore: ExploreView()
                case .largeFiles: LargeFilesView()
                default: OverviewView()
                }
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cleanup: CleanupStore

    private var hasScan: Bool { store.root != nil && !store.isScanning }

    var body: some View {
        List(selection: $store.section) {
            Section("Storage") {
                Label("Overview", systemImage: "chart.pie.fill").tag(AppStore.Section.overview)
                // Sidebar rows ignore .disabled; leaving them untagged is what makes them unselectable.
                Label("Explore", systemImage: "square.grid.2x2.fill")
                    .tag(AppStore.Section.explore, if: hasScan)
                    .foregroundStyle(hasScan ? .primary : .tertiary)
                    .help(hasScan ? "" : "Available after a scan")
                Label("Largest Files", systemImage: "doc.text.magnifyingglass")
                    .tag(AppStore.Section.largeFiles, if: hasScan)
                    .foregroundStyle(hasScan ? .primary : .tertiary)
                    .help(hasScan ? "" : "Available after a scan")
            }
            Section("Clean Up") {
                Label("Suggestions", systemImage: "sparkles")
                    .badge(cleanup.hasLoaded && cleanup.safeTotal > 0 ? Text(cleanup.safeTotal.bytes) : nil)
                    .tag(AppStore.Section.cleanup)
                Label("Trash & History", systemImage: "trash.fill").tag(AppStore.Section.history)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let v = store.volume {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                        Text(v.name).font(.callout.weight(.semibold))
                    }
                    DiskUsageBar(volume: v, height: 7)
                    Text("\(v.available.bytes) available of \(v.total.bytes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("See what's filling up your Mac")
                        .font(.largeTitle.bold())
                    Text("Scan a location to get a map of everything in it, find the biggest space hogs, and clean up safely. Nothing is ever deleted without your OK — items go to the Trash so you can put them back.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560)
                }

                if let v = store.volume {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(v.name).font(.headline)
                            Spacer()
                            Text("\(v.used.bytes) used of \(v.total.bytes)").foregroundStyle(.secondary)
                        }
                        DiskUsageBar(volume: v, height: 16)
                        HStack(spacing: 16) {
                            LegendDot(color: .secondary.opacity(0.55), label: "Used", value: v.used.bytes)
                            LegendDot(color: .secondary.opacity(0.2), label: "Available", value: v.available.bytes)
                            if v.purgeable > 100_000_000 {
                                Text("includes \(v.purgeable.bytes) macOS can free automatically")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: 620)
                }

                HStack(spacing: 14) {
                    ScanChoice(target: .home, detail: "Your files, apps' data and caches. Best place to start.") { store.startScan(.home) }
                    ScanChoice(target: .disk, detail: "Everything on the disk you have access to.") { store.startScan(.disk) }
                    ScanChoice(title: "Choose Folder…", symbol: "folder.badge.plus", detail: "Any folder or external drive.") { store.chooseFolderAndScan() }
                }
                .frame(maxWidth: 760)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ScanChoice: View {
    var title: String
    var symbol: String
    var detail: String
    var action: () -> Void

    init(target: ScanTarget, detail: String, action: @escaping () -> Void) {
        self.title = target.title
        self.symbol = target.symbol
        self.detail = detail
        self.action = action
    }

    init(title: String, symbol: String, detail: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: hovering ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ScanningView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Scanning \(store.target?.title ?? "")…").font(.title2.bold())
            Text("\(store.progressFiles.formatted()) files · \(store.progressBytes.bytes)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(store.progressPath.abbreviatingHome)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
            Button("Stop Scanning") { store.cancelScan() }
                .padding(.top, 6)
            Text("macOS may ask for permission to read folders like Documents or Downloads — allow it so they can be measured.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    @ViewBuilder func tag<V: Hashable>(_ value: V, if condition: Bool) -> some View {
        if condition { tag(value) } else { self }
    }
}
