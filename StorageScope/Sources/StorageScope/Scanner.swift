import Foundation
import Darwin

/// Thread-safe progress shared between the background scan and the UI.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var path = ""
    private var cancelled = false

    /// Adds to the running totals; called by every scan worker.
    func add(files: Int, bytes: Int64, path: String) {
        lock.lock(); self.files += files; self.bytes += bytes; self.path = path; lock.unlock()
    }

    func snapshot() -> (files: Int, bytes: Int64, path: String) {
        lock.lock(); defer { lock.unlock() }
        return (files, bytes, path)
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct ScanResult: @unchecked Sendable {
    let root: FileNode
    let categoryTotals: [FileCategory: Int64]
    let largeFiles: [FileNode]
    let nodeModules: [FileNode]
    let unreadableCount: Int
    let duration: TimeInterval
}

enum Scanner {
    static let largeFileThreshold: Int64 = 50_000_000

    /// Walks `path` measuring allocated (on-disk) size. Never follows symlinks, never crosses
    /// into other volumes, and never downloads iCloud files that aren't local.
    ///
    /// Each folder is read with getattrlistbulk(2), which returns the attributes of many entries
    /// per system call. Folders are spread across several worker threads, and each worker opens
    /// subfolders relative to their parent instead of by full path. Sizes are summed up the tree
    /// once the walk finishes.
    static func scan(path: String, progress: ScanProgress? = nil) -> ScanResult? {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let started = Date()
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }

        let root = FileNode(
            name: (path as NSString).lastPathComponent, isDirectory: (st.st_mode & S_IFMT) == S_IFDIR,
            size: Int64(st.st_blocks) * 512, modified: Double(st.st_mtimespec.tv_sec), rootPath: path
        )
        guard root.isDirectory else {
            root.fileCount = 1
            let category = category(ofFileNamed: root.name)
            return ScanResult(
                root: root, categoryTotals: [category: root.size],
                largeFiles: root.size >= largeFileThreshold ? [root] : [], nodeModules: [],
                unreadableCount: 0, duration: Date().timeIntervalSince(started)
            )
        }

        let rootCategory = FileCategory.bundleCategory(forDirectoryNamed: root.name)
        let rootJob = DirJob(node: root, path: path, category: rootCategory, depth: 0, inNodeModules: root.name == "node_modules")
        // Directory reads stop scaling past about six threads; more only adds kernel contention.
        let workerCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6))
        let queue = WorkQueue(rootJob)
        let walkers = (0..<workerCount).map { _ in Walker(rootDevice: st.st_dev, progress: progress) }
        progress?.add(files: 0, bytes: root.size, path: path)

        DispatchQueue.concurrentPerform(iterations: workerCount) { i in
            walkers[i].run(queue)
        }
        if queue.wasStopped { return nil }

        var totals: [FileCategory: Int64] = [:]
        var large: [FileNode] = []
        var nodeModules: [FileNode] = root.name == "node_modules" ? [root] : []
        var hardLinks: [UInt64: [FileNode]] = [:]
        var directories: [[FileNode]] = []
        var unreadable = 0
        for w in walkers {
            totals.merge(w.totals, uniquingKeysWith: +)
            large += w.large
            nodeModules += w.nodeModules
            unreadable += w.unreadable
            for (inode, node) in w.hardLinks { hardLinks[inode, default: []].append(node) }
            for (depth, nodes) in w.directories.enumerated() {
                if directories.count <= depth { directories.append([]) }
                directories[depth] += nodes
            }
        }

        // Count hard-linked data once, keeping the copy a depth-first walk would reach first.
        for group in hardLinks.values where group.count > 1 {
            let keep = group.min { walkOrder($0).lexicographicallyPrecedes(walkOrder($1)) }
            for node in group where node !== keep {
                totals[node.category, default: 0] -= node.size
                node.parent?.size -= node.size
                node.size = 0
            }
        }

        // Roll sizes up from the deepest folders; folders on the same level are independent.
        for level in directories.reversed() {
            let chunk = 256
            DispatchQueue.concurrentPerform(iterations: (level.count + chunk - 1) / chunk) { c in
                for node in level[(c * chunk)..<min(level.count, (c + 1) * chunk)] {
                    for child in node.children where child.isDirectory {
                        node.size += child.size
                        node.fileCount += child.fileCount
                    }
                    node.children.sort { $0.size > $1.size }
                }
            }
        }

        large.removeAll { $0.size < largeFileThreshold }
        large.sort { $0.size > $1.size }
        if large.count > 2000 { large.removeSubrange(2000...) }
        nodeModules.sort { $0.size > $1.size }
        return ScanResult(
            root: root, categoryTotals: totals, largeFiles: large, nodeModules: nodeModules,
            unreadableCount: unreadable, duration: Date().timeIntervalSince(started)
        )
    }

    /// Category for a file from its extension, matching
    /// `FileCategory.forExtension((name as NSString).pathExtension.lowercased())`.
    static func category(ofFileNamed name: String) -> FileCategory {
        var name = name
        return name.withUTF8 { category(ofFileNamed: UnsafeRawBufferPointer($0)) }
    }

    /// Same as above, working on the raw name bytes so no strings are built for most files.
    static func category(ofFileNamed name: UnsafeRawBufferPointer) -> FileCategory {
        // A leading dot marks a hidden file, not an extension (".lock" has none).
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return .other }
        let length = name.count - dot - 1
        guard length > 0, length <= 15 else { return .other }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: length) { ext in
            for i in 0..<length {
                let b = name[dot + 1 + i]
                switch b {
                case UInt8(ascii: "A")...UInt8(ascii: "Z"): ext[i] = b | 0x20
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): ext[i] = b
                default: return .other // every known extension is plain ASCII letters and digits
                }
            }
            return FileCategory.forExtension(String(decoding: ext, as: UTF8.self))
        }
    }

    /// Position of `node` in a depth-first walk of the unsorted tree, as child indexes from the root.
    private static func walkOrder(_ node: FileNode) -> [Int] {
        var order: [Int] = []
        var n = node
        while let parent = n.parent {
            order.append(parent.children.firstIndex { $0 === n } ?? 0)
            n = parent
        }
        return order.reversed()
    }
}

