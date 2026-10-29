import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Orbit Preview: Space on an archive or a folder shows what's inside, without unpacking anything.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let tree = try await Task.detached(priority: .userInitiated) { try ContentsTree.load(url) }.value
        let host = NSHostingView(rootView: ContentsView(tree: tree))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(host)
        preferredContentSize = NSSize(width: 720, height: 520)
    }
}

final class Node: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    var size: Int64
    var modified: Date?
    var children: [Node]?
    var childIndex: [String: Node] = [:]
    var fileCount = 0

    init(name: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        children = isDirectory ? [] : nil
    }

    func child(_ name: String, directory: Bool) -> Node {
        if let n = childIndex[name] { return n }
        let n = Node(name: name, isDirectory: directory)
        childIndex[name] = n
        children?.append(n)
        return n
    }

    /// Folders first, then by name; sizes rolled up.
    @discardableResult
    func finish() -> (Int64, Int) {
        guard var kids = children else { return (size, 1) }
        var total: Int64 = 0, files = 0
        for k in kids { let (s, f) = k.finish(); total += max(0, s); files += f }
        kids.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        children = kids.isEmpty ? nil : kids
        if size <= 0 { size = total }
        fileCount = files
        childIndex = [:]
        return (size, files)
    }
}

struct ContentsTree: Sendable {
    let title: String
    let kind: String
    let root: Node
    let truncated: Bool
    let onDisk: Int64?
    let encrypted: Bool

    static let limit = 20_000

    static func load(_ url: URL) throws -> ContentsTree {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue ? try folder(url) : try archive(url)
    }

    private static func archive(_ url: URL) throws -> ContentsTree {
        let root = Node(name: url.lastPathComponent, isDirectory: true)
        var entries: [ArchiveEntryInfo] = []
        var encrypted = false
        do { entries = try LibArchive.shared.list(url, limit: limit) } catch ArchiveError.needsPassword { encrypted = true }
        for e in entries {
            let parts = e.path.split(separator: "/").map(String.init).filter { $0 != "." }
            guard !parts.isEmpty, parts.first != "__MACOSX" else { continue }
            var node = root
            for (i, p) in parts.enumerated() {
                let last = i == parts.count - 1
                node = node.child(p, directory: !last || e.isDirectory)
            }
            if !e.isDirectory { node.size = e.size; node.modified = e.modified }
            if e.isEncrypted { encrypted = true }
        }
        root.finish()
        let onDisk = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let type = UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? url.pathExtension.uppercased()
        return ContentsTree(title: url.lastPathComponent, kind: type, root: root, truncated: entries.count >= limit, onDisk: onDisk, encrypted: encrypted)
    }

    private static func folder(_ url: URL) throws -> ContentsTree {
        let root = Node(name: url.lastPathComponent, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        var count = 0
        let deadline = Date().addingTimeInterval(1.5)
        func walk(_ dir: URL, into node: Node, depth: Int) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            for item in items {
                count += 1
                if count > limit || Date() > deadline { return }
                let v = try? item.resourceValues(forKeys: Set(keys))
                let isDir = v?.isDirectory == true && v?.isPackage != true
                let child = node.child(item.lastPathComponent, directory: isDir)
                child.modified = v?.contentModificationDate
                if isDir {
                    walk(item, into: child, depth: depth + 1)
                } else {
                    child.size = Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
                }
            }
        }
        walk(url, into: root, depth: 0)
        root.finish()
        return ContentsTree(title: url.lastPathComponent, kind: "Folder", root: root, truncated: count > limit || Date() > deadline, onDisk: nil, encrypted: false)
    }
}

struct ContentsView: View {
    let tree: ContentsTree

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: tree.kind == "Folder" ? "folder.fill" : "archivebox.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.22))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(tree.title).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if tree.encrypted {
                    Label(t("Password", "암호"), systemImage: "lock.fill").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
            }
            .padding(18)
            Divider()
            if let children = shown, !children.isEmpty {
                List {
                    OutlineGroup(children, children: \.children) { node in
                        Row(node: node)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
                Text(tree.encrypted ? t("The file names are locked with a password.", "파일 이름까지 암호로 잠겨 있어요.") : t("Empty", "비어 있어요"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
            Text("Orbit Preview").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(Color(white: 0.09))
        .environment(\.colorScheme, .dark)
    }

    /// An archive holding one folder opens straight into it.
    private var shown: [Node]? {
        if let kids = tree.root.children, kids.count == 1, kids[0].isDirectory { return kids[0].children }
        return tree.root.children
    }

    private var summary: String {
        let f = ByteCountFormatter()
        var parts = [tree.kind == "Folder" ? t("Folder", "폴더") : tree.kind,
                     t("\(tree.root.fileCount.formatted()) items", "항목 \(tree.root.fileCount.formatted())개"),
                     f.string(fromByteCount: tree.root.size)]
        if let onDisk = tree.onDisk, tree.root.size > 0 {
            parts.append(t("\(f.string(fromByteCount: onDisk)) compressed", "압축 \(f.string(fromByteCount: onDisk))"))
        }
        if tree.truncated { parts.append(t("showing the first part", "앞부분만 보여요")) }
        return parts.joined(separator: " · ")
    }
}

private struct Row: View {
    let node: Node

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if let m = node.modified {
                Text(m, format: .dateTime.year().month(.abbreviated).day()).foregroundStyle(.secondary).font(.system(size: 11))
            }
            Text(ByteCountFormatter.string(fromByteCount: max(0, node.size), countStyle: .file))
                .foregroundStyle(.secondary).font(.system(size: 11).monospacedDigit())
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var icon: NSImage {
        if node.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (node.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

/// The extension has no string catalog of its own; Korean is the only other language Orbit speaks.
private func t(_ en: String, _ ko: String) -> String {
    (Locale.preferredLanguages.first ?? "").hasPrefix("ko") ? ko : en
}