private struct DirJob {
    let node: FileNode
    let path: String
    let category: FileCategory?
    let depth: Int
    let inNodeModules: Bool
}

/// Folders handed between workers. A worker walks its folder's subtree itself and only
/// shares subfolders here while another worker is idle.
private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [DirJob]
    private var active = 0
    private var waiting = 0
    private var stopped = false

    init(_ first: DirJob) {
        jobs = [first]
    }

    var wasStopped: Bool { condition.lock(); defer { condition.unlock() }; return stopped }

    func next() -> DirJob? {
        condition.lock(); defer { condition.unlock() }
        waiting += 1
        while jobs.isEmpty && active > 0 && !stopped { condition.wait() }
        waiting -= 1
        guard !stopped, let job = jobs.popLast() else { return nil }
        active += 1
        return job
    }

    func finish() {
        condition.lock(); defer { condition.unlock() }
        active -= 1
        if active == 0 { condition.broadcast() }
    }

    /// How many folders idle workers could take right now.
    func wanted() -> Int {
        condition.lock(); defer { condition.unlock() }
        return waiting - jobs.count
    }

    func share(_ new: ArraySlice<DirJob>) {
        condition.lock(); defer { condition.unlock() }
        jobs += new
        for _ in new { condition.signal() }
    }

    func stop() {
        condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
    }
}

/// One scan thread. Each folder is read by exactly one walker, which is the only writer of its `children`.
private final class Walker: @unchecked Sendable {
    let rootDevice: dev_t
    let progress: ScanProgress?

    var totals: [FileCategory: Int64] = [:]
    var large: [FileNode] = []
    var nodeModules: [FileNode] = []
    var hardLinks: [(UInt64, FileNode)] = []
    var directories: [[FileNode]] = []
    var unreadable = 0

    private var pendingFiles = 0
    private var pendingBytes: Int64 = 0
    private var foldersSinceCheck = 0
    private var stopping = false

    private static let bufferSize = 256 * 1024
    private static let maxLocalDepth = 128
    private static let mountFlags = UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    private var attributes: attrlist = {
        var a = attrlist()
        a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        a.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID | ATTR_CMN_ERROR)
        a.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS | ATTR_DIR_ALLOCSIZE)
        a.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
        return a
    }()

    init(rootDevice: dev_t, progress: ScanProgress?) {
        self.rootDevice = rootDevice
        self.progress = progress
    }

    deinit { buffer.deallocate() }

    func run(_ queue: WorkQueue) {
        while let job = queue.next() {
            // Shared folders are opened by path; everything below is opened relative to its parent.
            let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            walk(fd, job, startDepth: job.depth, queue: queue)
            queue.finish()
        }
    }

    /// Reads `dir` (already opened as `fd`, which this closes), then its subfolders.
    private func walk(_ fd: Int32, _ dir: DirJob, startDepth: Int, queue: WorkQueue) {
        while directories.count <= dir.depth { directories.append([]) }
        directories[dir.depth].append(dir.node)
        guard fd >= 0 else { unreadable += 1; return }
        defer { close(fd) }

        var subfolders = read(fd, dir)
        reportProgress(dir.path, queue: queue)

        // Shared folders are reopened by path, so only share while their paths fit in PATH_MAX.
        let canShare = dir.path.utf8.count + 1 + Int(NAME_MAX) < Int(PATH_MAX)
        let tooDeep = dir.depth - startDepth >= Self.maxLocalDepth
        var i = 0
        while i < subfolders.count && !stopping {
            let remaining = subfolders.count - i - 1
            if canShare && (remaining > 0 || tooDeep) {
                let give = tooDeep ? remaining + 1 : min(queue.wanted(), remaining)
                if give > 0 {
                    queue.share(subfolders[(subfolders.count - give)...])
                    subfolders.removeLast(give)
                    if i >= subfolders.count { break }
                }
            }
            let sub = subfolders[i]
            i += 1
            let child = openat(fd, sub.node.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            walk(child, sub, startDepth: startDepth, queue: queue)
        }
    }

    private func reportProgress(_ path: String, queue: WorkQueue) {
        foldersSinceCheck += 1
        guard pendingFiles >= 512 || foldersSinceCheck >= 64 else { return }
        foldersSinceCheck = 0
        progress?.add(files: pendingFiles, bytes: pendingBytes, path: path)
        pendingFiles = 0
        pendingBytes = 0
        if progress?.isCancelled == true { stopping = true; queue.stop() }
    }

    /// Reads one folder's entries, attaching a node for each and returning the subfolders to walk.
    private func read(_ fd: Int32, _ dir: DirJob) -> [DirJob] {
        let parent = dir.node
        let prefix = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        var subfolders: [DirJob] = []

        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, 0)
            if count == 0 { break }
            if count < 0 { unreadable += 1; break }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // Fields are packed in attribute-bit order, except the error, which comes first.
                let common = returned.commonattr
                if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if error != 0 { unreadable += 1; continue }
                }
                guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { unreadable += 1; continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let nameBytes = UnsafeRawBufferPointer(start: field + Int(nameRef.attr_dataoffset), count: max(0, Int(nameRef.attr_length) - 1))
                field += MemoryLayout<attrreference_t>.size
                var device = rootDevice
                if common & attrgroup_t(ATTR_CMN_DEVID) != 0 { device = field.loadUnaligned(as: dev_t.self); field += 4 }
                var type: fsobj_type_t = 0
                if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { type = field.loadUnaligned(as: fsobj_type_t.self); field += 4 }
                var modified: Double = 0
                if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    modified = Double(field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var fileID: UInt64 = 0
                if common & attrgroup_t(ATTR_CMN_FILEID) != 0 { fileID = field.loadUnaligned(as: UInt64.self); field += 8 }

                let name = String(decoding: nameBytes, as: UTF8.self)

                if type == VDIR.rawValue {
                    var mountStatus: UInt32 = 0
                    if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 { mountStatus = field.loadUnaligned(as: UInt32.self); field += 4 }
                    var size: Int64 = 0
                    if returned.dirattr & attrgroup_t(ATTR_DIR_ALLOCSIZE) != 0 { size = field.loadUnaligned(as: Int64.self); field += 8 }
                    let crossesVolume = device != rootDevice || mountStatus & Self.mountFlags != 0
                    if crossesVolume {
                        // Don't descend; report the folder the way lstat sees it, as fts did.
                        var st = stat()
                        if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { size = Int64(st.st_blocks) * 512; modified = Double(st.st_mtimespec.tv_sec) }
                    }
                    let node = FileNode(name: name, isDirectory: true, size: size, modified: modified)
                    node.parent = parent
                    parent.children.append(node)
                    pendingBytes += size
                    let isNodeModules = name == "node_modules"
                    if isNodeModules && !dir.inNodeModules { nodeModules.append(node) }
                    if !crossesVolume {
                        subfolders.append(DirJob(
                            node: node, path: prefix + name,
                            category: FileCategory.bundleCategory(forDirectoryNamed: name) ?? dir.category,
                            depth: dir.depth + 1, inNodeModules: dir.inNodeModules || isNodeModules
                        ))
                    }
                } else {
                    var links: UInt32 = 1
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { links = field.loadUnaligned(as: UInt32.self); field += 4 }
                    var size: Int64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { size = field.loadUnaligned(as: Int64.self); field += 8 }
                    let node = FileNode(name: name, isDirectory: false, size: size, modified: modified)
                    node.fileCount = 1
                    node.parent = parent
                    parent.children.append(node)
                    parent.size += size
                    parent.fileCount += 1
                    let category = dir.category ?? Scanner.category(ofFileNamed: nameBytes)
                    totals[category, default: 0] += size
                    pendingFiles += 1
                    pendingBytes += size
                    if type == VREG.rawValue && links > 1 { hardLinks.append((fileID, node)) }
                    if size >= Scanner.largeFileThreshold { large.append(node) }
                }
            }
        }
        return subfolders
    }
}
